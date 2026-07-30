#!/usr/bin/env python3
"""
GATE RECEIPT REEL — master order Run 4, PHASE P1, fonction 1.

Wrapper stdlib qui :
  - execute la VRAIE commande de gate (sous-processus, jamais un booléen
    fourni par l'appelant) ;
  - lit le VRAI code retour du processus fils ;
  - écrit un receipt `gate_receipt.json` hors du repo, dans
    `$HOME/.factory-receipts/factory-run4-memory/` ;
  - propage le code retour de la commande gate (rc=0 -> 0, rc=7 -> 7, etc.).

Schéma du receipt (master order P1, fonction 1) :
    {
      "task_id":     str,   # relie la tâche au verdict + lesson_candidate
      "commit":      str,   # sha du commit audité par le gate
      "command":     str,   # commande exécutée (audit reproductible)
      "exit_code":   int,   # code retour RÉEL du sous-processus
      "passed":      bool,  # true UNIQUEMENT si exit_code == 0
      "started_at":  str,   # ISO8601 UTC
      "finished_at": str,   # ISO8601 UTC
      "stdout_path": str,   # chemin du capture stdout (hors repo)
      "stderr_path": str    # chemin du capture stderr (hors repo)
    }

INVARIANTS NON NÉGOCIABLES (master order P1) :
  - `passed` est TOUJOURS calculé `exit_code == 0`. JAMAIS de PASS hardcodé.
  - JAMAIS de booléen `--passed` fourni par l'appelant : le rejeter explicitement.
  - Le code retour propagé est celui de la commande gate (transparence totale).

Stdlib uniquement (règle 1 du master order). Aucune dépendance externe.
"""
import argparse
import datetime
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

DEFAULT_RECEIPTS_DIR = Path.home() / ".factory-receipts" / "factory-run4-memory"
DEFAULT_RECEIPT_NAME = "gate_receipt.json"

# Le receipt est l'unique preuve de passage du gate. On l'écrit de façon
# atomique (tmp + os.replace) pour qu'un crash en cours ne laisse jamais un
# receipt partiel/illisible que promote pourrait interpréter à tort.


def _utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _atomic_write_json(path: Path, obj: dict) -> None:
    """Écriture atomique : tmp dans le même dossier puis os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp." + str(os.getpid()))
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def run_gate(
    command: List[str],
    task_id: str,
    commit: str,
    receipts_dir: Path = DEFAULT_RECEIPTS_DIR,
    receipt_name: str = DEFAULT_RECEIPT_NAME,
    cwd: Optional[Path] = None,
    env: Optional[dict] = None,
) -> tuple:
    """Exécute la commande gate, écrit le receipt, retourne (exit_code, receipt_path).

    `passed` est calculé `exit_code == 0`. Aucun booléen externe n'est accepté.
    Le stdout/stderr sont capturés dans des fichiers du dossier receipts.
    """
    if not command or not isinstance(command, list) or \
            not all(isinstance(a, str) and a for a in command):
        raise ValueError(
            "run_gate: `command` doit être une liste non vide de chaînes "
            "(jamais un shell string ambigu, jamais vide)")

    receipts_dir = Path(receipts_dir)
    receipts_dir.mkdir(parents=True, exist_ok=True)

    stem = Path(receipt_name).stem or "gate_receipt"
    stdout_path = receipts_dir / f"{stem}.stdout"
    stderr_path = receipts_dir / f"{stem}.stderr"
    receipt_path = receipts_dir / receipt_name

    started_at = _utc_now_iso()
    run_env = dict(env) if env is not None else None

    # Troncature préventive des captures (un receipt précédent ne doit pas
    # laisser un vieux stdout lu par erreur si la commande ne produit rien).
    for p in (stdout_path, stderr_path):
        p.write_text("", encoding="utf-8")

    try:
        with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
            # capture_output=False : on redirige nous-mêmes vers fichiers.
            # Le gate court dans un sous-processus réel : le code retour est
            # celui du fils, jamais synthétisé.
            proc = subprocess.run(
                command,
                stdout=out,
                stderr=err,
                cwd=str(cwd) if cwd else None,
                env=run_env,
            )
        exit_code = int(proc.returncode)
    except FileNotFoundError as e:
        # Commande introuvable : on consigne l'échec réel (exit_code=127 par
        # convention POSIX) et on lève — c'est une erreur d'appel, pas un PASS.
        with open(stderr_path, "a", encoding="utf-8") as err:
            err.write(f"\nrun_gate: commande introuvable : {e}\n")
        receipt = {
            "task_id": task_id,
            "commit": commit,
            "command": command,
            "exit_code": 127,
            "passed": False,
            "started_at": started_at,
            "finished_at": _utc_now_iso(),
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
        }
        _atomic_write_json(receipt_path, receipt)
        raise

    finished_at = _utc_now_iso()
    # INVARIANT : passed est CALCULÉ depuis exit_code. Jamais hardcodé, jamais
    # fourni par l'appelant. C'est la seule définition légale de « gate OK ».
    receipt = {
        "task_id": task_id,
        "commit": commit,
        "started_at": started_at,
        "finished_at": finished_at,
        "command": command,
        "exit_code": exit_code,
        "passed": exit_code == 0,
        "stdout_path": str(stdout_path),
        "stderr_path": str(stderr_path),
    }
    _atomic_write_json(receipt_path, receipt)
    return exit_code, receipt_path


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description=(
            "Gate receipt réel (Run 4 P1, fonction 1). Exécute la commande "
            "gate, écrit gate_receipt.json hors repo, propage le code retour. "
            "Stdlib uniquement. Jamais de PASS hardcodé."
        )
    )
    p.add_argument(
        "--task-id", required=True,
        help="identifiant de tâche (relie au verdict + lesson_candidate).",
    )
    p.add_argument(
        "--commit", required=True,
        help="sha du commit audité par le gate.",
    )
    p.add_argument(
        "--receipts-dir", default=str(DEFAULT_RECEIPTS_DIR),
        help=f"dossier receipts (défaut : {DEFAULT_RECEIPTS_DIR}).",
    )
    p.add_argument(
        "--receipt-name", default=DEFAULT_RECEIPT_NAME,
        help=f"nom du receipt (défaut : {DEFAULT_RECEIPT_NAME}).",
    )
    p.add_argument(
        "--cwd",
        help="répertoire de travail du gate (défaut : répertoire courant).",
    )
    p.add_argument(
        "--shell", action="store_true",
        help="interpréter COMMAND via /bin/sh -c (déconseillé : préférer une "
             "liste explicite).",
    )
    p.add_argument(
        "command", nargs=argparse.REMAINDER,
        help="commande gate à exécuter (ex: python3 -m pytest tests/). "
             "Préfixer par -- si elle commence par un tiret.",
    )
    # On utilise parse_known_args pour pouvoir INSPECTER argv nous-mêmes et
    # refuser explicitement tout booléen de triche (--passed/--force-pass),
    # plutôt que de laisser argparse le rejeter silencieusement comme un
    # argument inconnu. Le message doit être sans ambiguïté.
    args, unknown = p.parse_known_args(argv)

    # REFUS EXPLICITE d'un booléen --passed fourni par l'appelant : c'est la
    # forme même de triche que ce wrapper existe pour empêcher. `passed` est
    # TOUJOURS calculé depuis exit_code, jamais fourni.
    cheats = {"--passed", "--no-passed", "--force-pass", "--pass"}
    caught = cheats.intersection(argv or []) or cheats.intersection(unknown)
    if caught:
        print(f"run_gate: REFUS — argument(s) de triche interdit(s) : "
              f"{sorted(caught)} : `passed` est TOUJOURS calculé depuis "
              f"exit_code (jamais fourni par l'appelant)", file=sys.stderr)
        return 2
    # Tout autre argument inconnu est aussi refusé (pas d'option cachée).
    if unknown:
        print(f"run_gate: REFUS — argument(s) inconnu(s) : {unknown}. "
              f"Le wrapper n'accepte aucune option de contournement.",
              file=sys.stderr)
        return 2

    if not args.command:
        p.error("une commande gate est requise")

    # argparse.REMAINDER conserve un éventuel séparateur '--' utilisé pour
    # démarquer la commande des options du wrapper ; on le retire pour que la
    # commande réelle soit exécutée telle quelle.
    cmd_list = list(args.command)
    while cmd_list and cmd_list[0] == "--":
        cmd_list.pop(0)
    if not cmd_list:
        p.error("une commande gate est requise (après -- si besoin)")

    if args.shell:
        # Mode shell : on reçoit une seule chaîne. On l'exécute via /bin/sh -c
        # pour respecter l'opérateur (échappement variable), MAIS on garde le
        # code retour réel du shell (jamais synthétisé).
        shell_str = " ".join(cmd_list)
        command = ["/bin/sh", "-c", shell_str]
        receipt_command = ["/bin/sh", "-c", shell_str]
    else:
        command = list(cmd_list)
        receipt_command = list(command)

    try:
        exit_code, _ = run_gate(
            command=command,
            task_id=args.task_id,
            commit=args.commit,
            receipts_dir=Path(args.receipts_dir),
            receipt_name=args.receipt_name,
            cwd=Path(args.cwd) if args.cwd else None,
        )
    except FileNotFoundError as e:
        print(f"run_gate: commande introuvable : {e}", file=sys.stderr)
        return 127
    except ValueError as e:
        print(f"run_gate: {e}", file=sys.stderr)
        return 2

    # Le receipt est écrit (même en cas d'échec). On propage le VRAI code
    # retour du gate (rc=0 -> 0, rc=7 -> 7, etc.) — transparence totale.
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
