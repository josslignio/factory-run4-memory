"""Mini lock_manager.py — BRAS B (avec mémoire) — ablation Run 4 §4.

Build depuis ablation/TASK_SPEC.md + le bloc de leçons pertinentes
produit par factory/bin/lesson_injector.py (sortie collée ci-dessous,
ablation/arm_B_INJECTED_LESSONS.md). 3 leçons ont été injectées :

  L-12 (P1) : os.fork sans register_at_fork -> enfant hérite fds + dict.
              FIX : os.register_at_fork(after_in_child=...) ferme chaque
              fd via os.close PUIS _LOCK_FDS.clear(), dans l'enfant.
  L-01 (P1) : lockfile PID-file + unlink/O_EXCL -> TOCTOU.
              FIX : fcntl.flock sur fichier PERSISTANT, JAMAIS unlink.
  L-07 (P2) : scalaire _LOCK_FD global -> 2e acquire écrase le 1er.
              FIX : dict indexé par chemin CANONIQUE _LOCK_FDS[path] = fd.

Application fidèle des 3 leçons (et de leurs fix_patterns en cascade) :
- flock sur fichier persistant, PAS d'os.unlink (L-01 fix).
- dict indexé par chemin canonicalisé via Path.resolve() (L-07 fix).
- os.register_at_fork(after_in_child=...) qui os.close les fds puis clear
  le dict, dans l'enfant seulement (L-12 fix). Pas de LOCK_UN.

Leçons NON injectées (la spec neutre ne contient pas leurs triggers) ->
laissées en defaults naturels, comme un builder sans ces leçons ferait :
- L-09 (acquire non idempotent) : non couverte par l'injection.
- L-16 (except BlockingIOError seul)   : non couverte par l'injection.
"""
import fcntl
import os
from pathlib import Path

# L-07 fix : dict indexé par chemin canonique (multi-verrous indépendants).
_LOCK_FDS = {}


def _canon(lockfile_path):
    # L-07 fix : canonicaliser la clé pour que relatif == absolu.
    return str(Path(lockfile_path).resolve())


def acquire_lock(lockfile_path):
    """Prend un verrou exclusif non bloquant. True si obtenu, False sinon."""
    fd = os.open(lockfile_path, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return False
    # L-01 fix : fichier PERSISTANT (pas d'unlink), seul le flock compte.
    _LOCK_FDS[_canon(lockfile_path)] = fd
    return True


def release_lock(lockfile_path):
    """Libère le verrou pris sur ce chemin."""
    fd = _LOCK_FDS.pop(_canon(lockfile_path), None)
    if fd is None:
        return
    os.close(fd)  # L-12/L-13 fix : close (pas LOCK_UN), fichier persiste.


# L-12 fix : après fork, l'enfant hérite des fds ET du dict. Fermer les
# fds dans l'enfant via os.close (pas flock LOCK_UN, qui déverrouillerait
# le parent via la file description partagée), puis vider le dict enfant.
def _after_fork_in_child():
    for fd in _LOCK_FDS.values():
        try:
            os.close(fd)
        except OSError:
            pass
    _LOCK_FDS.clear()


os.register_at_fork(after_in_child=_after_fork_in_child)
