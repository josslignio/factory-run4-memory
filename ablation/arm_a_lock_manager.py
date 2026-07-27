"""Mini lock_manager.py — BRAS A (sans mémoire) — ablation Run 4 §4.

Build « à froid » depuis ablation/TASK_SPEC.md, SANS accès aux leçons de
memory/lessons.jsonl. Implémentation compétente mais non informée par les
leçons : defaults naturels qu'un builder produit tant qu'il n'a pas
rencontré les pièges spécifiques de cette famille de code.
"""
import fcntl
import os

# Un verrou par chemin de lockfile.
_locks = {}


def acquire_lock(lockfile_path):
    """Prend un verrou exclusif non bloquant. True si obtenu, False sinon."""
    fd = os.open(lockfile_path, os.O_CREAT | os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return False
    _locks[lockfile_path] = fd
    return True


def release_lock(lockfile_path):
    """Libère le verrou pris sur ce chemin."""
    fd = _locks.pop(lockfile_path, None)
    if fd is None:
        return
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
    os.unlink(lockfile_path)
