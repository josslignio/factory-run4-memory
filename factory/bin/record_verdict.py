#!/usr/bin/env python3
"""
VERDICT REVIEWER ARTEFACT — master order Run 4, PHASE P1, fonction 2.

Écrit le fichier `codex_review_verdict.json` (le SEUL artefact que promote
accepte comme preuve de verdict de review). Schéma (master order P1) :

    {
      "task_id":    str,   # relie au gate receipt + lesson_candidate
      "commit":     str,   # sha du commit reviewé
      "reviewer":   str,   # identité du reviewer (ex: "codex")
      "verdict":    str,   # EXACTEMENT "PASS" ou un verdict non-PASS
      "report_path": str,  # chemin du rapport de review (preuve traçable)
      "timestamp":  str    # ISO8601 UTC
    }

INVARIANT NON NÉGOCIABLE (master order P1, fonction 2) :
  - Une variable d'environnement ou un flag CLI N'EST JAMAIS une preuve de
    verdict. Seul ce FICHIER persisté (lu ensuite par promote) compte.
  - Ce writer ne DECIDE JAMAIS du verdict : il ne fait que PERSISTER le
    verdict fourni par le reviewer (qui peut être PASS ou non-PASS).
    `--verdict PASS` ici ne promeut RIEN : promote vérifie en plus le gate
    receipt (exit_code=0), le test de régression, le schéma, le projet, etc.
  - Le verdict est normalisé en MAJUSCULES sans espaces (PASS / FAIL / etc.),
    MAIS promote n'accepte QUE le verdict exact "PASS".

Stdlib uniquement (règle 1 du master order). Aucune dépendance externe.
"""
import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import List, Optional

DEFAULT_RECEIPTS_DIR = Path.home() / ".factory-receipts" / "factory-run4-memory"
DEFAULT_VERDICT_NAME = "codex_review_verdict.json"

# Verdicts normalisés acceptés par le writer. promote n'accepte QUE "PASS" :
# cette liste large permet au writer de PERSISTÉ un verdict non-PASS (FAIL,
# NEEDS_FIX...) — c'est précisément le cas de refus que promote doit rejeter.
ACCEPTED_VERDICTS = {"PASS", "FAIL", "NEEDS_FIX", "NEEDS-FIX", "BLOCKED", "N/A"}


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


def write_verdict(
    task_id: str,
    commit: str,
    reviewer: str,
    verdict: str,
    report_path: str,
    receipts_dir: Path = DEFAULT_RECEIPTS_DIR,
    verdict_name: str = DEFAULT_VERDICT_NAME,
    timestamp: Optional[str] = None,
) -> Path:
    """Persiste le verdict de review dans codex_review_verdict.json.

    NE décide JAMAIS du verdict : ne fait que PERSISTER celui du reviewer.
    Lève ValueError si un champ obligatoire est vide ou le verdict inconnu.
    """
    for name, val in (("task_id", task_id), ("commit", commit),
                      ("reviewer", reviewer), ("verdict", verdict),
                      ("report_path", report_path)):
        if not isinstance(val, str) or not val.strip():
            raise ValueError(f"record_verdict: champ obligatoire vide : {name!r}")

    normalized = verdict.strip().upper().replace(" ", "_")
    if normalized not in ACCEPTED_VERDICTS:
        raise ValueError(
            f"record_verdict: verdict inconnu {verdict!r} "
            f"(attendu parmi {sorted(ACCEPTED_VERDICTS)})")

    ts = timestamp or _utc_now_iso()
    obj = {
        "task_id": task_id,
        "commit": commit,
        "reviewer": reviewer,
        "verdict": normalized,
        "report_path": report_path,
        "timestamp": ts,
    }
    out = Path(receipts_dir) / verdict_name
    _atomic_write_json(out, obj)
    return out


def load_verdict(path: Path) -> dict:
    """Lit et valide structurellement un verdict persisté.

    Utilisé par promote pour relire l'artefact (jamais une variable d'env).
    Lève ValueError si le fichier manque, est illisible, ou mal formé.
    """
    path = Path(path)
    if not path.exists():
        raise ValueError(f"verdict introuvable : {path}")
    if not path.is_file():
        raise ValueError(f"verdict n'est pas un fichier : {path}")
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise ValueError(f"verdict illisible ({path}) : {e}") from e
    if not isinstance(obj, dict):
        raise ValueError(f"verdict doit être un objet JSON, eu {type(obj).__name__}")
    required = ("task_id", "commit", "reviewer", "verdict", "report_path", "timestamp")
    for k in required:
        if k not in obj:
            raise ValueError(f"verdict : champ manquant {k!r}")
        v = obj[k]
        if not isinstance(v, str) or not v.strip():
            raise ValueError(f"verdict : champ {k!r} vide ou non-chaîne")
    return obj


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description=(
            "Verdict reviewer artefact (Run 4 P1, fonction 2). Persiste "
            "codex_review_verdict.json, le SEUL artefact que promote accepte "
            "comme preuve de verdict. Une variable d'env / un flag CLI ne "
            "sont JAMAIS une preuve. Ce writer ne décide jamais du verdict : "
            "il persiste celui du reviewer."
        )
    )
    p.add_argument("--task-id", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--reviewer", required=True,
                   help="identité du reviewer (ex: codex).")
    p.add_argument("--verdict", required=True,
                   help=f"verdict du reviewer parmi {sorted(ACCEPTED_VERDICTS)}.")
    p.add_argument("--report-path", required=True,
                   help="chemin du rapport de review (preuve traçable).")
    p.add_argument("--receipts-dir", default=str(DEFAULT_RECEIPTS_DIR))
    p.add_argument("--verdict-name", default=DEFAULT_VERDICT_NAME)
    p.add_argument("--timestamp", help="forcer le timestamp ISO8601 (tests).")
    args = p.parse_args(argv)

    try:
        out = write_verdict(
            task_id=args.task_id,
            commit=args.commit,
            reviewer=args.reviewer,
            verdict=args.verdict,
            report_path=args.report_path,
            receipts_dir=Path(args.receipts_dir),
            verdict_name=args.verdict_name,
            timestamp=args.timestamp,
        )
    except ValueError as e:
        print(f"record_verdict: {e}", file=sys.stderr)
        return 2

    print(str(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
