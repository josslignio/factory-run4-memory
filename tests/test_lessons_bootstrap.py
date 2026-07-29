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

    def test_bootstrap_is_deterministic(self):
        # Idempotence = DÉTERMINISME : même entrée -> mêmes octets. On écrit
        # DEUX fois le bootstrap dans deux fichiers indépendants et on compare.
        # On ne compare plus au memory/ accumulé : memory/lessons.jsonl est le
        # SEED puis ACCUMULE d'autres leçons par l'Experience Compiler — il
        # n'est donc plus byte-identique au bootstrap après accumulation (par
        # construction, ce n'est pas un défaut). La vraie invariant testée ici
        # est le déterminisme du bootstrap figé à l'extraction.
        import tempfile
        sys.path.insert(0, str(REPO / "factory" / "bin"))
        import bootstrap_lessons  # noqa: E402
        with tempfile.TemporaryDirectory() as d:
            a = Path(d) / "a.jsonl"
            b = Path(d) / "b.jsonl"
            bootstrap_lessons.write_jsonl(bootstrap_lessons.LESSONS, a)
            bootstrap_lessons.write_jsonl(bootstrap_lessons.LESSONS, b)
            self.assertEqual(
                a.read_text(encoding="utf-8"),
                b.read_text(encoding="utf-8"),
                "le bootstrap doit être déterministe (mêmes octets au re-run)")
            # Et le seed produit est bien une liste complète de leçons valides.
            rows = load_jsonl(a)
            self.assertEqual(len(rows), len(bootstrap_lessons.LESSONS))

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


# ===================================================================
# P0 finding 3 : écriture concurrente bootstrap SÉRIALISÉE (flock borné +
# tmp unique par process + fsync + os.replace atomique), FileNotFoundError
# capturé dans main(), jamais d'attente infinie. Preuve MULTIPROCESSUS RÉELLE.
# ===================================================================
class TestBootstrapConcurrentSerialization(unittest.TestCase):
    """Preuve réelle que write_jsonl résiste à la concurrence : deux vrais
    sous-processus bootstrap en parallèle sur le MÊME destination — aucun
    deadlock, aucun FileNotFoundError, aucun JSON partiel, aucun fd/.tmp
    résiduel, résultat final valide. + capture FileNotFoundError dans main()."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="run4_boot_conc_")
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_two_concurrent_bootstrap_same_dest_no_corruption(self):
        # MULTIPROCESSUS RÉEL : deux CLI bootstrap en parallèle (Popen
        # simultanés) sur le même --out. Le flock borné + tmp unique par
        # process + os.replace atomique garantissent l'absence de course.
        import subprocess
        d = Path(self.tmp)
        dest = d / "lessons.jsonl"
        cli = str(REPO / "factory" / "bin" / "bootstrap_lessons.py")
        cmd = [sys.executable, cli, "--out", str(dest)]
        p1 = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        p2 = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        # wait(timeout) borne l'attente -> un deadlock ferait lever TimeoutExpired.
        rc1 = p1.wait(timeout=60)
        rc2 = p2.wait(timeout=60)
        # Aucun FileNotFoundError / aucune erreur -> les deux rc=0.
        self.assertEqual(rc1, 0, f"process 1 rc={rc1} (aucune erreur attendue)")
        self.assertEqual(rc2, 0, f"process 2 rc={rc2} (aucune erreur attendue)")
        # Résultat final valide (pas de JSON partiel) : 18 leçons, schéma OK.
        rows = load_jsonl(dest)
        self.assertEqual(len(rows), 18, "18 leçons bootstrap complètes")
        # Aucun résidu .tmp (cleanup finally + tmp unique par process) :
        residue = sorted(p.name for p in d.glob("*.tmp"))
        self.assertEqual(residue, [], f".tmp résiduels (cleanup cassé) : {residue}")

    def test_write_jsonl_no_fd_leak(self):
        # P0 finding 3 : aucun fd restant ouvert après write_jsonl. On compte
        # les fd ouverts du process (via /dev/fd) avant/après plusieurs écritures
        # — le fd du verrou est fermé dans `finally`, le tmp dans un `with`.
        import os
        sys.path.insert(0, str(REPO / "factory" / "bin"))
        import bootstrap_lessons  # noqa: E402
        d = Path(self.tmp)
        try:
            os.listdir("/dev/fd")
        except OSError:
            self.skipTest("/dev/fd indisponible sur cette plateforme")
        baseline = len(os.listdir("/dev/fd"))
        for i in range(5):
            bootstrap_lessons.write_jsonl(
                bootstrap_lessons.LESSONS, d / f"seed{i}.jsonl")
        after = len(os.listdir("/dev/fd"))
        self.assertEqual(baseline, after,
                         f"fuite fd sur 5 write_jsonl : before={baseline} "
                         f"after={after}")

    def test_main_catches_filenotfounderror(self):
        # P0 finding 3 : main() doit capturer FileNotFoundError -> rc=1 PROPRE
        # (message clair, aucun traceback). Peut survenir si le répertoire
        # parent est retiré concurremment pendant l'écriture. On injecte
        # l'erreur contrôlée (write_jsonl patched) pour tester le gestionnaire.
        import io
        sys.path.insert(0, str(REPO / "factory" / "bin"))
        import bootstrap_lessons  # noqa: E402
        orig_wj = bootstrap_lessons.write_jsonl
        orig_argv = sys.argv

        def boom(lessons, out_path, timeout=None):
            raise FileNotFoundError(2, "simulated: parent dir gone", str(out_path))

        sys.argv = ["bootstrap_lessons.py",
                    "--out", str(Path(self.tmp) / "nope.jsonl")]
        backup_err = sys.stderr
        sys.stderr = io.StringIO()
        try:
            bootstrap_lessons.write_jsonl = boom
            rc = bootstrap_lessons.main()
            err = sys.stderr.getvalue()
        finally:
            bootstrap_lessons.write_jsonl = orig_wj
            sys.argv = orig_argv
            sys.stderr = backup_err
        self.assertEqual(rc, 1, "FileNotFoundError -> main() rc=1")
        self.assertIn("FileNotFoundError", err,
                       "message d'erreur clair attendu dans stderr")


if __name__ == "__main__":
    unittest.main(verbosity=2)
