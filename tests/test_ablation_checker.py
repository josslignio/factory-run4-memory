"""Test réel du bug-detector §4 — master order Run 4 §4.

Valide factory/bin/ablation_checker.py : chaque règle doit marquer DEFECT
sur un snippet défectueux et ok sur un snippet appliquant le fix_pattern
de la leçon correspondante. Sans ça, les chiffres de l'ablation A/B
n'ont aucune valeur (detector non validé = mesure non validée).

Usage : python3 tests/test_ablation_checker.py
Stdlib uniquement.
"""
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "factory" / "bin"))

import ablation_checker as chk  # noqa: E402


def _find(findings, lesson_suffix):
    for f in findings:
        if f.lesson_id.endswith(lesson_suffix):
            return f
    raise AssertionError(f"règle {lesson_suffix} non trouvée")


def run_checker(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False,
                                     encoding="utf-8") as f:
        f.write(src)
        path = f.name
    try:
        return chk.check_file(Path(path))
    finally:
        Path(path).unlink()


# ---- snippets défectueux (le défaut ciblé doit être présent) -----------

BAD_LOCK = '''
import os, fcntl
_LOCK_FD = None  # scalaire (L-07)

def acquire_lock(lockfile):
    global _LOCK_FD
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False  # L-16: seul BlockingIOError attrapé, fd leak sur autre OSError
    _LOCK_FD = fd
    return True

def release_lock(lockfile):
    global _LOCK_FD
    fcntl.flock(_LOCK_FD, fcntl.LOCK_UN)  # L-13: LOCK_UN au lieu de close
    os.unlink(lockfile)  # L-05: supprime le fichier
    _LOCK_FD = None
# pas de register_at_fork (L-12)
# acquire_lock pas idempotent (L-09): pas de check "déjà détenu"
# clé scalaire pas dict (L-10 N/A car scalaire — mais dict absent)
'''


# ---- snippets sains (applique les fix_patterns → défauts absents) ------

GOOD_LOCK = '''
import os, fcntl
from pathlib import Path

_LOCK_FDS = {}  # dict indexé par chemin canonique (L-07 fix)

def _key(lockfile):
    return str(Path(lockfile).resolve())  # L-10 fix: canonicalisation

def acquire_lock(lockfile):
    key = _key(lockfile)
    if key in _LOCK_FDS:  # L-09 fix: idempotent
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
    except BaseException:  # L-16 fix: filet large
        os.close(fd)
        raise
    _LOCK_FDS[key] = fd
    return True

def release_lock(lockfile):
    key = _key(lockfile)
    fd = _LOCK_FDS.pop(key, None)
    if fd is not None:
        os.close(fd)  # L-13 fix: close pas LOCK_UN ; L-05 fix: pas d'unlink

# L-12 fix: hook post-fork enfant ferme les fds hérités
def _after_child():
    for fd in _LOCK_FDS.values():
        try:
            os.close(fd)
        except OSError:
            pass
    _LOCK_FDS.clear()
os.register_at_fork(after_in_child=_after_child)
'''


class TestRulesOnBadSnippet(unittest.TestCase):
    """Chaque règle doit marquer DEFECT sur le snippet défectueux ciblé."""

    @classmethod
    def setUpClass(cls):
        cls.findings = run_checker(BAD_LOCK)

    def test_L07_scalar_global(self):
        f = _find(self.findings, "-07")
        self.assertEqual(f.status, "present",
                         f"L-07 devrait être DEFECT: {f}")

    def test_L05_unlink_in_release(self):
        f = _find(self.findings, "-05")
        self.assertEqual(f.status, "present",
                         f"L-05 devrait être DEFECT: {f}")

    def test_L09_acquire_not_idempotent(self):
        f = _find(self.findings, "-09")
        self.assertEqual(f.status, "present",
                         f"L-09 devrait être DEFECT: {f}")

    def test_L12_no_register_at_fork(self):
        f = _find(self.findings, "-12")
        self.assertEqual(f.status, "present",
                         f"L-12 devrait être DEFECT: {f}")

    def test_L13_lock_un_used(self):
        f = _find(self.findings, "-13")
        self.assertEqual(f.status, "present",
                         f"L-13 devrait être DEFECT: {f}")

    def test_L16_blockingioerror_only(self):
        f = _find(self.findings, "-16")
        self.assertEqual(f.status, "present",
                         f"L-16 devrait être DEFECT: {f}")


class TestRulesOnGoodSnippet(unittest.TestCase):
    """Chaque règle doit marquer ok sur le snippet appliquant les fixes."""

    @classmethod
    def setUpClass(cls):
        cls.findings = run_checker(GOOD_LOCK)

    def test_L01_flock_present(self):
        f = _find(self.findings, "-01")
        self.assertEqual(f.status, "absent",
                         f"L-01 devrait être ok (flock présent): {f}")

    def test_L05_no_unlink(self):
        f = _find(self.findings, "-05")
        self.assertEqual(f.status, "absent",
                         f"L-05 devrait être ok (pas d'unlink): {f}")

    def test_L07_dict_not_scalar(self):
        f = _find(self.findings, "-07")
        self.assertEqual(f.status, "absent",
                         f"L-07 devrait être ok (dict): {f}")

    def test_L09_idempotent(self):
        f = _find(self.findings, "-09")
        self.assertEqual(f.status, "absent",
                         f"L-09 devrait être ok (idempotent): {f}")

    def test_L10_canonicalized(self):
        f = _find(self.findings, "-10")
        self.assertEqual(f.status, "absent",
                         f"L-10 devrait être ok (resolve): {f}")

    def test_L12_register_at_fork(self):
        f = _find(self.findings, "-12")
        self.assertEqual(f.status, "absent",
                         f"L-12 devrait être ok (register_at_fork): {f}")

    def test_L13_no_lock_un(self):
        f = _find(self.findings, "-13")
        self.assertEqual(f.status, "absent",
                         f"L-13 devrait être ok (pas de LOCK_UN): {f}")

    def test_L16_wide_catch(self):
        f = _find(self.findings, "-16")
        self.assertEqual(f.status, "absent",
                         f"L-16 devrait être ok (filet large): {f}")


class TestSummary(unittest.TestCase):
    def test_bad_has_more_defects_than_good(self):
        bad = chk.summarize(run_checker(BAD_LOCK))
        good = chk.summarize(run_checker(GOOD_LOCK))
        self.assertGreater(bad["total_defects"], good["total_defects"])
        self.assertGreaterEqual(bad["p1_defects"], 2)  # L-12 + L-13 au moins
        self.assertEqual(good["p1_defects"], 0,
                         "le snippet sain ne doit avoir AUCUN défaut P1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
