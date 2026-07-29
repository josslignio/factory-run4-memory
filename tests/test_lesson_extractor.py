"""Test réel de l'extracteur §2 — master order Run 4.

Valide factory/bin/lesson_extractor.py sur critères OBJECTIFS :
  - parse 3 blocs finding réalistes (P1/P2/P3, multiline, sans test) ;
  - chaque leçon extraite passe lesson_schema.validate_lesson ;
  - ids au format L-<ts>-<seq>, séquence stable depuis le rapport ;
  - trigger_pattern normalisé (séparateurs `;`/`,` → `; `) ;
  - evidence contient file:line ET (si test fourni) le nom du test ;
  - reproductibilité : extraction-ts figé → ids identiques ;
  - détection d'erreurs (clé manquante, severity invalide, prose libre
    sans bloc, bloc non refermé, line non entière) ;
  - intégration append : collision d'id refusée (rien écrit) ;
  - intégration CLI : main() lit le fixture, produit 3 leçons sur stdout.

Usage : python3 tests/test_lesson_extractor.py
Stdlib uniquement.
"""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "factory" / "bin"))

import lesson_extractor as ex  # noqa: E402
from lesson_extractor import (  # noqa: E402
    ExtractionError,
    parse_findings,
    build_lesson,
    extract_lessons,
)
from lesson_schema import (  # noqa: E402
    validate_lesson,
    LessonError,
    load_jsonl,
)

FIXTURE = REPO / "tests" / "fixtures" / "review_sample.txt"
FIX_TS = "20260727T160000Z"  # ts figé pour reproductibilité


class TestParse(unittest.TestCase):
    def test_fixture_has_three_blocks(self):
        text = FIXTURE.read_text(encoding="utf-8")
        blocks = parse_findings(text)
        self.assertEqual(len(blocks), 3, f"attendu 3 blocs, eu {len(blocks)}")

    def test_multiline_continuation_joined(self):
        text = FIXTURE.read_text(encoding="utf-8")
        blocks = parse_findings(text)
        # Bloc #1 (P1) : description = 2 lignes indentées → une seule valeur.
        desc = blocks[0]["description"]
        # Les deux morceaux doivent apparaître, sans retour à la ligne.
        self.assertIn("sans masquer SIGINT dans", desc)
        self.assertIn("dans un état mi-écrit.", desc)
        self.assertNotIn("\n", desc)

    def test_header_ignored(self):
        text = FIXTURE.read_text(encoding="utf-8")
        blocks = parse_findings(text)
        # L'en-tête libre ne doit PAS se retrouver dans un bloc.
        for b in blocks:
            for k, v in b.items():
                self.assertNotIn("Ce fichier est un exemple", v)


class TestExtract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = FIXTURE.read_text(encoding="utf-8")
        cls.lessons = extract_lessons(cls.text, extraction_ts=FIX_TS)

    def test_three_lessons_extracted(self):
        self.assertEqual(len(self.lessons), 3)

    def test_all_pass_schema(self):
        for l in self.lessons:
            validate_lesson(l)  # lève si invalide

    def test_ids_deterministic_with_fixed_ts(self):
        again = extract_lessons(self.text, extraction_ts=FIX_TS)
        self.assertEqual([l["id"] for l in self.lessons],
                         [l["id"] for l in again],
                         "ids doivent être reproductibles avec ts figé")
        self.assertEqual([l["id"] for l in self.lessons],
                         [f"L-{FIX_TS}-01",
                          f"L-{FIX_TS}-02",
                          f"L-{FIX_TS}-03"])

    def test_severity_preserved_and_uppercased(self):
        self.assertEqual([l["severity"] for l in self.lessons],
                         ["P1", "P2", "P3"])

    def test_trigger_pattern_normalized_to_semicolon(self):
        # Bloc 1 utilise `;` (déjà ok), bloc 2 utilise `,` → doit devenir `; `.
        t2 = self.lessons[1]["trigger_pattern"]
        self.assertNotIn(",", t2)
        self.assertIn("tempfile", t2)
        self.assertIn("NamedTemporaryFile", t2)

    def test_trigger_dedup_case_insensitive(self):
        # Bloc 3 a 4 mots-clés, aucun doublon → 4 restent.
        t3 = self.lessons[2]["trigger_pattern"].split("; ")
        self.assertEqual(len(t3), len(set(p.lower() for p in t3)))

    def test_evidence_includes_file_line(self):
        from lesson_schema import FILE_LINE_RE
        for l in self.lessons:
            self.assertTrue(FILE_LINE_RE.search(l["evidence"]),
                            f"evidence sans repère file:line : {l['evidence']}")

    def test_evidence_with_and_without_test(self):
        # Bloc 1 et 2 ont un `test:`, bloc 3 n'en a pas.
        self.assertIn("— test:", self.lessons[0]["evidence"])
        self.assertIn("— test:", self.lessons[1]["evidence"])
        self.assertNotIn("— test:", self.lessons[2]["evidence"])

    def test_source_carried_through(self):
        for l in self.lessons:
            self.assertEqual(l["source"], "fixture-run4")


class TestErrors(unittest.TestCase):
    def test_no_block_raises(self):
        with self.assertRaises(ExtractionError):
            extract_lessons("juste de la prose, rien de structuré")

    def test_unclosed_block_raises(self):
        with self.assertRaises(ExtractionError):
            extract_lessons("[FINDING]\nseverity: P1\n")

    def test_missing_required_key_raises(self):
        # category absent.
        bad = ("[FINDING]\nseverity: P1\nfile: a.py\nline: 1\n"
               "description: x\nfix: y\ntrigger_keywords: z\nsource: r\n[/FINDING]\n")
        with self.assertRaises(ExtractionError):
            extract_lessons(bad)

    def test_bad_severity_raises(self):
        bad = ("[FINDING]\nseverity: P9\ncategory: other\nfile: a.py\nline: 1\n"
               "description: x\nfix: y\ntrigger_keywords: z\nsource: r\n[/FINDING]\n")
        with self.assertRaises(ExtractionError):
            extract_lessons(bad)

    def test_bad_category_raises(self):
        bad = ("[FINDING]\nseverity: P1\ncategory: bogus\nfile: a.py\nline: 1\n"
               "description: x\nfix: y\ntrigger_keywords: z\nsource: r\n[/FINDING]\n")
        with self.assertRaises(ExtractionError):
            extract_lessons(bad)

    def test_non_integer_line_raises(self):
        bad = ("[FINDING]\nseverity: P1\ncategory: other\nfile: a.py\nline: abc\n"
               "description: x\nfix: y\ntrigger_keywords: z\nsource: r\n[/FINDING]\n")
        with self.assertRaises(ExtractionError):
            extract_lessons(bad)

    def test_unknown_key_raises(self):
        bad = ("[FINDING]\nseverity: P1\ncategory: other\nfile: a.py\nline: 1\n"
               "description: x\nfix: y\ntrigger_keywords: z\nsource: r\n"
               "bogus_key: hello\n[/FINDING]\n")
        with self.assertRaises(ExtractionError):
            extract_lessons(bad)

    def test_empty_triggers_raises(self):
        bad = ("[FINDING]\nseverity: P1\ncategory: other\nfile: a.py\nline: 1\n"
               "description: x\nfix: y\ntrigger_keywords: ;;,\nsource: r\n[/FINDING]\n")
        with self.assertRaises(ExtractionError):
            extract_lessons(bad)

    def test_bad_extraction_ts_rejected(self):
        with self.assertRaises(ExtractionError):
            extract_lessons(FIXTURE.read_text(encoding="utf-8"),
                            extraction_ts="bad ts with spaces")


class TestAppendIntegration(unittest.TestCase):
    """Intégration réelle : --append sur un lessons.jsonl existant,
    collision d'id refusée (rien écrit), append sain sinon."""

    def setUp(self):
        # Répertoire temporaire isolé (INTERDIT de toucher au vrai memory/).
        self.tmp = tempfile.mkdtemp(prefix="run4_ext_test_")
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        # Nettoyage LOCAL uniquement (règle : pas de rm récursif large).
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_append_then_collision_refused(self):
        base = Path(self.tmp) / "lessons.jsonl"
        # Premier append : écrit 3 leçons (ts figé).
        rc1 = ex.main([str(FIXTURE), "--append", str(base),
                       "--extraction-ts", FIX_TS])
        self.assertEqual(rc1, 0)
        first = load_jsonl(base)
        self.assertEqual(len(first), 3)

        # Deuxième append avec MÊME ts → collision sur tous les ids,
        # RIEN ne doit être écrit, code de retour 1.
        rc2 = ex.main([str(FIXTURE), "--append", str(base),
                       "--extraction-ts", FIX_TS])
        self.assertEqual(rc2, 1, "collision d'id doit échouer (rien écrit)")
        second = load_jsonl(base)
        self.assertEqual(len(second), 3, "le fichier ne doit pas avoir bougé")

    def test_append_with_new_ts_extends(self):
        base = Path(self.tmp) / "lessons.jsonl"
        rc1 = ex.main([str(FIXTURE), "--append", str(base),
                       "--extraction-ts", FIX_TS])
        self.assertEqual(rc1, 0)
        rc2 = ex.main([str(FIXTURE), "--append", str(base),
                       "--extraction-ts", "20260727T170000Z"])
        self.assertEqual(rc2, 0)
        got = load_jsonl(base)
        self.assertEqual(len(got), 6)
        # Tous valides par load_jsonl (qui valide le schéma).

    def test_out_fresh_collision_with_existing_refused(self):
        base = Path(self.tmp) / "lessons.jsonl"
        # Pré-écrire avec un ts différent.
        rc = ex.main([str(FIXTURE), "--out", str(base),
                      "--extraction-ts", "20260727T170000Z"])
        self.assertEqual(rc, 0)
        # Re-tenter avec le MÊME ts sur un fichier existant via --out doit
        # refuser (le fichier existe déjà et contient ces ids).
        rc2 = ex.main([str(FIXTURE), "--out", str(base),
                       "--extraction-ts", "20260727T170000Z"])
        self.assertEqual(rc2, 1)


class TestOutConcurrentSerialization(unittest.TestCase):
    """P1 audit Codex : deux --out concurrents sur le même destination ne
    doivent ni corrompre le fichier ni se perdre silencieusement. Le flock
    partagé avec --append + la re-vérification SOUS verrou garantissent
    qu'un seul process gagne (rc=0) et que l'autre refuse proprement (rc=1)
    — jamais de traceback, jamais de fichier corrompu.

    Preuve RÉELLE par sous-processus parallèles (Popen simultanés), pas par
    mock : on lance deux CLI indépendantes en parallèle sur le même --out."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run4_ext_conc_")
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_two_concurrent_out_same_ids_one_wins_one_refuses(self):
        import subprocess
        base = Path(self.tmp) / "lessons.jsonl"
        # Même ts -> mêmes ids pour les deux process : collision garantie.
        # On lance les deux EN PARALLÈLE (Popen simultanés) pour exercer la
        # course qui, avant le fix, voyait les deux valider l'absence de
        # fichier et écrire le même `.tmp` fixe (écrasement silencieux).
        cli = str(REPO / "factory" / "bin" / "lesson_extractor.py")
        cmd = [sys.executable, cli, str(FIXTURE),
               "--out", str(base), "--extraction-ts", FIX_TS]
        p1 = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        p2 = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        rc1 = p1.wait(timeout=30)
        rc2 = p2.wait(timeout=30)
        # Exactement un des deux doit gagner (rc=0), l'autre doit refuser
        # proprement (rc=1). Jamais rc=2 (traceback) ni double-écriture.
        codes = sorted([rc1, rc2])
        self.assertEqual(codes, [0, 1],
                         f"attendu [0,1] (un gagnant + un refus propre), "
                         f"eu rc1={rc1} rc2={rc2}")
        # Le fichier destination doit être sain (3 leçons valides) — pas
        # corrompu par la course sur le `.tmp`.
        rows = load_jsonl(base)
        self.assertEqual(len(rows), 3)
        # Aucun résidu `.tmp` (mkstemp unique + nettoyage finally).
        leftovers = list(Path(self.tmp).glob("*.tmp"))
        self.assertEqual(leftovers, [], f".tmp résiduels : {leftovers}")


class TestCliStdout(unittest.TestCase):
    def test_main_stdout_emits_jsonl(self):
        # Capture stdout, stderr séparés. main() n'appelle pas sys.exit
        # directement (le wrapper __main__ le fait).
        backup_out, backup_err = sys.stdout, sys.stderr
        sys.stdout = io.StringIO()
        sys.stderr = io.StringIO()
        try:
            rc = ex.main([str(FIXTURE), "--extraction-ts", FIX_TS])
            captured = sys.stdout.getvalue()
        finally:
            sys.stdout, sys.stderr = backup_out, backup_err
        self.assertEqual(rc, 0)
        lines = [l for l in captured.strip().splitlines() if l.strip()]
        self.assertEqual(len(lines), 3)
        for l in lines:
            obj = json.loads(l)  # JSON valide
            self.assertIn("id", obj)
            self.assertTrue(obj["id"].startswith(f"L-{FIX_TS}-"))


# ===================================================================
# P0 finding 1 : --source-tag normalisé, validé, cohérent source/evidence
# ===================================================================
class TestSourceTag(unittest.TestCase):
    """--source-tag doit : strip(), refuser vide/espaces (rc!=0), appliquer
    AVANT la validation finale puis RE-valider, et préserver la cohérence
    source/evidence (evidence commence par '<source>:')."""

    def _run_main_capturing(self, argv):
        backup_out, backup_err = sys.stdout, sys.stderr
        sys.stdout = io.StringIO()
        sys.stderr = io.StringIO()
        try:
            rc = ex.main(argv)
            out = sys.stdout.getvalue()
            err = sys.stderr.getvalue()
        finally:
            sys.stdout, sys.stderr = backup_out, backup_err
        return rc, out, err

    def test_source_tag_empty_refused(self):
        # source-tag vide -> FAIL (rc != 0)
        rc, out, err = self._run_main_capturing(
            [str(FIXTURE), "--extraction-ts", FIX_TS, "--source-tag", ""])
        self.assertNotEqual(rc, 0, f"source-tag vide doit échouer, eu rc={rc}")
        self.assertEqual(out.strip(), "", "rien ne doit être émis sur stdout")

    def test_source_tag_spaces_refused(self):
        # source-tag réduit à des espaces -> FAIL (rc != 0) après strip()
        rc, out, err = self._run_main_capturing(
            [str(FIXTURE), "--extraction-ts", FIX_TS, "--source-tag", "   "])
        self.assertNotEqual(rc, 0, f"source-tag espaces doit échouer, eu rc={rc}")
        self.assertEqual(out.strip(), "")

    def test_source_tag_rewrites_source_and_evidence_prefix(self):
        # CAS COHÉRENT -> PASS : le tag remplace source ET le préfixe
        # d'evidence, la leçon re-validée passe le schéma.
        tag = "new-repo@sha123"
        rc, out, err = self._run_main_capturing(
            [str(FIXTURE), "--extraction-ts", FIX_TS, "--source-tag", tag])
        self.assertEqual(rc, 0, f"source-tag cohérent doit passer, err={err}")
        rows = [json.loads(l) for l in out.strip().splitlines() if l.strip()]
        self.assertEqual(len(rows), 3)
        for r in rows:
            self.assertEqual(r["source"], tag)
            self.assertTrue(r["evidence"].startswith(tag + ":"),
                            f"evidence doit commencer par '{tag}:' : {r['evidence']!r}")
            ex.assert_source_evidence_coherent(r)  # ne lève pas
            validate_lesson(r)  # re-valide -> passe

    def test_source_tag_strips_surrounding_whitespace(self):
        # Le tag entouré d'espaces est normalisé : source == valeur strippée.
        rc, out, err = self._run_main_capturing(
            [str(FIXTURE), "--extraction-ts", FIX_TS,
             "--source-tag", "  trimmed-tag  "])
        self.assertEqual(rc, 0, f"err={err}")
        rows = [json.loads(l) for l in out.strip().splitlines() if l.strip()]
        for r in rows:
            self.assertEqual(r["source"], "trimmed-tag")

    def test_incoherent_source_evidence_detected(self):
        # CAS INCOHÉRENT -> FAIL : on change `source` SANS remettre à jour
        # le préfixe d'evidence. assert_source_evidence_coherent doit lever.
        lessons = extract_lessons(FIXTURE.read_text(encoding="utf-8"),
                                  extraction_ts=FIX_TS)
        lesson = dict(lessons[0])
        old_ev = lesson["evidence"]
        lesson["source"] = "completely-different-source"
        # evidence NON réécrite -> commence encore par l'ancien préfixe.
        self.assertFalse(old_ev.startswith(lesson["source"] + ":"))
        with self.assertRaises(ex.ExtractionError):
            ex.assert_source_evidence_coherent(lesson)

    def test_apply_source_tag_unit_coherent_passes(self):
        # Unitaire : apply_source_tag réécrit source + evidence, cohérent -> OK.
        lessons = extract_lessons(FIXTURE.read_text(encoding="utf-8"),
                                  extraction_ts=FIX_TS)
        lesson = dict(lessons[0])
        ex.apply_source_tag(lesson, "  unit-tag  ")
        self.assertEqual(lesson["source"], "unit-tag")
        self.assertTrue(lesson["evidence"].startswith("unit-tag:"))
        validate_lesson(lesson)  # re-validation passe

    def test_apply_source_tag_unit_empty_refused(self):
        lessons = extract_lessons(FIXTURE.read_text(encoding="utf-8"),
                                  extraction_ts=FIX_TS)
        lesson = dict(lessons[0])
        with self.assertRaises(ex.ExtractionError):
            ex.apply_source_tag(lesson, "   ")


# ===================================================================
# P0 finding 2 : bloc [FINDING][/FINDING] vide -> fail-closed
# ===================================================================
class TestEmptyFindingBlockFailClosed(unittest.TestCase):
    """Un bloc [FINDING][/FINDING] vide fait échouer TOUTE l'extraction."""

    GOOD = ("[FINDING]\nseverity: P1\ncategory: other\nfile: a.py\nline: 1\n"
            "description: x\nfix: y\ntrigger_keywords: z\nsource: r\n"
            "[/FINDING]\n")

    def _valid_block(self, name="b.py", line="2"):
        return (f"[FINDING]\nseverity: P2\ncategory: other\nfile: {name}\n"
                f"line: {line}\ndescription: x\nfix: y\n"
                f"trigger_keywords: z\nsource: r\n[/FINDING]\n")

    def test_one_valid_block_passes(self):
        lessons = extract_lessons(self.GOOD, extraction_ts=FIX_TS)
        self.assertEqual(len(lessons), 1)

    def test_empty_block_fails(self):
        empty = "[FINDING]\n[/FINDING]\n"
        with self.assertRaises(ex.ExtractionError):
            extract_lessons(empty, extraction_ts=FIX_TS)

    def test_valid_plus_empty_fails_whole_extraction(self):
        # Un bloc valide + un bloc vide -> l'extraction entière échoue
        # (fail-closed : on n'ignore pas silencieusement le bloc vide).
        mixed = self.GOOD + "[FINDING]\n[/FINDING]\n"
        with self.assertRaises(ex.ExtractionError):
            extract_lessons(mixed, extraction_ts=FIX_TS)

    def test_empty_block_with_only_blank_lines_fails(self):
        # Un bloc contenant uniquement des lignes vides reste vide (dict={}) .
        blanky = "[FINDING]\n   \n\t\n[/FINDING]\n"
        with self.assertRaises(ex.ExtractionError):
            extract_lessons(blanky, extraction_ts=FIX_TS)

    def test_two_valid_blocks_pass(self):
        two = self._valid_block() + self._valid_block("c.py", "3")
        lessons = extract_lessons(two, extraction_ts=FIX_TS)
        self.assertEqual(len(lessons), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
