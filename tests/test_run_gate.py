"""Tests adversariaux du GATE RECEIPT REEL — master order Run 4, PHASE P1, fonction 1.

Valide factory/bin/run_gate.py sur les exigences EXACTES du brief P1 :
  - execute la VRAIE commande gate (sous-processus reel, jamais un booleen) ;
  - `passed` est CALCULE `exit_code == 0` — JAMAIS hardcode, JAMAIS fourni ;
  - le VRAI code retour est propage (rc=0 -> 0, rc=7 -> 7) ;
  - le receipt gate_receipt.json est ecrit hors du repo, avec le schema exact
    {task_id, commit, command, exit_code, passed, started_at, finished_at,
     stdout_path, stderr_path} ;
  - stdout/stderr sont capturés dans des fichiers du dossier receipts.

Test adversarial obligatoire (brief P1) couvert ici :
  - exit 7 au gate -> passed=false ET code retour 7 propage.

Stdlib uniquement. Usage : python3 tests/test_run_gate.py
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

import run_gate as rg  # noqa: E402

RUN_GATE = REPO / "factory" / "bin" / "run_gate.py"

REQUIRED_RECEIPT_FIELDS = {
    "task_id", "commit", "command", "exit_code", "passed",
    "started_at", "finished_at", "stdout_path", "stderr_path",
}


def _run(args, receipts_dir):
    """Invoque run_gate.py en CLI avec --receipts-dir force hors repo."""
    cmd = [sys.executable, str(RUN_GATE),
           "--task-id", "T1", "--commit", "abc123",
           "--receipts-dir", str(receipts_dir)] + args
    return subprocess.run(cmd, capture_output=True, text=True)


class TestReceiptSchemaAndLocation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run4_gate_")
        self.rd = Path(self.tmp)

    def test_rc0_passes_and_receipt_has_exact_schema(self):
        r = _run(["--", "true"], self.rd)
        self.assertEqual(r.returncode, 0, r.stderr)
        rcpt = json.loads((self.rd / "gate_receipt.json").read_text("utf-8"))
        # Schema EXACT du brief P1 (ni plus ni moins sur ces 9 cles) :
        self.assertEqual(set(rcpt.keys()), REQUIRED_RECEIPT_FIELDS)
        # Liens task_id/commit propages tels quels (reliage verdict/candidate) :
        self.assertEqual(rcpt["task_id"], "T1")
        self.assertEqual(rcpt["commit"], "abc123")
        # INVARIANT : passed == (exit_code == 0), calcule, jamais hardcode :
        self.assertEqual(rcpt["exit_code"], 0)
        self.assertIs(rcpt["passed"], True)
        # Timestamps ISO8601 UTC presents et coherents :
        self.assertTrue(rcpt["started_at"])
        self.assertTrue(rcpt["finished_at"])
        self.assertLessEqual(rcpt["started_at"], rcpt["finished_at"])
        # Commande reelle executee (audit reproductible) :
        self.assertEqual(rcpt["command"], ["true"])
        # Captures dans le dossier receipts (hors repo) :
        for key in ("stdout_path", "stderr_path"):
            p = Path(rcpt[key])
            self.assertTrue(p.is_file(), f"{key} pas un fichier: {p}")
            self.assertEqual(p.parent, self.rd)

    def test_receipt_written_outside_repo(self):
        # Le receipt ne doit JAMAIS atterrir dans le worktree git. On verifie
        # qu'aucun gate_receipt.json n'est cree dans le repo.
        r = _run(["--", "true"], self.rd)
        self.assertEqual(r.returncode, 0)
        self.assertFalse((REPO / "gate_receipt.json").exists(),
                         "le receipt a fuite dans le repo (interdit)")
        self.assertTrue((self.rd / "gate_receipt.json").exists())

    def test_stdout_stderr_captured_to_files(self):
        # Une commande qui produit du stdout ET du stderr : les captures les
        # recoivent integralement (pas de fuite vers le terminal du pilote).
        script = ("echo OUT_LINE; echo ERR_LINE 1>&2")
        r = _run(["--", "sh", "-c", script], self.rd)
        self.assertEqual(r.returncode, 0, r.stderr)
        rcpt = json.loads((self.rd / "gate_receipt.json").read_text("utf-8"))
        self.assertIn("OUT_LINE", Path(rcpt["stdout_path"]).read_text("utf-8"))
        self.assertIn("ERR_LINE", Path(rcpt["stderr_path"]).read_text("utf-8"))
        # Le stdout du wrapper lui-meme ne contient PAS la sortie du gate :
        self.assertNotIn("OUT_LINE", r.stdout)


class TestExitCodePropagation(unittest.TestCase):
    """ Brief P1 : « exit 7 au gate -> passed=false et code propage ». """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run4_gate_")
        self.rd = Path(self.tmp)

    def test_exit7_propagated_and_passed_false(self):
        r = _run(["--", "sh", "-c", "exit 7"], self.rd)
        # Le VRAI code retour est propage tel quel (transparence totale) :
        self.assertEqual(r.returncode, 7, r.stderr)
        rcpt = json.loads((self.rd / "gate_receipt.json").read_text("utf-8"))
        self.assertEqual(rcpt["exit_code"], 7)
        # passed calcule = (exit_code == 0) = False, JAMAIS True sur un echec :
        self.assertIs(rcpt["passed"], False)

    def test_exit1_passed_false(self):
        r = _run(["--", "false"], self.rd)
        self.assertEqual(r.returncode, 1)
        rcpt = json.loads((self.rd / "gate_receipt.json").read_text("utf-8"))
        self.assertIs(rcpt["passed"], False)
        self.assertEqual(rcpt["exit_code"], 1)

    def test_passed_is_always_calculated_not_asserted(self):
        # On execute plusieurs codes retour et on verifie l'invariant exact :
        # passed == (exit_code == 0) sur toute la gamme, sans exception.
        for code in (0, 1, 2, 7, 42, 127, 255):
            rd = Path(tempfile.mkdtemp(prefix="run4_gate_"))
            r = _run(["--", "sh", "-c", f"exit {code}"], rd)
            self.assertEqual(r.returncode, code,
                             f"rc non propage pour exit {code}")
            rcpt = json.loads((rd / "gate_receipt.json").read_text("utf-8"))
            self.assertEqual(rcpt["exit_code"], code)
            self.assertEqual(rcpt["passed"], (code == 0),
                             f"passed mal calcule pour exit {code}")


class TestNoHardcodedPass(unittest.TestCase):
    """ INVARIANT NON NEGOCIABLE : jamais de PASS hardcode, jamais de booleen
        fourni par l'appelant. """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run4_gate_")
        self.rd = Path(self.tmp)

    def _cheat_refused(self, flag):
        r = _run([flag, "--", "true"], self.rd)
        self.assertNotEqual(r.returncode, 0,
                            f"{flag} aurait du etre refuse (rc!=0)")
        # Le receipt n'est pas ecrit (refus avant execution) :
        self.assertFalse((self.rd / "gate_receipt.json").exists(),
                         f"{flag} a provoque l'ecriture d'un receipt")
        self.assertIn("REFUS", r.stderr)
        self.assertIn("triche", r.stderr.lower())

    def test_passed_flag_refused(self):
        self._cheat_refused("--passed")

    def test_no_passed_flag_refused(self):
        self._cheat_refused("--no-passed")

    def test_force_pass_refused(self):
        self._cheat_refused("--force-pass")

    def test_pass_alias_refused(self):
        self._cheat_refused("--pass")

    def test_no_hidden_override_writes_true(self):
        # Meme un --passed combine a un gate ECHEC ne doit JAMAIS produire
        # passed=true : le wrapper refuse avant d'executer quoi que ce soit.
        r = _run(["--passed", "--", "sh", "-c", "exit 7"], self.rd)
        self.assertEqual(r.returncode, 2)
        self.assertFalse((self.rd / "gate_receipt.json").exists())

    def test_unknown_argument_refused(self):
        # Aucune option cachee de contournement : un flag inconnu est refuse.
        r = _run(["--please-say-pass", "--", "true"], self.rd)
        self.assertNotEqual(r.returncode, 0)


class TestRealSubprocessExecution(unittest.TestCase):
    """ Le gate court dans un VRAI sous-processus : on ne peut pas simuler le
        code retour, il est lu sur le fils reel. """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run4_gate_")
        self.rd = Path(self.tmp)

    def test_command_not_found_is_failure_not_pass(self):
        # Un binaire inexistant : on ne PASSE jamais. run_gate consigne un
        # echec reel (rc 127 / FileNotFoundError) et ne renvoie jamais 0.
        r = _run(["--", "/ce/binaire/nexiste/pas"], self.rd)
        self.assertNotEqual(r.returncode, 0)

    def test_receipt_truncated_between_runs(self):
        # Un receipt precedent ne doit pas survivre a un nouveau run : les
        # captures stdout/stderr sont tronquees preventivement (un run sans
        # sortie ne lit pas la sortie du run precedent par erreur).
        rd = Path(tempfile.mkdtemp(prefix="run4_gate_"))
        _run(["--", "sh", "-c", "echo LEGACY_STDOUT"], rd)
        rcpt1 = json.loads((rd / "gate_receipt.json").read_text("utf-8"))
        self.assertIn("LEGACY_STDOUT",
                      Path(rcpt1["stdout_path"]).read_text("utf-8"))
        # 2e run silencieux : la capture stdout doit etre vide (tronquee).
        r2 = _run(["--", "true"], rd)
        self.assertEqual(r2.returncode, 0)
        rcpt2 = json.loads((rd / "gate_receipt.json").read_text("utf-8"))
        self.assertEqual(Path(rcpt2["stdout_path"]).read_text("utf-8").strip(),
                         "")


class TestRunGateFunction(unittest.TestCase):
    """ Tests de l'API Python directe (run_gate.run_gate), utiles pour promote. """

    def test_run_gate_returns_tuple_exit_and_path(self):
        rd = Path(tempfile.mkdtemp(prefix="run4_gate_"))
        code, rcpt_path = rg.run_gate(
            command=["true"], task_id="T-API", commit="cafef00d",
            receipts_dir=rd)
        self.assertEqual(code, 0)
        self.assertTrue(rcpt_path.is_file())
        rcpt = json.loads(rcpt_path.read_text("utf-8"))
        self.assertEqual(rcpt["task_id"], "T-API")
        self.assertEqual(rcpt["commit"], "cafef00d")
        self.assertIs(rcpt["passed"], True)

    def test_run_gate_empty_command_rejected(self):
        rd = Path(tempfile.mkdtemp(prefix="run4_gate_"))
        with self.assertRaises(ValueError):
            rg.run_gate(command=[], task_id="T", commit="c", receipts_dir=rd)


if __name__ == "__main__":
    unittest.main(verbosity=2)
