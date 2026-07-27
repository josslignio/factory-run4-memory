"""
Extracteur déterministe de leçons — master order Run 4 §2.

Prend en entrée un RAPPORT DE REVIEW au format finding-block structuré
(voir plus bas), produit une ou plusieurs entrées `lessons.jsonl` normalisées
et validées par `lesson_schema.validate_lesson`.

EXIGENCE MASTER ORDER §2 : « Déterministe, pas de LLM dans le chemin
d'extraction structurelle (parsing de texte structuré uniquement). »

Ce module ne contient DONC AUCUN appel à un LLM. Il parse un format
déterministe inspiré des rapports de review réels de Run #3 (fichier par
fichier, finding par finding). Si le format d'entrée n'est pas reconnu
(bloc absent, clé manquante, prose libre non structurée), l'extracteur
ÉCHOUE À FERMETURE (exit 1, message clair) plutôt que d'inventer une
interprétation sémantique — fail-closed.

Où un LLM pourrait intervenir (documenté pour L-049, transparence) :
un LLM externe peut être utilisé EN AMONT pour CONVERTIR un rapport de
review en prose libre vers le format finding-block ci-dessous. Mais ce
LLM n'appartient PAS à ce module : il produit du texte structuré que
l'humain/le pilote vérifie avant de le passer ici. L'extraction
structurelle elle-même reste 100% déterministe.

FORMAT D'ENTRÉE (finding-block)
================================
Un rapport est une suite de blocs délimités par `[FINDING]` ... `[/FINDING]`.
Chaque bloc contient des lignes `clé: valeur`. Les lignes vides à
l'intérieur d'un bloc sont ignorées. Une ligne commençant par une espace
ou une tabulation est une LIGNE DE SUITE : elle est concaténée à la valeur
précédente (permet les descriptions longues).

Clés (synonymes entre parenthèses) :

    severity            (requis)   : P1 | P2 | P3
    category            (requis)   : une catégorie autorisée par le schéma
    file                (requis)   : chemin du fichier fautif
    line                (requis)   : numéro de ligne (entier > 0)
    description         (requis)   : défaut observé, phrase factuelle
    fix  (fix_pattern)  (requis)   : remède générique réutilisable
    trigger_keywords    (requis)   : mots-clés/signature, séparés par
                                     `;` ou `,` → trigger_pattern
    source              (requis)   : ex: run3-lab, run4-memory, <repo>
    test                (optionnel): nom du test qui prouve défaut ET fix
    date                (optionnel): ISO8601 (défaut: UTC du jour)

Exemple :

    [FINDING]
    severity: P1
    category: concurrency
    file: lock_manager.py
    line: 100
    description: Verrou fichier par PID-file + unlink/O_EXCL : fenêtre TOCTOU
      entre le unlink du verrou périmé et la création exclusive.
    fix: fcntl.flock(fd, LOCK_EX|LOCK_NB) sur un fichier PERSISTANT,
      libéré par l'OS à la mort du process. Jamais unlink.
    trigger_keywords: fcntl.flock; lockfile; PID-file; check-then-set
    source: run3-lab
    test: test_zombie_lock.test_three_processes_race
    [/FINDING]

SORTIE
======
- Par défaut : JSONL sur stdout (une leçon par ligne, ensure_ascii=False).
- `--out PATH`  : écrit un fichier FRAIS (truncate puis écrit ; échec si
                   le fichier existant contient déjà ces ids — sécurité).
- `--append PATH` : ajoute à un fichier existant (lit les ids présents,
                    refuse la collision, n'écrit RIEN si un seul id colle).

IDS
===
`L-<extraction_ts>-<seq>` :
- extraction_ts : `--extraction-ts` (défaut : timestamp UTC courant
  `YYYYMMDDThhmmssZ`). Figeable pour reproductibilité des tests.
- seq : numéro d'ordre du bloc dans le rapport, sur 2 chiffres, à partir
  de 01. Permet de retrouver la leçon depuis le rapport source.

Stdlib uniquement. Aucune dépendance externe (règle 1).
"""
import argparse
import datetime as _dt
import fcntl
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lesson_schema import (  # noqa: E402
    validate_lesson,
    load_jsonl,
    LessonError,
    ALLOWED_CATEGORIES,
    ALLOWED_SEVERITIES,
)

# --- Délimiteurs du format finding-block -------------------------------
BLOCK_OPEN = "[FINDING]"
BLOCK_CLOSE = "[/FINDING]"

# Clés reconnues + mapping vers le champ cible du schéma. Les synonymes
# permettent d'accepter `fix` ou `fix_pattern` indifféremment.
KEY_MAP: Dict[str, str] = {
    "severity": "severity",
    "category": "category",
    "file": "_file",
    "line": "_line",
    "description": "description",
    "fix": "fix_pattern",
    "fix_pattern": "fix_pattern",
    "trigger_keywords": "_triggers",
    "source": "source",
    "test": "_test",
    "date": "date",
}

# Paires (alias_affiché_erreur, clé_canonique_stockée). L'alias est ce que
# l'utilisateur voit dans le message d'erreur ; la clé canonique est le nom
# sous lequel parse_findings range la valeur (via KEY_MAP).
REQUIRED_KEYS: Tuple[Tuple[str, str], ...] = (
    ("severity", "severity"),
    ("category", "category"),
    ("file", "_file"),
    ("line", "_line"),
    ("description", "description"),
    ("fix", "fix_pattern"),
    ("trigger_keywords", "_triggers"),
    ("source", "source"),
)

# Repère fichier:ligne, même tolérance que lesson_schema.
FILE_LINE_RE = re.compile(r"[\w/.@\-+]+:\d+")


class ExtractionError(Exception):
    """Erreur d'extraction (format non reconnu, clé manquante, etc.)."""


# ---------------------------------------------------------------- parse
def parse_findings(text: str) -> List[Dict[str, str]]:
    """Découpe `text` en blocs `[FINDING]...[/FINDING]` et renvoie, pour
    chaque bloc, un dict {clé: valeur} (valeurs déjà multi-lignes jointes).

    Échoue (ExtractionError) si :
      - aucun bloc trouvé (entrée probablement en prose libre) ;
      - un bloc n'est pas refermé ;
      - une clé est inconnue ;
      - une ligne de suite apparaît avant toute clé.
    """
    blocks: List[Dict[str, str]] = []
    current: Dict[str, str] = None  # type: ignore[assignment]
    current_key: str = None  # type: ignore[assignment]
    in_block = False
    saw_block = False

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip()
        stripped = line.strip()

        if stripped == BLOCK_OPEN:
            if in_block:
                raise ExtractionError(
                    f"ligne {lineno}: `[FINDING]` ouvert alors qu'un bloc "
                    f"est déjà en cours (il manque un `[/FINDING]`)"
                )
            in_block = True
            saw_block = True
            current = {}
            current_key = None
            continue

        if stripped == BLOCK_CLOSE:
            if not in_block:
                raise ExtractionError(
                    f"ligne {lineno}: `[/FINDING]` sans `[FINDING]` ouvrant"
                )
            if current:
                blocks.append(current)
            in_block = False
            current = None
            current_key = None
            continue

        if not in_block:
            # Hors bloc : on ignore le commentaire libre (en-tête de rapport,
            # lignes vides) tant qu'on n'a pas rencontré de bloc. Dès qu'on
            # a vu au moins un bloc, toute ligne hors-bloc non vide est
            # suspicieuse : on l'ignore aussi (permet rapports mélangés),
            # mais on ne consomme rien.
            continue

        if stripped == "":
            # Ligne vide dans un bloc : on conserve la continuité de la
            # valeur précédente (un simple séparateur visuel).
            continue

        # Ligne de suite (indentée) : on rattache à la dernière clé.
        if raw[:1] in (" ", "\t") and current_key is not None:
            current[current_key] = (current[current_key] + " " + stripped).strip()
            continue

        # Nouvelle clé `key: value`.
        if ":" not in stripped:
            raise ExtractionError(
                f"ligne {lineno}: ligne non vide dans un bloc mais sans `clé: valeur` "
                f"(et non indentée) : {stripped!r}"
            )
        key, _, value = stripped.partition(":")
        key = key.strip().lower()
        value = value.strip()
        if key not in KEY_MAP:
            raise ExtractionError(
                f"ligne {lineno}: clé inconnue {key!r} "
                f"(clés reconnues : {sorted(KEY_MAP)})"
            )
        canon = KEY_MAP[key]
        if canon in current and current[canon]:
            # Même clé canonique vue deux fois dans un bloc (ex: `fix:` puis
            # `fix_pattern:`) → on concatène (tolérant).
            current[canon] = current[canon] + " " + value
        else:
            current[canon] = value
        current_key = canon

    if in_block:
        raise ExtractionError(
            "fin d'entrée : un bloc `[FINDING]` n'est pas refermé par `[/FINDING]`"
        )
    if not saw_block:
        raise ExtractionError(
            "aucun bloc `[FINDING]...[/FINDING]` trouvé dans l'entrée ; "
            "le format finding-block est requis (pas de prose libre). "
            "Voir docstring de lesson_extractor.py pour le format."
        )
    return blocks


# ------------------------------------------------------- build lessons
def _normalize_triggers(raw: str) -> str:
    """`trigger_keywords` brut → trigger_pattern normalisé.

    Séparateurs acceptés : `;` ou `,`. On normalise vers `; ` (cohérent
    avec le bootstrap §1) en supprimant les vides et les doublons
    en préservant l'ordre.
    """
    parts = [p.strip() for p in re.split(r"[;,]", raw) if p.strip()]
    seen = set()
    out = []
    for p in parts:
        if p.lower() not in seen:
            seen.add(p.lower())
            out.append(p)
    if not out:
        raise ExtractionError(
            f"trigger_keywords vide après normalisation (entrée brute : {raw!r})"
        )
    return "; ".join(out)


def build_lesson(block: Dict[str, str], extraction_ts: str, seq: int) -> dict:
    """Construit et valide une leçon à partir d'un bloc parsé.

    Lève ExtractionError (clé manquante / valeur incohérente) ou
    LessonError (schéma) — l'appelant décide du traitement.
    """
    for alias, canon in REQUIRED_KEYS:
        if canon not in block or not block[canon].strip():
            raise ExtractionError(
                f"bloc #{seq}: clé requise manquante ou vide : {alias!r} "
                f"(clés présentes : {sorted(block)})"
            )

    severity = block["severity"].strip().upper()
    if severity not in ALLOWED_SEVERITIES:
        raise ExtractionError(
            f"bloc #{seq}: severity {severity!r} hors de {ALLOWED_SEVERITIES}"
        )

    category = block["category"].strip().lower()
    if category not in ALLOWED_CATEGORIES:
        raise ExtractionError(
            f"bloc #{seq}: category {category!r} hors de {ALLOWED_CATEGORIES}"
        )

    line_raw = block["_line"].strip()
    if not re.fullmatch(r"\d+", line_raw):
        raise ExtractionError(
            f"bloc #{seq}: line doit être un entier positif, eu {line_raw!r}"
        )
    line_no = int(line_raw)
    if line_no <= 0:
        raise ExtractionError(f"bloc #{seq}: line doit être > 0, eu {line_no}")

    file_path = block["_file"].strip()
    # evidence au même format que le bootstrap : "<source_ref>:<file>:<line> — test: <test>"
    # On utilise ici la source du bloc comme préfixe (ex: run3-lab, my-repo@sha).
    source_ref = block["source"].strip()
    evidence_core = f"{source_ref}:{file_path}:{line_no}"
    test = block.get("_test", "").strip()
    if test:
        evidence = f"{evidence_core} — test: {test}"
    else:
        evidence = evidence_core

    lesson = {
        "id": f"L-{extraction_ts}-{seq:02d}",
        "date": block.get("date", "").strip()
        or _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d"),
        "source": source_ref,
        "category": category,
        "trigger_pattern": _normalize_triggers(block["_triggers"]),
        "description": block["description"].strip(),
        "fix_pattern": block["fix_pattern"].strip(),
        "severity": severity,
        "evidence": evidence,
    }
    # Double-défense : le validateur du schéma doit aussi PASSER (ex: il
    # vérifie qu'il y a bien un repère fichier:ligne dans evidence).
    validate_lesson(lesson)
    return lesson


def extract_lessons(
    text: str, extraction_ts: str = None
) -> List[dict]:
    """Pipeline complet : texte → liste de leçons validées.

    `extraction_ts` : si None, timestamp UTC courant (déterminisme pour
    les tests : passer une valeur fixe).
    """
    if extraction_ts is None:
        extraction_ts = _dt.datetime.now(_dt.timezone.utc).strftime(
            "%Y%m%dT%H%M%SZ"
        )
    elif not re.fullmatch(r"[0-9A-Za-z._:+\-]+", extraction_ts):
        raise ExtractionError(
            f"extraction_ts contient des caractères interdits : {extraction_ts!r}"
        )

    blocks = parse_findings(text)
    lessons: List[dict] = []
    for i, b in enumerate(blocks, start=1):
        lessons.append(build_lesson(b, extraction_ts, i))
    return lessons


# ------------------------------------------------------------ writer
def _read_existing_ids(path: Path) -> Tuple[List[dict], set]:
    """Charge un lessons.jsonl existant (vide si absent), retourne
    (leçons, ids_set). Lève si le fichier existant est corrompu."""
    if not path.exists():
        return [], set()
    existing = load_jsonl(path)  # valide chaque ligne
    return existing, {l["id"] for l in existing}


def _write_jsonl_fresh(path: Path, lessons: List[dict]) -> None:
    # P1 audit Codex (sérialisation --out) : écriture ATOMIQUE ET SÉRIALISÉE.
    #   1. flock exclusif sur le MÊME fichier .lock que _append_jsonl, pour
    #      qu'un --out concurrent d'un --append (ou d'un autre --out) ne puisse
    #      pas valider l'absence de collision en parallèle puis écrire.
    #   2. tmp UNIQUE par process (mkstemp) : le `.tmp` fixe d'origine était
    #      partagé par tous les --out concurrents -> un os.replace pouvait
    #      écraser silencieusement le résultat d'un autre process (perte).
    #   3. re-vérification des collisions SOUS verrou : couvre la course
    #      entre le pré-check hors-verrou de main() et l'écriture effective.
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(path.suffix + ".lock")
    lines = [json.dumps(l, ensure_ascii=False, sort_keys=False) for l in lessons]
    lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        _, existing_ids = _read_existing_ids(path)
        collisions = existing_ids & {l["id"] for l in lessons}
        if collisions:
            raise LessonError(
                f"collision d'ids détectée sous verrou (--out/append "
                f"concurrent ?) : {sorted(collisions)}")
        fd, tmp_name = tempfile.mkstemp(
            dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
        tmp = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        finally:
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass
    finally:
        os.close(lock_fd)


def _append_jsonl(path: Path, new_lessons: List[dict]) -> None:
    # P2 audit Codex : l'append est sérialisé par un flock EXCLUSIF sur un
    # fichier de verrou dédié, et les collisions d'ids sont re-vérifiées
    # À L'INTÉRIEUR du verrou — deux --append concurrents ne peuvent plus
    # valider les mêmes ids puis écrire tous les deux (perte/duplication).
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(path.suffix + ".lock")
    lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        _, existing_ids = _read_existing_ids(path)
        collisions = existing_ids & {l["id"] for l in new_lessons}
        if collisions:
            raise LessonError(
                f"collision d'ids détectée sous verrou (append concurrent ?) "
                f": {sorted(collisions)}")
        with open(path, "a", encoding="utf-8") as f:
            for l in new_lessons:
                f.write(json.dumps(l, ensure_ascii=False, sort_keys=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
    finally:
        os.close(lock_fd)


# --------------------------------------------------------------- main
def main(argv: List[str] = None) -> int:
    p = argparse.ArgumentParser(
        description=(
            "Extracteur déterministe de leçons (master order Run 4 §2). "
            "Lit un rapport finding-block, produit du JSONL normalisé. "
            "Aucun LLM dans le chemin d'extraction."
        )
    )
    p.add_argument(
        "input",
        nargs="?",
        default="-",
        help="rapport en finding-block (défaut: stdin)",
    )
    p.add_argument(
        "--out",
        help="écrire un fichier FRAIS (truncate) ; conflit refusé si ids "
        "déjà présents dans le fichier",
    )
    p.add_argument(
        "--append",
        help="ajouter à un fichier lessons.jsonl existant (collision d'id "
        "refusée : n'écrit RIEN si un seul id colle)",
    )
    p.add_argument(
        "--extraction-ts",
        help="figer le timestamp des ids (reproductibilité tests) ; "
        "défaut = UTC courant YYYYMMDDThhmmssZ",
    )
    p.add_argument(
        "--source-tag",
        help="forcer la balise source pour tous les blocs extraits ; "
        "par défaut on prend la clé `source:` de chaque bloc",
    )
    args = p.parse_args(argv)

    # Lecture entrée.
    if args.input == "-":
        text = sys.stdin.read()
    else:
        try:
            text = Path(args.input).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            print(f"lesson_extractor: lecture de {args.input} impossible — "
                  f"{type(e).__name__}: {e}", file=sys.stderr)
            return 1

    try:
        lessons = extract_lessons(text, extraction_ts=args.extraction_ts)
        # P3 audit Codex : --source-tag était exposé mais jamais appliqué.
        if args.source_tag:
            for l in lessons:
                l["source"] = args.source_tag
    except (ExtractionError, LessonError) as e:
        print(f"lesson_extractor: ECHEC — {e}", file=sys.stderr)
        return 1

    if not lessons:
        print("lesson_extractor: aucun bloc finding trouvé", file=sys.stderr)
        return 1

    # Destination.
    if args.out and args.append:
        print(
            "lesson_extractor: --out et --append sont mutuellement exclusifs",
            file=sys.stderr,
        )
        return 1

    if args.out:
        out_path = Path(args.out)
        try:
            # Pré-check hors-verrou : rejette tôt avec un message clair. La
            # re-vérification SOUS verrou dans _write_jsonl_fresh couvre la
            # course entre deux --out/--append concurrents.
            _, existing_ids = _read_existing_ids(out_path)
            new_ids = {l["id"] for l in lessons}
            collisions = existing_ids & new_ids
            if collisions:
                print(
                    f"lesson_extractor: collision d'ids avec le fichier existant "
                    f"{out_path} : {sorted(collisions)} — refuse d'écraser",
                    file=sys.stderr,
                )
                return 1
            _write_jsonl_fresh(out_path, lessons)
        except (LessonError, OSError) as e:
            print(f"lesson_extractor: écriture {out_path} impossible — "
                  f"{type(e).__name__}: {e}", file=sys.stderr)
            return 1
        print(
            f"lesson_extractor: {len(lessons)} leçons écrites (frais) dans {out_path}",
            file=sys.stderr,
        )
    elif args.append:
        app_path = Path(args.append)
        try:
            _, existing_ids = _read_existing_ids(app_path)
            new_ids = [l["id"] for l in lessons]
            dups = [i for i in new_ids if i in existing_ids]
            if dups:
                print(
                    f"lesson_extractor: {len(dups)} id(s) déjà présent(s) dans "
                    f"{app_path} : {dups} — RIEN n'a été écrit (atomicité)",
                    file=sys.stderr,
                )
                return 1
            _append_jsonl(app_path, lessons)
        except (LessonError, OSError) as e:
            print(f"lesson_extractor: ajout à {app_path} impossible — "
                  f"{type(e).__name__}: {e}", file=sys.stderr)
            return 1
        print(
            f"lesson_extractor: {len(lessons)} leçons ajoutées à {app_path} "
            f"(total précédent : {len(existing_ids)})",
            file=sys.stderr,
        )
    else:
        # stdout : JSONL brut, prêt à être pipé.
        for l in lessons:
            print(json.dumps(l, ensure_ascii=False, sort_keys=False))

    return 0


if __name__ == "__main__":
    sys.exit(main())
