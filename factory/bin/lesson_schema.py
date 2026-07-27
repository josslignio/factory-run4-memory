"""
Schéma canonique d'une leçon Run 4 (Experience Compiler).

Une leçon est un dict conforme au schéma du master order §1 :
    {
      "id": "L-<timestamp>-<seq>",
      "date": "ISO8601",
      "source": "run3-lab | run4-memory | <repo>",
      "category": "concurrency | data-validation | resource-leak |
                   migration-safety | doc-sync | cli-validation | other",
      "trigger_pattern": "mots-clés / signature de code",
      "description": "défaut observé, une phrase factuelle",
      "fix_pattern": "remède générique réutilisable",
      "severity": "P1 | P2 | P3",
      "evidence": "fichier:ligne + test qui prouve le défaut ET le fix"
    }

Stdlib uniquement. Aucune dépendance externe (règle 1 du master order).

Ce module est volontairement sans effet de bord : il expose des validateurs
réutilisables par le bootstrap (§1), l'extracteur (§2) et l'injecteur (§3),
afin que les trois capacités partagent la MÊME définition d'une leçon valide.
"""
import json
import re
from typing import List, Tuple

# Catégories autorisées (master order §1). Toute autre valeur -> invalide.
ALLOWED_CATEGORIES = (
    "concurrency",
    "data-validation",
    "resource-leak",
    "migration-safety",
    "doc-sync",
    "cli-validation",
    "other",
)

ALLOWED_SEVERITIES = ("P1", "P2", "P3")

# Champs obligatoires et attendus (type, vide autorisé ?).
# `evidence` ne doit JAMAIS être vide (règle 4 : toute affirmation tracée
# fichier:ligne). `description` et `fix_pattern` non plus : une leçon sans
# description ni remède n'apporte rien.
REQUIRED_FIELDS: Tuple[Tuple[str, type, bool], ...] = (
    ("id", str, False),
    ("date", str, False),
    ("source", str, False),
    ("category", str, False),
    ("trigger_pattern", str, False),
    ("description", str, False),
    ("fix_pattern", str, False),
    ("severity", str, False),
    ("evidence", str, False),
)

# id au format L-<timestamp>-<seq>. On reste permissif sur le timestamp
# (digits/T/Z/-) pour ne pas casser un id légitime, mais on exige le préfixe
# L- pour distinguer d'un seq brut ou d'un hash.
ID_RE = re.compile(r"^L-[0-9TZa-z._:+-]+-[0-9A-Za-z]+$")

# Repère fichier:ligne : <chemin>:<ligne> quelque part dans evidence.
# Le chemin peut contenir un @ (ex: repo@branche:fichier:ligne, convention D-006).
FILE_LINE_RE = re.compile(r"[\w/.@\-+]+:\d+")


class LessonError(Exception):
    """Leçon invalide selon le schéma."""


def validate_lesson(obj) -> None:
    """Lève LessonError si `obj` n'est pas une leçon valide. Sinon rien.

    Distinction voulue (L-049) : on valide la FORME, pas la vérité terrain
    de l'affirmation (seul un humain/une review peut le faire). On exige
    juste que chaque affirmation soit TRAÇABLE (présence d'un fichier:ligne).
    """
    if not isinstance(obj, dict):
        raise LessonError(f"une leçon doit être un objet JSON, eu {type(obj).__name__}")
    for name, typ, allow_empty in REQUIRED_FIELDS:
        if name not in obj:
            raise LessonError(f"champ obligatoire manquant : {name!r}")
        v = obj[name]
        if not isinstance(v, typ):
            raise LessonError(
                f"champ {name!r} doit être {typ.__name__}, eu {type(v).__name__}"
            )
        if not allow_empty and (v is None or (isinstance(v, str) and v.strip() == "")):
            raise LessonError(f"champ {name!r} est vide")
    if obj["category"] not in ALLOWED_CATEGORIES:
        raise LessonError(
            f"category invalide : {obj['category']!r} "
            f"(attendu parmi {ALLOWED_CATEGORIES})"
        )
    if obj["severity"] not in ALLOWED_SEVERITIES:
        raise LessonError(
            f"severity invalide : {obj['severity']!r} (attendu parmi {ALLOWED_SEVERITIES})"
        )
    if not ID_RE.match(obj["id"]):
        raise LessonError(f"id mal formé : {obj['id']!r} (attendu L-<timestamp>-<seq>)")
    if not FILE_LINE_RE.search(obj["evidence"]):
        raise LessonError(
            f"evidence doit contenir un repère fichier:ligne ; eu : {obj['evidence']!r}"
        )


def load_jsonl(path) -> List[dict]:
    """Lit un fichier .jsonl (une leçon par ligne), valide chaque ligne.

    Lève LessonError sur : ligne non-JSON, JSON non-objet, leçon invalide,
    id en doublon. Retourne la liste des leçons (ordre du fichier).
    """
    lessons: List[dict] = []
    seen_ids = set()
    with open(path, "r", encoding="utf-8") as f:
        for lineno, raw in enumerate(f, start=1):
            stripped = raw.strip()
            if stripped == "":
                continue  # ligne vide tolérée (formatage)
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError as e:
                raise LessonError(f"ligne {lineno} : JSON invalide ({e})") from e
            validate_lesson(obj)
            if obj["id"] in seen_ids:
                raise LessonError(f"ligne {lineno} : id en doublon : {obj['id']!r}")
            seen_ids.add(obj["id"])
            lessons.append(obj)
    return lessons
