"""Tests de conformité spec — P0 reprise Run 4 (Memoire / Experience Compiler).

Encode 1:1 les cas d'acceptation EXACTS enumeres dans le brief de reprise P0
(27/07), par item, pour servir de porte d'acceptation de reprise. Ces tests
completent (ne remplacent pas) la suite existante ; ils figent les cas nommes
du brief afin qu'une regression sur l'un des 6 defauts soit bloquee.

Coverage :
  - Item 1 (--source-tag) : vide->FAIL, espaces->FAIL, incoherent->FAIL,
    coherent->PASS, + CLI rc!=0/rc==0, + re-validation post-modif.
  - Item 2 (bloc [FINDING] vide) : un valide->PASS, un vide->FAIL,
    valide+vide->FAIL (fail-closed sur TOUTE l'extraction).
  - Item 3 (ecriture concurrente bootstrap) : 2 processus reels ->
    aucun deadlock / FileNotFoundError / perte / JSON partiel / fd ouvert ;
    resultat final valide ; main() capture FileNotFoundError (rc=1 propre).
  - Item 4 (ablation L-16 comportement REEL) : safe->ok, mutants
    (return False sans close, mauvais fd, code mort) -> DEFECT.

Stdlib uniquement. Usage : python3 tests/test_p0_reprise.py
"""
import contextlib
import io
import json
import multiprocessing as mp
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "factory" / "bin"))

import lesson_extractor as ex  # noqa: E402
from lesson_extractor import (  # noqa: E402
    ExtractionError, apply_source_tag, assert_source_evidence_coherent,
    extract_lessons,
)
from lesson_schema import validate_lesson  # noqa: E402
import bootstrap_lessons as bs  # noqa: E402
import ablation_checker as chk  # noqa: E402

FIXTURE = REPO / "tests" / "fixtures" / "review_sample.txt"
TS = "20260730T120000Z"

VALID_BLOCK = (
    "[FINDING]\nseverity: P2\ncategory: resource-leak\nfile: t.py\nline: 9\n"
    "description: d\nfix: f\ntrigger_keywords: tempfile, leak\nsource: r\n"
    "test: t_x\n[/FINDING]\n"
)
EMPTY_BLOCK = "[FINDING]\n[/FINDING]\n"   # convention repo : bloc vide 2 lignes


def _run_cli(*extra):
    """Lance lesson_extractor.py sur la fixture (input positionnel)."""
    cmd = [sys.executable, str(REPO / "factory" / "bin" / "lesson_extractor.py"),
           str(FIXTURE), "--extraction-ts", TS, *extra]
    return subprocess.run(cmd, capture_output=True, text=True)


# ============================================================ Item 1
class TestItem1SourceTag(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = {k: v for k, v in
                    extract_lessons(FIXTURE.read_text(encoding="utf-8"),
                                    extraction_ts=TS)[0].items()}

    def test_vide_echoue(self):
        with self.assertRaises(ExtractionError):
            apply_source_tag(dict(self.base), "")

    def test_espaces_echoue(self):
        with self.assertRaises(ExtractionError):
            apply_source_tag(dict(self.base), "   ")

    def test_incoherent_echoue_coherence(self):
        bad = dict(self.base); bad["source"] = "AAA"
        bad["evidence"] = "BBB:t.py:9"   # evidence d'une autre source
        with self.assertRaises(ExtractionError):
            assert_source_evidence_coherent(bad)

    def test_incoherent_echoue_rewrite(self):
        weird = dict(self.base); weird["source"] = "orig"
        weird["evidence"] = "stranger:t.py:9"   # prefixe absent -> non reecrit
        with self.assertRaises(ExtractionError):
            apply_source_tag(weird, "new")

    def test_coherent_passe_et_revalide(self):
        coh = dict(self.base); coh["source"] = "orig-src"
        coh["evidence"] = "orig-src:t.py:9 — test: t"
        out = apply_source_tag(coh, "fresh-src")
        self.assertEqual(out["source"], "fresh-src")
        self.assertTrue(out["evidence"].startswith("fresh-src:"))
        validate_lesson(out)   # re-validation post-modif ne leve pas

    def test_cli_vide_rc_nonzero(self):
        self.assertNotEqual(_run_cli("--source-tag", "").returncode, 0)

    def test_cli_espaces_rc_nonzero(self):
        self.assertNotEqual(_run_cli("--source-tag", "   ").returncode, 0)

    def test_cli_valide_applique_tag(self):
        r = _run_cli("--source-tag", "good-tag")
        self.assertEqual(r.returncode, 0, r.stderr)
        first = json.loads(r.stdout.splitlines()[0])
        self.assertEqual(first["source"], "good-tag")


# ============================================================ Item 2
class TestItem2EmptyFindingBlock(unittest.TestCase):
    def test_un_valide_passe(self):
        ls = extract_lessons(VALID_BLOCK, extraction_ts=TS)
        self.assertEqual(len(ls), 1)

    def test_un_vide_echoue(self):
        with self.assertRaises(ExtractionError):
            extract_lessons(EMPTY_BLOCK, extraction_ts=TS)

    def test_valide_plus_vide_echoue_tout(self):
        # Le bloc vide fait echouer TOUTE l'extraction (fail-closed).
        with self.assertRaises(ExtractionError):
            extract_lessons(VALID_BLOCK + "\n" + EMPTY_BLOCK, extraction_ts=TS)


# ============================================================ Item 3
def _worker(out_path, iters, q):
    errs = []
    for _ in range(iters):
        try:
            bs.write_jsonl(bs.LESSONS, Path(out_path))
        except Exception as e:   # noqa: BLE001
            errs.append(f"{type(e).__name__}: {e}")
    q.put(errs)


def _count_fds():
    try:
        return len(os.listdir("/dev/fd"))
    except OSError:
        return None


class TestItem3ConcurrentWrite(unittest.TestCase):
    def setUp(self):
        self.ctx = mp.get_context("fork") if "fork" in mp.get_all_start_methods() \
            else mp.get_context()

    def test_deux_processus_aucun_deadlock_perte_partiel(self):
        tmp = tempfile.mkdtemp(prefix="p0r3_")
        out = Path(tmp) / "lessons.jsonl"
        q = self.ctx.Queue()
        procs = [self.ctx.Process(target=_worker, args=(str(out), 25, q))
                 for _ in range(2)]
        for p in procs:
            p.start()
        for p in procs:
            p.join(timeout=35)
            self.assertFalse(p.is_alive(), "deadlock : process toujours vivant")
        errs = []
        for _ in range(2):
            try:
                errs += q.get(timeout=5)
            except Exception:   # noqa: BLE001
                pass
        self.assertEqual(errs, [], f"exceptions relevees : {errs[:3]}")
        # aucun JSON partiel + aucune perte d'entree + resultat valide
        lines = [l for l in out.read_text(encoding="utf-8").splitlines() if l.strip()]
        parsed = [json.loads(l) for l in lines]   # JSONDecodeError si partiel
        self.assertEqual({l["id"] for l in parsed}, {l["id"] for l in bs.LESSONS})
        for l in parsed:
            validate_lesson(l)
        self.assertEqual(list(Path(tmp).glob("*.tmp")), [])   # aucun tmp residuel

    def test_aucun_fd_restant_ouvert(self):
        baseline = _count_fds()
        if baseline is None:
            self.skipTest("/dev/fd indisponible")
        tmp = tempfile.mkdtemp(prefix="p0r3_")
        out = Path(tmp) / "lessons.jsonl"
        for _ in range(50):
            bs.write_jsonl(bs.LESSONS, out)
        self.assertLessEqual(abs(_count_fds() - baseline), 1, "fuite de fd")

    def test_main_capturer_filenotfounderror_rc1_propre(self):
        tmp = tempfile.mkdtemp(prefix="p0r3_")
        orig = bs.write_jsonl
        boom_err = io.StringIO()
        def boom(lessons, out_path, timeout=30.0):
            raise FileNotFoundError(2, "simulated", str(out_path))
        bs.write_jsonl = boom
        old_argv = sys.argv
        sys.argv = ["bootstrap_lessons.py", "--out", str(Path(tmp) / "x.jsonl")]
        try:
            with contextlib.redirect_stderr(boom_err):
                rc = bs.main()
        finally:
            bs.write_jsonl = orig
            sys.argv = old_argv
        err = boom_err.getvalue()
        self.assertEqual(rc, 1)
        self.assertIn("FileNotFoundError", err)
        self.assertNotIn("Traceback", err)


# ============================================================ Item 4
SAFE_CLOSE = '''
import os, fcntl
def acquire_lock(lockfile):
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd); return False
    except OSError:
        os.close(fd); raise
    return True
'''
MUTANT_NO_CLOSE = '''
import os, fcntl
def acquire_lock(lockfile):
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError:
        return False
    return True
'''
MUTANT_WRONG_FD = '''
import os, fcntl
def acquire_lock(lockfile):
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError:
        os.close(0); return False
    return True
'''
MUTANT_DEAD = '''
import os, fcntl
def acquire_lock(lockfile):
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError:
        if False:
            os.close(fd)
        return False
    return True
'''


class TestItem4AblationFdBehavior(unittest.TestCase):
    def _measure(self, src):
        return chk._measure_acquire_lock_fd_closure(src)

    def _status(self, src):
        return chk.rule_L16(chk._code_only(src), src, "<uut>").status

    def test_safe_ferme_le_fd(self):
        self.assertTrue(self._measure(SAFE_CLOSE) is True)
        self.assertEqual(self._status(SAFE_CLOSE), "absent")

    def test_mutant_return_false_sans_fermer_defect(self):
        self.assertFalse(self._measure(MUTANT_NO_CLOSE))   # exigence litterale
        self.assertEqual(self._status(MUTANT_NO_CLOSE), "present")

    def test_mutant_mauvais_fd_defect(self):
        self.assertFalse(self._measure(MUTANT_WRONG_FD))
        self.assertEqual(self._status(MUTANT_WRONG_FD), "present")

    def test_mutant_code_mort_defect(self):
        self.assertFalse(self._measure(MUTANT_DEAD))
        self.assertEqual(self._status(MUTANT_DEAD), "present")


if __name__ == "__main__":
    unittest.main(verbosity=2)
