"""Test réel du bootstrap §1 — master order Run 4.

Valide memory/lessons.jsonl sur critères OBJECTIFS (pas d'opinion) :
  - fichier existe et chaque ligne est du JSON valide ;
  - chaque leçon passe le validateur de schéma (factory/bin/lesson_schema.py) ;
  - ids uniques ;
  - >= 15 leçons (exigence master order §1) ;
  - chaque category dans l'ensemble autorisé ;
  - chaque severity dans {P1,P2,P3} ;
  - chaque evidence contient un repère fichier:ligne ;
  - la source documentée (D-006) est traçable : au moins une leçon pointe vers
    factory-run3-lab (preuve que ce ne sont pas des exemples inventés).

Usage : python3 tests/test_lessons_bootstrap.py
Stdlib uniquement. Aucune dépendance externe.
"""
import re
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "factory" / "bin"))
from lesson_schema import load_jsonl, LessonError  # noqa: E402

LESSONS_FILE = REPO / "memory" / "lessons.jsonl"
EXPECTED_MIN = 15
REPO_TAG_RE = re.compile(r"factory-run3-lab@", re.IGNORECASE)
FILE_LINE_RE = re.compile(r":[0-9]+(\D|$)")


class TestLessonsBootstrap(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Charge et valide une fois pour toute la classe. Si le fichier est
        # invalide, load_jsonl lève LessonError -> tous les tests échouent.
        cls.lessons = load_jsonl(LESSONS_FILE)

    def test_file_exists(self):
        self.assertTrue(LESSONS_FILE.exists(),
                        f"{LESSONS_FILE} doit exister après bootstrap")

    def test_min_15_lessons(self):
        self.assertGreaterEqual(
            len(self.lessons), EXPECTED_MIN,
            f"master order §1 exige >= {EXPECTED_MIN} leçons réelles, "
            f"eu {len(self.lessons)}")

    def test_ids_unique(self):
        ids = [l["id"] for l in self.lessons]
        self.assertEqual(len(ids), len(set(ids)),
                         f"ids en doublon : {ids}")

    def test_categories_in_allowed_set(self):
        allowed = {"concurrency", "data-validation", "resource-leak",
                   "migration-safety", "doc-sync", "cli-validation", "other"}
        for l in self.lessons:
            self.assertIn(l["category"], allowed,
                          f"{l['id']}: category {l['category']!r} non autorisée")

    def test_severities_in_allowed_set(self):
        for l in self.lessons:
            self.assertIn(l["severity"], {"P1", "P2", "P3"},
                          f"{l['id']}: severity {l['severity']!r} non autorisée")

    def test_evidence_has_file_line(self):
        for l in self.lessons:
            self.assertTrue(FILE_LINE_RE.search(l["evidence"]),
                            f"{l['id']}: evidence sans repère fichier:ligne : "
                            f"{l['evidence']!r}")

    def test_source_traceable_to_run3(self):
        # Preuve que les données viennent de Run #3 (D-006), pas inventées.
        with_run3 = [l for l in self.lessons if REPO_TAG_RE.search(l["evidence"])]
        self.assertGreaterEqual(
            len(with_run3), EXPECTED_MIN,
            f"au moins {EXPECTED_MIN} leçons doivent tracer leur source vers "
            f"factory-run3-lab (D-006) ; eu {len(with_run3)}")

    def test_every_severity_present_at_least_once(self):
        # Le bootstrap couvre les 3 niveaux (sinon la preuve d'ablation §4
        # serait biaisée par un échantillon non représentatif).
        sev = {l["severity"] for l in self.lessons}
        self.assertEqual(sev, {"P1", "P2", "P3"},
                         f"attendu au moins une leçon par sévérité, eu {sev}")

    def test_at_least_one_lesson_per_main_category(self):
        # Les catégories utiles au matching de l'injecteur (§3) doivent être
        # représentées dans le bootstrap, sinon l'injecteur ne pourra pas être
        # testé sur 3 leçons pertinentes distinctes (master order §3).
        cats = {l["category"] for l in self.lessons}
        for required in ("concurrency", "data-validation", "migration-safety"):
            self.assertIn(required, cats,
                          f"catégorie {required!r} requise pour le test §3 "
                          f"absente du bootstrap")

    def test_no_empty_required_field(self):
        for l in self.lessons:
            for k in ("description", "fix_pattern", "trigger_pattern", "evidence"):
                self.assertTrue(
                    l[k] and l[k].strip(),
                    f"{l['id']}: champ {k!r} vide")

    def test_bootstrap_is_idempotent(self):
        # Re-run le bootstrap dans un fichier temporaire : mêmes octets.
        import tempfile
        sys.path.insert(0, str(REPO / "factory" / "bin"))
        import bootstrap_lessons  # noqa: E402
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d) / "lessons.jsonl"
            bootstrap_lessons.write_jsonl(bootstrap_lessons.LESSONS, tmp)
            self.assertEqual(
                tmp.read_text(encoding="utf-8"),
                LESSONS_FILE.read_text(encoding="utf-8"),
                "le bootstrap doit être idempotent (mêmes octets au re-run)")

    def test_invalid_lesson_rejected_by_schema(self):
        # Contrôle de cohérence : le validateur doit REJETER une leçon cassée.
        from lesson_schema import validate_lesson  # noqa: E402
        bad = dict(self.lessons[0])
        bad["severity"] = "P9"
        with self.assertRaises(LessonError):
            validate_lesson(bad)
        bad2 = dict(self.lessons[0])
        bad2["evidence"] = "pas de repère fichier ligne ici"
        with self.assertRaises(LessonError):
            validate_lesson(bad2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
