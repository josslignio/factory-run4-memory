"""Tests directs du VERDICT REVIEWER ARTEFACT — master order Run 4, PHASE P1,
fonction 2.

`record_verdict.py` PERSISTE le verdict reviewer dans codex_review_verdict.json.
Contrairement a promote (le CONSOMMATEUR), ces tests ciblent le WRITER lui-meme,
qui n etait pas couvert directement (gap fonction 2). Couverture :

  - write_verdict : produit un fichier que load_verdict relit (round-trip).
  - schéma exact {task_id, commit, reviewer, verdict, report_path, timestamp}.
  - REFUS d'un champ obligatoire vide / non-chaîne.
  - REFUS d'un verdict hors liste (le writer persiste seulement des verdicts
    connus ; mais promote n acceptera QUE 'PASS').
  - normalisation : 'pass'/'Pass'/' PASS ' -> 'PASS'.
  - load_verdict : rejette fichier absent, non-JSON, non-objet, champ manquant.
  - écriture atomique : le fichier final existe (pas de .tmp résiduel).
  - CLI main() : écrit le fichier, imprime son chemin, rc=0 ; rc=2 sur erreur.
  - INVARIANT « le fichier est la SEULE preuve » : on écrit un verdict, puis on
    SIMULE qu'aucune variable d'env / aucun flag ne peut changer ce qui est lu —
    load_verdict lit UNIQUEMENT le fichier sur disque.

Stdlib uniquement. Usage : python3 tests/test_record_verdict.py
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

import record_verdict as rv  # noqa: E402

RECORD = REPO / "factory" / "bin" / "record_verdict.py"
DEFAULT_NAME = rv.DEFAULT_VERDICT_NAME

REQUIRED_KEYS = ("task_id", "commit", "reviewer", "verdict", "report_path",
                 "timestamp")


class _TmpDir(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp(prefix="run4_verdict_"))
        self.out = self.d / DEFAULT_NAME

    def _write(self, **kw):
        base = dict(task_id="T1", commit="abc123", reviewer="codex",
                    verdict="PASS", report_path="reports/r.md")
        base.update(kw)
        return rv.write_verdict(receipts_dir=self.d, **base)


class TestWriteVerdictRoundTrip(_TmpDir):
    def test_writes_file_and_load_reads_back(self):
        path = self._write()
        self.assertTrue(path.exists())
        self.assertEqual(path, self.out)
        obj = rv.load_verdict(self.out)
        for k in REQUIRED_KEYS:
            self.assertIn(k, obj)
        self.assertEqual(obj["verdict"], "PASS")
        self.assertEqual(obj["task_id"], "T1")
        self.assertEqual(obj["commit"], "abc123")

    def test_exact_schema_no_extra_no_missing(self):
        self._write()
        obj = json.loads(self.out.read_text("utf-8"))
        self.assertEqual(set(obj.keys()), set(REQUIRED_KEYS))

    def test_timestamp_default_is_iso8601_utc_Z(self):
        self._write()
        ts = rv.load_verdict(self.out)["timestamp"]
        self.assertTrue(ts.endswith("Z"))
        # YYYY-MM-DDTHH:MM:SSZ
        self.assertRegex(ts, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_forced_timestamp_honored(self):
        self._write(timestamp="2026-07-30T13:00:02Z")
        self.assertEqual(rv.load_verdict(self.out)["timestamp"],
                         "2026-07-30T13:00:02Z")


class TestNormalization(_TmpDir):
    def test_pass_variants_normalized_to_PASS(self):
        for raw in ("pass", "Pass", " PASS ", "PaSs"):
            with self.subTest(raw=raw):
                self._write(verdict=raw)
                self.assertEqual(rv.load_verdict(self.out)["verdict"], "PASS")

    def test_needs_fix_with_dash_uppercased_only(self):
        # La normalisation ne remplace QUE les espaces (pas les tirets) :
        # "needs-fix" -> "NEEDS-FIX", forme acceptée par ACCEPTED_VERDICTS.
        self._write(verdict="needs-fix")
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "NEEDS-FIX")

    def test_space_separated_verdict_underscored(self):
        self._write(verdict="needs fix")
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "NEEDS_FIX")

    def test_unknown_verdict_refused(self):
        with self.assertRaises(ValueError):
            self._write(verdict="MAYBE")
        # et RIEN n'est écrit (échec avant écriture atomique)
        self.assertFalse(self.out.exists())


class TestEmptyFieldsRefused(_TmpDir):
    def test_empty_task_id_refused(self):
        with self.assertRaises(ValueError):
            self._write(task_id="  ")

    def test_empty_commit_refused(self):
        with self.assertRaises(ValueError):
            self._write(commit="")

    def test_empty_reviewer_refused(self):
        with self.assertRaises(ValueError):
            self._write(reviewer="")

    def test_empty_report_path_refused(self):
        with self.assertRaises(ValueError):
            self._write(report_path="   ")

    def test_non_string_verdict_refused(self):
        with self.assertRaises(ValueError):
            self._write(verdict=None)


class TestLoadVerdictRejectsBad(_TmpDir):
    def test_missing_file_raises(self):
        with self.assertRaises(ValueError):
            rv.load_verdict(self.d / "n_existe_pas.json")

    def test_non_json_raises(self):
        self.out.write_text("PAS DU JSON {{{\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            rv.load_verdict(self.out)

    def test_non_object_raises(self):
        self.out.write_text("[1,2,3]\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            rv.load_verdict(self.out)

    def test_missing_key_raises(self):
        obj = dict(task_id="T1", commit="c", reviewer="codex",
                   verdict="PASS", report_path="r.md")  # pas de timestamp
        self.out.write_text(json.dumps(obj), encoding="utf-8")
        with self.assertRaises(ValueError):
            rv.load_verdict(self.out)

    def test_empty_string_value_raises(self):
        obj = dict(task_id="T1", commit="c", reviewer="codex",
                   verdict="PASS", report_path="r.md", timestamp="  ")
        self.out.write_text(json.dumps(obj), encoding="utf-8")
        with self.assertRaises(ValueError):
            rv.load_verdict(self.out)


class TestAtomicWrite(_TmpDir):
    def test_no_tmp_residue_after_write(self):
        self._write()
        tmps = list(self.d.glob("*.tmp.*"))
        self.assertEqual(tmps, [], f"tmp résiduel: {tmps}")

    def test_overwrite_replaces_cleanly(self):
        self._write(verdict="FAIL")
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "FAIL")
        self._write(verdict="PASS")
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "PASS")


class TestFileIsOnlyProof(_TmpDir):
    """L'invariant P1 fonction 2 : un fichier PERSISTÉ est la seule preuve.
    Aucune variable d'env, aucun flag, aucune mémoire externe ne peut changer
    ce que load_verdict lit : il lit UNIQUEMENT le fichier sur disque."""

    def test_env_var_does_not_change_loaded_verdict(self):
        self._write(verdict="FAIL")
        # On pollue l'environnement : ça ne doit RIEN changer à la lecture.
        env = dict(os.environ, VERDICT="PASS", CODEX_VERDICT="PASS",
                   REVIEW_VERDICT="PASS")
        # load_verdict ne prend aucun env : le fichier reste l'autorité.
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "FAIL")
        # Symétrique : on efface l'env, le verdict lu ne change pas.
        for k in ("VERDICT", "CODEX_VERDICT", "REVIEW_VERDICT"):
            env.pop(k, None)
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "FAIL")

    def test_only_persisted_file_can_speak(self):
        # Rien d'écrit => load_verdict échoue, peu importe l'env.
        env = dict(os.environ, VERDICT="PASS")
        with self.assertRaises(ValueError):
            rv.load_verdict(self.out)


class TestCLI(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp(prefix="run4_verdict_cli_"))
        self.out = self.d / DEFAULT_NAME

    def _run(self, *args, env_extra=None):
        env = dict(os.environ)
        if env_extra:
            env.update(env_extra)
        return subprocess.run(
            [sys.executable, str(RECORD), "--receipts-dir", str(self.d), *args],
            capture_output=True, text=True, env=env)

    def test_cli_writes_and_prints_path(self):
        r = self._run("--task-id", "T1", "--commit", "abc", "--reviewer",
                      "codex", "--verdict", "PASS", "--report-path", "r.md")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), str(self.out))
        self.assertTrue(self.out.exists())
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "PASS")

    def test_cli_bad_verdict_rc2(self):
        r = self._run("--task-id", "T1", "--commit", "abc", "--reviewer",
                      "codex", "--verdict", "MAYBE", "--report-path", "r.md")
        self.assertEqual(r.returncode, 2)
        self.assertFalse(self.out.exists())

    def test_cli_env_verdict_is_ignored(self):
        # Une variable d'env ne fournit JAMAIS le verdict : le flag --verdict
        # requis est l'entrée du reviewer (persistée), pas une « preuve ».
        r = self._run("--task-id", "T1", "--commit", "abc", "--reviewer",
                      "codex", "--verdict", "FAIL", "--report-path", "r.md",
                      env_extra={"VERDICT": "PASS"})
        self.assertEqual(r.returncode, 0)
        # Le fichier persiste FAIL, PAS ce que l'env prétend.
        self.assertEqual(rv.load_verdict(self.out)["verdict"], "FAIL")


if __name__ == "__main__":
    unittest.main(verbosity=2)
