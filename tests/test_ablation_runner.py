"""Test réel du runner d'ablation (P0 finding 5 + contre-audit Codex P1 #1).

Le rapport reports/RUN4_ABLATION_AB.md admettait qu'AUCUN script n'écrivait
le journal ABLATION_RUN_LOG.txt (recopie manuelle) -> l'exécution réelle des
chiffres n'était pas prouvée, seulement leur reproductibilité. Ce test prouve
que ablation/run_ablation.sh :

  - exécute RÉELLEMENT le checker déterministe sur les deux bras ;
  - APPEND automatiquement un bloc daté (UTC + hash HEAD) au journal ;
  - rafraîchit arm_{a,b}_measurements.json (JSON valides, schéma stats) ;
  - émet un verdict honnête basé sur les chiffres réels ;
  - n'écrit JAMAIS en truncate sur le journal (append-only par convention) ;
  - ne construit AUCUN chaînage cryptographique (interdit par P0 finding 5).

Le journal et les JSON sont redirigés vers un répertoire temporaire via les
env RUN_ABLATION_* -> AUCUNE pollution du journal/JSON commités.

Usage : python3 -m pytest tests/test_ablation_runner.py -q
Stdlib uniquement.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "ablation" / "run_ablation.sh"
ARM_A = REPO / "ablation" / "arm_a_lock_manager.py"
ARM_B = REPO / "ablation" / "arm_b_lock_manager.py"


class TestAblationRunner(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run4_abl_runner_")
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self):
        # Redirige TOUTES les sorties vers le temp dir : journal + 2 JSON.
        # Le journal démarre VIDE (pas de contenu commité) pour mesurer
        # précisément ce que le script append.
        env = dict(os.environ)
        env["RUN_ABLATION_LOG"] = str(Path(self.tmp) / "run.log")
        env["RUN_ABLATION_JSON_A"] = str(Path(self.tmp) / "a.json")
        env["RUN_ABLATION_JSON_B"] = str(Path(self.tmp) / "b.json")
        proc = subprocess.run(
            ["bash", str(SCRIPT)], env=env, capture_output=True, text=True,
            cwd=str(REPO), timeout=60)
        return proc

    def test_script_executes_and_appends_dated_block(self):
        proc = self._run()
        self.assertEqual(proc.returncode, 0,
                         f"runner rc={proc.returncode} stderr={proc.stderr}")
        log_path = Path(self.tmp) / "run.log"
        self.assertTrue(log_path.exists(), "le journal doit être créé")
        content = log_path.read_text(encoding="utf-8")
        # Un bloc daté '===== RUN <ISO8601>Z =====' est présent.
        self.assertIn("===== RUN ", content,
                      "un bloc daté doit être appendé")
        self.assertIn("Repo HEAD:", content,
                      "le repère de commit (reproductibilité) doit figurer")
        # Les deux bras ont été exécutés (les deux commandes sont consignées).
        self.assertIn("arm_a_lock_manager.py --json", content)
        self.assertIn("arm_b_lock_manager.py --json", content)
        # Verdict consolidé présent.
        self.assertIn("VERDICT:", content)
        # AUCUN chaînage cryptographique (interdit par P0 finding 5) : pas de
        # mention de hash-chain / signature / seal dans le bloc produit.
        low = content.lower()
        for forbidden in ("chain", "chaine", "signature", "seal", "hmac"):
            self.assertNotIn(forbidden, low,
                             f"le journal ne doit pas évoquer de chaînage/"
                             f"scellement crypto (interdit) : '{forbidden}'")

    def test_measurements_json_valid_and_consistent(self):
        proc = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        a = json.load(open(Path(self.tmp) / "a.json"))
        b = json.load(open(Path(self.tmp) / "b.json"))
        for d in (a, b):
            self.assertIn("stats", d)
            st = d["stats"]
            for k in ("total_defects", "p1_defects",
                      "distinct_categories_with_defect"):
                self.assertIn(k, st)
            self.assertEqual(st["total_applicable_lessons"], 8)
        # Verdict honnête : bras B meilleur (p1 1->0 ET total 5->2) — ce sont
        # les chiffres RÉELS re-mesurés par cette exécution, pas une constante.
        self.assertLess(b["stats"]["p1_defects"], a["stats"]["p1_defects"])
        self.assertLess(b["stats"]["total_defects"], a["stats"]["total_defects"])

    def test_journal_is_append_only_convention(self):
        # Le script doit APPEND (>>), jamais truncate : deux exécutions
        # successives accumulent DEUX blocs (aucune perte du premier).
        self._run()
        self._run()
        content = (Path(self.tmp) / "run.log").read_text(encoding="utf-8")
        n = content.count("===== RUN ")
        self.assertEqual(n, 2,
                         f"append-only : 2 runs -> 2 blocs, eu {n}")

    def test_committed_log_not_polluted_by_test(self):
        # Garde-fou : ce test ne doit JAMAIS écrire dans le journal commité.
        # On snapshot le nombre de blocs avant/après un run de test.
        committed = REPO / "ablation" / "ABLATION_RUN_LOG.txt"
        before = committed.read_text(encoding="utf-8").count("===== RUN ")
        self._run()
        after = committed.read_text(encoding="utf-8").count("===== RUN ")
        self.assertEqual(before, after,
                         "le test a pollué le journal commité (interdit)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
