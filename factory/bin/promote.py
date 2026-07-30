#!/usr/bin/env python3
"""
PROMOTION AUTOMATIQUE VÉRIFIANTE — master order Run 4, PHASE P1, fonction 3.

Outil stdlib `promote` qui ne promeut une leçon candidate dans
`memory/lessons.jsonl` QUE si TOUTES les conditions suivantes sont vraies :

  1. les 3 artefacts existent et sont lisibles :
       lesson_candidate.json, gate_receipt.json, codex_review_verdict.json
  2. même task_id  (lesson_candidate == gate_receipt == verdict)
  3. même commit   (lesson_candidate == gate_receipt == verdict)
  4. même projet   (candidate.project == projet du run ; jamais "*")
       + candidate.lesson.source == candidate.project (cohérence interne)
  5. gate_receipt.passed == true  ET  gate_receipt.exit_code == 0
  6. verdict.verdict == "PASS" EXACTEMENT (aucun autre verdict)
  7. le test de régression référencé EXISTE (candidate.regression_test)
  8. la leçon candidate est valide selon lesson_schema.py (validate_lesson)
  9. candidate.project != "*"
 10. pas de doublon d'id dans memory/lessons.jsonl
 11. task packet <= 8 fichiers (borne P1 : candidate.files)

Si UNE SEULE de ces conditions est fausse → REFUS (rc=2), rien n'est écrit.
Si tout est vrai → append de la leçon dans memory/lessons.jsonl (rc=0).

INVARIANTS (master order P1, fonction 3) :
  - Aucune variable d'environnement, aucun flag CLI ne peut FORCER la
    promotion. Seuls les 3 FICHIERS d'artefacts sont des preuves.
  - Le verdict d'env / flag CLI n'est JAMAIS une preuve (fonction 2).
  - `passed` du receipt est recalculé-et-vérifié = (exit_code == 0) ; on ne
    fait JAMAIS confiance à un booléen `passed:true` avec un exit_code != 0.

Stdlib uniquement (règle 1 du master order). Aucune dépendance externe.
"""
import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lesson_schema  # noqa: E402
from record_verdict import load_verdict  # noqa: E402  (P1 fonction 2)

DEFAULT_RECEIPTS_DIR = Path.home() / ".factory-receipts" / "factory-run4-memory"
DEFAULT_MEMORY = Path(__file__).resolve().parents[2] / "memory" / "lessons.jsonl"
DEFAULT_CANDIDATE_NAME = "lesson_candidate.json"
DEFAULT_GATE_NAME = "gate_receipt.json"
DEFAULT_VERDICT_NAME = "codex_review_verdict.json"

MAX_TASK_PACKET_FILES = 8   # borne P1 (master order)
WILDCARD_PROJECT = "*"      # projet interdit (master order : pas de leçon globale)
PASS_VERDICT = "PASS"       # seul verdict que promote accepte


class PromotionRefused(Exception):
    """Une condition de promotion est fausse. Rien n'est écrit."""


class PromotionError(Exception):
    """Erreur technique (artefact illisible, mémoire corrompue, etc.)."""


# ----------------------------------------------------------- chargements
def _load_json_file(path: Path, artefact: str) -> dict:
    if not path.exists():
        raise PromotionRefused(f"artefact {artefact} absent : {path}")
    if not path.is_file():
        raise PromotionRefused(f"artefact {artefact} n'est pas un fichier : {path}")
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise PromotionError(
            f"artefact {artefact} illisible ({path}) : {e}") from e
    if not isinstance(obj, dict):
        raise PromotionError(
            f"artefact {artefact} doit être un objet JSON, eu {type(obj).__name__}")
    return obj


def _run_project(receipts_dir: Path, override: Optional[str] = None) -> str:
    """Projet du run = basename du dossier receipts (surcharge --project).

    Le dossier receipts par défaut est ~/.factory-receipts/factory-run4-memory/
    -> projet "factory-run4-memory". C'est l'autorité du « même projet ».
    """
    if override:
        return override
    return Path(receipts_dir).name


# ------------------------------------------------------- vérif du receipt
def _check_gate_receipt(receipt: dict, task_id: str, commit: str) -> None:
    if receipt.get("task_id") != task_id:
        raise PromotionRefused(
            f"task_id mismatch : candidate={task_id!r} receipt="
            f"{receipt.get('task_id')!r}")
    if receipt.get("commit") != commit:
        raise PromotionRefused(
            f"commit mismatch : candidate={commit!r} receipt="
            f"{receipt.get('commit')!r}")
    exit_code = receipt.get("exit_code")
    passed = receipt.get("passed")
    if not isinstance(exit_code, int):
        raise PromotionRefused(
            f"gate_receipt.exit_code absent ou non-entier : {exit_code!r}")
    # RECALCUL défensif : passed doit valoir (exit_code == 0). On ne fait
    # JAMAIS confiance à un booléen passed:true accolé à un exit_code != 0.
    recomputed_passed = (exit_code == 0)
    if passed is not True:
        raise PromotionRefused(
            f"gate_receipt.passed != true (eu {passed!r}) -> gate échoué")
    if passed != recomputed_passed:
        raise PromotionRefused(
            f"gate_receipt incohérent : passed={passed!r} mais exit_code="
            f"{exit_code!r} (passed DOIT valoir exit_code==0). Refus : un "
            f"receipt truqué ne peut pas promouvoir.")
    if exit_code != 0:
        raise PromotionRefused(
            f"gate_receipt.exit_code={exit_code!r} != 0 -> gate échoué")


def _check_verdict(verdict: dict, task_id: str, commit: str) -> None:
    if verdict.get("task_id") != task_id:
        raise PromotionRefused(
            f"task_id mismatch : candidate={task_id!r} verdict="
            f"{verdict.get('task_id')!r}")
    if verdict.get("commit") != commit:
        raise PromotionRefused(
            f"commit mismatch : candidate={commit!r} verdict="
            f"{verdict.get('commit')!r}")
    v = verdict.get("verdict")
    # verdict exactement "PASS" (record_verdict normalise en MAJUSCULES).
    if v != PASS_VERDICT:
        raise PromotionRefused(
            f"verdict != 'PASS' (eu {v!r}) -> review non passante")


def _check_candidate(candidate: dict) -> Tuple[str, str, str, str, list, dict]:
    """Extrait et valide la structure du lesson_candidate.

    Retourne (task_id, commit, project, regression_test, files, lesson).
    Lève PromotionRefused/PromotionError sur anomalie structurelle.
    """
    for k in ("task_id", "commit", "project", "regression_test", "files", "lesson"):
        if k not in candidate:
            raise PromotionRefused(f"lesson_candidate : champ manquant {k!r}")

    task_id = candidate["task_id"]
    commit = candidate["commit"]
    project = candidate["project"]
    regression_test = candidate["regression_test"]
    files = candidate["files"]
    lesson = candidate["lesson"]

    if not isinstance(task_id, str) or not task_id.strip():
        raise PromotionRefused("lesson_candidate.task_id vide")
    if not isinstance(commit, str) or not commit.strip():
        raise PromotionRefused("lesson_candidate.commit vide")
    if not isinstance(project, str) or not project.strip():
        raise PromotionRefused("lesson_candidate.project vide")
    if not isinstance(regression_test, str) or not regression_test.strip():
        raise PromotionRefused("lesson_candidate.regression_test vide")
    if not isinstance(lesson, dict):
        raise PromotionRefused("lesson_candidate.lesson doit être un objet")
    if not isinstance(files, list) or not all(
            isinstance(f, str) and f.strip() for f in files):
        raise PromotionRefused(
            "lesson_candidate.files doit être une liste de chaînes non vides")
    return task_id, commit, project, regression_test, files, lesson


def evaluate(
    candidate_path: Path,
    gate_path: Path,
    verdict_path: Path,
    memory_path: Path,
    receipts_dir: Path,
    run_project_override: Optional[str] = None,
) -> dict:
    """Évalue la promotion. Retourne un rapport (ne modifie pas la mémoire).

    Lève PromotionRefused si une condition est fausse, PromotionError sur
    erreur technique. Sinon retourne le dict de la leçon à promouvoir.
    """
    run_project = _run_project(receipts_dir, run_project_override)

    candidate = _load_json_file(candidate_path, "lesson_candidate")
    task_id, commit, project, regression_test, files, lesson = _check_candidate(
        candidate)

    # --- borne 4 : task packet <= 8 fichiers ---
    if len(files) > MAX_TASK_PACKET_FILES:
        raise PromotionRefused(
            f"task packet trop grand : {len(files)} fichiers "
            f"(borne P1 = {MAX_TASK_PACKET_FILES})")

    # --- borne « même projet uniquement » ---
    if project == WILDCARD_PROJECT:
        raise PromotionRefused(
            f"project='*' interdit : une leçon ne peut pas être globale "
            f"(doit cibler un projet précis)")
    if project != run_project:
        raise PromotionRefused(
            f"project mismatch : candidate={project!r} run={run_project!r} "
            f"(la leçon n'est pas pour CE projet)")
    if lesson.get("source") != project:
        raise PromotionRefused(
            f"lesson.source ({lesson.get('source')!r}) != project ({project!r}) "
            f": un lesson_candidate doit avoir une cohérence interne projet")

    # --- gate receipt ---
    receipt = _load_json_file(gate_path, "gate_receipt")
    _check_gate_receipt(receipt, task_id, commit)

    # --- verdict artefact ---
    # On charge via load_verdict (P1 fonction 2) pour valider le schéma au
    # passage. Une variable d'env ne serait jamais passée par ici. Un verdict
    # absent/malformé est un REFUS (pas un crash) : la preuve fait défaut.
    try:
        verdict = load_verdict(verdict_path)
    except ValueError as e:
        raise PromotionRefused(f"artefact verdict invalide/absent : {e}") from e
    _check_verdict(verdict, task_id, commit)

    # --- test de régression EXISTANT ---
    rg_path = Path(regression_test)
    # On résout relatif au repo (parent de factory/) si le chemin est relatif.
    if not rg_path.is_absolute():
        repo_root = Path(__file__).resolve().parents[2]
        rg_resolved = repo_root / rg_path
    else:
        rg_resolved = rg_path
    if not rg_resolved.exists() or not rg_resolved.is_file():
        raise PromotionRefused(
            f"test de régression introuvable : {regression_test} "
            f"(résolu {rg_resolved})")

    # --- schéma lesson_schema.py valide ---
    try:
        lesson_schema.validate_lesson(lesson)
    except lesson_schema.LessonError as e:
        raise PromotionRefused(f"leçon invalide (lesson_schema) : {e}") from e

    # --- pas de doublon d'id ---
    # On charge le store EXISTANT via lesson_schema.load_jsonl : cela valide
    # TOUT le fichier au passage (fail-closed : une mémoire corrompue ne peut
    # JAMAIS être promotée — on lève PromotionError AVANT d'écrire quoi que ce
    # soit). Le doublon est ensuite un simple test sur les ids chargés.
    existing_lessons = _load_existing_lessons(memory_path)
    existing_ids = {l["id"] for l in existing_lessons}
    if lesson["id"] in existing_ids:
        raise PromotionRefused(
            f"doublon d'id : {lesson['id']!r} déjà présent dans {memory_path}")

    return {"lesson": lesson, "task_id": task_id, "commit": commit,
            "project": project, "files": files}


def _load_existing_lessons(memory_path: Path) -> list:
    """Charge et valide TOUT le store mémoire (fail-closed sur corruption).

    Lève PromotionError si la mémoire est corrompue (le driver traduira en
    MEMORY_SYSTEM_FAIL). On ne promeut JAMAIS dans un store illisible.
    """
    if not memory_path.exists():
        return []  # mémoire vierge : valide par construction
    try:
        return lesson_schema.load_jsonl(memory_path)
    except lesson_schema.LessonError as e:
        raise PromotionError(
            f"mémoire corrompue ({memory_path}) : {e} -> refus fail-closed "
            f"(MEMORY_SYSTEM_FAIL côté driver)") from e
    except OSError as e:
        raise PromotionError(f"mémoire illisible ({memory_path}) : {e}") from e


def _append_lesson(memory_path: Path, lesson: dict) -> None:
    """Append atomique d'une ligne JSON dans la mémoire (append-only).

    Le store EXISTANT a déjà été validé par _load_existing_lessons (dans
    evaluate), et la leçon candidate par lesson_schema.validate_lesson :
    l'append d'une ligne JSON valide à un store valide reste donc valide.
    On append (O_APPEND POSIX, un seul writer), fsync, puis on relit la
    DERNIÈRE ligne pour confirmer qu'elle parse (sanity bon marché).
    """
    memory_path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(lesson, ensure_ascii=False, sort_keys=True)
    with open(memory_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())
    # Sanity : relire la dernière ligne écrite et confirmer qu'elle redonne
    # exactement la leçon (détecte un disque plein / encoding cassé).
    try:
        with open(memory_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            back = min(size, 65536)
            f.seek(size - back)
            tail = f.read().decode("utf-8", errors="replace").splitlines()
        if not tail or json.loads(tail[-1]) != lesson:
            raise PromotionError(
                "la dernière ligne écrite ne relit pas la leçon attendue — "
                "INSPECTION MANUELLE REQUISE")
    except (OSError, json.JSONDecodeError) as e:
        raise PromotionError(
            f"post-check append échoué (mémoire peut-être corrompue) : {e} "
            f"— INSPECTION MANUELLE REQUISE") from e


# ----------------------------------------------------------------- main
def main(argv: Optional[list] = None) -> int:
    p = argparse.ArgumentParser(
        description=(
            "Promotion automatique vérifiante (Run 4 P1, fonction 3). Lit "
            "lesson_candidate.json + gate_receipt.json + codex_review_verdict.json, "
            "ne promeut dans memory/lessons.jsonl QUE si toutes les conditions "
            "sont vraies (même task_id/commit/projet, passed+exit_code=0, "
            "verdict=PASS exact, test régression existant, schéma valide, "
            "project!='*', pas de doublon, packet<=8). Stdlib uniquement."
        )
    )
    p.add_argument(
        "--candidate",
        help=f"chemin du lesson_candidate.json "
             f"(défaut : <receipts-dir>/{DEFAULT_CANDIDATE_NAME}).",
    )
    p.add_argument(
        "--gate-receipt",
        help=f"chemin du gate_receipt.json "
             f"(défaut : <receipts-dir>/{DEFAULT_GATE_NAME}).",
    )
    p.add_argument(
        "--verdict",
        help=f"chemin du codex_review_verdict.json "
             f"(défaut : <receipts-dir>/{DEFAULT_VERDICT_NAME}).",
    )
    p.add_argument(
        "--receipts-dir", default=str(DEFAULT_RECEIPTS_DIR),
        help=f"dossier receipts (défaut : {DEFAULT_RECEIPTS_DIR}).",
    )
    p.add_argument(
        "--memory", default=str(DEFAULT_MEMORY),
        help=f"fichier mémoire lessons.jsonl (défaut : {DEFAULT_MEMORY}).",
    )
    p.add_argument(
        "--project", default=None,
        help="forcer le projet du run (défaut : basename du dossier receipts). "
             "Un flag CLI ne FORCE jamais la promotion : il ne fait que préciser "
             "l'autorité du projet attendue.",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="évalue sans écrire (utile pour les tests/adversariaux).",
    )
    args = p.parse_args(argv)

    receipts_dir = Path(args.receipts_dir)
    candidate_path = Path(args.candidate) if args.candidate \
        else receipts_dir / DEFAULT_CANDIDATE_NAME
    gate_path = Path(args.gate_receipt) if args.gate_receipt \
        else receipts_dir / DEFAULT_GATE_NAME
    verdict_path = Path(args.verdict) if args.verdict \
        else receipts_dir / DEFAULT_VERDICT_NAME
    memory_path = Path(args.memory)

    try:
        report = evaluate(
            candidate_path=candidate_path,
            gate_path=gate_path,
            verdict_path=verdict_path,
            memory_path=memory_path,
            receipts_dir=receipts_dir,
            run_project_override=args.project,
        )
    except PromotionRefused as e:
        print(f"promote: REFUS — {e}", file=sys.stderr)
        return 2
    except PromotionError as e:
        print(f"promote: ERREUR — {e}", file=sys.stderr)
        return 1

    if args.dry_run:
        print(f"promote: OK (dry-run) — leçon {report['lesson']['id']!r} "
              f"éligible, non écrite")
        return 0

    try:
        _append_lesson(memory_path, report["lesson"])
    except PromotionError as e:
        print(f"promote: ERREUR écriture mémoire — {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"promote: ERREUR écriture mémoire — {e}", file=sys.stderr)
        return 1

    print(f"promote: PROMU — leçon {report['lesson']['id']!r} ajoutée à "
          f"{memory_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
