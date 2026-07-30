"""Tests adversariaux de la PROMOTION AUTOMATIQUE — master order Run 4, PHASE
P1, fonction 3.

Valide factory/bin/promote.py sur TOUS les cas adversariaux obligatoires
enumeres dans le brief P1 :

  - promotion sans receipt      -> REFUS (rc=2)
  - sans verdict                 -> REFUS (rc=2)
  - mauvais task_id              -> REFUS (rc=2)
  - mauvais commit               -> REFUS (rc=2)
  - verdict autre que PASS       -> REFUS (rc=2)
  - project="*"                  -> REFUS (rc=2)
  - doublon d'id                 -> REFUS (rc=2)
  - exit 7 au gate -> passed=false -> REFUS (rc=2)
  - memoire corrompue            -> arret fail-closed (rc=1, RIEN ecrit)

Plus les bornes et invariants P1 supplementaires :
  - happy path (tout vrai)        -> PROMU (rc=0), ligne appendee
  - task packet > 8 fichiers      -> REFUS
  - project mismatch (autre run)  -> REFUS
  - lesson.source != project      -> REFUS (incoherence interne)
  - test de regression absent     -> REFUS
  - schema lesson_schema invalide -> REFUS
  - receipt truque (passed:true + exit_code=7) -> REFUS (passed RECALCULE)
  - dry-run n'ecrit rien
  - une variable d'environnement ne FORCE JAMAIS la promotion

Stdlib uniquement. Usage : python3 tests/test_promote.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "factory" / "bin"))

import promote as prom  # noqa: E402
import record_verdict as rv  # noqa: E402
from lesson_schema import validate_lesson  # noqa: E402

PROMOTE = REPO / "factory" / "bin" / "promote.py"


def _lesson(project, lid="L-20260730T150000Z-77"):
    """Une leçon canonique valide, `source` == project (cohérence interne)."""
    return {
        "id": lid,
        "date": "2026-07-30",
        "source": project,
        "category": "cli-validation",
        "trigger_pattern": "gate receipt; exit code; subprocess",
        "description": "défaut observé",
        "fix_pattern": "remède générique",
        "severity": "P2",
        "evidence": f"factory/bin/run_gate.py:42 — test: test_x (projet={project})",
    }


def _candidate(project, task_id="T1", commit="abc123",
               regression_test="tests/test_run_gate.py",
               files=None, lesson=None, lid="L-20260730T150000Z-77"):
    """Un lesson_candidate canonique valide."""
    return {
        "task_id": task_id,
        "commit": commit,
        "project": project,
        "regression_test": regression_test,
        "files": files if files is not None else ["factory/bin/run_gate.py"],
        "lesson": lesson if lesson is not None else _lesson(project, lid),
    }


def _receipt(task_id="T1", commit="abc123", exit_code=0, passed=None,
             command=None):
    if passed is None:
        passed = (exit_code == 0)
    return {
        "task_id": task_id, "commit": commit,
        "command": command or ["true"],
        "exit_code": exit_code, "passed": passed,
        "started_at": "2026-07-30T13:00:00Z",
        "finished_at": "2026-07-30T13:00:01Z",
        "stdout_path": "x", "stderr_path": "y",
    }


def _verdict(task_id="T1", commit="abc123", verdict="PASS"):
    return {
        "task_id": task_id, "commit": commit,
        "reviewer": "codex", "verdict": verdict,
        "report_path": "reports/r.md", "timestamp": "2026-07-30T13:00:02Z",
    }


def _write_json(path, obj):
    path.write_text(json.dumps(obj), encoding="utf-8")


class PromoteHarness(unittest.TestCase):
    """Monte un dossier receipts + memoire vierges, expose promote en CLI/Py."""

    def setUp(self):
        self.rd = Path(tempfile.mkdtemp(prefix="run4_promote_"))
        self.run_project = self.rd.name
        self.memory = Path(tempfile.mktemp(prefix="run4_mem_"))
        self.candidate_path = self.rd / "lesson_candidate.json"
        self.gate_path = self.rd / "gate_receipt.json"
        self.verdict_path = self.rd / "codex_review_verdict.json"

    def _setup_valid(self, **overrides):
        """Ecrit 3 artefacts valides + memoire vierge. overrides par artefact."""
        cand = overrides.pop("candidate", None) or _candidate(self.run_project)
        rcpt = overrides.pop("receipt", None) or _receipt()
        verd = overrides.pop("verdict", None) or _verdict()
        _write_json(self.candidate_path, cand)
        _write_json(self.gate_path, rcpt)
        _write_json(self.verdict_path, verd)
        for k, v in overrides.items():
            setattr(self, k, v)

    def _cli(self, *extra, env_extra=None):
        cmd = [sys.executable, str(PROMOTE),
               "--receipts-dir", str(self.rd),
               "--memory", str(self.memory)] + list(extra)
        env = dict(os.environ)
        if env_extra:
            env.update(env_extra)
        return subprocess.run(cmd, capture_output=True, text=True, env=env)

    # helper : compte les lignes non vides de la memoire
    def _mem_lines(self):
        if not self.memory.exists():
            return []
        return [l for l in self.memory.read_text("utf-8").splitlines() if l.strip()]


# -------------------------------------------------------- happy path
class TestHappyPath(PromoteHarness):
    def test_all_valid_promotes(self):
        self._setup_valid()
        r = self._cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("PROMU", r.stdout)
        lines = self._mem_lines()
        self.assertEqual(len(lines), 1, "exactement 1 leçon ajoutée")
        promoted = json.loads(lines[0])
        self.assertEqual(promoted["id"], "L-20260730T150000Z-77")
        # la leçon promotée reste valide selon le schéma (défense en profondeur) :
        validate_lesson(promoted)

    def test_dry_run_writes_nothing(self):
        self._setup_valid()
        r = self._cli("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._mem_lines(), [],
                         "dry-run ne doit RIEN écrire en mémoire")
        self.assertIn("dry-run", r.stdout)


# -------------------------------------------- cas adversariaux OBLIGATOIRES
class TestAdversarialRefusals(PromoteHarness):
    """ Chaque REFUS = rc=2 + RIEN écrit en mémoire. """

    def _assert_refused(self, r):
        self.assertEqual(r.returncode, 2,
                         f"devrait refuser (rc=2). stdout={r.stdout} "
                         f"stderr={r.stderr}")
        self.assertIn("REFUS", r.stderr)
        self.assertEqual(self._mem_lines(), [],
                         "un refus ne doit JAMAIS écrire en mémoire")

    def test_no_receipt_refused(self):
        self._setup_valid()
        self.gate_path.unlink()
        self._assert_refused(self._cli())

    def test_no_verdict_refused(self):
        self._setup_valid()
        self.verdict_path.unlink()
        self._assert_refused(self._cli())

    def test_no_candidate_refused(self):
        self._setup_valid()
        self.candidate_path.unlink()
        self._assert_refused(self._cli())

    def test_bad_task_id_in_receipt_refused(self):
        self._setup_valid(receipt=_receipt(task_id="OTHER"))
        self._assert_refused(self._cli())

    def test_bad_task_id_in_verdict_refused(self):
        self._setup_valid(verdict=_verdict(task_id="OTHER"))
        self._assert_refused(self._cli())

    def test_bad_commit_in_receipt_refused(self):
        self._setup_valid(receipt=_receipt(commit="deadbeef"))
        self._assert_refused(self._cli())

    def test_bad_commit_in_verdict_refused(self):
        self._setup_valid(verdict=_verdict(commit="deadbeef"))
        self._assert_refused(self._cli())

    def test_verdict_fail_refused(self):
        self._setup_valid(verdict=_verdict(verdict="FAIL"))
        self._assert_refused(self._cli())

    def test_verdict_needs_fix_refused(self):
        self._setup_valid(verdict=_verdict(verdict="NEEDS_FIX"))
        self._assert_refused(self._cli())

    def test_verdict_lowercase_pass_refused(self):
        # verdict doit etre EXACTEMENT "PASS" (record_verdict normalise en
        # MAJUSCULES, mais un verdict persiste "pass" doit etre refuse : on
        # n'accepte que la forme exacte).
        self._setup_valid(verdict=_verdict(verdict="pass"))
        self._assert_refused(self._cli())

    def test_project_wildcard_refused(self):
        self._setup_valid(candidate=_candidate(project="*"))
        self._assert_refused(self._cli())

    def test_duplicate_id_refused(self):
        self._setup_valid()
        # pre-remplit la memoire avec la MEME leçon -> doublon.
        seeded = json.dumps(_lesson(self.run_project), ensure_ascii=False)
        self.memory.write_text(seeded + "\n", encoding="utf-8")
        before = self._mem_lines()
        self.assertEqual(len(before), 1, "pré-conditions: 1 leçon en mémoire")
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("REFUS", r.stderr)
        # le refus ne doit JAMAIS ajouter de ligne (le doublon n'est pas appendé) :
        after = self._mem_lines()
        self.assertEqual(len(after), 1, "le doublon ne doit pas être appendé")
        self.assertEqual(after, before,
                         "la mémoire est intouchée en cas de refus")

    def test_exit7_receipt_refused(self):
        # Brief P1 : exit 7 au gate -> passed=false -> REFUS de promotion.
        self._setup_valid(receipt=_receipt(exit_code=7, passed=False))
        self._assert_refused(self._cli())


# --------------------------------------- receipt truque / passed recalculé
class TestTrucatedReceiptRefused(PromoteHarness):
    def test_passed_true_with_exit7_refused(self):
        # Receipt malicieux : passed=true MAIS exit_code=7. promote doit
        # RECALCULER passed=(exit_code==0) et refuser (jamais confiance au
        # booleen). Defense en profondeur : le receipt est la preuve, mais
        # son booleen n'est pas cru aveuglement.
        self._setup_valid(receipt=_receipt(exit_code=7, passed=True))
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("REFUS", r.stderr)
        self.assertEqual(self._mem_lines(), [])

    def test_passed_false_with_exit0_refused(self):
        # Receipt incoherent inverse : exit_code=0 mais passed=false.
        self._setup_valid(receipt=_receipt(exit_code=0, passed=False))
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)


# ----------------------------------------------- bornes supplementaires P1
class TestBoundsAndInvariants(PromoteHarness):
    def test_task_packet_over_8_files_refused(self):
        self._setup_valid(candidate=_candidate(
            self.run_project, files=[f"f{i}.py" for i in range(9)]))
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("REFUS", r.stderr)

    def test_task_packet_exactly_8_files_promotes(self):
        self._setup_valid(candidate=_candidate(
            self.run_project, files=[f"f{i}.py" for i in range(8)]))
        r = self._cli()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_project_mismatch_refused(self):
        # candidate.project != projet du run (basename du dossier receipts).
        self._setup_valid(candidate=_candidate("some-other-project",
                                               lesson=_lesson("some-other-project")))
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_lesson_source_not_project_refused(self):
        # Incoherence interne : project OK mais lesson.source different.
        bad_lesson = _lesson(self.run_project)
        bad_lesson["source"] = "incoherent-source"
        self._setup_valid(candidate=_candidate(
            self.run_project, lesson=bad_lesson))
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_missing_regression_test_refused(self):
        self._setup_valid(candidate=_candidate(
            self.run_project, regression_test="tests/does_not_exist_xyz.py"))
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_invalid_lesson_schema_refused(self):
        bad_lesson = _lesson(self.run_project)
        bad_lesson["severity"] = "P9"  # severity hors schéma
        self._setup_valid(candidate=_candidate(
            self.run_project, lesson=bad_lesson))
        r = self._cli()
        self.assertEqual(r.returncode, 2, r.stderr)


# ------------------------------------------- memoire corrompue = fail-closed
class TestCorruptedMemoryFailClosed(PromoteHarness):
    """ Brief P1 : « memoire corrompue -> arret fail-closed ». """

    def test_corrupted_memory_refuses_and_does_not_write(self):
        self._setup_valid()
        # memoire contenant du JSON invalide :
        self.memory.write_text("{not valid json\n", encoding="utf-8")
        r = self._cli()
        # fail-closed : rc=1 (PromotionError), JAMAIS rc=0, RIEN d'ajoute.
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("corrompue", r.stderr.lower())
        # la memoire n'est pas modifiee (on n'append pas dans un store pourri) :
        self.assertEqual(self.memory.read_text("utf-8"), "{not valid json\n")

    def test_corrupted_memory_duplicate_id_still_fail_closed(self):
        # Meme si l'id serait un doublon, une memoire corrompue doit echouer
        # AVANT de chercher le doublon (fail-closed prioritaire).
        self._setup_valid()
        self.memory.write_text("not json at all\n", encoding="utf-8")
        r = self._cli()
        self.assertEqual(r.returncode, 1)


# --------------------------- une env var / un flag ne FORCE jamais la promotion
class TestNoEnvOrFlagForcing(PromoteHarness):
    def test_env_var_cannot_force_promotion(self):
        # Une variable d'environnement « magique » ne doit RIEN forcer.
        self._setup_valid()
        # on retire le receipt (normalement -> refus) et on tente de forcer
        # via une env var bidon : le refus doit tenir.
        self.gate_path.unlink()
        env = {"FORCE_PROMOTE": "1", "PROMOTE_OVERRIDE": "true",
               "VERDICT": "PASS", "SKIP_GATE": "1"}
        r = self._cli(env_extra=env)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(self._mem_lines(), [])

    def test_env_verdict_cannot_override_file_verdict_FAIL(self):
        # Preuve PRECISE de l'invariant « verdict uniquement par artefact
        # persiste » sur le CONSOMMATEUR promote (audit P1 round-repair).
        # Contrairement a test_env_var_cannot_force_promotion (qui retire
        # AUSSI le gate receipt et n'isole donc pas le verdict), ICI tous les
        # artefacts sont valides et SEUL le verdict FICHIER vaut FAIL. On
        # pollue l'environnement avec VERDICT=PASS (et variantes plausibles) :
        # promote DOIT refuser (le fichier est l'autorite). Si promote lisait
        # l'environnement pour le verdict, il promouvrait (rc=0) et ce test
        # echouerait -> c'est une VRAIE regression test de l'invariant.
        self._setup_valid(verdict=_verdict(verdict="FAIL"))
        env = {"VERDICT": "PASS", "CODEX_VERDICT": "PASS",
               "PROMOTE_VERDICT": "PASS", "REVIEW_VERDICT": "PASS",
               "FORCE_VERDICT": "PASS"}
        r = self._cli(env_extra=env)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("REFUS", r.stderr)
        self.assertEqual(self._mem_lines(), [],
                         "une env-var verdict ne doit JAMAIS promouvoir")

    def test_env_verdict_cannot_override_file_verdict_NEEDS_FIX(self):
        # Variante du precedent : verdict fichier = NEEDS_FIX (non-PASS) avec
        # VERDICT=PASS dans l'env. Refus attendu (env ignore, fichier autorite).
        self._setup_valid(verdict=_verdict(verdict="NEEDS_FIX"))
        r = self._cli(env_extra={"VERDICT": "PASS", "CODEX_VERDICT": "PASS"})
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(self._mem_lines(), [])

    def test_cli_project_flag_does_not_force_promotion(self):
        # --project precise l'autorite du projet attendu, mais ne FORCE pas la
        # promotion : si le receipt est absent, refus quand meme.
        self._setup_valid()
        self.gate_path.unlink()
        r = self._cli("--project", self.run_project)
        self.assertEqual(r.returncode, 2, r.stderr)


# --------------------------------------------- tests de l'API Python directe
class TestEvaluateApi(PromoteHarness):
    def test_evaluate_returns_report_on_success(self):
        self._setup_valid()
        report = prom.evaluate(
            candidate_path=self.candidate_path,
            gate_path=self.gate_path,
            verdict_path=self.verdict_path,
            memory_path=self.memory,
            receipts_dir=self.rd,
        )
        self.assertEqual(report["task_id"], "T1")
        self.assertEqual(report["commit"], "abc123")
        self.assertEqual(report["project"], self.run_project)
        validate_lesson(report["lesson"])

    def test_evaluate_raises_refused_on_bad_task_id(self):
        self._setup_valid(verdict=_verdict(task_id="X"))
        with self.assertRaises(prom.PromotionRefused):
            prom.evaluate(self.candidate_path, self.gate_path,
                          self.verdict_path, self.memory, self.rd)

    def test_evaluate_raises_error_on_corrupt_memory(self):
        self._setup_valid()
        self.memory.write_text("garbage\n", encoding="utf-8")
        with self.assertRaises(prom.PromotionError):
            prom.evaluate(self.candidate_path, self.gate_path,
                          self.verdict_path, self.memory, self.rd)


if __name__ == "__main__":
    unittest.main(verbosity=2)
