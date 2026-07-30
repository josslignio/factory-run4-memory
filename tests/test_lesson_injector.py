"""Test réel de l'injecteur §3 — master order Run 4.

Valide factory/bin/lesson_injector.py sur critères OBJECTIFS :
  - select_lessons : une tâche connue remonte AU MOINS 3 leçons du
    bootstrap (master order §3 : « injecte une tâche connue pour matcher
    au moins 3 leçons du bootstrap ») ;
  - discrimination : une tâche ciblée ne remonte QUE les leçons attendues,
    aucune parasite (master order §3 : « vérifie que les bonnes leçons
    remontent et pas d'autres ») ;
  - score, tri (score puis severity puis id), tie-break stable ;
  - formats text/json/quiet ;
  - CLI : arg positionnel, --task-file, stdin, rc=0 si sain (match OU
    non-match), rc=1 si tâche vide / mémoire absente (contrat P1 fail-closed).

Usage : python3 tests/test_lesson_injector.py
Stdlib uniquement.
"""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "factory" / "bin"))

import lesson_injector as inj  # noqa: E402
from lesson_injector import (  # noqa: E402
    InjectionError,
    load_memory,
    select_lessons,
    score_lesson,
    _split_triggers,
)
from lesson_schema import validate_lesson, load_jsonl  # noqa: E402

MEMORY = REPO / "memory" / "lessons.jsonl"

# Tâche large (lock_manager + fork + checkpoint) : doit matcher AU MOINS
# 3 leçons du bootstrap, et les leçons attendues sont toutes présentes.
TASK_BROAD = (
    "Construire un lock_manager.py avec lockfile PID-file + unlink lock et "
    "verrou fichier. Attention au check-then-set lock (TOCTOU). Le pool "
    "lance os.fork() : prévoir register_at_fork et gérer le _LOCK_FDS "
    "hérité par release_lock enfant. Sauvegarder le checkpoint après "
    "travail (crash mid-step), stocker output_offset, ne pas avaler "
    "except OSError silencieux."
)
# IDs obligatoirement présents pour TASK_BROAD (positifs connus).
EXPECTED_BROAD = {
    "L-20260727T150500Z-01",  # lockfile PID-file, verrou fichier (concurrency)
    "L-20260727T150500Z-12",  # os.fork, register_at_fork (concurrency)
    "L-20260727T150500Z-02",  # crash mid-step (data-validation)
    "L-20260727T150500Z-08",  # except OSError silencieux (data-validation)
}

# Tâche ciblée fork : doit matcher UNIQUEMENT L-12 (etaucun autre).
# L-12 est la SEULE leçon du bootstrap avec os.fork + register_at_fork +
# release_lock enfant comme co-occurrence dans son trigger_pattern.
TASK_FORK_ONLY = (
    "Build a process pool with os.fork(); register_at_fork hook to clean "
    "up _LOCK_FDS hérité in the child; the release_lock enfant must not "
    "unlock the parent."
)
EXPECTED_FORK_ONLY = {"L-20260727T150500Z-12"}


class TestMemory(unittest.TestCase):
    def test_real_memory_loads_and_validates(self):
        lessons = load_memory(MEMORY)
        self.assertGreaterEqual(len(lessons), 15,
                                "le bootstrap doit contenir ≥15 leçons "
                                "(master order §1)")
        for l in lessons:
            validate_lesson(l)  # valide au passage

    def test_missing_memory_raises(self):
        with self.assertRaises(InjectionError):
            load_memory(REPO / "memory" / "does_not_exist.jsonl")

    def test_directory_memory_raises_injection_error(self):
        # P1 Codex : --memory pointant vers un RÉPERTOIRE doit lever
        # InjectionError (sortie contrôlée rc=1), PAS une traceback
        # IsADirectoryError non gérée.
        with self.assertRaises(InjectionError):
            load_memory(REPO / "memory")  # répertoire, pas un .jsonl


class TestSplitTriggers(unittest.TestCase):
    def test_semicolon_split(self):
        items = _split_triggers("os.fork; _LOCK_FDS hérité; register_at_fork")
        self.assertEqual(items, ["os.fork", "_lock_fds hérité", "register_at_fork"])

    def test_comma_tolerated_and_dedup(self):
        items = _split_triggers("os.fork, os.fork, register_at_fork")
        self.assertEqual(items, ["os.fork", "register_at_fork"])

    def test_short_items_dropped(self):
        # Items longueur < 3 écartés (ex: « x », « le »).
        items = _split_triggers("os.fork; le; x; _LOCK_FDS")
        self.assertNotIn("le", items)
        self.assertNotIn("x", items)
        self.assertIn("os.fork", items)

    def test_stopwords_dropped(self):
        items = _split_triggers("lock; file; the; os.fork")
        # « lock » et « file » sont stop-words dans ce module (trop génériques
        # seuls) — ils ne doivent pas matcher seuls.
        self.assertNotIn("lock", items)
        self.assertNotIn("file", items)
        self.assertIn("os.fork", items)


class TestScore(unittest.TestCase):
    def test_no_match_zero(self):
        l = {"trigger_pattern": "os.fork; register_at_fork",
             "category": "concurrency"}
        score, matched = score_lesson(l, "implement a web server with flask")
        self.assertEqual(score, 0)
        self.assertEqual(matched, [])

    def test_keyword_match(self):
        l = {"trigger_pattern": "os.fork; register_at_fork; _LOCK_FDS hérité",
             "category": "concurrency"}
        score, matched = score_lesson(
            l, "pool with os.fork and register_at_fork hook")
        self.assertEqual(score, 2)
        self.assertIn("os.fork", matched)
        self.assertIn("register_at_fork", matched)

    def test_category_bonus(self):
        # Tâche cite explicitement la catégorie « concurrency ».
        l = {"trigger_pattern": "os.fork; register_at_fork",
             "category": "concurrency"}
        score, matched = score_lesson(l, "concurrency: pool with os.fork")
        # 1 (os.fork) + 1 (catégorie) = 2
        self.assertEqual(score, 2)
        self.assertIn("[cat:concurrency]", matched)

    def test_category_word_boundary_no_false_positive(self):
        # « concurrency » ne doit pas matcher « dataconcurrency » (frontière).
        l = {"trigger_pattern": "rien a voir",
             "category": "concurrency"}
        score, _ = score_lesson(l, "le module dataconcurrency est pret")
        # Aucun trigger ne matche, ni la catégorie (word boundary).
        self.assertEqual(score, 0)


class TestSelectBroad(unittest.TestCase):
    """ master order §3 : « matcher au moins 3 leçons du bootstrap ». """

    @classmethod
    def setUpClass(cls):
        cls.lessons = load_memory(MEMORY)

    def test_broad_task_matches_at_least_3(self):
        selected = select_lessons(self.lessons, TASK_BROAD, top_n=0)
        self.assertGreaterEqual(
            len(selected), 3,
            f"TASK_BROAD doit matcher ≥3 leçons, eu {len(selected)}")
        ids = {l["id"] for l, _, _ in selected}
        # Toutes les leçons attendues doivent être dans la sélection.
        missing = EXPECTED_BROAD - ids
        self.assertFalse(
            missing,
            f"leçons attendues manquantes pour TASK_BROAD : {missing}")

    def test_broad_task_top_id_is_highest_score(self):
        selected = select_lessons(self.lessons, TASK_BROAD, top_n=0)
        top_lesson, top_score, _ = selected[0]
        # L-01 (lockfile PID-file + unlink lock + verrou fichier +
        # check-then-set lock) doit être #1 (score 4).
        self.assertEqual(top_lesson["id"], "L-20260727T150500Z-01")
        self.assertGreaterEqual(top_score, 4)

    def test_scores_sorted_desc(self):
        selected = select_lessons(self.lessons, TASK_BROAD, top_n=0)
        scores = [s for _, s, _ in selected]
        self.assertEqual(scores, sorted(scores, reverse=True))


class TestSelectDiscrimination(unittest.TestCase):
    """ master order §3 : « vérifie que les bonnes leçons remontent et
    pas d'autres ». Tâche fork ultra-ciblée → exactement 1 leçon. """

    @classmethod
    def setUpClass(cls):
        cls.lessons = load_memory(MEMORY)

    def test_fork_task_matches_exactly_one_lesson(self):
        selected = select_lessons(self.lessons, TASK_FORK_ONLY, top_n=0)
        ids = {l["id"] for l, _, _ in selected}
        self.assertEqual(
            ids, EXPECTED_FORK_ONLY,
            f"TASK_FORK_ONLY doit matcher EXACTEMENT L-12, eu {ids}")

    def test_unrelated_task_matches_nothing(self):
        # Tâche sans rapport avec aucune leçon du bootstrap.
        selected = select_lessons(
            self.lessons,
            "Dessiner un logo SVG pour la page marketing.", top_n=0)
        self.assertEqual(selected, [],
                         "une tâche sans rapport ne doit rien matcher")


class TestRanking(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lessons = load_memory(MEMORY)

    def test_severity_tiebreak_when_score_equal(self):
        # Construire 3 fausses leçons de même score, severity différente,
        # vérifier que la P1 sort avant la P2 avant la P3.
        fake = [
            {"id": "L-20260727T150500Z-91", "severity": "P2", "category": "other",
             "trigger_pattern": "alpha-beta-gamma; x-y-z-1",
             "description": "d", "fix_pattern": "f",
             "evidence": "src/a.py:1",
             "source": "test", "date": "2026-07-27"},
            {"id": "L-20260727T150500Z-92", "severity": "P1", "category": "other",
             "trigger_pattern": "alpha-beta-gamma; x-y-z-1",
             "description": "d", "fix_pattern": "f",
             "evidence": "src/a.py:1",
             "source": "test", "date": "2026-07-27"},
            {"id": "L-20260727T150500Z-93", "severity": "P3", "category": "other",
             "trigger_pattern": "alpha-beta-gamma; x-y-z-1",
             "description": "d", "fix_pattern": "f",
             "evidence": "src/a.py:1",
             "source": "test", "date": "2026-07-27"},
        ]
        for l in fake:
            validate_lesson(l)
        task = "tâche avec alpha-beta-gamma et x-y-z-1 dedans"
        selected = select_lessons(fake, task, top_n=0)
        # Tous score = 2 → tie-break severity : P1 avant P2 avant P3.
        self.assertEqual([l["id"] for l, _, _ in selected],
                         ["L-20260727T150500Z-92",
                          "L-20260727T150500Z-91",
                          "L-20260727T150500Z-93"])

    def test_top_n_limit(self):
        selected = select_lessons(self.lessons, TASK_BROAD, top_n=2)
        self.assertEqual(len(selected), 2)


class TestRender(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lessons = load_memory(MEMORY)
        cls.selected = select_lessons(cls.lessons, TASK_BROAD, top_n=2)

    def test_text_format_has_required_sections(self):
        out = inj.render_text(self.selected, len(self.lessons), "preview")
        self.assertIn("## LEÇONS PERTINENTES", out)
        self.assertIn("**score** :", out)
        self.assertIn("**description** :", out)
        self.assertIn("**déclencheur** :", out)
        self.assertIn("**remède** :", out)
        self.assertIn("**preuve** :", out)
        # L'id de la leçon top doit apparaître.
        self.assertIn("L-20260727T150500Z-01", out)

    def test_text_format_empty_selection(self):
        out = inj.render_text([], 18, "tâche sans rapport")
        self.assertIn("aucune leçon ne matche", out)

    def test_text_format_truncates_long_preview(self):
        long_task = "x" * 500
        out = inj.render_text([], 18, long_task)
        # Le preview est tronqué à 160 caractères + « ... ».
        self.assertIn("...", out)
        # Pas la tâche complète.
        self.assertNotIn("x" * 500, out)

    def test_json_format_parses_and_has_fields(self):
        out = inj.render_json(self.selected)
        data = json.loads(out)
        self.assertIsInstance(data, list)
        self.assertEqual(len(data), 2)
        for item in data:
            for f in ("id", "severity", "category", "score", "matched",
                      "description", "fix_pattern", "trigger_pattern",
                      "evidence"):
                self.assertIn(f, item)
        self.assertGreater(data[0]["score"], 0)

    def test_quiet_format_ids_only(self):
        out = inj.render_quiet(self.selected)
        ids = out.splitlines()
        self.assertEqual(ids, [l["id"] for l, _, _ in self.selected])


class TestCli(unittest.TestCase):
    """ Intégration CLI : arg positionnel, --task-file, stdin, codes de
    retour (0 sain match OU non-match, 1 panne ; 2 argparse). """

    def _capture(self, argv, stdin_text=None):
        """Invoque inj.main avec argv, capture stdout/stderr/rc."""
        backup_out, backup_err, backup_in = (
            sys.stdout, sys.stderr, sys.stdin)
        sys.stdout = io.StringIO()
        sys.stderr = io.StringIO()
        if stdin_text is not None:
            sys.stdin = io.StringIO(stdin_text)
        try:
            rc = inj.main(argv)
        finally:
            captured_out = sys.stdout.getvalue()
            captured_err = sys.stderr.getvalue()
            sys.stdout, sys.stderr, sys.stdin = (
                backup_out, backup_err, backup_in)
        return rc, captured_out, captured_err

    def test_positional_task_text(self):
        rc, out, _ = self._capture([TASK_BROAD, "--format", "quiet", "--top", "0"])
        self.assertEqual(rc, 0)
        ids = set(out.strip().splitlines())
        self.assertTrue(EXPECTED_BROAD.issubset(ids),
                        f"IDs attendus manquants. eu={ids}")

    def test_task_file(self):
        with tempfile.NamedTemporaryFile(
            "w", suffix=".txt", delete=False, encoding="utf-8"
        ) as f:
            f.write(TASK_BROAD)
            path = f.name
        try:
            rc, out, _ = self._capture(
                ["--task-file", path, "--format", "quiet", "--top", "0"])
            self.assertEqual(rc, 0)
            ids = set(out.strip().splitlines())
            self.assertTrue(EXPECTED_BROAD.issubset(ids))
        finally:
            os.unlink(path)

    def test_stdin_pipe(self):
        rc, out, _ = self._capture(
            ["--format", "quiet", "--top", "0"],
            stdin_text=TASK_BROAD)
        self.assertEqual(rc, 0)
        ids = set(out.strip().splitlines())
        self.assertTrue(EXPECTED_BROAD.issubset(ids))

    def test_no_match_returns_0(self):
        # Contrat P1 fail-closed : rc!=0 = panne système UNIQUEMENT. Un run
        # sain (mémoire lisible) sans leçon pertinente est un SUCCÈS (rc=0) ;
        # la sortie vide signale le non-match. Renvoyer rc!=0 forcerait le
        # préflight driver à un MEMORY_SYSTEM_FAIL intempestif sur mémoire
        # saine (audit P1 round 5 : l'ancien rc=2 était ambigu avec argparse).
        rc, out, _ = self._capture(
            ["tâche sans aucun rapport avec les leçons", "--format", "quiet"])
        self.assertEqual(rc, 0,
                         "non-match sur mémoire saine doit renvoyer rc=0 "
                         "(sain), PAS rc=2 (qui forcerait un arrêt driver)")
        self.assertEqual(out.strip(), "",
                         "non-match en --format quiet produit une sortie vide")

    def test_empty_task_returns_1(self):
        rc, _, err = self._capture(["   "])
        self.assertEqual(rc, 1)
        self.assertIn("vide", err.lower())

    def test_missing_memory_returns_1(self):
        rc, _, err = self._capture(
            [TASK_BROAD, "--memory", "/tmp/run4_does_not_exist.jsonl",
             "--format", "quiet"])
        self.assertEqual(rc, 1)
        self.assertIn("mémoire", err.lower())

    def test_task_file_directory_returns_1(self):
        # P1 Codex : --task-file pointant vers un RÉPERTOIRE doit retourner
        # rc=1 (erreur contrôlée), PAS une traceback IsADirectoryError.
        rc, _, err = self._capture(
            ["--task-file", str(REPO / "memory"), "--format", "quiet"])
        self.assertEqual(rc, 1)
        self.assertIn("répertoire", err.lower() + "repertoire")

    def test_memory_directory_returns_1(self):
        # P1 Codex : --memory pointant vers un RÉPERTOIRE doit retourner
        # rc=1 (erreur contrôlée), PAS une traceback IsADirectoryError.
        rc, _, err = self._capture(
            [TASK_BROAD, "--memory", str(REPO / "memory"),
             "--format", "quiet"])
        self.assertEqual(rc, 1)
        self.assertIn("mémoire", err.lower())

    def test_no_task_no_stdin_returns_1(self):
        # stdin fermé (isatty() faux en test), pas d'arg → on lève en Python
        # via la capture. Pour ce test, on simule stdin vide non-tty.
        rc, _, err = self._capture([], stdin_text="")
        # Soit on lit stdin vide → tâche vide → rc=1, soit pas d'arg → rc=1.
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
