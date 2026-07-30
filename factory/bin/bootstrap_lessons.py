"""
Bootstrap RÉEL de memory/lessons.jsonl — master order Run 4 §1.

Extrait les leçons de Run #3 (factory de résilience aux accidents, branche
`fix-lock-flock-checkpoint-sha256`) où chaque défaut P1/P2 a été trouvé puis
corrigé chirurgicalement sur 16 commits. Ce sont des données RÉELLES déjà
produites, pas des exemples inventés (master order §1, dernière phrase).

Source (D-006 — DECISIONS_AUTONOMOUS.md) :
  ~/factory-run3-lab @ fix-lock-flock-checkpoint-sha256
Fichiers dépouillés : worker.py, lock_manager.py, anti_loop.py,
                      test_crash_resume.py, test_zombie_lock.py,
                      test_anti_loop.py, RUN3_REPORT.md.

Chaque leçon est conforme au schéma factory/bin/lesson_schema.py (validé).
Le champ `evidence` pointe vers factory-run3-lab@fix-lock-flock-...:<file>:<line>
(état final vérifié) + le nom du test qui prouve le défaut ET le fix.

Usage :
    python3 factory/bin/bootstrap_lessons.py [--out memory/lessons.jsonl]

Idempotent : réécrire le même fichier à l'octet près si rien n'a changé
(bootstrap figé à l'extraction). Stdlib uniquement.
"""
import argparse
import fcntl
import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lesson_schema import validate_lesson, LessonError  # noqa: E402

REPO = "factory-run3-lab@fix-lock-flock-checkpoint-sha256"

# `date` = date du fix dans Run #3 (RUN3_REPORT.md:6). Les leçons ont été
# apprises pendant Run #3, pas pendant l'extraction Run #4.
RUN3_DATE = "2026-07-27"

# Marqueur d'extraction Run #4 (figé pour idempotence). Les ids sont
# L-<extraction_ts>-<seq> : la date d'extraction rend l'id globalement unique,
# le seq rend l'ordre stable.
EXTRACTION_TS = "20260727T150500Z"


def _ev(file_line: str, test: str) -> str:
    """Construit le champ evidence au format repère + test qui prouve."""
    return f"{REPO}:{file_line} — test: {test}"


LESSONS = [
    # ----------------------------------------------------------- L-001 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-01",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "concurrency",
        "trigger_pattern": "lockfile PID-file; O_CREAT|O_EXCL; unlink lock; "
                           "verrou fichier; check-then-set lock",
        "description": "Verrou fichier par mécanisme PID-file + unlink/O_EXCL : "
                       "fenêtre TOCTOU entre le unlink du verrou périmé et la "
                       "création exclusive — deux process peuvent tous deux "
                       "croire détenir le verrou.",
        "fix_pattern": "Remplacer par fcntl.flock(fd, LOCK_EX|LOCK_NB) sur un "
                       "fichier PERSISTANT : atomique au niveau kernel, libéré "
                       "par l'OS à la mort du process (plus de zombie, plus de "
                       "TOCTOU). Le fichier de lock n'est JAMAIS unlink.",
        "severity": "P1",
        "evidence": _ev("lock_manager.py:100",
                        "test_zombie_lock.test_three_processes_race "
                        "(20 courses à 3 process, codes=[0,2,2] systématiques)"),
    },
    # ----------------------------------------------------------- L-002 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-02",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "data-validation",
        "trigger_pattern": "crash mid-step; checkpoint après travail; append "
                           "output.txt; SIGKILL worker; reprise après coupure",
        "description": "Un crash entre l'écriture de la sortie (append sur "
                       "output.txt) et la sauvegarde du checkpoint laisse une "
                       "ligne orpheline non couverte — à la reprise la ligne "
                       "est rejouée et dupliquée.",
        "fix_pattern": "Stocker output_offset (taille en octets de output.txt) "
                       "dans le checkpoint APRÈS le travail ; à la reprise, "
                       "tronquer output.txt à cet offset AVANT de reprendre.",
        "severity": "P1",
        "evidence": _ev("worker.py:225",
                        "test_crash_resume.test_sigkill_mid_step "
                        "(SIGKILL réel, troncature 36o→24o, 6/6, zéro doublon)"),
    },
    # ----------------------------------------------------------- L-003 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-03",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "data-validation",
        "trigger_pattern": "fingerprint; hash de concaténation; sha256(erreur "
                           "+ fichier); séparateur |; détection de boucle",
        "description": "Empreinte par concaténation simple (erreur + '|' + "
                       "fichier) : collision de frontière — "
                       "('a|b','c') et ('a','b|c') produisent le même hash, "
                       "deux erreurs distinctes sont confondues.",
        "fix_pattern": "Sérialiser le couple via json.dumps([erreur, fichier], "
                       "ensure_ascii=False) avant de hasher : la structure de "
                       "liste JSON lève toute ambiguïté de frontière.",
        "severity": "P1",
        "evidence": _ev("anti_loop.py:45",
                        "test_anti_loop.test_pipe_in_values_no_collision "
                        "(hashes effectivement distincts)"),
    },
    # ----------------------------------------------------------- L-004 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-04",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "migration-safety",
        "trigger_pattern": "migration legacy; checkpoint legacy; dériver "
                           "offset; os.path.getsize; taille physique",
        "description": "Migration d'un checkpoint legacy sans output_offset en "
                       "dérivant l'offset de la taille PHYSIQUE de output.txt : "
                       "une ligne orpheline d'une étape jamais validée est "
                       "incorporée à tort, jamais tronquée, puis dupliquée à "
                       "la reprise.",
        "fix_pattern": "Dériver output_offset de last_completed_step uniquement "
                       "(sum des longueurs des lignes validées 1..last_step), "
                       "JAMAIS de os.path.getsize ; tronquer toute sortie "
                       "au-delà.",
        "severity": "P1",
        "evidence": _ev("worker.py:125",
                        "test_crash_resume."
                        "test_legacy_migration_derives_offset_from_completed_steps "
                        "(legacy + étape orpheline, output_offset=24 pas 36)"),
    },
    # ----------------------------------------------------------- L-005 (P2)
    {
        "id": f"L-{EXTRACTION_TS}-05",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "resource-leak",
        "trigger_pattern": "release_lock unlink; suppression fichier de lock; "
                           "lockfile persistant",
        "description": "release_lock qui os.unlink le fichier de lock casse la "
                       "sémantique persistante attendue d'un flock-file et "
                       "peut supprimer un lockfile qu'un autre process vient "
                       "de re-créer.",
        "fix_pattern": "release_lock = flock(LOCK_UN) + close(fd) seulement. "
                       "Le fichier PERSISTE sur disque : le flock (pas le "
                       "fichier) est la source de vérité.",
        "severity": "P2",
        "evidence": _ev("lock_manager.py:142",
                        "test_zombie_lock.test_acquire_release_reacquire_same_file "
                        "(20 cycles, fichier jamais supprimé)"),
    },
    # ----------------------------------------------------------- L-006 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-06",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "migration-safety",
        "trigger_pattern": "migration non persistée; différer save_state; "
                           "output_offset calculé puis perdu",
        "description": "Migration legacy qui calcule output_offset en mémoire "
                       "sans le persister avant tout nouveau travail : un crash "
                       "pendant l'étape post-migration fait re-dériver "
                       "output_offset depuis un output.txt déjà pollué par la "
                       "ligne orpheline → la troncature ne se déclenche pas.",
        "fix_pattern": "Persister la migration via save_state(workdir, st) "
                       "IMMÉDIATEMENT après calcul de output_offset, AVANT "
                       "tout nouveau travail, HORS de tout bloc protecteur.",
        "severity": "P1",
        "evidence": _ev("worker.py:145",
                        "test_crash_resume."
                        "test_legacy_migration_persisted_before_work_crash_safe "
                        "(output_offset=24 sur disque avant travail, crash, "
                        "6/6 final zéro doublon)"),
    },
    # ----------------------------------------------------------- L-007 (P2)
    {
        "id": f"L-{EXTRACTION_TS}-07",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "concurrency",
        "trigger_pattern": "_LOCK_FD global unique; verrou fichier; multi-lock; "
                           "fd écrasé; second acquire",
        "description": "Variable globale _LOCK_FD (scalaire) pour le fd du "
                       "verrou : un 2e acquire_lock sur un chemin différent "
                       "écrase la référence au premier fd → flock du premier "
                       "verrou perdu (fd orphan) et 2e verrou réutilise un fd "
                       "qui n'est pas le sien.",
        "fix_pattern": "Remplacer la globale scalaire par un dict indexé par "
                       "chemin canonique (_LOCK_FDS[path] = fd) : un processus "
                       "peut détenir plusieurs verrous indépendants.",
        "severity": "P2",
        "evidence": _ev("lock_manager.py:31",
                        "test_zombie_lock.test_multi_lock_independent_paths "
                        "(acquire A + acquire B, release A ne libère pas B)"),
    },
    # ----------------------------------------------------------- L-008 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-08",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "data-validation",
        "trigger_pattern": "except OSError silencieux; fallback offset=0; "
                           "except trop large; avaler erreur disque",
        "description": "Bloc `except OSError` large autour de load_state qui "
                       "avale l'échec de save_state (disque plein, permissions) "
                       "et retourne un fallback offset=0 → main() déclenche "
                       "truncate_output_to_offset(0) → tout output.txt effacé.",
        "fix_pattern": "Restreindre le try à la LECTURE seule ; save_state est "
                       "HORS du bloc protecteur et son OSError doit remonter "
                       "pour arrêter le worker proprement, jamais être traitée "
                       "comme « pas d'état = repartir de zéro ».",
        "severity": "P1",
        "evidence": _ev("worker.py:110",
                        "test_crash_resume."
                        "test_legacy_migration_save_failure_propagates "
                        "(monkeypatch save_state lève OSError, propagée, "
                        "output.txt intact 36o)"),
    },
    # ----------------------------------------------------------- L-009 (P2)
    {
        "id": f"L-{EXTRACTION_TS}-09",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "resource-leak",
        "trigger_pattern": "acquire_lock non idempotent; double acquire même "
                           "chemin; fd orphan; réouverture",
        "description": "acquire_lock(path) appelé 2x sur le même chemin dans le "
                       "même process rouvre et reflock un 2e fd, écrasant "
                       "l'entrée dict : le 1er fd devient orphan (plus jamais "
                       "close, fuite + flock indéfiniment détenu).",
        "fix_pattern": "Idempotence intra-process : si _LOCK_FDS.get(key) "
                       "existe, retourner ce fd sans rouvrir ni reflock.",
        "severity": "P2",
        "evidence": _ev("lock_manager.py:92",
                        "test_zombie_lock.test_acquire_lock_idempotent_same_path "
                        "(3 acquire retournent le même fd, dict=1 entrée)"),
    },
    # ----------------------------------------------------------- L-010 (P2)
    {
        "id": f"L-{EXTRACTION_TS}-10",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "concurrency",
        "trigger_pattern": "clé dict chemin relatif; release chemin absolu; "
                           "Path.resolve; key mismatch lock",
        "description": "Clé de _LOCK_FDS prise comme str(lockfile) brut : un "
                       "acquire via chemin relatif et un release via chemin "
                       "absolu équivalent ne matchent pas → release no-op, "
                       "flock détenu indéfiniment par ce process.",
        "fix_pattern": "Canonicaliser la clé via str(Path(lockfile).resolve()) "
                       "partout (acquire ET release) : deux chemins équivalents "
                       "sont vus comme la même ressource.",
        "severity": "P2",
        "evidence": _ev("lock_manager.py:92",
                        "test_zombie_lock."
                        "test_canonical_path_relative_acquire_absolute_release"),
    },
    # ----------------------------------------------------------- L-011 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-11",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "data-validation",
        "trigger_pattern": "JSONDecodeError silencieux; state.json corrompu; "
                           "fallback offset=0; repli lecture checkpoint",
        "description": "Repli silencieux « JSONDecodeError/OSError lecture → "
                       "offset=0 » sur checkpoint corrompu : main() déclenche "
                       "truncate_output_to_offset(0) → tout output.txt effacé "
                       "sur un simple problème de lecture.",
        "fix_pattern": "Distinguer « absent » (offset=0 légitime) de "
                       "« présent-corrompu » : dans le 2e cas, laisser remonter "
                       "l'exception ; main() l'attrape et ABORT en stderr rc=1 "
                       "SANS appeler truncate_output_to_offset.",
        "severity": "P1",
        "evidence": _ev("worker.py:103",
                        "test_crash_resume."
                        "test_corrupt_checkpoint_aborts_no_truncation "
                        "(JSON invalide, abort rc=1, output.txt byte-identique)"),
    },
    # ----------------------------------------------------------- L-012 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-12",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "concurrency",
        "trigger_pattern": "os.fork; _LOCK_FDS hérité; release_lock enfant; "
                           "flock partagé parent/enfant; register_at_fork",
        "description": "Après os.fork(), l'enfant hérite par copy-on-write de "
                       "_LOCK_FDS ET des fds ouverts : release_lock(chemin) "
                       "dans l'enfant ferme le fd hérité → comme le flock suit "
                       "la file description partagée parent/enfant, ça "
                       "déverrouille aussi le PARENT.",
        "fix_pattern": "os.register_at_fork(after_in_child=…) ferme chaque fd "
                       "tracké via os.close PUIS _LOCK_FDS.clear(), dans "
                       "l'enfant seulement. close() sur le fd enfant ne ferme "
                       "que la copie enfant ; le verrou parent reste intact.",
        "severity": "P1",
        "evidence": _ev("lock_manager.py:44",
                        "test_zombie_lock."
                        "test_fork_child_does_not_inherit_lock_release "
                        "(vrai os.fork, enfant _LOCK_FDS vide, parent "
                        "toujours REFUSÉ à un 3e process)"),
    },
    # ----------------------------------------------------------- L-013 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-13",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "concurrency",
        "trigger_pattern": "flock(LOCK_UN) dans enfant; file description "
                           "partagée; hook post-fork; libérer verrou parent",
        "description": "Variante du L-012 : utiliser fcntl.flock(fd, LOCK_UN) "
                       "dans l'enfant pour « fermer » le fd hérité déverrouille "
                       "AUSSI le parent — les fds hérités partagent la même "
                       "file description OS, et LOCK_UN agit sur elle.",
        "fix_pattern": "Dans le hook post-fork enfant, utiliser os.close(fd) "
                       "(PAS flock LOCK_UN) puis _LOCK_FDS.clear(). Fermer le "
                       "fd enfant libère seulement sa référence à la file "
                       "description, sans toucher au verrou parent.",
        "severity": "P1",
        "evidence": _ev("lock_manager.py:47",
                        "test_zombie_lock."
                        "test_fork_child_does_not_hold_os_lock_when_parent_crashes "
                        "(parent crashé + gc vivante → flock LIBRE, 3e ACQUIERT ; "
                        "contre-épreuve : parent vivant → 3e REFUSÉ)"),
    },
    # ----------------------------------------------------------- L-014 (P1)
    {
        "id": f"L-{EXTRACTION_TS}-14",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "data-validation",
        "trigger_pattern": "checkpoint JSON-valide mais incomplet; types "
                           "attendus; state.get(..., 0); validation stricte",
        "description": "Checkpoint JSON-valide mais structurellement invalide "
                       "(ex. {\"output_offset\": 0} sans last_completed_step) : "
                       "le code de migration/troncature fait state.get("
                       "\"output_offset\", 0) → tombe à 0 → truncate à 0 AVANT "
                       "que le KeyError sur last_completed_step ne soit levé.",
        "fix_pattern": "Valider strictement le checkpoint (types, clés, "
                       "intervalles) AVANT toute migration/troncature et lever "
                       "CheckpointError si invalide ; main() ABORT sans toucher "
                       "à output.txt.",
        "severity": "P1",
        "evidence": _ev("worker.py:46",
                        "test_crash_resume."
                        "test_invalid_checkpoint_aborts_no_truncation"),
    },
    # ----------------------------------------------------------- L-015 (P2)
    {
        "id": f"L-{EXTRACTION_TS}-15",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "data-validation",
        "trigger_pattern": "output.txt plus court que checkpoint; incohérence "
                           "fichier/état; perte silencieuse d'étape",
        "description": "output.txt plus court que l'offset du checkpoint : le "
                       "checkpoint prétend que output.txt contient plus de "
                       "données validées que ce qui existe réellement — perte "
                       "silencieuse d'au moins une étape si on accepte.",
        "fix_pattern": "truncate_output_to_offset lève CheckpointError si "
                       "output.txt MANQUANT avec offset≠0 ou plus court que "
                       "l'offset ; main() capture et ABORT sans toucher au "
                       "fichier.",
        "severity": "P2",
        "evidence": _ev("worker.py:169",
                        "test_crash_resume."
                        "test_checkpoint_output_mismatch_aborts_no_truncation"),
    },
    # ----------------------------------------------------------- L-016 (P2)
    {
        "id": f"L-{EXTRACTION_TS}-16",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "resource-leak",
        "trigger_pattern": "except BlockingIOError seul; fuite fd sur autre "
                           "OSError; ENOTSUP flock; fd non fermé",
        "description": "acquire_lock qui n'attrape que BlockingIOError laisse "
                       "le fd ouvert sur tout autre OSError (ENOTSUP/EOPNOTSUPP "
                       "sur FS non supporté) → fuite de descripteur.",
        "fix_pattern": "Attraper BlockingIOError (refus propre) puis un "
                       "`except BaseException` qui os.close(fd) avant de "
                       "relancer — couvre OSError, KeyboardInterrupt, etc.",
        "severity": "P2",
        "evidence": _ev("lock_manager.py:106",
                        "test_zombie_lock."
                        "test_acquire_lock_closes_fd_on_non_blocking_oserror"),
    },
    # ----------------------------------------------------------- L-017 (P3)
    {
        "id": f"L-{EXTRACTION_TS}-17",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "data-validation",
        "trigger_pattern": "isinstance(x, int); bool est int; True comme "
                           "index/étape; validation type Python",
        "description": "isinstance(True, int) est True en Python : un checkpoint "
                       "avec last_completed_step=true ou steps_done=[true] passe "
                       "la validation entière si on ne teste pas bool "
                       "explicitement.",
        "fix_pattern": "Dans toute validation d'entier venu d'un format "
                       "sérialisé, exclure bool explicitement : "
                       "`isinstance(lcs, bool) or not isinstance(lcs, int)`.",
        "severity": "P3",
        "evidence": _ev("worker.py:69",
                        "test_crash_resume.test_invalid_checkpoint_aborts_no_truncation "
                        "(couvert par la validation stricte générale)"),
    },
    # ----------------------------------------------------------- L-018 (P2)
    {
        "id": f"L-{EXTRACTION_TS}-18",
        "date": RUN3_DATE,
        "source": "run3-lab",
        "category": "doc-sync",
        "trigger_pattern": "rapport décrivant code stale; RUN3_REPORT non "
                           "resync; doc décrivant implémentation inexistante",
        "description": "Un rapport final qui décrit une implémentation "
                       "obsolète (anciennes fonctions, anciennes lignes) après "
                       "des fixes chirurgicaux est pire que pas de rapport : "
                       "il induit en erreur toute review/audit ultérieur.",
        "fix_pattern": "Réécrire le rapport INTEGRALEMENT à chaque fix qui "
                       "change la sémantique (commit dédié « rapport: "
                       "réécriture intégrale »), pas seulement éditer la "
                       "section touchée — recoller les sorties de test réelles.",
        "severity": "P2",
        "evidence": _ev("RUN3_REPORT.md:42",
                        "(commit 2bdc619 « RUN3_REPORT.md: réécriture intégrale "
                        "pour refléter l'implémentation actuelle » + commit "
                        "a24f832 pour les fixes postérieurs)"),
    },
]


# Délai max d'attente du verrou d'écriture (P0 finding 3) : un flock(LOCK_EX)
# classique bloque indéfiniment ; on l'acquiert en LOCK_NB borné -> JAMAIS
# d'attente infinie, deadlock impossible. 30s est très large pour du IO local.
LOCK_TIMEOUT = 30.0


def _flock_ex_timeout(fd: int, timeout: float = LOCK_TIMEOUT) -> None:
    """Acquiert flock(LOCK_EX) en mode non-bloquant, réessayé jusqu'au
    `timeout` (en secondes). Lève TimeoutError si la contention dépasse le
    délai — JAMAIS d'attente infinie, JAMAIS de deadlock."""
    deadline = time.monotonic() + timeout
    delay = 0.02
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"impossible d'acquérir le verrou d'écriture bootstrap "
                    f"après {timeout}s (contention) — abandon fail-closed")
            time.sleep(delay)
            delay = min(delay * 1.5, 0.5)


def write_jsonl(lessons, out_path: Path, timeout: float = LOCK_TIMEOUT) -> None:
    """Écrit les leçons (une par ligne, JSON UTF-8, ensure_ascii=False).

    Idempotent : même entrée → mêmes octets. Pas de newline final superflu.

    P0 finding 3 : écriture CONCURRENTE SÉRIALISÉE en réutilisant le pattern
    déjà validé du repo (cf. lesson_extractor._write_jsonl_fresh et les
    leçons L-10..L-16 de memory/lessons.jsonl) — PAS de nouvelle abstraction
    de lock :
      - fcntl.flock exclusif sur un fichier de verrou dédié `<out>.lock` ;
      - fd de verrou ouvert puis TOUJOURS fermé dans un `finally` (libération
        garantie même sur crash) ;
      - acquisition BORNÉE (_flock_ex_timeout) : jamais d'attente infinie ;
      - tmp UNIQUE par processus (tempfile.mkstemp, pas un `.tmp` fixe
        partagé) + `with os.fdopen(fd)` (context manager) + fsync ;
      - `os.replace` atomique : le fichier destination n'est jamais vu à
        moitié écrit, jamais corrompu par une course ;
      - nettoyage du tmp dans un `finally`.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = out_path.with_suffix(out_path.suffix + ".lock")
    lines = [json.dumps(l, ensure_ascii=False, sort_keys=False) for l in lessons]
    # O_CREAT : le fichier de verrou est créé s'il n'existe pas. Il persiste
    # après exécution (fichier auxiliaire) — c'est attendu et sans impact
    # sur lessons.jsonl lui-même (cf. D-009 / leçon L-05 : on n'unlink pas).
    lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        _flock_ex_timeout(lock_fd, timeout)
        fd, tmp_name = tempfile.mkstemp(
            dir=str(out_path.parent),
            prefix=out_path.name + ".",
            suffix=".tmp")
        tmp = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, out_path)
        finally:
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass
    finally:
        os.close(lock_fd)


def main() -> int:
    p = argparse.ArgumentParser(description="Bootstrap réel de memory/lessons.jsonl.")
    p.add_argument("--out", default="memory/lessons.jsonl",
                   help="fichier de sortie (défaut: memory/lessons.jsonl)")
    p.add_argument("--min", type=int, default=15,
                   help="nombre minimum de leçons exigé (défaut: 15)")
    args = p.parse_args()

    # Valide chaque leçon avant d'écrire (fail-closed : n'écrit rien si l'une
    # est invalide — on ne veut jamais d'un lessons.jsonl partiellement sale).
    for i, l in enumerate(LESSONS, start=1):
        try:
            validate_lesson(l)
        except LessonError as e:
            print(f"bootstrap: leçon interne #{i} ({l.get('id','?')}) invalide : {e}",
                  file=sys.stderr)
            return 1

    n = len(LESSONS)
    if n < args.min:
        print(f"bootstrap: {n} leçons < minimum {args.min} exigé par le master order",
              file=sys.stderr)
        return 1

    out = Path(args.out)
    try:
        write_jsonl(LESSONS, out)
    except FileNotFoundError as e:
        # P0 finding 3 : capturé explicitement — peut survenir si le répertoire
        # parent est retiré concurremment, ou si mkstemp/fsync tombe sur un
        # chemin disparu. main() le traduit en rc=1 contrôlé (pas de traceback).
        print(f"bootstrap: écriture {out} impossible — "
              f"FileNotFoundError: {e}", file=sys.stderr)
        return 1
    except TimeoutError as e:
        print(f"bootstrap: écriture {out} impossible — "
              f"timeout de verrou: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"bootstrap: écriture {out} impossible — "
              f"{type(e).__name__}: {e}", file=sys.stderr)
        return 1
    print(f"bootstrap: {n} leçons valides écrites dans {out} "
          f"(min={args.min}, source={REPO}, date={RUN3_DATE})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
