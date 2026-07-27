"""
Récupérateur / injecteur de leçons — master order Run 4 §3.

Prend en entrée une DESCRIPTION DE TÂCHE (texte libre ou chemin de fichier)
et retourne les leçons pertinentes de `memory/lessons.jsonl`, formatées en
un bloc de texte prêt à coller en tête d'un master order.

Méthode (master order §3, strict) :
  - Correspondance par MOT-CLÉ et par CATÉGORIE sur `trigger_pattern`.
  - PAS d'embeddings, PAS de ML, PAS de dépendance externe, stdlib uniquement.

Moteur de score (déterministe, reproductible) :
  Pour chaque leçon on découpe son `trigger_pattern` en items (séparateur `;`),
  on lower-case, et on compte combien d'items apparaissent comme sous-chaîne
  dans la tâche lower-casée. Chaque item matché vaut +1.
  Bonus catégorie : si la tâche cite explicitement la catégorie de la leçon
  (ex: « concurrency », « data-validation »), +1 supplémentaire.
  Les items vides ou triviaux (longueur < 3, ou stop-word commun) sont ignorés
  pour éviter les faux positifs (« lock », « the », « file » seuls).

Tri : score décroissant, puis severity P1>P2>P3, puis id (stable, reproductible).

Sortie :
  - Par défaut : bloc Markdown prêt à coller en tête d'un master order.
  - `--format json` : liste JSON des leçons matchées + leur score.
  - `--quiet` : uniquement les ids (un par ligne), pour scripting.

Code de retour :
  - 0 si au moins une leçon remonte,
  - 2 si aucune leçon ne matche (signal explicite « rien à injecter »,
    fail-closed : ne pas silencieusement ne rien écrire),
  - 1 sur erreur (f mémoire illisible, tâche vide, etc.).

Où un LLM pourrait intervenir (transparence L-049) : un LLM externe peut être
utilisé EN AMONT pour transformer une spec vague en description de tâche riche
en mots-clés technique. Mais la correspondance elle-même est 100% déterministe.
Aucun LLM dans ce module.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lesson_schema import load_jsonl, LessonError  # noqa: E402

DEFAULT_MEMORY = Path(__file__).resolve().parents[2] / "memory" / "lessons.jsonl"

# Mots-clés trop génériques pour matcher seuls (longueur < 4 ou stop-words
# techniques). Évite qu'une tâche disant « the file » ne matche toutes les
# leçons dont un trigger contient le mot « file ».
STOPWORDS: Set[str] = {
    "the", "and", "for", "with", "that", "this", "from", "into", "using",
    "use", "used", "via", "any", "all", "new", "old", "set", "get", "put",
    "out", "int", "str", "list", "dict", "true", "false", "none", "null",
    "file", "lock", "code", "test", "data", "bug", "fix",  # trop génériques seuls
}

SEVERITY_RANK = {"P1": 0, "P2": 1, "P3": 2}


class InjectionError(Exception):
    """Erreur d'entrée (tâche vide, mémoire illisible, etc.)."""


# ----------------------------------------------------------- chargement
def load_memory(path: Path) -> List[dict]:
    """Charge et valide le fichier lessons.jsonl (via lesson_schema.load_jsonl).

    Lève InjectionError sur problème de lecture / schéma.
    """
    if not path.exists():
        raise InjectionError(f"fichier mémoire introuvable : {path}")
    try:
        return load_jsonl(path)
    except LessonError as e:
        raise InjectionError(f"mémoire invalide ({path}) : {e}") from e


# --------------------------------------------------------- normalisation
def _split_triggers(trigger_pattern: str) -> List[str]:
    """Découpe un trigger_pattern brut en items nettoyés.

    Séparateurs acceptés : `;` (forme canonique du schéma). On tolère aussi
    la virgule pour la robustesse (certains rapports historiques peuvent
    l'utiliser). Les items vides ou triviaux (STOPWORDS ou longueur < 3
    après normalisation) sont écartés.
    """
    raw_items = re.split(r"[;,]", trigger_pattern)
    out: List[str] = []
    seen: Set[str] = set()
    for it in raw_items:
        item = it.strip().lower()
        # On garde les items alphanumériques significatifs (autorise . _ -
        # pour des tokens comme « os.fork », « _LOCK_FDS », « check-then-set »).
        norm = re.sub(r"\s+", " ", item).strip()
        if len(norm) < 3:
            continue
        if norm in STOPWORDS:
            continue
        if norm in seen:
            continue
        seen.add(norm)
        out.append(norm)
    return out


def _tokenize_task(task: str) -> str:
    """Normalise la tâche pour la correspondance par sous-chaîne.

    On lower-case et on compacte les espaces, sans supprimer la ponctuation
    technique (. _ - :) pour que des tokens comme « os.fork » ou
    « register_at_fork » restent entiers et matchables.
    """
    return re.sub(r"\s+", " ", task.strip().lower())


# ---------------------------------------------------------------- score
def score_lesson(lesson: dict, task_norm: str) -> Tuple[int, List[str]]:
    """Score d'une leçon vs tâche normalisée. Retourne (score, items_matchés).

    Règle :
      - Pour chaque trigger_pattern item, si l'item est une sous-chaîne de
        la tâche → +1.
      - Bonus catégorie : si la catégorie de la leçon apparaît comme mot
        entier dans la tâche → +1 (ex: « concurrency » dans la tâche).
    """
    matched: List[str] = []
    for item in _split_triggers(lesson.get("trigger_pattern", "")):
        if item in task_norm:
            matched.append(item)
    score = len(matched)

    category = lesson.get("category", "").strip().lower()
    if category and re.search(r"\b" + re.escape(category) + r"\b", task_norm):
        score += 1
        matched.append(f"[cat:{category}]")
    return score, matched


def select_lessons(
    lessons: List[dict],
    task: str,
    min_score: int = 1,
    top_n: int = 0,
) -> List[Tuple[dict, int, List[str]]]:
    """Sélectionne et trie les leçons pertinentes pour la tâche.

    Renvoie une liste de tuples (lesson, score, matched_items), triée par
    score décroissant, puis severity (P1 avant), puis id (ordre stable).
    `top_n=0` → pas de limite.
    """
    task_norm = _tokenize_task(task)
    if not task_norm:
        return []

    scored: List[Tuple[dict, int, List[str]]] = []
    for l in lessons:
        s, matched = score_lesson(l, task_norm)
        if s >= min_score and matched:
            scored.append((l, s, matched))

    scored.sort(key=lambda t: (-t[1], SEVERITY_RANK.get(t[0]["severity"], 99), t[0]["id"]))
    if top_n > 0:
        scored = scored[:top_n]
    return scored


# --------------------------------------------------------------- render
def render_text(
    selected: List[Tuple[dict, int, List[str]]],
    total_in_memory: int,
    task_preview: str,
) -> str:
    """Bloc Markdown prêt à coller en tête d'un master order."""
    lines: List[str] = []
    lines.append("## LEÇONS PERTINENTES (mémoire Run 4 — auto-injectées)")
    lines.append("")
    lines.append(f"- Source : `memory/lessons.jsonl` ({total_in_memory} leçons au total).")
    lines.append("- Critère : correspondance par mot-clé/catégorie sur `trigger_pattern` "
                 "(stdlib, pas d'embeddings, pas de ML).")
    preview = task_preview if len(task_preview) <= 160 else task_preview[:157] + "..."
    lines.append(f"- Tâche analysée : « {preview} ».")
    lines.append(f"- Sélection : {len(selected)} leçon(s) retenue(s) "
                 f"(score ≥ 1, tri score puis severity puis id).")
    lines.append("")
    if not selected:
        lines.append("_(aucune leçon ne matche — mémoire silencieuse pour cette tâche)_")
        return "\n".join(lines) + "\n"

    for lesson, score, matched in selected:
        lines.append(f"### [{lesson['severity']}] `{lesson['id']}` — {lesson['category']}")
        lines.append(f"- **description** : {lesson['description']}")
        lines.append(f"- **déclencheur** : `{lesson['trigger_pattern']}`")
        lines.append(f"- **remède** : {lesson['fix_pattern']}")
        lines.append(f"- **preuve** : {lesson['evidence']}")
        lines.append(f"- **score** : {score} — matchés : {', '.join(matched)}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_json(selected: List[Tuple[dict, int, List[str]]]) -> str:
    out = [
        {"id": l["id"], "severity": l["severity"], "category": l["category"],
         "score": s, "matched": m,
         "description": l["description"], "fix_pattern": l["fix_pattern"],
         "trigger_pattern": l["trigger_pattern"], "evidence": l["evidence"],
         "source": l["source"], "date": l["date"]}
        for l, s, m in selected
    ]
    return json.dumps(out, ensure_ascii=False, indent=2)


def render_quiet(selected: List[Tuple[dict, int, List[str]]]) -> str:
    return "\n".join(l["id"] for l, _, _ in selected)


# ----------------------------------------------------------------- main
def main(argv: List[str] = None) -> int:
    p = argparse.ArgumentParser(
        description=(
            "Injecteur de leçons (master order Run 4 §3). Lit une tâche, "
            "retourne les leçons pertinentes de memory/lessons.jsonl. "
            "Déterministe, stdlib uniquement, pas d'embeddings."
        )
    )
    p.add_argument(
        "task",
        nargs="?",
        help="description de tâche (texte libre). Si absente : --task-file requis.",
    )
    p.add_argument(
        "--task-file",
        help="lire la description de tâche depuis ce fichier (ex: spec.md).",
    )
    p.add_argument(
        "--memory",
        default=str(DEFAULT_MEMORY),
        help=f"fichier lessons.jsonl (défaut : {DEFAULT_MEMORY}).",
    )
    p.add_argument(
        "--top",
        type=int,
        default=5,
        help="limiter aux N meilleures leçons (défaut : 5 ; 0 = illimité).",
    )
    p.add_argument(
        "--min-score",
        type=int,
        default=1,
        help="score minimal pour retenir une leçon (défaut : 1).",
    )
    p.add_argument(
        "--format",
        choices=("text", "json", "quiet"),
        default="text",
        help="format de sortie (défaut : text = bloc Markdown).",
    )
    args = p.parse_args(argv)

    # Lecture tâche.
    if args.task_file:
        task_path = Path(args.task_file)
        if not task_path.exists():
            print(f"lesson_injector: --task-file introuvable : {task_path}",
                  file=sys.stderr)
            return 1
        task = task_path.read_text(encoding="utf-8")
    elif args.task is not None:
        task = args.task
    else:
        # Pas de tâche fournie → on tente stdin (mode pipe).
        if sys.stdin.isatty():
            print("lesson_injector: aucune tâche (passer un argument, "
                  "--task-file, ou pipe sur stdin)", file=sys.stderr)
            return 1
        task = sys.stdin.read()

    if not task.strip():
        print("lesson_injector: tâche vide", file=sys.stderr)
        return 1

    try:
        lessons = load_memory(Path(args.memory))
    except InjectionError as e:
        print(f"lesson_injector: ECHEC — {e}", file=sys.stderr)
        return 1

    selected = select_lessons(lessons, task,
                              min_score=args.min_score,
                              top_n=args.top)

    if args.format == "json":
        sys.stdout.write(render_json(selected) + "\n")
    elif args.format == "quiet":
        if selected:
            sys.stdout.write(render_quiet(selected) + "\n")
    else:
        sys.stdout.write(render_text(selected, len(lessons), task.strip()))

    # Code de retour :
    # 0 si au moins une leçon remonte ; 2 si vide (fail-closed, signal
    # explicite au pilote/appelant : rien à injecter, mémoire silencieuse).
    return 0 if selected else 2


if __name__ == "__main__":
    sys.exit(main())
