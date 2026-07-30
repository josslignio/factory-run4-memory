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


BAD_FORK_HOOK = """
import os, fcntl
from pathlib import Path

_LOCK_FDS = {}

def acquire_lock(lockfile):
    key = str(Path(lockfile).resolve())
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
    except BaseException:
        os.close(fd)
        raise
    _LOCK_FDS[key] = fd
    return True

def release_lock(lockfile):
    key = str(Path(lockfile).resolve())
    fd = _LOCK_FDS.pop(key, None)
    if fd is not None:
        os.close(fd)

def _bad_child_hook():
    for fd in _LOCK_FDS.values():
        fcntl.flock(fd, fcntl.LOCK_UN)  # L-13: DEFECT reel — deverrouille le parent
    _LOCK_FDS.clear()
os.register_at_fork(after_in_child=_bad_child_hook)
"""


# ---- snippets défectueux round-2 (P1 detecteur : presence-token != safe) -

# register_at_fork présent mais le hook enfant est un NO-OP : ne ferme aucun
# fd hérité ni ne vide le dict. L'ancien rule_L12 créditait à tort ceci
# comme fork-safe (contre-audit Codex/Claude round 2, P1).
NOOP_FORK_HOOK = '''
import os, fcntl
from pathlib import Path

_LOCK_FDS = {}

def acquire_lock(lockfile):
    key = str(Path(lockfile).resolve())
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
    except BaseException:
        os.close(fd)
        raise
    _LOCK_FDS[key] = fd
    return True

def release_lock(lockfile):
    key = str(Path(lockfile).resolve())
    fd = _LOCK_FDS.pop(key, None)
    if fd is not None:
        os.close(fd)

def _noop_child():
    pass
os.register_at_fork(after_in_child=_noop_child)
'''


# Hook enfant qui ferme les fds MAIS oublie de vider le dict : l'enfant
# croit encore tenir les verrous. Fix_pattern incomplet -> L-12 present.
HOOK_CLOSE_NO_CLEAR = '''
import os, fcntl
from pathlib import Path

_LOCK_FDS = {}

def acquire_lock(lockfile):
    key = str(Path(lockfile).resolve())
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
    except BaseException:
        os.close(fd)
        raise
    _LOCK_FDS[key] = fd
    return True

def release_lock(lockfile):
    key = str(Path(lockfile).resolve())
    fd = _LOCK_FDS.pop(key, None)
    if fd is not None:
        os.close(fd)

def _close_no_clear():
    for fd in _LOCK_FDS.values():
        try:
            os.close(fd)
        except OSError:
            pass
os.register_at_fork(after_in_child=_close_no_clear)
'''


# fcntl.flock apparaît UNIQUEMENT dans release_lock : ne protège PAS
# acquire_lock (acquisition non atomique kernel -> TOCTOU). L'ancien rule_L01
# créditait à tort ceci comme TOCTOU-safe (contre-audit Claude round 2).
FLOCK_ONLY_IN_RELEASE = '''
import os, fcntl

_LOCK_FD = None

def acquire_lock(lockfile):
    global _LOCK_FD
    fd = os.open(lockfile, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    _LOCK_FD = fd
    return True

def release_lock(lockfile):
    global _LOCK_FD
    fcntl.flock(_LOCK_FD, fcntl.LOCK_UN)
    os.close(_LOCK_FD)
    _LOCK_FD = None
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

    def test_L13_lock_un_in_release_is_legitimate(self):
        # CORRIGÉ (contre-audit Codex) : LOCK_UN dans release_lock est
        # l'usage LÉGITIME de libération. Sans hook post-fork, le défaut de
        # fork-safety est porté par L-12 — L-13 ne doit PAS double-compter.
        f = _find(self.findings, "-13")
        self.assertEqual(f.status, "absent",
                         f"L-13 ne doit pas marquer un LOCK_UN de release: {f}")

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


class TestRuleL13OnBadForkHook(unittest.TestCase):
    """Le VRAI défaut L-13 : LOCK_UN à l'intérieur du hook enfant post-fork.
    La règle corrigée doit toujours l'attraper (test discriminant : ce
    snippet est propre partout ailleurs)."""

    @classmethod
    def setUpClass(cls):
        cls.findings = run_checker(BAD_FORK_HOOK)

    def test_L13_lock_un_in_child_hook_is_defect(self):
        f = _find(self.findings, "-13")
        self.assertEqual(f.status, "present",
                         f"L-13 doit marquer LOCK_UN dans le hook enfant: {f}")

    def test_L12_bad_hook_without_close_is_defect(self):
        # CORRIGÉ round 2 : le hook _bad_child_hook fait .clear() mais N'utilise
        # PAS os.close (il emploie LOCK_UN à la place -> défaut L-13). La règle
        # L-12 durcie exige os.close ET .clear() : un hook incomplet est donc
        # aussi un défaut L-12 (présence seule de register_at_fork ne suffit pas).
        f = _find(self.findings, "-12")
        self.assertEqual(f.status, "present",
                         f"L-12 doit marquer DEFECT (hook sans os.close): {f}")


class TestRuleL12OnNoopHook(unittest.TestCase):
    """P1 central du contre-audit round 2 : un hook after_in_child NO-OP ne
    doit PLUS être crédité comme fork-safe. L'ancien rule_L12 marquait
    'absent' dès qu'un os.register_at_fork( apparaissait."""

    @classmethod
    def setUpClass(cls):
        cls.findings = run_checker(NOOP_FORK_HOOK)

    def test_L12_noop_hook_is_defect(self):
        f = _find(self.findings, "-12")
        self.assertEqual(f.status, "present",
                         f"L-12 doit marquer DEFECT sur un hook no-op: {f}")

    def test_L13_noop_hook_not_flagged(self):
        # Pas de LOCK_UN -> L-13 ne double-compte pas (le défaut est porté par L-12).
        f = _find(self.findings, "-13")
        self.assertEqual(f.status, "absent",
                         f"L-13 ne doit pas marquer un hook sans LOCK_UN: {f}")


class TestRuleL12OnIncompleteHook(unittest.TestCase):
    """Hook qui ferme les fds mais oublie .clear() : fix_pattern incomplet,
    l'enfant croit encore tenir les verrous -> L-12 present."""

    @classmethod
    def setUpClass(cls):
        cls.findings = run_checker(HOOK_CLOSE_NO_CLEAR)

    def test_L12_close_without_clear_is_defect(self):
        f = _find(self.findings, "-12")
        self.assertEqual(f.status, "present",
                         f"L-12 doit marquer DEFECT (hook sans .clear()): {f}")


class TestRuleL01FlockOnlyInRelease(unittest.TestCase):
    """P2-eq round 2 : flock uniquement dans release_lock ne protège PAS
    acquire_lock (TOCTOU). L'ancien rule_L01 créditait à tort ceci."""

    @classmethod
    def setUpClass(cls):
        cls.findings = run_checker(FLOCK_ONLY_IN_RELEASE)

    def test_L01_flock_not_in_acquire_is_defect(self):
        f = _find(self.findings, "-01")
        self.assertEqual(f.status, "present",
                         f"L-01 doit marquer DEFECT (flock hors acquire_lock): {f}")


class TestEvidenceLineNoOffByOne(unittest.TestCase):
    """Régression rule 4 (traceabilité fichier:ligne non négociable) : le
    calcul d'offset du corps de fonction était décalé d'une ligne (corps
    démarre APRÈS la ligne `def`, l'ancien code oubliait le +1)."""

    def test_L16_arm_a_points_to_except_line_not_flock(self):
        findings = chk.check_file(REPO / "ablation" / "arm_a_lock_manager.py")
        l16 = _find(findings, "-16")
        # `except BlockingIOError:` est en ligne 20 d'arm_a ; l'ancien calcul
        # off-by-one pointait faussement vers la ligne 19 (le fcntl.flock).
        self.assertIn("arm_a_lock_manager.py:20 ", l16.evidence,
                      f"L-16 evidence doit pointer ligne 20 (except), pas 19: {l16.evidence}")
        self.assertNotIn("arm_a_lock_manager.py:19 ", l16.evidence)


class TestSummary(unittest.TestCase):
    def test_bad_has_more_defects_than_good(self):
        bad = chk.summarize(run_checker(BAD_LOCK))
        good = chk.summarize(run_checker(GOOD_LOCK))
        self.assertGreater(bad["total_defects"], good["total_defects"])
        self.assertGreaterEqual(bad["p1_defects"], 1)  # L-12 (L-13 ne
        # double-compte plus le LOCK_UN de release — contre-audit Codex)
        self.assertEqual(good["p1_defects"], 0,
                         "le snippet sain ne doit avoir AUCUN défaut P1")


# ===================================================================
# P0 finding 4 : rule_L16 mesure le COMPORTEMENT RÉEL (fd réellement fermé),
# ne crédite plus un `except OSError` générique.
# ===================================================================

# Mutant statique : `except OSError: return False` SANS fermer le fd. L'ancien
# rule_L16 créditait à tort ceci comme sûr (présence d'un filet large). Le
# détecteur durci doit le marquer DEFECT (present) car le fd fuit réellement.
MUTANT_NO_CLOSE = '''
import os, fcntl
_LOCK_FDS = {}

def acquire_lock(lockfile):
    key = lockfile
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError:
        return False
    _LOCK_FDS[key] = fd
    return True
'''


class TestRuleL16MutantNoClose(unittest.TestCase):
    """Un mutant `except OSError: return False` qui ne ferme PAS le fd doit
    être détecté comme DEFECT (NON-ok). C'était le défaut central du créditage
    générique d'un `except OSError`."""

    def test_mutant_returning_false_without_close_is_defect(self):
        findings = run_checker(MUTANT_NO_CLOSE)
        f = _find(findings, "-16")
        self.assertEqual(f.status, "present",
                         f"un mutant 'return False sans fermer' doit être "
                         f"DEFECT (present), eu {f.status}: {f}")


class _FdTracker:
    """Compteur réel de fd ouverts/fermés, injecté à la place de os.open /
    os.close pour mesurer le COMPORTEMENT RÉEL (fuite ou non) sans toucher aux
    ressources OS. C'est le 'compteur de fd ouverts' exigé par le finding 4."""
    def __init__(self):
        self.open_count = 0
        self.close_count = 0
        self._next = 3

    def open(self, path):
        self.open_count += 1
        self._next += 1
        return self._next

    def close(self, fd):
        self.close_count += 1


class TestRuleL16BehavioralFdLeak(unittest.TestCase):
    """Le jugement de la règle L-16 est ancré dans le COMPORTEMENT RÉEL : on
    exécute vraiment un acquire_lock SÛR (filet large + os.close) et un MUTANT
    (`return False` sans fermer), en faisant lever une OSError NON bloquante
    par flock, et on compte les fd ouverts. Seul le mutant fuit.

    Prouve que 'return False sans fermer' = fuite RÉELLE de fd, donc le
    détecteur a raison de le marquer DEFECT."""

    @staticmethod
    def _raise_plain_oserror(fd):
        # Une OSError NON-BlockingIOError (ex: ENOTSUP/EOPNOTSUPP sur FS non
        # supporté) — c'est le chemin de fuite que L-16 doit détecter.
        raise OSError("simulated non-blocking oserror (leak path)")

    @staticmethod
    def _safe_acquire(lockfile, tracker, flock_fn):
        # fix_pattern L-16 : filet large + os.close RÉEL.
        fd = tracker.open(lockfile)
        try:
            flock_fn(fd)
        except BlockingIOError:
            tracker.close(fd)
            return False
        except BaseException:
            tracker.close(fd)
            raise
        return fd

    @staticmethod
    def _mutant_acquire(lockfile, tracker, flock_fn):
        # MUTANT : `except OSError: return False` SANS close.
        fd = tracker.open(lockfile)
        try:
            flock_fn(fd)
        except BlockingIOError:
            return False
        except OSError:
            return False
        return fd

    def test_safe_version_closes_fd_no_leak(self):
        tracker = _FdTracker()
        with self.assertRaises(OSError):
            self._safe_acquire("x.lock", tracker, self._raise_plain_oserror)
        self.assertEqual(tracker.open_count, 1)
        self.assertEqual(tracker.close_count, 1,
                         "la version sûre doit fermer le fd (close==open)")
        self.assertEqual(tracker.open_count - tracker.close_count, 0,
                         "aucun fd restant ouvert (pas de fuite)")

    def test_mutant_leaks_fd(self):
        tracker = _FdTracker()
        result = self._mutant_acquire("x.lock", tracker, self._raise_plain_oserror)
        self.assertFalse(result, "le mutant retourne False")
        self.assertEqual(tracker.open_count, 1)
        self.assertEqual(tracker.close_count, 0,
                         "le mutant ne ferme JAMAIS le fd")
        self.assertEqual(tracker.open_count - tracker.close_count, 1,
                         "1 fd reste ouvert = fuite réelle -> DEFECT légitime")

    def test_detector_judgment_matches_real_behavior(self):
        # Cohérence : le détecteur marque MUTANT_NO_CLOSE comme DEFECT ET le
        # comportement réel prouve la fuite. Les deux s'accordent.
        f = _find(run_checker(MUTANT_NO_CLOSE), "-16")
        self.assertEqual(f.status, "present")
        tracker = _FdTracker()
        self._mutant_acquire("x.lock", tracker, self._raise_plain_oserror)
        self.assertGreater(tracker.open_count - tracker.close_count, 0,
                           "le mutant fuit réellement -> le DEFECT est justifié")


# ===================================================================
# P0 finding 4 (round 3, contre-audit Codex) : rule_L16 ne crédite plus un
# .close() générique — il faut que la fermeture cible le fd issu de os.open.
# Un mutant fermant une ressource SANS RAPPORT doit rester DEFECT. Et la
# preuve comportementale exécute RÉELLEMENT le source contrôlé (pas une
# implémentation recopiée).
# ===================================================================

# Mutant : filet large `except OSError` qui ferme une ressource SANS RAPPORT
# (le fd issu de os.open fuit). L'ancien rule_L16 créditait à tort ceci comme
# sûr (présence d'un `.close()`). Le détecteur durci doit le marquer DEFECT.
MUTANT_UNRELATED_CLOSE = '''
import os, fcntl

_LOCK_FDS = {}
_unrelated = type("R", (), {"close": lambda self: None})()

def acquire_lock(lockfile):
    key = lockfile
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError:
        _unrelated.close()  # ferme une ressource sans rapport -> fd fuit
        return False
    _LOCK_FDS[key] = fd
    return True
'''

# Source SÛR de référence pour l'exécution contrôlée : filet large + os.close(fd).
SAFE_ACQUIRE_WIDE_CLOSE = '''
import os, fcntl

_LOCK_FDS = {}

def acquire_lock(lockfile):
    key = lockfile
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return False
    except BaseException:
        os.close(fd)
        raise
    _LOCK_FDS[key] = fd
    return True
'''


class TestRuleL16UnrelatedCloseMutant(unittest.TestCase):
    """Un mutant qui ferme une ressource SANS RAPPORT (pas le fd issu de
    os.open) doit rester DEFECT : le fd fuit réellement. C'était le déficit
    pointé par le contre-audit Codex (« crédite toute occurrence de .close() »)."""

    def test_unrelated_close_is_defect(self):
        f = _find(run_checker(MUTANT_UNRELATED_CLOSE), "-16")
        self.assertEqual(f.status, "present",
                         f"un .close() sur une ressource sans rapport doit être "
                         f"DEFECT (present), eu {f.status}: {f}")

    def test_safe_wide_close_is_ok(self):
        f = _find(run_checker(SAFE_ACQUIRE_WIDE_CLOSE), "-16")
        self.assertEqual(f.status, "absent",
                         f"os.close(fd) dans un filet large doit être ok, eu "
                         f"{f.status}: {f}")


class _ExecOs:
    """Fake `os` pour exécuter le source contrôlé : compte les fd ouverts /
    fermés via le tracker au lieu de toucher aux ressources OS réelles."""
    O_CREAT = 0
    O_WRONLY = 1

    def __init__(self, tracker):
        self._t = tracker

    def open(self, path, flags):
        return self._t.open(path)

    def close(self, fd):
        return self._t.close(fd)


class _ExecFcntlLeak:
    """Fake `fcntl` dont flock lève une OSError NON-BlockingIOError (= chemin
    de fuite que L-16 doit détecter)."""
    LOCK_EX = LOCK_NB = LOCK_UN = 0

    @staticmethod
    def flock(fd, flags):
        raise OSError("simulated non-blocking oserror (leak path)")


class TestRuleL16ExecutesControlledSource(unittest.TestCase):
    """Contre-audit Codex round 3 : « les tests comportementaux n'exécutent
    pas le source contrôlé, mais deux implémentations recopiées ». On exécute
    RÉELLEMENT le source du snippet (le mutant ET la version sûre, tels
    qu'écrits), en injectant un fake os/fcntl, et on compte les fd. Seul le
    source sûr ferme le fd issu de os.open ; le mutant le fuit."""

    @staticmethod
    def _exec_acquire(src):
        import types
        tracker = _FdTracker()
        mod = types.ModuleType("uut")
        exec(compile(src, "<uut>", "exec"), mod.__dict__)
        # On remplace os/fcntl dans l'espace de noms du module exécuté par des
        # fakes qui mesurent le comportement réel (fd ouverts/fermés).
        mod.os = _ExecOs(tracker)
        mod.fcntl = _ExecFcntlLeak
        try:
            rc = mod.acquire_lock("x.lock")
        except OSError:
            rc = "raised"   # la version sûre relance après os.close(fd)
        return rc, tracker

    def test_mutant_source_executed_leaks_fd(self):
        rc, tracker = self._exec_acquire(MUTANT_NO_CLOSE)
        self.assertFalse(rc, "le mutant source exécuté retourne False")
        self.assertEqual(tracker.open_count, 1)
        self.assertEqual(tracker.close_count, 0,
                         "le mutant source (exécuté, pas recopié) ne ferme pas "
                         "le fd -> fuite réelle prouvée sur le source contrôlé")
        self.assertEqual(tracker.open_count - tracker.close_count, 1)

    def test_unrelated_close_source_executed_leaks_fd(self):
        rc, tracker = self._exec_acquire(MUTANT_UNRELATED_CLOSE)
        self.assertFalse(rc)
        self.assertEqual(tracker.open_count, 1)
        self.assertEqual(tracker.close_count, 0,
                         "le .close() sans rapport ne ferme pas le fd issu de "
                         "os.open -> fuite réelle, DEFECT justifié")

    def test_safe_source_executed_closes_fd(self):
        rc, tracker = self._exec_acquire(SAFE_ACQUIRE_WIDE_CLOSE)
        self.assertEqual(rc, "raised",
                         "la version sûre relance l'OSError après os.close(fd)")
        self.assertEqual(tracker.open_count, 1)
        self.assertEqual(tracker.close_count, 1,
                         "le source sûr exécuté ferme réellement le fd")
        self.assertEqual(tracker.open_count - tracker.close_count, 0,
                         "aucun fd restant ouvert -> pas de fuite")

    def test_detector_matches_executed_behavior(self):
        # Cohérence finale : le jugement STATIQUE du détecteur correspond au
        # COMPORTEMENT RÉEL exécuté du source contrôlé.
        for src, expected in ((MUTANT_NO_CLOSE, "present"),
                              (MUTANT_UNRELATED_CLOSE, "present"),
                              (MUTANT_DEAD_CODE_CLOSE, "present"),
                              (SAFE_ACQUIRE_WIDE_CLOSE, "absent")):
            f = _find(run_checker(src), "-16")
            self.assertEqual(f.status, expected,
                             f"juge statique {expected} != {f.status} pour "
                             f"le source exécuté: {f}")


# ===================================================================
# P0 finding 4 (round 4, contre-audit Codex) : règle COMPORTEMENTALE.
# Une fermeture MORTELLE `if False: os.close(fd)` porte l'occurrence textuelle
# `os.close(fd)` mais ne ferme JAMAIS le fd en réalité. L'ancienne règle
# (textuelle) la créditait à tort comme sûre (FAUX NÉGATIF). La règle
# comportementale DOIT la marquer DEFECT (present), car le fd fuit réellement.
# ===================================================================

MUTANT_DEAD_CODE_CLOSE = '''
import os, fcntl

_LOCK_FDS = {}

def acquire_lock(lockfile):
    key = lockfile
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError:
        if False:
            os.close(fd)   # fermeture MORTELLE — fd fuit réellement
        return False
    _LOCK_FDS[key] = fd
    return True
'''


class TestRuleL16DeadCodeCloseMutant(unittest.TestCase):
    """La régression signalée par le contre-audit Codex (round 4) : un mutant
    dont la fermeture est textuellement présente (`os.close(fd)`) mais derrière
    un `if False:` (code mort) fuit RÉELLEMENT le fd. La règle comportementale
    doit le marquer DEFECT (present) — ce qu'une analyse textuelle ne pouvait
    pas faire (faux négatif)."""

    def test_dead_code_close_is_defect(self):
        f = _find(run_checker(MUTANT_DEAD_CODE_CLOSE), "-16")
        self.assertEqual(f.status, "present",
                         f"une fermeture mortelle `if False: os.close(fd)` doit "
                         f"être DEFECT (present), eu {f.status}: {f}")

    def test_dead_code_close_really_leaks_fd(self):
        # Preuve comportementale : on exécute RÉELLEMENT le source (avec faux
        # os/fcntl où flock lève une OSError non-bloquante) et on compte les fd.
        # La fermeture étant morte, le fd fuit (close_count == 0).
        tracker = _FdTracker()
        mod = __import__("types").ModuleType("uut")
        exec(compile(MUTANT_DEAD_CODE_CLOSE, "<uut>", "exec"), mod.__dict__)
        mod.os = _ExecOs(tracker)
        mod.fcntl = _ExecFcntlLeak
        rc = mod.acquire_lock("x.lock")
        self.assertFalse(rc, "le mutant retourne False (filet large sans close)")
        self.assertEqual(tracker.open_count, 1)
        self.assertEqual(tracker.close_count, 0,
                         "la fermeture `if False:` ne s'exécute jamais -> le fd "
                         "fuit réellement (close==0), DEFECT justifié")

    def test_safe_wide_close_still_ok(self):
        # Non-régression : la version SÛRE (filet large + os.close(fd) réel)
        # reste marquée ok (absent) — pas de faux positif introduit.
        f = _find(run_checker(SAFE_ACQUIRE_WIDE_CLOSE), "-16")
        self.assertEqual(f.status, "absent",
                         f"os.close(fd) réel dans un filet large doit rester ok, "
                         f"eu {f.status}: {f}")


# ===================================================================
# P0 finding 4 (round 5, contre-audit Claude) : le tracker comportemental
# doit vérifier l'IDENTITÉ du fd fermé. Un mutant `os.close(0)` ferme le
# MAUVAIS fd (stdin) — le fd réel du verrou (issu de os.open) fuit. La règle
# DOIT le marquer DEFECT (present) ; l'ancien tracker crédite toute fermeture
# sans vérifier le fd -> faux négatif (absent à tort).
# ===================================================================

# Mutant : filet large `except OSError` qui ferme un MAUVAIS fd (os.close(0)),
# pas le fd du verrou. Contre-audit Claude round 5 : l'ancien _Tracker.closed
# incrémentait closes sur n'importe quel os.close(...) -> closes>=opens -> sûr
# à tort. Le tracker durci ne crédite qu'un close() ciblant un fd RÉELLEMENT
# ouvert.
MUTANT_WRONG_FD_CLOSE = '''
import os, fcntl

_LOCK_FDS = {}

def acquire_lock(lockfile):
    key = lockfile
    if key in _LOCK_FDS:
        return True
    fd = os.open(lockfile, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError:
        os.close(0)   # MAUVAIS fd (stdin) — le fd du verrou (fd) fuit réellement
        return False
    _LOCK_FDS[key] = fd
    return True
'''


class TestRuleL16WrongFdCloseMutant(unittest.TestCase):
    """Contre-audit Claude round 5 : un mutant qui ferme le MAUVAIS fd
    (`os.close(0)`, pas le fd du verrou) doit rester DEFECT — le fd réel fuit.
    Le tracker comportemental ne crédite une fermeture QUE si elle cible un fd
    réellement ouvert par os.open (identité du fd), pas n'importe quel close()."""

    def test_wrong_fd_close_is_defect(self):
        f = _find(run_checker(MUTANT_WRONG_FD_CLOSE), "-16")
        self.assertEqual(f.status, "present",
                         f"un os.close(0) fermant le MAUVAIS fd doit être "
                         f"DEFECT (present), eu {f.status}: {f}")

    def test_wrong_fd_close_really_leaks_lock_fd(self):
        # Preuve comportementale : on exécute RÉELLEMENT le source (faux
        # os/fcntl où flock lève une OSError non-bloquante) en comptant les fd
        # PAR IDENTITÉ. Le fd du verrou (retourné par os.open) n'est JAMAIS
        # fermé par os.close(0) -> il reste vivant -> fuite réelle -> DEFECT.
        tracker = _FdTrackerById()
        mod = __import__("types").ModuleType("uut")
        exec(compile(MUTANT_WRONG_FD_CLOSE, "<uut>", "exec"), mod.__dict__)
        mod.os = _ExecOsById(tracker)
        mod.fcntl = _ExecFcntlLeak
        rc = mod.acquire_lock("x.lock")
        self.assertFalse(rc, "le mutant retourne False")
        lock_fd = tracker.lock_fd
        self.assertIsNotNone(lock_fd, "os.open doit avoir été appelé")
        self.assertNotIn(lock_fd, tracker.closed_fds,
                         "le fd du verrou n'est PAS fermé par os.close(0) -> "
                         "fuite réelle, DEFECT justifié")
        self.assertIn(0, tracker.closed_fds,
                      "le mutant ferme bien fd 0 (le mauvais) — preuve que le "
                      "tracker distingue identité des fd")
        self.assertGreater(tracker.open_count, tracker.matched_close_count,
                           "moins de fermetures CORRECTES que d'ouvertures -> "
                           "fuite (le mauvais fd ne compte pas)")

    def test_safe_wide_close_still_ok_round5(self):
        # Non-régression : la version SÛRE (filet large + os.close(fd) ciblant
        # le bon fd) reste ok (absent) — pas de faux positif introduit par la
        # vérification d'identité.
        f = _find(run_checker(SAFE_ACQUIRE_WIDE_CLOSE), "-16")
        self.assertEqual(f.status, "absent",
                         f"os.close(fd) réel (bon fd) doit rester ok, "
                         f"eu {f.status}: {f}")


class _FdTrackerById:
    """Compteur de fd PAR IDENTITÉ (round 5) : enregistre le fd exact retourné
    par os.open (le fd du verrou) et ne crédite une fermeture QUE si elle cible
    ce fd. Distingue os.close(lock_fd) de os.close(mauvais_fd)."""
    def __init__(self):
        self.open_count = 0
        self.matched_close_count = 0   # fermetures ciblant un fd réellement ouvert
        self.closed_fds = []           # tous les fd passés à close (audit)
        self._next = 3
        self.lock_fd = None

    def open(self, path):
        self.open_count += 1
        self._next += 1
        self.lock_fd = self._next
        return self._next

    def close(self, fd):
        self.closed_fds.append(fd)
        if fd == self.lock_fd:
            self.matched_close_count += 1


class _ExecOsById:
    """Fake `os` qui compte les fd PAR IDENTITÉ (round 5)."""
    O_CREAT = 0
    O_WRONLY = 1

    def __init__(self, tracker):
        self._t = tracker

    def open(self, path, flags):
        return self._t.open(path)

    def close(self, fd):
        return self._t.close(fd)


class TestCheckerReadFailureIsClean(unittest.TestCase):
    """Contre-audit Codex (round 3) : le checker, cœur de la mesure A/B, ne
    doit JAMAIS planter en traceback sur une source illisible/non-UTF8. Il
    échoue proprement (rc=1, message clair) — il n'invente pas de mesure."""

    def test_non_utf8_source_returns_clean_rc1(self):
        import os as _os
        fd, path = tempfile.mkstemp(suffix=".py")
        with _os.fdopen(fd, "wb") as f:
            f.write(b"def acquire_lock():\n    pass\n  # \xff\xfe non-utf8\n")
        try:
            rc = chk.main([path, "--json"])
        finally:
            _os.unlink(path)
        self.assertEqual(rc, 1, "source non-UTF8 -> rc=1 propre (pas de mesure)")

    def test_unreadable_source_returns_clean_rc1(self):
        # Fichier existant mais illisible (chmod 0). Skip si root (root lit tout).
        import os as _os
        if hasattr(_os, "geteuid") and _os.geteuid() == 0:
            self.skipTest("root lit tout : chmod 0 non discriminant")
        fd, path = tempfile.mkstemp(suffix=".py")
        with _os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("x = 1\n")
        _os.chmod(path, 0o000)
        try:
            rc = chk.main([path, "--json"])
        finally:
            _os.chmod(path, 0o600)
            _os.unlink(path)
        self.assertEqual(rc, 1, "source illisible -> rc=1 propre (pas de traceback)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
