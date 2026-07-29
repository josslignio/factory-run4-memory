#!/usr/bin/env python3
"""
Bug detector déterministe pour l'ablation A/B — master order Run 4 §4.

Mix STATIQUE + COMPORTEMENTAL de source Python à la recherche des
anti-patterns CONCRETS couverts par les leçons du bootstrap qui s'appliquent à
la tâche lock_manager + fork-safety. La plupart des règles sont statiques
(regex / présence-absence de tokens). L-16 est vérifiée COMPORTEMENTALEMENT
(exécution de acquire_lock sous faux os/fcntl, comptage réel des fd — cf.
rule_L16) : c'est le comportement réel, pas le texte, qui décide.

  L-01 (P1, concurrency) : lockfile TOCTOU — absent fcntl.flock
  L-05 (P2, resource-leak): release_lock unlink le lockfile
  L-07 (P2, concurrency) : scalaire _LOCK_FD global (pas un dict)
  L-09 (P2, resource-leak): acquire_lock non idempotent
  L-10 (P2, concurrency) : clé dict non canonicalisée (pas de .resolve())
  L-12 (P1, concurrency) : os.fork sans os.register_at_fork
  L-13 (P1, concurrency) : flock(LOCK_UN) dans enfant au lieu de os.close
  L-16 (P2, resource-leak): except BlockingIOError seul (fuite fd) —
        vérifié COMPORTEMENTALEMENT (fermeture réelle du fd, pas le texte)

Les leçons data-validation (L-02/04/06/08/11/14/15/17) concernent les
checkpoints ; la tâche d'ablation est lock_manager seul → non applicables.

Chaque règle est déterministe (regex / présence-absence de tokens) et
produit (status present|absent, evidence fichier:ligne + extrait).

USAGE :
    python3 factory/bin/ablation_checker.py <source.py> [--json] [--md]

Sortie par défaut : Markdown humain. --json : machine. rc=0 quand la mesure
s'exécute ; rc=1 si la source est illisible/introuvable/non-UTF8 (échec
contrôlé, JAMAIS de traceback — la mesure ne peut pas être produite, on ne
l'invente pas). Le checker ne mesure que du code qu'il arrive à lire.
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
    Defect present si fcntl.flock ne PROTÈGE PAS acquire_lock (acquisition
    non atomique au kernel → TOCTOU). La présence de flock n'importe où dans
    le fichier ne suffit PAS : un flock uniquement dans release_lock ne
    protège pas l'acquisition (contre-audit Claude/Codex round 2). Fix L-01
    = fcntl.flock DANS le corps de acquire_lock."""
    body = _func_body(code, "acquire_lock")
    if body:
        if re.search(r"\bfcntl\.flock\s*\(", body):
            ln = _body_abs_line(code, "acquire_lock",
                                _line_of(r"\bfcntl\.flock\s*\(", body))
            return Finding("L-20260727T150500Z-01", "concurrency", "P1", "absent",
                           f"{path}:{ln} {_line_content(orig, ln)}",
                           "flock protège acquire_lock (acquisition atomique kernel)")
        ln = _body_abs_line(
            code, "acquire_lock",
            _line_of(r"O_EXCL|os\.unlink|O_CREAT|\bos\.open\s*\(", body)
        ) or _line_of(r"\bdef\s+acquire_lock\b", code)
        ev = f"{path}:{ln} {_line_content(orig, ln) or '(acquire_lock sans flock → TOCTOU)'}"
        return Finding("L-20260727T150500Z-01", "concurrency", "P1", "present",
                       ev, "acquire_lock non protégé par fcntl.flock() → verrou non atomique kernel")
    # Pas de acquire_lock isolable : repli conservateur sur présence fichier.
    has_flock = bool(re.search(r"\bfcntl\.flock\s*\(", code))
    if has_flock:
        return Finding("L-20260727T150500Z-01", "concurrency", "P1", "absent",
                       f"{path}: (flock présent — pas de acquire_lock isolé)",
                       "présence de fcntl.flock()")
    return Finding("L-20260727T150500Z-01", "concurrency", "P1", "present",
                   f"{path}: (aucun flock — acquisition non atomique kernel)",
                   "absence de fcntl.flock() → verrou non atomique kernel")


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


def _func_body(code: str, funcname: str) -> str:
    """Extrait le corps source d'une fonction `def funcname(...)` jusqu'à
    la prochaine def/class au même niveau d'indentation (ou fin de fichier).

    Indispensable pour que L-09/L-16 n'aillent PAS chercher des patterns
    (`for ... in`, `except OSError`) dans d'autres fonctions (hook fork,
    release_lock...) — sinon faux positifs qui créditent à tort arm B.
    """
    m = re.search(
        r"(?ms)^[ \t]*def\s+" + re.escape(funcname) + r"\s*\([^)]*\)\s*(?:->[^:]+)?:\n",
        code)
    if not m:
        return ""
    start = m.end()
    # Déterminer l'indentation du corps (lignes non vides suivantes).
    after = code[start:]
    indent = ""
    for line in after.splitlines(True):
        if line.strip() == "":
            continue
        stripped = line.lstrip(" \t")
        indent = line[: len(line) - len(stripped)]
        break
    if not indent:
        return after
    # Le corps = toutes les lignes indentées d'au moins `indent` (+ lignes
    # vides), jusqu'à la première ligne non vide moins indentée.
    body_lines = []
    for line in after.splitlines(True):
        if line.strip() == "":
            body_lines.append(line)
            continue
        if line.startswith(indent) or line[: len(indent)] == indent:
            body_lines.append(line)
        else:
            break
    return "".join(body_lines)


def _body_abs_line(code: str, funcname: str, rel_ln: int) -> int:
    """Convertit un numéro de ligne `rel_ln` RELATIF au corps de `funcname`
    (tel que produit par `_line_of` sur le `body` extrait par `_func_body`)
    en numéro de ligne absolu du fichier (1-indexé). 0 si rel_ln==0.

    `_func_body` démarre le corps juste APRÈS la ligne `def funcname(...):`,
    donc la 1ʳᵉ ligne du corps = (ligne du def) + 1. L'ancien calcul
    (`code[:code.find('def X')].count('\\n')`) oubliait ce +1 → evidence
    décalée d'une ligne (cf. contre-audit Claude/Codex round 2, P2 rule 4)."""
    if not rel_ln:
        return 0
    defoff = code.find("def " + funcname)
    if defoff < 0:
        return rel_ln
    return rel_ln + code[:defoff].count("\n") + 1


def rule_L09(code: str, orig: str, path: str) -> Finding:
    """L-09 (P2, resource-leak) : acquire_lock non idempotent.
    Defect present si acquire_lock existe mais ne court-circuite pas un
    chemin déjà détenu. Détection STRUCTURELLE SCOPE-AWARE : on n'analyse
    QUE le corps de acquire_lock (pas le hook fork ni release_lock)."""
    if not re.search(r"\bdef\s+acquire_lock\b", code):
        return Finding("L-20260727T150500Z-09", "resource-leak", "P2",
                       "absent", f"{path}: (pas de acquire_lock)",
                       "acquire_lock absent — non applicable")
    body = _func_body(code, "acquire_lock")
    # Idempotence = early-return quand le chemin est déjà en cache,
    # testé DANS acquire_lock avant le os.open.
    has_idem = bool(re.search(r"\bin\s+[A-Za-z_]\w*", body) or
                    re.search(r"\.\s*get\s*\(", body))
    ret_pos = body.find("return")
    open_pos = body.find("os.open")
    early_return = ret_pos >= 0 and (open_pos < 0 or ret_pos < open_pos)
    if has_idem or early_return:
        ln = _line_of(r"(\.\s*get\s*\(|\bin\s+[A-Za-z_]\w*)", body)
        # _line_of travaille sur `body` (décalage) ; on convertit en absolu.
        abs_ln = _body_abs_line(code, "acquire_lock", ln)
        return Finding("L-20260727T150500Z-09", "resource-leak", "P2",
                       "absent", f"{path}:{abs_ln} {_line_content(orig, abs_ln)}",
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
    """L-12 (P1, concurrency) : fork-safety absente ou INCORRECTE.

    Le fix_pattern exact (leçon L-12, arm_b) = os.register_at_fork(
    after_in_child=<hook>) où le hook ferme les fds hérités (os.close) PUIS
    vide le dict process-local (.clear()) dans l'enfant seulement.

    Defect 'present' si l'une de :
      - os.register_at_fork n'est JAMAIS appelé (enfant hérite fds + dict) ;
      - register_at_fork présent SANS after_in_child nommé identifiable ;
      - le hook after_in_child est vide/introuvable (no-op) ;
      - le hook ne ferme PAS les fds (pas d'os.close) ;
      - le hook ne vide PAS le dict (pas de .clear()).

    La présence seule de register_at_fork ne suffit PAS (un hook no-op serait
    faussement crédité — contre-audit Codex/Claude round 2, P1 central pour
    la métrique A/B)."""
    m = re.search(r"os\.register_at_fork\s*\(([^)]*)\)", code)
    if not m:
        return Finding("L-20260727T150500Z-12", "concurrency", "P1", "present",
                       f"{path}: (AUCUN register_at_fork — enfant hérite fds + dict)",
                       "absence de os.register_at_fork()")
    reg_ln = _line_of(r"os\.register_at_fork\s*\(", code)
    hm = re.search(r"after_in_child\s*=\s*([A-Za-z_]\w*)", m.group(1))
    if not hm:
        return Finding("L-20260727T150500Z-12", "concurrency", "P1", "present",
                       f"{path}:{reg_ln} {_line_content(orig, reg_ln)}",
                       "register_at_fork sans after_in_child identifiable")
    hook_name = hm.group(1)
    hook_body = _func_body(code, hook_name)
    if not hook_body or not hook_body.strip():
        ln = _line_of(rf"\bdef\s+{re.escape(hook_name)}\b", code) or reg_ln
        return Finding("L-20260727T150500Z-12", "concurrency", "P1", "present",
                       f"{path}:{ln} {_line_content(orig, ln)}",
                       f"hook after_in_child '{hook_name}' vide/no-op — enfant hérite l'état")
    has_close = bool(re.search(r"\bos\.close\s*\(", hook_body))
    has_clear = bool(re.search(r"\.\s*clear\s*\(", hook_body))
    if has_close and has_clear:
        return Finding("L-20260727T150500Z-12", "concurrency", "P1", "absent",
                       f"{path}:{reg_ln} {_line_content(orig, reg_ln)}",
                       f"hook after_in_child '{hook_name}' ferme les fds (os.close) "
                       f"ET vide le dict (.clear())")
    missing = []
    if not has_close:
        missing.append("os.close")
    if not has_clear:
        missing.append(".clear()")
    ln = _line_of(rf"\bdef\s+{re.escape(hook_name)}\b", code) or reg_ln
    return Finding("L-20260727T150500Z-12", "concurrency", "P1", "present",
                   f"{path}:{ln} {_line_content(orig, ln)}",
                   f"hook after_in_child '{hook_name}' incomplet (sans "
                   f"{' et '.join(missing)}) — fork-safety partielle")


def rule_L13(code: str, orig: str, path: str) -> Finding:
    """L-13 (P1, concurrency) : LOCK_UN dans le hook post-fork ENFANT.

    CORRIGE (contre-audit Codex, review finale Run 4) : l'ancienne version
    marquait TOUT LOCK_UN du fichier comme defaut P1 — y compris l'usage
    LEGITIME de liberation dans release_lock — ce qui gonflait
    artificiellement le comptage du bras A de l'ablation. La semantique
    reelle de la lecon L-13 est : *dans le hook enfant post-fork*, utiliser
    os.close (qui ne libere que la reference de CE processus), jamais
    LOCK_UN (qui deverrouille la file description PARTAGEE avec le parent).

    Le defaut n'est donc 'present' que si un hook after_in_child
    identifiable contient LOCK_UN. Sans hook post-fork du tout, c'est L-12
    qui porte le defaut de fork-safety — pas de double comptage."""
    m = re.search(r"os\.register_at_fork\s*\(([^)]*)\)", code)
    if not m:
        return Finding("L-20260727T150500Z-13", "concurrency", "P1",
                       "absent",
                       f"{path}: (pas de hook post-fork — l'absence de "
                       f"fork-safety est portee par L-12 ; un LOCK_UN hors "
                       f"hook enfant est l'usage legitime de release)",
                       "aucun hook after_in_child ; LOCK_UN hors contexte "
                       "enfant = liberation normale, pas un defaut")
    hm = re.search(r"after_in_child\s*=\s*([A-Za-z_]\w*)", m.group(1))
    if not hm:
        return Finding("L-20260727T150500Z-13", "concurrency", "P1",
                       "absent",
                       f"{path}: (register_at_fork sans after_in_child "
                       f"nomme identifiable)",
                       "hook enfant non identifiable — non applicable")
    hook_name = hm.group(1)
    hook_body = _func_body(code, hook_name)
    if not hook_body:
        return Finding("L-20260727T150500Z-13", "concurrency", "P1",
                       "absent",
                       f"{path}: (corps du hook {hook_name} introuvable)",
                       "corps du hook enfant introuvable — non applicable")
    ln_rel = _line_of(r"\bLOCK_UN\b", hook_body)
    if ln_rel:
        abs_ln = _body_abs_line(code, hook_name, ln_rel)
        return Finding("L-20260727T150500Z-13", "concurrency", "P1",
                       "present",
                       f"{path}:{abs_ln} {_line_content(orig, abs_ln)}",
                       f"LOCK_UN dans le hook enfant {hook_name} -> "
                       f"deverrouille la file description partagee du parent")
    return Finding("L-20260727T150500Z-13", "concurrency", "P1", "absent",
                   f"{path}: (hook {hook_name} sans LOCK_UN — utilise "
                   f"os.close)",
                   f"hook enfant {hook_name} propre (pas de LOCK_UN)")


def _measure_acquire_lock_fd_closure(src: str):
    """Mesure COMPORTEMENTALE (P0 finding 4) : exécute la fonction
    `acquire_lock` extraite du source sous des faux modules `os`/`fcntl` où
    `fcntl.flock` lève une OSError NON-BlockingIOError (= le chemin de fuite
    que L-16 doit détecter), et compte les fd ouverts/fermés.

    Renvoie :
      - True  si le fd issu de `os.open` est RÉELLEMENT fermé (filet sûr) ;
      - False si le fd fuit (filet large sans fermeture réelle, fermeture
        mortelle `if False: os.close(fd)`, ou .close() sur une ressource sans
        rapport avec le fd) ;
      - None  si la mesure comportementale est impossible (source non
        exécutable sous les fakes, os.open non atteint...).

    Pourquoi l'exécution plutôt que le texte : un mutant `except OSError:
    if False: os.close(fd); return False` contient l'occurrence textuelle
    `os.close(fd)` mais ne ferme JAMAIS le fd en réalité (contre-audit Codex).
    Seul le COMPORTEMENT RÉEL compte — exigence explicite du finding 4.

    Sandbox : exec dans un espace de noms frais, `__import__` intercepté pour
    que `import os`/`import fcntl` retournent des fakes (aucun effet de bord
    OS réel, aucune ressource OS touchée, aucun register_at_fork réel). Le
    source exécuté est celui du fichier analysé : PAS une réimplémentation
    recopiée."""
    import builtins

    class _Tracker:
        def __init__(self):
            self.opens = 0
            self.closes = 0

        def opened(self):
            self.opens += 1
            return 100 + self.opens

        def closed(self, fd):
            self.closes += 1

    tracker = _Tracker()

    class _Wrap:
        # Wrapper retourné par fake os.fdopen : .close()/contexte comptabilise
        # la fermeture du fd sous-jacent (c'est le `with os.fdopen(fd)` crédité).
        def __init__(self, fd):
            self._fd = fd

        def close(self):
            tracker.closed(self._fd)

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            tracker.closed(self._fd)

    class _FakeOs:
        O_CREAT = O_WRONLY = O_EXCL = O_RDWR = 0

        def open(self, path, flags):
            return tracker.opened()

        def close(self, fd):
            return tracker.closed(fd)

        def fdopen(self, fd, *a, **k):
            return _Wrap(fd)

        def register_at_fork(self, **kw):
            return None

        def unlink(self, path):
            return None

    class _FakeFcntl:
        LOCK_EX = LOCK_NB = LOCK_UN = 0

        @staticmethod
        def flock(fd, flags):
            # OSError NON-BlockingIOError : c'est précisément le chemin de
            # fuite (BlockingIOError est une sous-classe ; OSError elle-même
            # ne l'est pas -> remonte jusqu'au filet large, s'il existe).
            raise OSError("simulated non-blocking oserror (leak path)")

    fake_os = _FakeOs()
    real_import = builtins.__import__

    def _import(name, *a, **k):
        if name == "os":
            return fake_os
        if name == "fcntl":
            return _FakeFcntl
        return real_import(name, *a, **k)

    bi = dict(vars(builtins))
    bi["__import__"] = _import
    g = {"__builtins__": bi, "__name__": "uut"}
    try:
        exec(compile(src, "<acquire_lock_uut>", "exec"), g)
    except BaseException:
        return None
    acq = g.get("acquire_lock")
    if not callable(acq):
        return None
    try:
        acq("x.lock")
    except OSError:
        pass  # version sûre : relance l'OSError APRÈS os.close(fd)
    except BaseException:
        return None
    if tracker.opens == 0:
        return None  # os.open non atteint -> non mesurable
    return tracker.closes >= tracker.opens


def rule_L16(code: str, orig: str, path: str) -> Finding:
    """L-16 (P2, resource-leak) : except BlockingIOError SANS fermeture réelle.

    P0 finding 4 : un filet large (`except BaseException/Exception/OSError` ou
    `finally`) n'est crédité sûr QUE s'il ferme RÉELLEMENT le fd dans
    acquire_lock. C'est le COMPORTEMENT RÉEL qui compte — PAS le texte.

    Trois mutants portant une fermeture « textuelle » mais fuyant en réalité,
    que la règle DOIT marquer DEFECT (present) :
      - `except OSError: return False` (aucun close) ;
      - `except OSError: _unrelated.close()` (close sur une ressource sans
        rapport avec le fd issu de os.open) ;
      - `except OSError: if False: os.close(fd); return False` (fermeture
        MORTELLE — contre-audit Codex : l'occurrence textuelle crédite à tort
        une analyse purement lexicale).

    Décision :
      1. pas d'acquire_lock / pas de `except BlockingIOError` isolé -> absent
         (non applicable : L-16 cible spécifiquement ce pattern) ;
      2. `except BlockingIOError` SANS filet large -> present (fuite
         déterministe sur toute autre OSError — cas des bras A et B réels) ;
      3. filet large présent -> mesure COMPORTEMENTALE
         (_measure_acquire_lock_fd_closure) : absent SEULEMENT si le fd est
         RÉELLEMENT fermé.

    Scope-aware : on ne regarde QUE le corps de acquire_lock (un `except
    OSError` dans le hook fork ne compte pas — sinon faux positif crédité)."""
    body = _func_body(code, "acquire_lock")
    if not body:
        return Finding("L-20260727T150500Z-16", "resource-leak", "P2",
                       "absent", f"{path}: (pas de acquire_lock)",
                       "acquire_lock absent — non applicable")
    ln_rel = _line_of(r"except\s+BlockingIOError", body)
    if not ln_rel:
        return Finding("L-20260727T150500Z-16", "resource-leak", "P2",
                       "absent",
                       f"{path}: (pas de except BlockingIOError dans acquire_lock)",
                       "aucun except BlockingIOError isolé dans acquire_lock")
    # offset absolu pour evidence (corps démarre APRÈS la ligne `def`)
    abs_ln = _body_abs_line(code, "acquire_lock", ln_rel)
    # Filet large = except BaseException/Exception/OSError OU finally.
    has_wide = bool(re.search(r"except\s+(BaseException|Exception|OSError)", body)
                    or re.search(r"\bfinally\s*:", body))
    if not has_wide:
        # Cas déterministe (bras A et B réels) : seul BlockingIOError est
        # attrapé -> toute autre OSError après os.open fuit le fd.
        return Finding("L-20260727T150500Z-16", "resource-leak", "P2", "present",
                       f"{path}:{abs_ln} {_line_content(orig, abs_ln)}",
                       "acquire_lock : except BlockingIOError SANS filet large "
                       "→ fuite fd sur toute autre OSError")
    # Filet large présent : seule une mesure COMPORTEMENTALE prouve la fermeture
    # RÉELLE. L'analyse textuelle créditerait à tort une fermeture mortelle
    # (`if False: os.close(fd)`) ou un .close() sur une ressource sans rapport
    # (contre-audit Codex, round 4).
    closed = _measure_acquire_lock_fd_closure(orig)
    if closed is True:
        return Finding("L-20260727T150500Z-16", "resource-leak", "P2", "absent",
                       f"{path}:{abs_ln} {_line_content(orig, abs_ln)}",
                       "filet large ET fermeture RÉELLE du fd prouvée "
                       "comportementalement (exécution sous faux os/fcntl)")
    return Finding("L-20260727T150500Z-16", "resource-leak", "P2", "present",
                   f"{path}:{abs_ln} {_line_content(orig, abs_ln)}",
                   "acquire_lock : filet large SANS fermeture RÉELLE du fd "
                   "(mesure comportementale : le fd fuit sur une OSError non "
                   "bloquante) → fuite fd")


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

    # Lecture protégée (contre-audit : la source peut être illisible ou non
    # UTF-8 — read_text lèverait alors UnicodeDecodeError/OSError et ferait
    # planter le checker, cœur de la mesure A/B, en traceback). On traduit en
    # rc=1 contrôlé : la mesure ne peut pas être produite, on ne l'invente pas.
    try:
        findings = check_file(path)
    except (OSError, UnicodeDecodeError) as e:
        print(f"ablation_checker: source {path} illisible/non-UTF8 — "
              f"{type(e).__name__}: {e} (mesure impossible, rc=1)", file=sys.stderr)
        return 1
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
