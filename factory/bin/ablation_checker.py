#!/usr/bin/env python3
"""
Bug detector déterministe pour l'ablation A/B — master order Run 4 §4.

Scan STATIQUE de source Python (aucune exécution du code testé) à la
recherche des anti-patterns CONCRETS couverts par les leçons du bootstrap
qui s'appliquent à la tâche lock_manager + fork-safety :

  L-01 (P1, concurrency) : lockfile TOCTOU — absent fcntl.flock
  L-05 (P2, resource-leak): release_lock unlink le lockfile
  L-07 (P2, concurrency) : scalaire _LOCK_FD global (pas un dict)
  L-09 (P2, resource-leak): acquire_lock non idempotent
  L-10 (P2, concurrency) : clé dict non canonicalisée (pas de .resolve())
  L-12 (P1, concurrency) : os.fork sans os.register_at_fork
  L-13 (P1, concurrency) : flock(LOCK_UN) dans enfant au lieu de os.close
  L-16 (P2, resource-leak): except BlockingIOError seul (fuite fd)

Les leçons data-validation (L-02/04/06/08/11/14/15/17) concernent les
checkpoints ; la tâche d'ablation est lock_manager seul → non applicables.

Chaque règle est déterministe (regex / présence-absence de tokens) et
produit (status present|absent, evidence fichier:ligne + extrait).

USAGE :
    python3 factory/bin/ablation_checker.py <source.py> [--json] [--md]

Sortie par défaut : Markdown humain. --json : machine. rc=0 toujours
(le checker ne « fail » pas ; il mesure).
"""
import argparse
import io
import json
import re
import sys
import tokenize
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import List


# ------------------------------------------------------------------- règle
@dataclass
class Finding:
    lesson_id: str
    category: str
    severity: str
    status: str          # "present" (défaut) | "absent" (correctement évité)
    evidence: str        # fichier:ligne + extrait court
    rule: str            # description de la règle déterministe


def _line_of(pattern: str, src: str, flags: int = 0) -> int:
    """Premier numéro de ligne (1-indexé) où pattern matche, 0 si rien."""
    m = re.search(pattern, src, flags)
    if not m:
        return 0
    return src.count("\n", 0, m.start()) + 1


def _line_content(src: str, lineno: int, ctx: int = 0) -> str:
    """Contenu de la ligne `lineno` (1-indexé) du source ORIGINAL (avec
    commentaires, pour qu'un humain lise l'extrait réel), tronqué."""
    lines = src.splitlines()
    if lineno < 1 or lineno > len(lines):
        return ""
    return lines[lineno - 1].strip()[:100]


def _code_only(src: str) -> str:
    """Retourne le source en ayant BLANCHI commentaires et contenus de
    strings (tokens COMMENT/STRING), pour éviter les faux positifs quand
    un mot-clé technique (LOCK_UN, os.unlink, register_at_fork…) n'apparaît
    que dans un commentaire ou une docstring.

    Préserve la structure de lignes (les numéros de ligne sont intacts) en
    remplaçant chaque caractère blanchi par une espace. Utilise `tokenize`
    (stdlib) pour une découpe correcte ; en cas d'échec (syntaxe invalide),
    repli sur un stripper de commentaires `#` au niveau ligne.
    """
    out = list(src)
    try:
        tokens = tokenize.generate_tokens(io.StringIO(src).readline)
        for tok in tokens:
            if tok.type in (tokenize.COMMENT, tokenize.STRING):
                start_off = _offset_of(src, tok.start)
                end_off = _offset_of(src, tok.end)
                for i in range(start_off, min(end_off, len(out))):
                    if out[i] != "\n":
                        out[i] = " "
    except (tokenize.TokenError, IndentationError, SyntaxError):
        # Repli : stripper `#` naïf (commentaires de ligne).
        cleaned = []
        for line in src.splitlines(True):
            hash_idx = line.find("#")
            if hash_idx >= 0:
                line = line[:hash_idx] + " " * (len(line) - hash_idx)
            cleaned.append(line)
        return "".join(cleaned)
    return "".join(out)


def _offset_of(src: str, pos) -> int:
    """Convertit une position (row, col) de tokenize en offset absolu."""
    row, col = pos[0], pos[1]
    offset = 0
    for _ in range(row - 1):
        nl = src.find("\n", offset)
        offset = nl + 1 if nl >= 0 else len(src)
    return offset + col


# --------------------------------------------------------- les 8 règles
# Chaque règle retourne un Finding avec status present/absent.
# `code` = source sans commentaires/strings (pour matcher sans faux positif).
# `orig` = source original (pour extraire l'evidence lisible par humain).
# `path` = nom de fichier pour evidence.

def rule_L01(code: str, orig: str, path: str) -> Finding:
    """L-01 (P1, concurrency) : lockfile TOCTOU.
    Defect present si fcntl.flock n'est JAMAIS appelé (acquisition non
    atomique au kernel → TOCTOU possible). Fix L-01 = fcntl.flock."""
    has_flock = bool(re.search(r"\bfcntl\.flock\s*\(", code))
    if has_flock:
        return Finding("L-20260727T150500Z-01", "concurrency", "P1", "absent",
                       f"{path}: (flock présent — acquisition atomique kernel)",
                       "présence de fcntl.flock()")
    ln = _line_of(r"O_EXCL|os\.unlink|O_CREAT", code)
    ev = f"{path}:{ln} {_line_content(orig, ln) or '(pas de flock, pas de O_EXCL/unlink non plus)'}"
    return Finding("L-20260727T150500Z-01", "concurrency", "P1", "present",
                   ev, "absence de fcntl.flock() → verrou non atomique kernel")


def rule_L05(code: str, orig: str, path: str) -> Finding:
    """L-05 (P2, resource-leak) : release_lock unlink le lockfile.
    Defect present si os.unlink est appelé (le fichier de lock doit
    PERSISTER, seul le flock compte)."""
    ln = _line_of(r"os\.unlink\s*\(", code)
    if ln:
        return Finding("L-20260727T150500Z-05", "resource-leak", "P2",
                       "present", f"{path}:{ln} {_line_content(orig, ln)}",
                       "os.unlink() présent → fichier de lock supprimé")
    return Finding("L-20260727T150500Z-05", "resource-leak", "P2", "absent",
                   f"{path}: (aucun os.unlink — fichier persistant)",
                   "aucun os.unlink()")


def rule_L07(code: str, orig: str, path: str) -> Finding:
    """L-07 (P2, concurrency) : scalaire _LOCK_FD global (un seul fd).
    Defect STRUCTUREL present si AUCUNE assignation dict `<name>[<key>] =`
    n'existe (le fd est stocké en scalaire → un seul verrou possible).
    Indépendant du nom de variable (équité de mesure entre bras A et B)."""
    # N'importe quelle assignation dict (directe `d[k]=os.open` ou via temp
    # `fd=os.open; d[k]=fd`) suffit à prouver le stockage multi-verrous.
    has_dict_store = bool(
        re.search(r"(?m)^[ \t]*[A-Za-z_]\w*\s*\[[^\]]+\]\s*=", code))
    has_open = bool(re.search(r"os\.open\s*\(", code))
    if has_dict_store:
        ln = _line_of(r"(?m)^[ \t]*[A-Za-z_]\w*\s*\[[^\]]+\]\s*=", code)
        return Finding("L-20260727T150500Z-07", "concurrency", "P2",
                       "absent", f"{path}:{ln} {_line_content(orig, ln)}",
                       "fd stocké dans un dict [clé] (multi-verrous supporté)")
    if has_open:
        # os.open présent mais aucun stockage dict → scalaire implicite.
        ln = _line_of(r"os\.open\s*\(", code)
        return Finding("L-20260727T150500Z-07", "concurrency", "P2",
                       "present", f"{path}:{ln} {_line_content(orig, ln)}",
                       "aucun stockage dict [clé] → fd scalaire (un seul verrou)")
    return Finding("L-20260727T150500Z-07", "concurrency", "P2", "absent",
                   f"{path}: (pas de os.open évident)",
                   "pas de os.open détecté — non applicable")


def _acquire_param(code: str):
    """Retourne le nom du paramètre chemin de acquire_lock, ou None."""
    m = re.search(r"\bdef\s+acquire_lock\s*\(\s*(?:self\s*,\s*)?([A-Za-z_]\w*)",
                  code)
    return m.group(1) if m else None


def rule_L09(code: str, orig: str, path: str) -> Finding:
    """L-09 (P2, resource-leak) : acquire_lock non idempotent.
    Defect present si acquire_lock existe mais ne court-circuite pas un
    chemin déjà détenu. Détection STRUCTURELLE (indépendante du nom du
    dict) : cherche un test d'appartenance / .get() dans le corps."""
    if not re.search(r"\bdef\s+acquire_lock\b", code):
        return Finding("L-20260727T150500Z-09", "resource-leak", "P2",
                       "absent", f"{path}: (pas de acquire_lock)",
                       "acquire_lock absent — non applicable")
    # Idempotence = early-return quand le chemin est déjà en cache.
    # Patterns structurels : `if <x> in <dict>`, `<dict>.get(<x>`,
    # `if <x> in self.<dict>`, retour anticipé avant os.open.
    has_idem = bool(re.search(r"\bin\s+[A-Za-z_]\w*(\.[A-Za-z_]\w*)?\b",
                              code) or
                    re.search(r"\.\s*get\s*\(\s*[A-Za-z_]\w*", code))
    # Plus précis : un return True/le-fd AVANT le os.open dans acquire_lock.
    acq_match = re.search(r"\bdef\s+acquire_lock\b.*?(?=\ndef\s|\Z)",
                          code, re.DOTALL)
    early_return = False
    if acq_match:
        body = acq_match.group(0)
        # Y a-t-il un `return` avant le premier os.open ?
        ret_pos = body.find("return")
        open_pos = body.find("os.open")
        if ret_pos >= 0 and (open_pos < 0 or ret_pos < open_pos):
            early_return = True
    if has_idem or early_return:
        ln = _line_of(r"(\.\s*get\s*\(|\bin\s+[A-Za-z_]\w*)", code)
        return Finding("L-20260727T150500Z-09", "resource-leak", "P2",
                       "absent", f"{path}:{ln} {_line_content(orig, ln)}",
                       "acquire_lock idempotent (cache testé avant ouverture)")
    ln = _line_of(r"\bdef\s+acquire_lock\b", code)
    return Finding("L-20260727T150500Z-09", "resource-leak", "P2", "present",
                   f"{path}:{ln} {_line_content(orig, ln)}",
                   "acquire_lock sans cache check → double acquire = fuite fd")


def rule_L10(code: str, orig: str, path: str) -> Finding:
    """L-10 (P2, concurrency) : clé dict non canonicalisée.
    Defect present si le paramètre chemin de acquire_lock est utilisé
    DIRECTEMENT comme clé de dict (sans Path.resolve()/realpath au préalable).
    Détection STRUCTURELLE (indépendante du nom du dict) pour équité de
    mesure."""
    param = _acquire_param(code)
    if not param:
        return Finding("L-20260727T150500Z-10", "concurrency", "P2",
                       "absent", f"{path}: (pas de acquire_lock)",
                       "acquire_lock absent — non applicable")
    # Canonicalisation présente ?
    has_canon = bool(re.search(r"\.resolve\s*\(", code) or
                     re.search(r"os\.path\.realpath\s*\(", code))
    # Le paramètre est-il utilisé comme clé brute ?
    raw_key = bool(re.search(r"\[[\s]*" + re.escape(param) + r"[\s]*\]",
                             code))
    if not raw_key:
        return Finding("L-20260727T150500Z-10", "concurrency", "P2",
                       "absent", f"{path}: ({param} pas utilisé comme clé dict brute)",
                       "paramètre chemin pas clé de dict — non applicable")
    if has_canon:
        ln = _line_of(r"(\.resolve\s*\(|os\.path\.realpath\s*\()", code)
        return Finding("L-20260727T150500Z-10", "concurrency", "P2",
                       "absent", f"{path}:{ln} {_line_content(orig, ln)}",
                       f"clé canonicalisée (resolve/realpath) avant indexation")
    ln = _line_of(r"\[[\s]*" + re.escape(param) + r"[\s]*\]", code)
    return Finding("L-20260727T150500Z-10", "concurrency", "P2", "present",
                   f"{path}:{ln} {_line_content(orig, ln)}",
                   f"clé dict = paramètre brut '{param}' (pas de resolve) → "
                   f"mismatch relatif/absolu")


def rule_L12(code: str, orig: str, path: str) -> Finding:
    """L-12 (P1, concurrency) : os.fork sans register_at_fork.
    La tâche exige la sécurité fork. Defect present si
    os.register_at_fork n'est JAMAIS appelé."""
    has_reg = bool(re.search(r"os\.register_at_fork\s*\(", code))
    if has_reg:
        ln = _line_of(r"os\.register_at_fork\s*\(", code)
        return Finding("L-20260727T150500Z-12", "concurrency", "P1",
                       "absent", f"{path}:{ln} {_line_content(orig, ln)}",
                       "register_at_fork appelé → enfant ne libère pas le verrou parent")
    return Finding("L-20260727T150500Z-12", "concurrency", "P1", "present",
                   f"{path}: (AUCUN register_at_fork — enfant hérite fds + dict)",
                   "absence de os.register_at_fork()")


def rule_L13(code: str, orig: str, path: str) -> Finding:
    """L-13 (P1, concurrency) : flock(LOCK_UN) dans enfant au lieu de os.close.
    Defect present si LOCK_UN est référencé en code (un hook enfant doit
    utiliser os.close, pas LOCK_UN qui déverrouille le parent)."""
    ln = _line_of(r"\bLOCK_UN\b", code)
    if ln:
        return Finding("L-20260727T150500Z-13", "concurrency", "P1",
                       "present", f"{path}:{ln} {_line_content(orig, ln)}",
                       "LOCK_UN présent → déverrouille la file description partagée parent/enfant")
    return Finding("L-20260727T150500Z-13", "concurrency", "P1", "absent",
                   f"{path}: (aucun LOCK_UN — enfant utiliserait os.close)",
                   "aucun LOCK_UN en code")


def rule_L16(code: str, orig: str, path: str) -> Finding:
    """L-16 (P2, resource-leak) : except BlockingIOError seul.
    Defect present si `except BlockingIOError` apparaît SANS un filet
    large (finally ou except BaseException/Exception + os.close) couvrant
    les autres OSError (ENOTSUP etc. → fuite fd)."""
    ln = _line_of(r"except\s+BlockingIOError", code)
    if not ln:
        return Finding("L-20260727T150500Z-16", "resource-leak", "P2",
                       "absent", f"{path}: (pas de except BlockingIOError isolé)",
                       "aucun except BlockingIOError isolé")
    has_wide = bool(re.search(r"except\s+(BaseException|Exception|OSError)", code) or
                    re.search(r"finally\s*:\s*\n\s*os\.close", code))
    if has_wide:
        ln2 = _line_of(r"except\s+(BaseException|Exception|OSError)", code)
        return Finding("L-20260727T150500Z-16", "resource-leak", "P2",
                       "absent",
                       f"{path}:{ln2 or ln} {_line_content(orig, ln2 or ln)}",
                       "filet large présent (finally/except large + close)")
    return Finding("L-20260727T150500Z-16", "resource-leak", "P2", "present",
                   f"{path}:{ln} {_line_content(orig, ln)}",
                   "except BlockingIOError seul → fuite fd sur autre OSError")


RULES = (rule_L01, rule_L05, rule_L07, rule_L09, rule_L10,
         rule_L12, rule_L13, rule_L16)


# ------------------------------------------------------------- runner
def check_file(path: Path) -> List[Finding]:
    orig = path.read_text(encoding="utf-8")
    code = _code_only(orig)  # commentaires/strings blanchis (pas de faux positif)
    return [r(code, orig, str(path)) for r in RULES]


def summarize(findings: List[Finding]) -> dict:
    present = [f for f in findings if f.status == "present"]
    cats = {f.category for f in present}
    p1 = [f for f in present if f.severity == "P1"]
    avoided = [f for f in findings if f.status == "absent"]
    return {
        "total_defects": len(present),
        "distinct_categories_with_defect": len(cats),
        "categories_with_defect": sorted(cats),
        "p1_defects": len(p1),
        "p1_defect_ids": [f.lesson_id for f in p1],
        "covered_lessons_avoided": len(avoided),
        "total_applicable_lessons": len(findings),
    }


def render_md(label: str, findings: List[Finding], stats: dict) -> str:
    lines = [f"## Bras {label}", ""]
    lines.append(f"- anti-patterns applicables : **{stats['total_applicable_lessons']}**")
    lines.append(f"- défauts présents : **{stats['total_defects']}** "
                 f"(dont **{stats['p1_defects']} P1**)")
    lines.append(f"- catégories distinctes touchées : "
                 f"**{stats['distinct_categories_with_defect']}** "
                 f"{stats['categories_with_defect']}")
    lines.append(f"- leçons couvertes correctement évitées : "
                 f"**{stats['covered_lessons_avoided']}**/"
                 f"{stats['total_applicable_lessons']}")
    lines.append("")
    lines.append("| leçon | sév. | catégorie | statut | evidence |")
    lines.append("|-------|------|-----------|--------|----------|")
    for f in findings:
        mark = "DEFECT" if f.status == "present" else "ok"
        ev = f.evidence.replace("|", "\\|")
        lines.append(f"| {f.lesson_id} | {f.severity} | {f.category} | "
                     f"**{mark}** | `{ev}` |")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("source", help="fichier Python à scanner")
    p.add_argument("--json", action="store_true", help="sortie JSON machine")
    p.add_argument("--md", action="store_true", help="sortie Markdown (défaut)")
    p.add_argument("--label", default="", help="étiquette bras (A/B)")
    args = p.parse_args(argv)

    path = Path(args.source)
    if not path.is_file():
        print(f"ablation_checker: {path} n'est pas un fichier", file=sys.stderr)
        return 1

    findings = check_file(path)
    stats = summarize(findings)

    if args.json:
        out = {"label": args.label, "source": str(path),
               "findings": [asdict(f) for f in findings], "stats": stats}
        sys.stdout.write(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    else:
        sys.stdout.write(render_md(args.label or path.stem, findings, stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
