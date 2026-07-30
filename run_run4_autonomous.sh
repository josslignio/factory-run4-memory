#!/usr/bin/env bash
# Pilote headless Run #4 (Mémoire / Experience Compiler).
# GLM (via opencode, zai-coding-plan) construit ; Codex review chaque tranche
# (avis indépendant, lecture seule) et fait l'audit final exhaustif.
# (Relevé 30/07 Jocelyn : Claude retiré de la boucle de review/audit — Codex seul.)
# Ne s'arrête jamais tout seul sauf état terminal explicite.
#
# ATTENTION AVANT DE LANCER EN LONGUE DURÉE — deux smoke-tests de 30s à faire d'abord (UN PAR UN,
# jamais collés ensemble — piège zsh des collages multi-lignes) :
#   opencode run --model zai-coding-plan/glm-5.2 "dis juste OK et rien d'autre"
#   codex exec "dis juste OK et rien d'autre"
# Si les deux répondent et rendent la main sans rester bloqués en attente d'input, les commandes
# ci-dessous sont bonnes. Sinon adapte-les selon ce qui marche réellement.
# RÈGLE ABSOLUE MODÈLE : toujours zai-coding-plan/* (abonnement), JAMAIS zai/* (API au compteur).
# `opencode models` du 27/07 confirme que zai-coding-plan/glm-5.2 existe ; sans --model explicite,
# le CLI partait sur glm-5v-turbo (défaut dangereux) — d'où le flag forcé partout ci-dessous.
# `codex login status` a déjà confirmé la connexion ChatGPT ; `codex exec` est le mode non-interactif
# usuel de la CLI Codex, à vérifier quand même avec le smoke-test ci-dessus.
#
# FIXES P1 (post-review Run #4 tranche 0) — voir DECISIONS_AUTONOMOUS.md D-001..D-005 :
#   D-001 (Codex#1) : branche run4/build forcée, main jamais touchée par GLM.
#   D-002 (Claude#2): reviewers en lecture seule technique (--allowedTools Read/Grep/Glob
#                     pour claude, -s read-only pour codex), diff embarqué dans le prompt.
#   D-003 (Claude#1): contrat d'état cohérent (prompt = valeur seule ; lecteur tolérant au préfixe).
#   D-004 (Codex#2) : audit final gating — non-PASS -> retour RUNNING (round de
#                     repair) au lieu de WAITING_HUMAN_BOSS_GO. Budget repair
#                     courant = MAX_P0_REPAIR=30 / MAX_P1_REPAIR=30 (relevé 30/07
#                     Jocelyn ; plus bas à l'origine). AUTORITÉ UNIQUE : § MACHINE
#                     À ÉTATS du MASTER_ORDER + constantes ci-dessous.
#   D-005 (Codex#3) : backoff infra 30/120/300s -> WAITING_INFRA. Seuil courant
#                     = MAX_INFRA_FAILS=10 (relevé 30/07 Jocelyn ; plus bas à
#                     l'origine). AUTORITÉ UNIQUE : § MACHINE À ÉTATS du
#                     MASTER_ORDER + constante ci-dessous. Aucune valeur de
#                     budget ailleurs ne doit contredire ces constantes.

set -u
REPO="${RUN4_REPO:-$HOME/factory-run4-memory}"   # surchargeable : RUN4_REPO=/chemin/worktree-conductor
STATE_FILE="factory/campaigns/CAMPAIGN_STATE"
LOG="reports/run4-driver.log"
REVIEW_CLAUDE="reports/run4-review-latest-claude.md"
REVIEW_CODEX="reports/run4-review-latest-codex.md"
AUDIT_CLAUDE="reports/RUN4_FINAL_AUDIT_CLAUDE.md"
AUDIT_CODEX="reports/RUN4_FINAL_AUDIT_CODEX.md"

BUILD_BRANCH="run4/build"
MAX_ITERS=300
MAX_INFRA_FAILS=10           # releve 30/07 (Jocelyn) : tolerer plus de hoquets infra transitoires (ex. codex_models_manager cache TTL) avant WAITING_INFRA
BACKOFFS=(30 120 300)        # D-005 : backoff 30s/120s/300s
MAX_P0_REPAIR=6             # redescendu 30/07 (Jocelyn, apres 6h/16+ rounds inutiles) : un budget trop haut a laisse tourner en silence sur un audit mal cadre -- desormais audit scope (FINAL_AUDIT_PROMPT) + budget bas = echec rapide -> FAIL -> notification, plutot que derive longue
MAX_P1_REPAIR=6             # meme raison
PHASE_FILE="factory/campaigns/CAMPAIGN_PHASE"
RECEIPTS_DIR="$HOME/.factory-receipts/factory-run4-memory"   # receipts hors du repo (hors perimetre builder)
LOCK_DIR="$RECEIPTS_DIR/driver.lock.d"   # verrou d execution atomique (mkdir), detenu toute la vie du driver
HB_FILE="factory/campaigns/PILOT_HEARTBEAT"
ITER_FILE="factory/campaigns/PILOT_ITER"
HB_INTERVAL="${HB_INTERVAL:-60}"

# --- D-001 : protection de main (Codex#1). GLM ne committe jamais sur main. ---
ensure_build_branch() {
  local cur
  cur=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ "$cur" = "main" ] || [ "$cur" = "master" ] || [ -z "$cur" ]; then
    if git show-ref --verify --quiet "refs/heads/$BUILD_BRANCH"; then
      git checkout "$BUILD_BRANCH" >>"$LOG" 2>&1
    else
      git checkout -b "$BUILD_BRANCH" >>"$LOG" 2>&1
    fi
  fi
}

# --- D-003 : lecture robuste de l'état (Claude#1). ---
# Tolérant à un éventuel préfixe "CAMPAIGN_STATE=" laissé par GLM, et aux espaces.
read_state() {
  local raw=""
  # NOTE : `$(<file)` est un raccourci bash qui ne fonctionne QUE seul — lui coller
  # `2>/dev/null || echo ""` le transforme en commande vide à redirect ignoré et renvoie "".
  # Bug P1 réel attrapé par test_driver_helpers.bash avant commit (D-003 fix-of-fix).
  if [ -f "$STATE_FILE" ]; then
    raw=$(<"$STATE_FILE")
  fi
  # D-003 : tolère un éventuel préfixe "CAMPAIGN_STATE=" laissé par GLM ET les
  # espaces de BORD (trailing newline, indentation). MAIS (P0 finding 6 / audit
  # fail-open 27/07) on ne retire PLUS les espaces INTERNES : un état malformé
  # comme "RUN NING" ne doit PAS être réparé silencieusement en "RUNNING" — sinon
  # state_kind ne le voit jamais comme illegal (fail-open). L'ancien
  # `${raw//[[:space:]]/}` retirait TOUT whitespace -> normalisation silencieuse.
  # On trime donc UNIQUEMENT les bords (idiom POSIX), on strippe le préfixe, et
  # on laisse state_kind trancher sur la valeur exacte. Testé par
  # tests/test_driver_helpers.bash (entrées malformées incluses).
  raw="${raw#"${raw%%[![:space:]]*}"}"      # trim leading whitespace
  raw=${raw#CAMPAIGN_STATE=}                # tolère un préfixe (D-003)
  raw="${raw#"${raw%%[![:space:]]*}"}"      # re-trim leading (ex: "= RUNNING")
  raw="${raw%"${raw##*[![:space:]]}"}"      # trim trailing whitespace
  printf '%s' "$raw"
}

# --- Contre-relecture GPT 29/07 : lecture stricte de la phase (jamais de reinit silencieuse). ---
read_phase() {
  local p
  p=$(cat "$PHASE_FILE" 2>/dev/null)
  # P0 finding 6 / audit fail-open 27/07 : on ne retire PLUS les espaces internes
  # (l'ancien `tr -d ' \r\n'` réparait silencieusement "P 1" en "P1", autorisant
  # l'entrée en P1 sans checkpoint valide). On trime UNIQUEMENT les bords :
  # "P 1" reste "P 1" -> ne matche pas P0|P1 -> return 1 (fail-closed).
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  case "$p" in
    P0|P1) printf '%s' "$p"; return 0 ;;
    *) return 1 ;;
  esac
}

# --- P0 finding 6 : autorité UNIQUE des états (MASTER_ORDER § « MACHINE À ÉTATS »).
# state_kind classifie un état lu dans CAMPAIGN_STATE en action LÉGALE. Toute
# valeur non listée -> 'illegal' : le pilote ne répare JAMAIS silencieusement un
# état invalide. (L'ancien code laissait un état inconnu tomber dans la boucle
# de build = traité de fait comme RUNNING, ce qui était une réparation
# silencieuse.) États légaux et leur action :
#   RUNNING                       -> build   (continue vers la construction)
#   READY_FOR_FINAL_AUDIT         -> audit   (audit simple Codex -- Claude retire de la boucle 30/07)
#   WAITING_INFRA                 -> infra_stop
#   WAITING_HUMAN_BOSS_GO|WAITING_HUMAN|FAIL|DONE|MEMORY_SYSTEM_FAIL -> terminal
# Testé par tests/test_driver_helpers.bash.
state_kind() {
  case "$1" in
    RUNNING) printf 'build' ;;
    READY_FOR_FINAL_AUDIT) printf 'audit' ;;
    WAITING_INFRA) printf 'infra_stop' ;;
    WAITING_HUMAN_BOSS_GO|WAITING_HUMAN|FAIL|DONE|MEMORY_SYSTEM_FAIL) printf 'terminal' ;;
    *) printf 'illegal' ;;
  esac
}

# --- P0 finding 6 (transitions légales) : AUTORITÉ UNIQUE des transitions.
# `state_kind` valide les VALEURS d'état ; `legal_transition` valide les
# TRANSITIONS (from -> to). Une transition non listée ici est 'illegal' :
# main() l'applique en tête de chaque itération et s'arrête fail-closed
# (JAMAIS de réparation silencieuse). C'était précisément le finding de
# l'audit Codex (PHASE_P0_FAIL) : « le pilote valide des valeurs d'état mais
# n'applique pas les transitions légales ; un builder peut écrire directement
# WAITING_HUMAN_BOSS_GO ou READY_FOR_FINAL_AUDIT depuis n'importe quel
# état/phase ; le pilote les accepte ».
#
# Source unique = MASTER_ORDER § « MACHINE À ÉTATS » -> « Transitions
# légales » (lignes 84-89). Transitions autorisées :
#   - identité (X -> X) : toujours légale (pas de changement d'état).
#   - RUNNING -> READY_FOR_FINAL_AUDIT : builder déclare fin de phase.
#   - RUNNING -> WAITING_INFRA | MEMORY_SYSTEM_FAIL : pilot signale
#     quota/réseau indispo ou mémoire corrompue (terminal, écrit puis exit).
#   - READY_FOR_FINAL_AUDIT -> RUNNING : audit résolu (P0 PASS -> P1, ou
#     non-PASS -> repair round, retour build).
#   - READY_FOR_FINAL_AUDIT -> WAITING_HUMAN_BOSS_GO : audit P1 PASS (Codex seul).
#   - READY_FOR_FINAL_AUDIT -> FAIL : budget de repair épuisé.
#   - FAIL -> RUNNING : UNIQUEMENT via RESUME_AFTER_FAIL=1 (traité au
#     démarrage, pas en boucle).
# Toute autre transition est illégale (ex: RUNNING -> WAITING_HUMAN_BOSS_GO,
# RUNNING -> DONE, READY_FOR_FINAL_AUDIT -> WAITING_INFRA, etc.).
# Testé par tests/test_driver_helpers.bash (cas légaux ET illégaux + boucle
# réelle de main).
legal_transition() {
  local from="$1" to="$2"
  [ "$from" = "$to" ] && { printf 'legal'; return 0; }
  case "$from" in
    RUNNING)
      case "$to" in
        READY_FOR_FINAL_AUDIT|WAITING_INFRA|MEMORY_SYSTEM_FAIL) printf 'legal'; return 0 ;;
      esac ;;
    READY_FOR_FINAL_AUDIT)
      case "$to" in
        RUNNING|WAITING_HUMAN_BOSS_GO|FAIL) printf 'legal'; return 0 ;;
      esac ;;
    FAIL)
      # Réservé à RESUME_AFTER_FAIL (démarrage). En boucle, FAIL est terminal.
      case "$to" in
        RUNNING) printf 'legal'; return 0 ;;
      esac ;;
  esac
  printf 'illegal'
}

# --- P0 finding 6 (garde-boucle testable) : applique la transition légale.
# C'est le GARDE RÉEL de tête de boucle de main() : toute transition
# `prev -> st` non listée par legal_transition est ILLÉGALE -> exit 1
# (fail-closed). Le pilote ne répare JAMAIS silencieusement un état invalide.
# Extrait en fonction nommée (vs inline) pour que tests/test_driver_helpers.bash
# appelle le VRAI garde de production (pas une copie) — exigence « teste
# réellement l'item » + contre-audit Codex (PHASE_P0_FAIL) : « la machine à
# états n'est pas testée par une exécution réelle de main() ».
enforce_legal_transition_or_die() {
  local prev="$1" st="$2"
  if [ "$st" != "$prev" ] && [ "$(legal_transition "$prev" "$st")" = "illegal" ]; then
    echo "[$(date -u +%FT%TZ)] TRANSITION ILLÉGALE '$prev' -> '$st' dans $STATE_FILE -> arret fail-closed (aucune réparation silencieuse). Transitions légales : cf. MASTER_ORDER § MACHINE À ÉTATS + legal_transition." >> "$LOG"
    echo "Transition illégale '$prev' -> '$st' dans $STATE_FILE -> arret fail-closed (voir MASTER_ORDER § MACHINE À ÉTATS). Aucune réinitialisation silencieuse." >&2
    exit 1
  fi
}

sha256_file() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null; }

# --- Verdict d audit par token EXACT en premiere ligne (PHASE_P0_PASS / PHASE_P1_PASS). ---
phase_audit_ok() {
  [ -s "$1" ] || return 1
  local first
  first=$(head -n 1 "$1" | tr -d ' \t\r')
  [ "$first" = "$2" ]
}

# --- FIX 2 (post-mortem 30/07 : bug CLI Codex "failed to load models cache:
# missing field supports_reasoning_summaries") : le bruit d'erreur du CLI Codex
# peut fuiter dans stdout et se retrouver DANS le contenu de AUDIT_CODEX /
# REVIEW_CODEX. Sans cette garde, phase_audit_ok echouait (1ere ligne != token)
# et le round etait compte comme un VRAI audit non-PASS -> audit_repairs++,
# brulant des rounds de repair reels (et du quota Codex) pour du simple bruit
# infra. Desormais ce bruit est detecte et traite comme infra_fail dans main()
# (backoff + retenter, pas de round de repair consomme). Renvoie 0 (vrai) si le
# fichier contient la signature du bug CLI cache, 1 sinon. Teste reellement par
# tests/test_driver_helpers.bash. ---
codex_cache_bug_in_file() {
  [ -s "$1" ] || return 1
  grep -qE 'failed to load models cache|supports_reasoning_summaries' "$1"
}

# --- FIX 3 (post-mortem 30/07 : 6h/16+ rounds perdus) : detection de boucle
# sur audit IDENTIQUE. Quand 2 audits Codex consecutifs sont identiques mot
# pour mot (meme SHA-256), GLM n a produit AUCUN changement de comportement
# reel sur le finding signale -- continuer bouclerait jusqu au plafond
# MAX_*_REPAIR en brulant budget/quota pour rien. Renvoie 0 (vrai) si l'audit
# courant ($2) est identique a l'audit du round precedent (SHA-256 consigne
# dans $1), 1 sinon. Extrait de la logique inline de main() pour etre teste
# reellement (meme discipline que enforce_legal_transition_or_die : le test
# appelle le VRAI predicat de production, pas une copie locale). ---
audit_same_as_previous() {
  local prev_sha_file="$1" cur_file="$2" prev="" cur=""
  [ -f "$prev_sha_file" ] || return 1
  prev=$(cat "$prev_sha_file" 2>/dev/null)
  [ -n "$prev" ] || return 1
  # D-013-quater : la comparaison de stall porte sur la signature des findings
  # P1/High extraits du rapport (stall_signature), PAS sur le rapport entier.
  # Si le rapport courant ne contient AUCUN finding P1/High, pas de stall
  # possible : l absence de finding critique est un etat distinct (D-013 vise un
  # blocage CRITIQUE recurrent, pas une stagnation cosmetique sur du P2). Un
  # echec du parser (rc 1) est propage (on ne decide JAMAIS d un stall sur une
  # signature incalculable).
  cur="$(stall_signature "$cur_file")" || return 1
  [ -n "$cur" ] || return 1
  [ "$prev" = "$cur" ]
}

# --- D-013-quater (granularite de la detection de stall) : la signature de
# stall etait calculee sur le RAPPORT ENTIER (sha256_file $AUDIT_CODEX) ->
# (1) FAUX NEGATIF : un meme finding P1/High persistant mais noye dans un
# rapport qui change par ailleurs (reformulation, autre finding P2, timestamp)
# -> SHA differant -> pas de stall -> boucle jusqu au plafond MAX_*_REPAIR (29
# rounds observes), exactement le mode d echec que D-013 devait corriger ;
# (2) FAUX POSITIF : 2 rapports identiques sans AUCUN P1/High -> stall/FAIL
# cosmetique sur du bruit P2 alors que rien de critique n est bloque.
# Desormais la signature ne porte QUE sur les findings P1/High extraits.
# Perimetre strict (RIEN d autre touche) : extract_p1_high_findings +
# stall_signature + audit_same_as_previous + le site d ecriture du SHA. Ni
# stall_action, ni build_cur_prompt, ni FIX1/2/3, ni D-001..D-013-ter, ni la
# machine a etats ne sont modifies. La robustesse crash-safe de D-013-ter
# (atomic_write_exact / purge_file_logged) est preservee integralement : seul
# le CONTENU hache change. ---

# extract_p1_high_findings : extrait DETERMINISTEMENT les blocs de findings de
# severite P1 ou High d un rapport d audit Codex. Un en-tete de severite est
# reconnu dans toutes les formes legitimement produites par Codex : "P1" / "High"
# nus, mais aussi "## P1", "### High" (titres markdown) ou "[P1] Titre" /
# "[High] ..." (etiquettes entre crochets, avec optionnellement un separateur
# ':'/'—'/'-' et un titre). Les autres severites (P0/P2/P3/P4/Medium/Low/Info/
# Minor) ferment le bloc courant. Plusieurs blocs P1/High sont emis comme un
# TABLEAU JSON de chaines (une par bloc, frontieres PRESERVEES) dans l ordre
# d apparition (stable, deterministe : meme entree -> meme sortie). Conserver
# les frontieres entre blocs evite que deux blocs distincts "P1->A" et "P1->B"
# produisent la meme signature qu un seul bloc "P1->A+B" (masquerait un vrai
# changement de structure en stall). Renvoie vide si aucun finding P1/High.
# Echec du parser (fichier illisible, UTF-8 invalide) -> rc!=0 propage a l
# appelant (stall_signature -> audit_same_as_previous / site d ecriture).
# Teste reellement par tests/test_driver_helpers.bash.
extract_p1_high_findings() {
  local f="$1"
  [ -s "$f" ] || return 0

  python3 - "$f" <<'PY'
import json
import re
import sys
from pathlib import Path

SEVERITIES = r"P[0-4]|HIGH|MEDIUM|LOW|INFO|MINOR"

def severity_header(raw):
    text = raw.strip()
    markdown = bool(re.match(r"^#{1,6}\s+", text))
    text = re.sub(r"^#{1,6}\s*", "", text)

    match = re.match(
        rf"^\[({SEVERITIES})\](?:\s*[:\u2014-]?\s*(.*))?$",
        text,
        re.IGNORECASE,
    )
    if match:
        return match.group(1).upper(), (match.group(2) or "").strip()

    match = re.match(rf"^({SEVERITIES})(.*)$", text, re.IGNORECASE)
    if not match:
        return None

    rest = match.group(2)
    if rest.strip() and not markdown and not re.match(r"^\s*[:\u2014-]", rest):
        return None

    title = re.sub(r"^\s*[:\u2014-]?\s*", "", rest)
    return match.group(1).upper(), title

blocks = []
current = None

def flush():
    global current
    if current is None:
        return
    while current and not current[0].strip():
        current.pop(0)
    while current and not current[-1].strip():
        current.pop()
    if current:
        blocks.append("\n".join(current))
    current = None

for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    header = severity_header(raw)
    if header:
        flush()
        severity, title = header
        current = [] if severity in {"P1", "HIGH"} else None
        if current is not None and title:
            current.append(title)
    elif re.match(r"^\s*#{1,6}\s+", raw):
        flush()
    elif current is not None:
        current.append(raw)

flush()

if blocks:
    sys.stdout.write(
        json.dumps(blocks, ensure_ascii=False, separators=(",", ":"))
    )
PY
}

# stall_signature : SHA-256 du texte des findings P1/High extraits (via
# extract_p1_high_findings, sortie tableau JSON frontieres preservees). C est la
# signature EFFECTIVEMENT stockee dans last_audit_${PHASE}.sha256 et comparee par
# audit_same_as_previous. L usage d une FONCTION UNIQUE pour stocker ET comparer
# garantit la coherence byte-exacte de la paire ecriture/lecture (lecon D-013-ter
# : un ecart entre les deux -> faux negatif de stall). Renvoie vide (rc 0) si le
# rapport ne contient AUCUN finding P1/High (etat distinct -> pas de stall
# possible) ; rc 1 si le parser echoue (propage a l appelant).
stall_signature() {
  local f="$1" extracted
  [ -s "$f" ] || return 0
  extracted="$(extract_p1_high_findings "$f")" || return 1
  [ -n "$extracted" ] || return 0
  printf '%s' "$extracted" |
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

# --- D-013 (post-post-mortem 30/07 : FIX 3 trop brutal) : redirection
# CHIRURGICALE bornee a UNE SEULE tentative quand le verdict Codex est identique
# au round precedent. Au lieu du FAIL immediat de FIX 3 au 1er stall (2 audits
# identiques) -- qui abandonnait trop tot un point potentiellement fixable en
# une derniere tentative ciblee -- on extrait les findings du dernier rapport
# Codex et on redirige GLM UNE fois avec un prompt chirurgical. Un 2e stall
# identique APRES redirection -> FAIL immediat (flag redirect_attempt_PHASE.used).
# Objectif mesurable : un blocage reel ne depasse JAMAIS 3 rounds Codex avant
# FAIL (1 normal + 1 stall + 1 redirection), au lieu de boucler jusqu au plafond
# MAX_*_REPAIR (29 rounds observes) ou de FAIL trop tot. Jamais de boucle, meme
# deguisee : la redirection est strictement bornee a 1 tentative par sequence.

# Extract les lignes de finding (motif fichier:numero) d un rapport Codex, pour
# la redirection chirurgicale. Aucune regex de parsing de finding n existait
# ailleurs dans le pilote -> motif raisonnable fichier.(py|sh|md|json):numero,
# capture les lignes ENTIERES (contexte utile pour GLM). Une ligne sans
# localisation fichier:numero est ecartee (bruit non exploitable). Si rien ne
# matche, renvoie vide (le prompt partira avec un placeholder d ambiguïte).
# Teste reellement par tests/test_driver_helpers.bash.
extract_findings() {
  local f="$1"
  [ -s "$f" ] || return 0
  grep -E '[a-zA-Z0-9_./]+\.(py|sh|md|json):[0-9]+' "$f" 2>/dev/null || return 0
}

# Construit le REDIRECT_PROMPT chirurgical (texte fixe D-013 + findings extraits).
# Prompt court, cible, DERNIERE tentative avant FAIL. Teste reellement par
# tests/test_driver_helpers.bash.
build_redirect_prompt() {
  local findings="${1:-}"
  if [ -z "$findings" ]; then
    findings="<aucun finding fichier:ligne extrait -- le rapport Codex ne cite pas de localisation exploitable ; traite l ambiguite explicitement dans ton commit plutot que de re-tenter en aveugle>"
  fi
  printf 'Ta derniere tentative n a RIEN change au probleme signale (verdict Codex identique au round precedent). N ESSAIE PAS la meme chose une deuxieme fois. Voici EXACTEMENT et UNIQUEMENT le(s) finding(s) a corriger, extrait du dernier rapport Codex :\n%s\nApplique un patch MINIMAL et CHIRURGICAL qui cible precisement cette ligne/ce comportement, ne touche a AUCUN autre fichier ni AUCUNE autre logique. Si le finding te semble deja corrige ou ambigu, dis-le explicitement dans ton commit plutot que de re-tenter en aveugle. C est ta DERNIERE tentative sur ce point avant arret FAIL du pilote et intervention humaine.' "$findings"
}

# --- D-013-bis (correctif de branchement, post-revue independante Codex sur
# le commit b674838) : le mecanisme D-013 de redirection chirurgicale vers GLM
# en cas de stall etait STRUCTURELLEMENT present mais FONCTIONNELLEMENT INERTE.
# Le REDIRECT_PROMPT etait ecrit dans REVIEW_CLAUDE puis copie dans REVIEW_CODEX,
# mais CUR_PROMPT (la valeur REELLEMENT passee a `opencode run`, l'appel GLM qui
# construit) etait TOUJOURS assigne depuis BUILD_PROMPT_P0/P1 statique et ne
# lisait JAMAIS REVIEW_CLAUDE, REVIEW_CODEX ni REDIRECT_PROMPT. Resultat : GLM
# ne voyait JAMAIS le contenu de redirection, meme apres un stall detecte -- la
# redirection ne produisait aucun effet cible.
#
# Ce correctif branche REELLEMENT la redirection. Isoler la construction de
# CUR_PROMPT dans une fonction testable build_cur_prompt(PHASE) :
#   - au moment ou REDIRECT_PROMPT est construit (branche redirect du case
#     stall_action), son contenu est persiste dans
#     RECEIPTS_DIR/pending_redirect_PHASE.txt (PHASE = P0 ou P1) ;
#   - build_cur_prompt(PHASE) verifie ce fichier : s'il existe, CUR_PROMPT =
#     contenu du fichier PUIS BUILD_PROMPT_P0/P1 (redirection EN PLUS du prompt
#     de build standard, jamais a la place) ; sinon CUR_PROMPT = BUILD_PROMPT
#     standard seul ;
#   - APRES l'appel opencode run, le fichier pending_redirect est supprime ->
#     usage UNIQUE, jamais de re-injection sur une iteration ulterieure.
# Teste reellement par tests/test_driver_helpers.bash (verification du CONTENU
# reel de CUR_PROMPT produit, pas seulement l'existence des fonctions D-013). ---
build_cur_prompt() {
  local phase="$1" base pr
  if [ "$phase" = "P1" ]; then base="$BUILD_PROMPT_P1"; else base="$BUILD_PROMPT_P0"; fi
  pr="$RECEIPTS_DIR/pending_redirect_${phase}.txt"
  if [ -f "$pr" ]; then
    # Redirection chirurgicale D-013 EN TETE du prompt : GLM recoit le contenu de
    # redirection AVANT le build standard, pour garantir qu'il est effectivement
    # pris en compte. $(cat ...) evite le bruit d'une commande vide.
    printf '%s\n\n%s' "$(cat "$pr")" "$base"
  else
    printf '%s' "$base"
  fi
}

# ====================================================================
# D-013-ter (audit défensif complet de la mécanique stall/redirect) :
# écriture atomique + nettoyage crash-safe des fichiers d'état de la redirection
# (pending_redirect_PHASE.txt, redirect_attempt_PHASE.used, last_audit_PHASE.sha256).
# Ces helpers ne touchent NI à la logique de décision (stall_action), NI à
# build_cur_prompt, NI à FIX1/FIX2/FIX3, NI à D-001..D-012, NI à la machine à
# états (state_kind/legal_transition/enforce_legal_transition_or_die) : ils ne
# font que rendre atomiques et crash-safe les ÉCRITURES/SUPPRESSIONS de ces
# fichiers. Testés réellement (nominal + simulation crash/interruption) par
# tests/test_driver_helpers.bash.
# ====================================================================

# atomic_write_exact : écrit <content> À L'IDENTIQUE (aucun newline ajouté) dans
# <path> via le pattern tmp-puis-mv (atomique au sens POSIX rename). Indispensable
# pour last_audit_PHASE.sha256 dont la comparaison est byte-exacte (un newline
# parasite casserait audit_same_as_previous -> faux négatif de stall). Retourne 0
# si ok, 1 sinon (logge l'échec + purge le tmp ; l'appelant décide du fail-closed).
atomic_write_exact() {
  local path="$1" content="$2" tmp rc
  tmp="${path}.tmp.$$"
  if printf '%s' "$content" > "$tmp" 2>>"$LOG"; then
    if mv -f "$tmp" "$path" 2>>"$LOG"; then
      return 0
    fi
  fi
  rc=$?
  rm -f "$tmp" 2>/dev/null || true
  echo "[$(date -u +%FT%TZ)] atomic_write_exact ECHEC sur $path (rc=$rc) -> fichier NON ecrit, tmp purge" >> "$LOG"
  return 1
}

# purge_file_logged : supprime <path> SANS avaler l'erreur (remplace les
# 'rm -f ... 2>/dev/null' muets sur les fichiers d'état de redirection). Logge
# explicitement la suppression réussie et l'échec éventuel. Retourne 0 si le
# fichier n'existe plus après (ou n'existait pas), 1 si la suppression a échoué.
purge_file_logged() {
  local path="$1" label="${2:-$1}"
  [ -e "$path" ] || return 0
  if rm -f "$path" 2>>"$LOG"; then
    echo "[$(date -u +%FT%TZ)] purge $label : supprime ($path)" >> "$LOG"
    return 0
  fi
  echo "[$(date -u +%FT%TZ)] purge $label : ECHEC suppression ($path)" >> "$LOG"
  return 1
}

# enter_scoped_purge / exit_scoped_purge : pour la section critique (appel
# opencode run), on ÉTEND temporairement le trap EXIT global du driver (SANS
# remplacer sa déclaration dans main : on sauvegarde l'état exact des traps
# EXIT/INT/TERM/HUP puis on le RESTAURE à l'identique après la section) afin que
# <file> soit purgé même si le pilote est tué (SIGTERM/SIGINT/SIGHUP -> tous
# 'exit 143' -> EXIT) ou crashe pendant la section. Les traps INT/TERM/HUP
# eux-mêmes ne sont PAS modifiés : leur 'exit 143' global funnel vers EXIT, donc
# la purge se déclenche quand même sur signal.
_SCP_FILE=""; _SCP_SAVED=""
enter_scoped_purge() {
  _SCP_FILE="$1"
  _SCP_SAVED="$(trap -p EXIT INT TERM HUP)"
  # EXIT augmenté : purge le fichier PUIS invoque le cleanup original du driver
  # (verrou + heartbeat). On rappelle cleanup explicitement car ré-armer un trap
  # pendant un EXIT en cours ne l'exécute pas une seconde fois.
  trap 'rm -f "$_SCP_FILE" 2>/dev/null || true; cleanup' EXIT
}
exit_scoped_purge() {
  local line
  trap - EXIT INT TERM HUP
  while IFS= read -r line; do
    [ -n "$line" ] && eval "$line"
  done <<SCPHEREDOC
$_SCP_SAVED
SCPHEREDOC
  _SCP_FILE=""; _SCP_SAVED=""
}

# commit_redirect : engagement TRANSACTIONNEL et atomique d'une redirection
# chirurgicale. Écrit pending_redirect (tmp-puis-mv atomique) PUIS touche le
# flag, le tout sous un scoped trap qui ROLLBACK (supprime pending + tmp + flag)
# sur interruption entre les deux écritures -> JAMAIS d'état inconsistent :
#   - jamais pending sans flag (re-injection + 2e redirection autorisée),
#   - jamais flag sans pending (FAIL sans avoir délivré la redirection).
# Ordre pending-puis-flag : en cas de signal non rattrapable (SIGKILL, hors
# scope du trap), la fenêtre résiduelle laisse au pire pending-sans-flag (la
# redirection est re-délivrée une fois, moins dangereux que flag-sans-pending
# qui perdrait la tentative). Retourne 0 si ok, 1 sinon (fail-closed :
# l'appelant ne doit PAS compter la redirection comme engagée).
CR_SAVED=""; CR_PENDING=""; CR_TMP=""; CR_FLAG=""
commit_redirect() {
  local pending="$1" flag="$2" content="$3"
  CR_SAVED="$(trap -p EXIT INT TERM HUP)"
  CR_PENDING="$pending"; CR_TMP="${pending}.tmp.$$"; CR_FLAG="$flag"
  # scoped rollback EXIT : interruption (signal -> exit 143 -> EXIT, ou crash)
  # entre l'écriture de pending et le touch du flag -> on retire TOUT.
  trap 'rm -f "$CR_PENDING" "$CR_TMP" "$CR_FLAG" 2>/dev/null || true' EXIT
  printf '%s\n' "$content" > "$CR_TMP" 2>>"$LOG" || { _commit_redirect_fail; return 1; }
  mv -f "$CR_TMP" "$pending" 2>>"$LOG"        || { _commit_redirect_fail; return 1; }
  touch "$flag" 2>>"$LOG"                     || { _commit_redirect_fail; return 1; }
  _cr_restore
  return 0
}
_commit_redirect_fail() {
  rm -f "$CR_TMP" "$CR_PENDING" 2>/dev/null || true
  _cr_restore
}
_cr_restore() {
  local line
  trap - EXIT INT TERM HUP
  while IFS= read -r line; do
    [ -n "$line" ] && eval "$line"
  done <<CRHEREDOC
$CR_SAVED
CRHEREDOC
}

# Decision de stall en 2 temps (D-013). Entrees :
#   $1 = code retour du predicat audit_same_as_previous (0 = stalled, autre = non).
#   $2 = chemin du flag redirect_attempt_PHASE.used.
# Renvoie 'redirect' / 'fail' / 'normal' :
#   - non stalled                          -> 'normal'  (progres reel : reset flag, boucle standard)
#   - stalled + flag ABSENT (1er stall)    -> 'redirect' (1 redirection chirurgicale vers GLM)
#   - stalled + flag PRESENT (deja tente)  -> 'fail'     (FAIL immediat fail-closed, pas de 3e tentative)
# Extrait en fonction nommee (vs inline) pour que tests/test_driver_helpers.bash
# appelle la VRAIE table de decision de production (meme discipline que
# enforce_legal_transition_or_die / audit_same_as_previous : le test appelle le
# VRAI predicat, pas une copie locale).
stall_action() {
  local stalled="$1" flag="$2"
  [ "$stalled" = "0" ] || { printf 'normal'; return 0; }
  if [ -f "$flag" ]; then printf 'fail'; return 0; fi
  printf 'redirect'
}

# --- Verrou d execution atomique (mkdir) : SEULE autorite anti-double-pilote (pgrep = diagnostic). ---
LOCK_ACQUIRED=0
HB_PID=""
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    printf '{"pid":%d,"commit":"%s","started":"%s"}\n' "$$" \
      "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "$(date -u +%FT%TZ)" > "$LOCK_DIR/info.json"
    printf '%d\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  local other
  other=$(cat "$LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n')
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    echo "Verrou driver detenu par le PID $other (actif) -> refus de demarrer un second pilote." >&2
  else
    echo "Verrou driver present mais PID ${other:-inconnu} inactif (verrou stale probable)." >&2
    echo "Verifie manuellement puis supprime : rm -rf $LOCK_DIR — aucun auto-nettoyage (PID recyclable)." >&2
  fi
  return 1
}

cleanup() {
  [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null
  if [ "$LOCK_ACQUIRED" = "1" ]; then
    rm -f "$LOCK_DIR/pid" "$LOCK_DIR/info.json" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
}

# --- Verification du checkpoint P0 (reprise phase P1) : hashes des audits recalcules. ---
verify_checkpoint_p0() {
  python3 - "$RECEIPTS_DIR/checkpoint_p0" <<'PYCHK'
import hashlib, json, os, sys
d = sys.argv[1]
try:
    ck = json.load(open(os.path.join(d, "checkpoint.json"), encoding="utf-8"))
except Exception as e:
    sys.stderr.write("checkpoint illisible: %s\n" % e); sys.exit(1)
if ck.get("phase") != "P0" or not ck.get("commit"):
    sys.stderr.write("checkpoint invalide (phase/commit)\n"); sys.exit(1)
hashes = ck.get("audit_sha256") or {}
if not hashes:
    sys.stderr.write("checkpoint sans hashes d audits\n"); sys.exit(1)
for name, expected in hashes.items():
    pth = os.path.join(d, name)
    try:
        got = hashlib.sha256(open(pth, "rb").read()).hexdigest()
    except Exception as e:
        sys.stderr.write("audit manquant %s: %s\n" % (name, e)); sys.exit(1)
    if got != expected:
        sys.stderr.write("audit modifie: %s\n" % name); sys.exit(1)
sys.exit(0)
PYCHK
}

# --- Heartbeat minimal (leçon L-20) : boucle de fond independante des appels agents. ---
start_heartbeat() {
  (
    while :; do
      printf '{"timestamp":"%s","pid":%d,"state":"%s","phase":"%s","iter":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$$" "$(read_state)" "$(read_phase || echo INVALID)" "$(cat "$ITER_FILE" 2>/dev/null | tr -d ' \r\n')" \
        > "$HB_FILE.tmp.$$" 2>/dev/null && mv -f "$HB_FILE.tmp.$$" "$HB_FILE" 2>/dev/null
      sleep "$HB_INTERVAL"
    done
  ) &
  HB_PID=$!
}

BUILD_PROMPT_P0='PHASE P0 UNIQUEMENT — Reprise Run 4 (Memoire / Experience Compiler) apres FAIL du 27/07. Corrige les 6 defauts suivants, RIEN d autre (aucune fonction Sharp Core, aucun receipt, aucune promotion automatique — tout cela est la phase P1 qui viendra apres le checkpoint P0) : (1) factory/bin/lesson_extractor.py:301-323,478-480 -- --source-tag : normaliser par strip(), refuser vide/espaces (erreur rc!=0), appliquer AVANT la validation finale, revalider la leçon apres modification, verifier la coherence source/evidence ; tests exiges : source-tag vide -> FAIL, espaces -> FAIL, source remplacee avec evidence ancienne incoherente -> FAIL, source et evidence coherentes -> PASS. (2) factory/bin/lesson_extractor.py:176-183 -- un bloc [FINDING][/FINDING] vide fait echouer TOUTE l extraction (fail-closed) ; tests : un valide -> PASS, un vide -> FAIL, un valide + un vide -> FAIL. (3) factory/bin/bootstrap_lessons.py:445-452,479-480 -- serialiser l ecriture concurrente en REUTILISANT le pattern deja valide du repo (fcntl.flock + context manager + liberation dans finally + tmp unique par processus + fsync + os.replace atomique — voir leçons L-10 a L-16 de memory/lessons.jsonl, ne PAS inventer une nouvelle abstraction de lock) ; capturer FileNotFoundError dans main() ; timeout de lock obligatoire, jamais d attente infinie ; test multiprocessus reel : deux processus simultanes -> aucun deadlock, aucun FileNotFoundError, aucune perte d entree, aucun JSON partiel, aucun fd restant ouvert, resultat final valide. (4) factory/bin/ablation_checker.py:438-446 -- ne plus crediter un except OSError generique : le test doit mesurer le comportement REEL (compteur de fd ouverts, ou mock verifiant close(), ou contexte with) ; un mutant qui retourne False sans fermer doit etre detecte comme NON sur. (5) reports/RUN4_ABLATION_AB.md -- reformuler honnetement : append-only par convention d ecriture, NON tamper-evident, NON cryptographiquement scelle ; ne PAS construire de chainage crypto. (6) machine a etats : une seule autorite des etats et transitions legales, documentee ; le pilote ne repare jamais silencieusement un etat invalide. Teste reellement chaque item, committe chaque etape verifiee sur la branche run4/build, main INTACT, aucun push/merge/tag/deploy, INTERDIT cleanup/rm large ou recursif. Quand les 6 items sont fermes par des tests reels qui passent, ecris UNIQUEMENT la valeur READY_FOR_FINAL_AUDIT dans factory/campaigns/CAMPAIGN_STATE et arrete-toi. Sinon laisse RUNNING.'

BUILD_PROMPT_P1='PHASE P1 — Sharp Core minimal (le checkpoint P0 est fige et valide : ne retouche PAS les fichiers P0 sauf regression prouvee). Branche exactement 4 fonctions, rien de plus : (1) GATE RECEIPT REEL : un wrapper factory/bin/run_gate.py (stdlib uniquement) qui execute la vraie commande de gate, lit le vrai code retour, et ecrit un gate_receipt.json {task_id, commit, command, exit_code, passed, started_at, finished_at, stdout_path, stderr_path} dans $HOME/.factory-receipts/factory-run4-memory/ (hors du repo) ; passed=true UNIQUEMENT si exit_code=0 ; jamais de PASS hardcode, jamais de booleen fourni par l appelant. (2) VERDICT REVIEWER ARTEFACT : la promotion exige un codex_review_verdict.json {task_id, commit, reviewer, verdict, report_path, timestamp} dans le meme dossier receipts ; une variable d environnement ou un flag CLI ne sont JAMAIS une preuve. (3) PROMOTION AUTOMATIQUE : un outil promote (factory/bin/, stdlib) qui lit lesson_candidate.json + gate_receipt.json + codex_review_verdict.json, verifie meme task_id, meme commit, meme projet, passed=true, exit_code=0, verdict exactement PASS, test de regression existant, schema lesson_schema.py valide, project different de "*", pas de doublon id — et append dans memory/lessons.jsonl SEULEMENT si tout est vrai. (4) INJECTION FAIL-CLOSED : documenter et tester que le driver appelle lesson_injector.py --format quiet avant chaque tache et s arrete en MEMORY_SYSTEM_FAIL si rc!=0 (le hook driver existe deja, ajoute le test qui le prouve). Bornes : retrieval max 5 leçons, meme projet uniquement, task packet max 8 fichiers. Tests adversariaux obligatoires : promotion sans receipt -> refus ; sans verdict -> refus ; mauvais task_id -> refus ; mauvais commit -> refus ; verdict autre que PASS -> refus ; project="*" -> refus ; doublon -> refus ; exit 7 au gate -> passed=false et code propage ; memoire corrompue -> arret fail-closed. Teste reellement, committe chaque etape sur run4/build, main INTACT, aucun push/merge/tag/deploy, aucun SQLite/embeddings/graphe/dashboard. Quand les 4 fonctions sont branchees et les tests adversariaux verts, ecris UNIQUEMENT READY_FOR_FINAL_AUDIT dans factory/campaigns/CAMPAIGN_STATE et arrete-toi. Sinon laisse RUNNING.'

REVIEW_HEADER='Tu es un reviewer independant (jamais le builder) de Run 4, factory de Jocelyn. Review UNIQUEMENT le dernier commit du repo courant. Cherche : bugs reels reproduits, donnees inventees non tracees fichier:ligne, violations des INTERDITS ABSOLUS du master order. Tu disposes uniquement des outils Read/Grep/Glob (lecture seule) ; le diff du dernier commit t est fourni ci-dessous. Commence ta reponse par PASS ou FIX_NEEDED en premiere ligne, puis la liste des findings avec fichier:ligne si FIX_NEEDED, vide si PASS. Sois concis, ceci est une review de tranche, pas un audit complet.'

FINAL_AUDIT_PROMPT='Tu es un reviewer independant de Run 4, factory de Jocelyn. Review CIBLEE et RAPIDE, PAS un audit exhaustif du repo entier : verifie UNIQUEMENT les items enumeres explicitement dans la note de phase ci-dessus (rien d autre). Pour chaque item : le comportement demande est-il reellement implemente et couvert par un test qui echoue si on le casse (pas juste un test cosmetique) ? Ne cherche PAS de nouveaux sujets hors de cette liste (pas de nouvelle exhaustivite sur validation/erreurs/concurrence/cas limites non demandes) -- ce n est pas le role de cet audit, ca ralentit le run sans ajouter de valeur. Seule exception autorisee hors liste : si un item de la liste ci-dessus a une consequence factuelle directe sur reports/RUN4_FINAL_REPORT.md (ex: chiffre invente), le signaler. Tu disposes uniquement des outils Read/Grep/Glob (lecture seule). Rends un rapport COURT dont la PREMIERE LIGNE est EXACTEMENT le token de verdict exige par la note de phase ci-dessus (rien d autre sur cette ligne), puis UNIQUEMENT les findings sur les items de la liste, avec fichier:ligne. Si tout est ferme, la reponse est le token PASS suivi de rien.'

# --- D-005 : applique le backoff infra courant puis continue la boucle. ---
# Renvoie le délai (s) choisi pour n-ième échec (sans dormir) — testable sans sleep réel.
backoff_secs() {
  local n="$1" idx
  idx=$((n-1))
  [ "$idx" -ge "${#BACKOFFS[@]}" ] && idx=$((${#BACKOFFS[@]}-1))
  [ "$idx" -lt 0 ] && idx=0
  printf '%s' "${BACKOFFS[$idx]}"
}
apply_backoff() {
  echo "[$(date -u +%FT%TZ)] infra_fails=$1 -> sleep $(backoff_secs "$1")s (backoff)" >> "$LOG"
  sleep "$(backoff_secs "$1")"
}

# --- LEGACY (remplace par phase_audit_ok + tokens de phase, conserve pour reference). ---
# OK = fichier non vide ET verdict positif sur la PREMIERE ligne ET absence
# de "PAS PRET" sur cette ligne. L'ancienne version cherchait la locution
# n'importe ou dans le fichier : un audit negatif citant la locution cible
# (ex. "verdict attendu : PRET A MERGER") passait a tort.
audit_ok() {
  [ -s "$1" ] || return 1
  local first
  first=$(head -n 1 "$1")
  case "$first" in
    *"PAS PRET"*|*"PAS PRÊT"*) return 1 ;;
  esac
  printf '%s' "$first" | grep -qi "PRET A MERGER" >/dev/null 2>&1 && return 0
  printf '%s' "$first" | grep -qi "PRÊT À MERGER" >/dev/null 2>&1 && return 0
  return 1
}

main() {
  cd "$REPO" || { echo "Repo $REPO introuvable — crée-le et colle MASTER_ORDER_RUN4_MEMORY.md dedans d'abord." >&2; exit 1; }
  mkdir -p reports factory/campaigns memory
  [ -f "$STATE_FILE" ] || echo RUNNING > "$STATE_FILE"

  # --- Contre-relecture GPT 29/07 : verrou atomique = SEULE autorite anti-double-pilote. ---
  local ST0 OTHERS RESUME_PHASE STALL_SIG
  if ! acquire_lock; then exit 1; fi
  trap cleanup EXIT
  trap 'exit 143' TERM INT HUP
  OTHERS=$(pgrep -f "run_run4_autonomous\.sh$" 2>/dev/null | grep -v "^$$\$" | grep -v "^${PPID:-0}\$" | wc -l | tr -d ' ')
  [ "${OTHERS:-0}" -gt 0 ] && echo "[$(date -u +%FT%TZ)] NOTE diagnostic (non bloquant): pgrep voit $OTHERS autre(s) process — le verrou atomique reste la seule autorite" >> "$LOG"

  # --- Reprise explicite phase-aware apres FAIL, jamais d auto-reset ni de reinit de phase. ---
  ST0=$(read_state)
  if [ "${RESUME_AFTER_FAIL:-0}" = "1" ]; then
    if [ "$ST0" != "FAIL" ]; then
      echo "RESUME_AFTER_FAIL=1 mais etat=$ST0 (attendu FAIL) -> refus." >&2
      exit 1
    fi
    if [ ! -f "$PHASE_FILE" ]; then
      RESUME_PHASE="P0"
      echo "P0" > "$PHASE_FILE"
      echo "[$(date -u +%FT%TZ)] reprise: phase absente -> reprise legacy en P0 (explicite, loggee)" >> "$LOG"
    elif RESUME_PHASE=$(read_phase); then
      if [ "$RESUME_PHASE" = "P1" ] && ! verify_checkpoint_p0; then
        echo "Reprise en phase P1 REFUSEE : checkpoint P0 absent, incomplet ou modifie ($RECEIPTS_DIR/checkpoint_p0). Fail-closed." >&2
        exit 1
      fi
    else
      echo "Reprise REFUSEE : phase inconnue dans $PHASE_FILE (ni P0 ni P1). Aucune reinitialisation silencieuse." >&2
      exit 1
    fi
    printf '{"old_state":"FAIL","new_state":"RUNNING","phase":"%s","commit":"%s","timestamp":"%s","reason":"%s"}\n' \
      "$RESUME_PHASE" "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "$(date -u +%FT%TZ)" \
      "${RESUME_REASON:-RESUME_AFTER_FAIL}" > "$RECEIPTS_DIR/resume_receipt.json"
    echo "RUNNING" > "$STATE_FILE"
    echo "[$(date -u +%FT%TZ)] RESUME_AFTER_FAIL=1 : FAIL -> RUNNING (phase $RESUME_PHASE), resume_receipt.json ecrit dans $RECEIPTS_DIR" >> "$LOG"
  elif [ "$ST0" = "FAIL" ]; then
    echo "Etat FAIL : relance interdite sans RESUME_AFTER_FAIL=1 (aucun auto-reset silencieux)." >&2
    exit 1
  fi
  if [ ! -f "$PHASE_FILE" ]; then
    echo "P0" > "$PHASE_FILE"
  else
    local _STARTUP_PHASE
    if ! _STARTUP_PHASE=$(read_phase); then
      echo "Phase inconnue dans $PHASE_FILE (ni P0 ni P1) -> refus fail-closed, aucune reinitialisation silencieuse." >&2
      exit 1
    fi
    # Durcissement 30/07 (Codex) : une phase P1 lue au demarrage DOIT etre couverte par un
    # checkpoint P0 verifiable, meme hors chemin RESUME_AFTER_FAIL (demarrage direct avec
    # CAMPAIGN_PHASE deja a P1 sans etre passe par un FAIL -- contournement possible sinon).
    if [ "$_STARTUP_PHASE" = "P1" ] && ! verify_checkpoint_p0; then
      echo "Demarrage en phase P1 REFUSE : checkpoint P0 absent, incomplet ou modifie ($RECEIPTS_DIR/checkpoint_p0). Fail-closed, aucun contournement du gate P0->P1." >&2
      exit 1
    fi
  fi
  start_heartbeat
  echo "[$(date -u +%FT%TZ)] === RUN4 DRIVER START (review Codex seul -- Claude retire 30/07, fixes D-001..D-005) ===" >> "$LOG"
  ensure_build_branch

  local infra_fails=0 audit_repairs=0
  local ST rc i DIFF DIFF_TRUNC REVIEW_PROMPT PID_CLAUDE PID_CODEX
  local PHASE PHASE_NOTE MAX_REPAIR CUR_PROMPT INJ_RC INJ_ERR TOKEN WT_DIRTY WT_STATE WT_DIFF_SHA
  local PREV_ST
  local STALL_FILE REDIRECT_FLAG STALL_RC EXTRACTED REDIRECT_PROMPT
  # P0 finding 6 : état consommé au démarrage (post-resume). Sert de référence
  # pour valider chaque transition lue en tête de boucle via legal_transition.
  PREV_ST="$(read_state)"

  for i in $(seq 1 $MAX_ITERS); do
  echo "$i" > "$ITER_FILE"
  ST=$(read_state)
  # P0 finding 6 (transitions légales) : toute transition PREV_ST -> ST non
  # listée par legal_transition est ILLÉGALE -> arret fail-closed. Le pilote ne
  # répare JAMAIS silencieusement un état invalide (ex: un builder qui écrit
  # WAITING_HUMAN_BOSS_GO pendant la phase de build -> refus, pas d'arrêt muet).
  # Le garde lui-même vit dans enforce_legal_transition_or_die (testé pour de
  # vrai par tests/test_driver_helpers.bash).
  enforce_legal_transition_or_die "$PREV_ST" "$ST"
  PREV_ST="$ST"
  case "$(state_kind "$ST")" in
    terminal)
      echo "[$(date -u +%FT%TZ)] STATE=$ST -> arret pilote (iter $i)" >> "$LOG"; exit 0 ;;
    infra_stop)
      echo "[$(date -u +%FT%TZ)] STATE=WAITING_INFRA -> arret pilote (quota/reseau, iter $i)" >> "$LOG"; exit 0 ;;
    audit)
      PHASE=$(read_phase) || { echo "[$(date -u +%FT%TZ)] phase invalide dans $PHASE_FILE -> arret fail-closed (aucune reinit silencieuse)" >> "$LOG"; exit 1; }
      if [ "$PHASE" = "P0" ]; then
        PHASE_NOTE="AUDIT DE PHASE P0 UNIQUEMENT : verifie que les 6 findings P0 (source-tag/evidence, finding vide fail-closed, ecriture concurrente bootstrap, credit fd comportemental, claim ablation honnete, machine a etats) sont fermes par des tests reels. PRECISION SCOPE (evite un faux P1 -- desambiguisation 30/07) : RECEIPTS_DIR, resume_receipt.json, checkpoint_p0/, sha256_file() et verify_checkpoint_p0() dans run_run4_autonomous.sh sont l ORCHESTRATION DU DRIVER lui-meme (prevue des le preflight initial 43aa069, approuvee, necessaire pour gater la transition P0->P1) -- ce N EST PAS le Sharp Core P1. Le Sharp Core P1 reel = les 4 fonctions listees dans BUILD_PROMPT_P1 (gate receipt de TACHE via factory/bin/run_gate.py, verdict reviewer artefact codex_review_verdict.json, outil promote de LECON, injection fail-closed) : verifie leur ABSENCE dans factory/bin/ (ls factory/bin/ ne doit lister aucun run_gate.py ni outil promote) comme preuve que le perimetre P1 n a pas ete franchi -- ne compte PAS l orchestration driver comme une violation. PREMIERE LIGNE de ta reponse : EXACTEMENT PHASE_P0_PASS si les 6 items sont fermes ET qu aucun outil Sharp Core P1 n existe dans factory/bin/, sinon EXACTEMENT PHASE_P0_FAIL suivi des findings."
        TOKEN="PHASE_P0_PASS"
        MAX_REPAIR="$MAX_P0_REPAIR"
      else
        PHASE_NOTE="AUDIT DE PHASE P1 : le checkpoint P0 est fige. Verifie les 4 fonctions Sharp Core (gate receipt reel, verdict codex artefact, promotion automatique verifiante, injection fail-closed) et les tests adversariaux associes. PREMIERE LIGNE de ta reponse : EXACTEMENT PHASE_P1_PASS si tout est branche et prouve, sinon EXACTEMENT PHASE_P1_FAIL suivi des findings."
        TOKEN="PHASE_P1_PASS"
        MAX_REPAIR="$MAX_P1_REPAIR"
      fi
      echo "[$(date -u +%FT%TZ)] iter $i: GLM se declare pret -> audit final phase $PHASE (Codex seul, reviewer independant, lecture seule -- Claude retire de la boucle de review sur demande explicite Jocelyn, economie de quota)" >> "$LOG"
      # FIX 1 : purge du cache modeles Codex AVANT chaque appel 'codex exec' pour
      # eviter le bug CLI "failed to load models cache: missing field
      # supports_reasoning_summaries" (silencieux, n'echoue jamais le script).
      rm -f "$HOME/.codex/models_cache.json" 2>/dev/null || true
      codex exec -s read-only --skip-git-repo-check "$PHASE_NOTE
$FINAL_AUDIT_PROMPT" > "$AUDIT_CODEX" 2>>"$LOG" \
        || echo "[$(date -u +%FT%TZ)] iter $i: audit codex rc non-zero" >> "$LOG"
      # FIX 2 : si le bruit d'erreur CLI du cache a fuite dans AUDIT_CODEX, on
      # NE l'incremente PAS comme un vrai audit non-PASS (sinon un round de
      # repair reel etait consomme pour du simple bruit infra). Traite comme
      # infra_fail -> backoff + retenter, sans consommer de round de repair ni
      # de quota inutile (meme logique backoff/infra_fails que le bloc review).
      if codex_cache_bug_in_file "$AUDIT_CODEX"; then
        infra_fails=$((infra_fails+1))
        echo "[$(date -u +%FT%TZ)] iter $i: codex cache bug detecte -> traite comme infra_fail, pas comme audit (infra_fails=$infra_fails/$MAX_INFRA_FAILS)" >> "$LOG"
        if [ "$infra_fails" -gt "$MAX_INFRA_FAILS" ]; then
          echo "WAITING_INFRA" > "$STATE_FILE"
          echo "[$(date -u +%FT%TZ)] $MAX_INFRA_FAILS echecs infra consecutifs -> STATE=WAITING_INFRA -> arret" >> "$LOG"
          exit 0
        fi
        apply_backoff "$infra_fails"
        continue
      fi
      # codex exec a rendu une sortie exploitable (pas du bruit infra) -> le
      # compteur d'echecs infra (consecutifs) est remis a 0.
      infra_fails=0
      if phase_audit_ok "$AUDIT_CODEX" "$TOKEN"; then
        if [ "$PHASE" = "P0" ]; then
          mkdir -p "$RECEIPTS_DIR/checkpoint_p0"
          cp "$AUDIT_CODEX" "$RECEIPTS_DIR/checkpoint_p0/" 2>>"$LOG"
          WT_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
          if [ "${WT_DIRTY:-0}" -eq 0 ]; then WT_STATE="clean"; WT_DIFF_SHA=""; else
            WT_STATE="dirty"
            WT_DIFF_SHA=$(git diff 2>/dev/null | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
            echo "[$(date -u +%FT%TZ)] AVERTISSEMENT checkpoint P0: worktree non propre (diff sha256=$WT_DIFF_SHA consigne)" >> "$LOG"
          fi
          printf '{"phase":"P0","commit":"%s","timestamp":"%s","worktree":"%s","diff_sha256":"%s","audit_sha256":{"%s":"%s"}}\n' \
            "$(git rev-parse HEAD)" "$(date -u +%FT%TZ)" "$WT_STATE" "$WT_DIFF_SHA" \
            "$(basename "$AUDIT_CODEX")" "$(sha256_file "$RECEIPTS_DIR/checkpoint_p0/$(basename "$AUDIT_CODEX")")" \
            > "$RECEIPTS_DIR/checkpoint_p0/checkpoint.json"
          echo "P1" > "$PHASE_FILE"
          # D-013-ter : purge explicite + loggee des stall files (plus de
          # 'rm -f ... 2>/dev/null' muet) a la transition P0 -> P1.
          purge_file_logged "$RECEIPTS_DIR/last_audit_P0.sha256" "last_audit_P0 (transition P0->P1)"
          purge_file_logged "$RECEIPTS_DIR/last_audit_P1.sha256" "last_audit_P1 (transition P0->P1)"
          audit_repairs=0
          echo "RUNNING" > "$STATE_FILE"
          echo "[$(date -u +%FT%TZ)] audit P0 OK (Codex seul) -> checkpoint P0 fige dans $RECEIPTS_DIR/checkpoint_p0 -> PHASE=P1, STATE=RUNNING" >> "$LOG"
          continue
        fi
        echo "WAITING_HUMAN_BOSS_GO" > "$STATE_FILE"
        echo "[$(date -u +%FT%TZ)] audit P1 OK (Codex seul, PRET A MERGER) -> STATE=WAITING_HUMAN_BOSS_GO -> arret pilote" >> "$LOG"
        exit 0
      fi
      # --- D-013 (post-post-mortem 30/07 : FIX 3 trop brutal) : detection de
      # stall en 2 TEMPS, bornee a MAXIMUM 1 redirection chirurgicale vers GLM.
      # FIX 3 faisait FAIL IMMEDIAT des le 1er stall (2 audits identiques) -- un
      # point qui aurait pu etre fixe en une derniere tentative ciblee etait
      # abandonne trop tot. Desormais :
      #   Round N (audit identique au round N-1, detecte par audit_same_as_previous) :
      #     - flag redirect_attempt_PHASE.used ABSENT -> extraire les findings du
      #       rapport Codex, construire un REDIRECT_PROMPT chirurgical, le router
      #       vers GLM via REVIEW_CLAUDE/REVIEW_CODEX (comme la review de tranche),
      #       STATE=RUNNING, poser le flag, UNE SEULE fois. Pas de FAIL immediat.
      #     - flag PRESENT (redirection deja tentee) -> FAIL IMMEDIAT.
      #   Round N+1 :
      #     - audit ENCORE identique (sha256 strict via audit_same_as_previous) ->
      #       stall + flag present -> FAIL IMMEDIAT fail-closed, message exact.
      #     - audit DIFFERENT (progres reel, meme partiel) -> branche normale,
      #       reset du flag + nouveau sha consigne, budget audit_repairs standard.
      # Objectif mesurable : un blocage reel sur un finding non resolu ne JAMAIS
      # depasser 3 rounds Codex avant FAIL (1 normal + 1 stall + 1 redirection),
      # au lieu de boucler jusqu au plafond MAX_*_REPAIR (29 rounds observes).
      # Jamais de boucle, meme deguisee : la redirection est strictement bornee a
      # 1 tentative par sequence de stall (le flag l interdit physiquement). ---
      STALL_FILE="$RECEIPTS_DIR/last_audit_${PHASE}.sha256"
      REDIRECT_FLAG="$RECEIPTS_DIR/redirect_attempt_${PHASE}.used"
      STALL_RC=1
      audit_same_as_previous "$STALL_FILE" "$AUDIT_CODEX" && STALL_RC=0
      case "$(stall_action "$STALL_RC" "$REDIRECT_FLAG")" in
        redirect)
          # 1er stall de la sequence : redirection chirurgicale UNE fois vers GLM.
          EXTRACTED="$(extract_findings "$AUDIT_CODEX")"
          REDIRECT_PROMPT="$(build_redirect_prompt "$EXTRACTED")"
          { echo "REDIRECT_CHIRURGICAL (phase $PHASE, stall : verdict Codex identique au round precedent -- D-013 DERNIERE tentative avant FAIL)";
            echo "--- REDIRECT_PROMPT ---"; printf '%s\n' "$REDIRECT_PROMPT"; } > "$REVIEW_CLAUDE"
          cp "$REVIEW_CLAUDE" "$REVIEW_CODEX"
          mkdir -p "$RECEIPTS_DIR"
          # D-013-bis : persiste le REDIRECT_PROMPT pour que build_cur_prompt le
          # lise au prochain tour de build. Sans cette persistance, CUR_PROMPT
          # resterait le BUILD_PROMPT statique et la redirection serait inerte
          # (GLM ne la verrait jamais). Le fichier est purge APRES l'appel
          # opencode run (usage unique).
          # D-013-ter : l'engagement (pending_redirect + flag redirect_attempt)
          # est desormais TRANSACTIONNEL et atomique (commit_redirect) : aucune
          # interruption (SIGTERM/SIGINT/crash) entre les deux écritures ne peut
          # laisser un état inconsistent (rollback sous scoped trap). Échec
          # d'écriture -> FAIL fail-closed (on ne peut pas engager la redirection
          # sans risquer une boucle ou une perte silencieuse).
          if commit_redirect "$RECEIPTS_DIR/pending_redirect_${PHASE}.txt" "$REDIRECT_FLAG" "$REDIRECT_PROMPT"; then
            :
          else
            echo "FAIL" > "$STATE_FILE"
            echo "[$(date -u +%FT%TZ)] STALL phase $PHASE : echec ecriture atomique (pending_redirect/redirect_attempt) -> STATE=FAIL fail-closed (redirection non engageable)" >> "$LOG"
            exit 0
          fi
          # NB : on NE consigne PAS le sha courant dans STALL_FILE et on N
          # incremente PAS audit_repairs. Le round de redirection doit etre
          # compare au MEME sha precedent (sinon un audit identique apres
          # redirection ne serait plus detecte comme stalled). Le sha precedent
          # reste donc valide pour le round N+1, et la presence du flag force le
          # FAIL si l audit est encore identique.
          echo "RUNNING" > "$STATE_FILE"
          echo "[$(date -u +%FT%TZ)] STALL_DETECTED phase $PHASE : verdict Codex identique au round precedent -> redirection chirurgicale vers GLM (1 seule tentative, flag redirect_attempt_${PHASE}.used pose), STATE=RUNNING, pas de FAIL immediat" >> "$LOG"
          continue ;;
        fail)
          # 2e stall APRES redirection deja tentee : FAIL immediat fail-closed,
          # message exact exige par D-013. Pas de 3e tentative, pas d attente du
          # plafond MAX_*_REPAIR.
          echo "FAIL" > "$STATE_FILE"
          echo "[$(date -u +%FT%TZ)] STALL_DETECTED phase $PHASE : meme finding non resolu APRES tentative de redirection chirurgicale -> arret fail-closed, intervention humaine necessaire (pas d attente du budget $MAX_REPAIR)" >> "$LOG"
          exit 0 ;;
        normal)
          # Pas stalled : progres reel (audit different). Reset du flag de
          # redirection pour cette phase -- une NOUVELLE sequence de stall aura
          # droit a sa propre redirection (bornage par sequence, pas global).
          if [ -f "$REDIRECT_FLAG" ]; then
            # D-013-ter : purge explicite + loggee du flag (plus de rm muet).
            purge_file_logged "$REDIRECT_FLAG" "redirect_attempt_${PHASE}.used (reset progres reel)"
            echo "[$(date -u +%FT%TZ)] phase $PHASE : audit different du precedent apres redirection -> progres reel, reset du flag redirect_attempt, boucle normale (budget audit_repairs standard)" >> "$LOG"
          fi ;;
      esac
      mkdir -p "$RECEIPTS_DIR"
      # D-013-ter : écriture atomique (tmp-puis-mv) du sha : une écriture
      # interrompue laisserait un sha partiel/vide -> audit_same_as_previous
      # faussé (faux négatif de stall). Échec -> on purge le stall file (prochain
      # round repart propre, pas de sha corrompu) + log explicite.
      # D-013-quater : le SHA consigné est celui de la signature P1/High
      # (stall_signature), PAS du rapport entier -- la détection de stall ne
      # porte plus que sur les findings critiques. Si le rapport courant est
      # sans P1/High, stall_signature est vide -> on consigne vide (rounds sans
      # finding critique = jamais stalled, par construction d'audit_same_as_previous).
      # Un échec de calcul du parser (rc 1) est traité comme l'échec d'écriture :
      # purge du stall file + log (on ne consigne JAMAIS une signature
      # incalculable, le prochain round repart propre).
      if STALL_SIG="$(stall_signature "$AUDIT_CODEX")" &&
         atomic_write_exact "$STALL_FILE" "$STALL_SIG"; then
        :
      else
        purge_file_logged "$STALL_FILE" "last_audit_${PHASE}.sha256"
        echo "[$(date -u +%FT%TZ)] phase $PHASE : echec calcul/ecriture last_audit sha -> stall file purge" >> "$LOG"
      fi
      audit_repairs=$((audit_repairs+1))
      if [ "$audit_repairs" -gt "$MAX_REPAIR" ]; then
        echo "FAIL" > "$STATE_FILE"
        echo "[$(date -u +%FT%TZ)] audits phase $PHASE non-OK apres $MAX_REPAIR rounds de repair -> STATE=FAIL -> arret" >> "$LOG"
        exit 0
      fi
      { echo "AUDIT_REPAIR_NEEDED (phase $PHASE, round $audit_repairs)"; echo "--- Codex audit ---"; cat "$AUDIT_CODEX" 2>/dev/null; } > "$REVIEW_CLAUDE"
      cp "$REVIEW_CLAUDE" "$REVIEW_CODEX"
      echo "RUNNING" > "$STATE_FILE"
      echo "[$(date -u +%FT%TZ)] audit phase $PHASE non-OK (round $audit_repairs) -> findings Codex routees vers review, STATE=RUNNING, boucle" >> "$LOG"
      continue ;;
    build)
      : ;;   # RUNNING (etat nominal) -> on continue vers la boucle de build
    illegal)
      # P0 finding 6 : etat INCONNU/illegal dans CAMPAIGN_STATE. Le pilote ne le
      # repare JAMAIS silencieusement (l'ancien code le laissait tomber a la
      # boucle de build = traite comme RUNNING). Fail-closed + message clair.
      echo "[$(date -u +%FT%TZ)] STATE='$ST' INCONNU/illegal dans $STATE_FILE -> arret fail-closed (aucune reparation silencieuse). Etats legaux : RUNNING, READY_FOR_FINAL_AUDIT, WAITING_INFRA, WAITING_HUMAN_BOSS_GO, WAITING_HUMAN, FAIL, DONE, MEMORY_SYSTEM_FAIL (cf. MASTER_ORDER MACHINE A ETATS)." >> "$LOG"
      echo "Etat illegal '$ST' dans $STATE_FILE -> arret fail-closed (voir MASTER_ORDER § MACHINE A ETATS). Aucune reinitialisation silencieuse ; corriges l'etat a la main si voulu." >&2
      exit 1 ;;
  esac

  # --- Garde mémoire fail-closed AVANT tout appel agent (AUTORITÉ UNIQUE :
  # MASTER_ORDER § MACHINE À ÉTATS, point « Mémoire de leçons »). C'est une
  # garde P0 de la machine à états, applicable à CHAQUE itération builder
  # toutes phases confondues — PAS une fonction P1. L'ancien commentaire la
  # présentait comme un livrable P1 du driver : SECONDE autorité contradictoire
  # (le prompt P1 point 4 ne fait qu'AJOUTER le test formel de ce hook déjà
  # existant : « le hook driver existe deja ») ; corrigé pour que la SEULE
  # autorité des états/gardes soit MASTER_ORDER § MACHINE À ÉTATS. ---
  # rc=0 (leçons trouvees) et rc=2 (memoire valide, aucune leçon pertinente) sont sains ;
  # rc=1 (store corrompu/schema invalide) ou injecteur manquant = MEMORY_SYSTEM_FAIL.
  if [ ! -f "factory/bin/lesson_injector.py" ]; then
    echo "MEMORY_SYSTEM_FAIL" > "$STATE_FILE"
    echo "[$(date -u +%FT%TZ)] iter $i: lesson_injector.py INTROUVABLE -> STATE=MEMORY_SYSTEM_FAIL -> arret" >> "$LOG"
    exit 1
  fi
  INJ_ERR="$RECEIPTS_DIR/injector_stderr.$$"
  python3 factory/bin/lesson_injector.py "healthcheck driver preflight" --format quiet >/dev/null 2>"$INJ_ERR"
  INJ_RC=$?
  # Contrat strict (contre-relecture GPT) : rc=0, OU rc=2 AVEC stderr vide (= MEMORY_VALID_NO_MATCH,
  # seul cas rc=2 legitime de l injecteur). Un rc=2 avec stderr (erreur argparse/CLI) = panne.
  if [ "$INJ_RC" -eq 0 ] || { [ "$INJ_RC" -eq 2 ] && [ ! -s "$INJ_ERR" ]; }; then
    rm -f "$INJ_ERR" 2>/dev/null
  else
    cat "$INJ_ERR" >> "$LOG" 2>/dev/null
    echo "MEMORY_SYSTEM_FAIL" > "$STATE_FILE"
    echo "[$(date -u +%FT%TZ)] iter $i: lesson_injector rc=$INJ_RC avec stderr non vide ou rc inattendu -> STATE=MEMORY_SYSTEM_FAIL -> arret" >> "$LOG"
    exit 1
  fi
  PHASE=$(read_phase) || { echo "[$(date -u +%FT%TZ)] phase invalide dans $PHASE_FILE -> arret fail-closed (aucune reinit silencieuse)" >> "$LOG"; exit 1; }
  # D-013-bis : CUR_PROMPT est construit par build_cur_prompt, qui PREPEND le
  # contenu d une eventuelle redirection chirurgicale D-013 (fichier
  # pending_redirect_PHASE.txt) au BUILD_PROMPT standard. Avant ce branchement,
  # CUR_PROMPT etait TOUJOURS assigne statiquement depuis BUILD_PROMPT_P0/P1 et
  # ne lisait JAMAIS REVIEW_CLAUDE/REVIEW_CODEX/REDIRECT_PROMPT -> la redirection
  # D-013 etait structurellement presente mais fonctionnellement inerte.
  CUR_PROMPT="$(build_cur_prompt "$PHASE")"
  echo "[$(date -u +%FT%TZ)] iter $i (state=$ST, phase=$PHASE) -> GLM build (opencode, zai-coding-plan/glm-5.2 force)" >> "$LOG"
  # D-013-ter : section critique. pending_redirect_PHASE.txt (s'il existe, ie
  # juste apres une redirection D-013) doit etre purge meme si le pilote est tue
  # (SIGTERM/SIGINT/SIGHUP) ou crashe pendant l'appel opencode run -- sinon la
  # redirection fuierait vers un 2e tour (violation de l usage unique). On etend
  # TEMPORAIREMENT le trap EXIT global (sauvegarde -> restauration exacte apres
  # la section ; INT/TERM/HUP laisses intacts, ils funnel vers EXIT via 'exit
  # 143'). Sans cette scoped trap, un kill pendant opencode laissait le fichier.
  _prf="$RECEIPTS_DIR/pending_redirect_${PHASE}.txt"
  enter_scoped_purge "$_prf"
  # ADAPTE CETTE LIGNE si le smoke-test opencode montre une autre syntaxe (mais garde TOUJOURS --model zai-coding-plan/*) :
  opencode run --model zai-coding-plan/glm-5.2 "$CUR_PROMPT" >> "$LOG" 2>&1
  rc=$?
  # D-013-bis / D-013-ter : purge du fichier pending_redirect APRES l'appel
  # opencode run -> la redirection chirurgicale est consommee (GLM l a recue),
  # usage UNIQUE, jamais de re-injection. purge_file_logged : explicite + loggee
  # (plus de 'rm -f ... 2>/dev/null' muet ; n avale pas l echec).
  purge_file_logged "$_prf" "pending_redirect_${PHASE}"
  exit_scoped_purge
  if [ "$rc" -eq 0 ]; then
    infra_fails=0
  else
    infra_fails=$((infra_fails+1))
    echo "[$(date -u +%FT%TZ)] iter $i: opencode rc=$rc, infra_fails=$infra_fails/$MAX_INFRA_FAILS" >> "$LOG"
    if [ "$infra_fails" -gt "$MAX_INFRA_FAILS" ]; then
      echo "WAITING_INFRA" > "$STATE_FILE"
      echo "[$(date -u +%FT%TZ)] $MAX_INFRA_FAILS echecs infra consecutifs -> STATE=WAITING_INFRA -> arret" >> "$LOG"
      exit 0
    fi
    apply_backoff "$infra_fails"
    continue
  fi
  ensure_build_branch   # D-001 : GLM doit rester hors de main

  echo "[$(date -u +%FT%TZ)] iter $i -> review de tranche Codex seul (independant, lecture seule -- Claude retire de la boucle de review)" >> "$LOG"

  # D-002 : diff du dernier commit embarqué dans le prompt (les reviewers n'ont que Read/Grep/Glob).
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    DIFF=$(git --no-pager diff HEAD~1 HEAD)
  else
    DIFF=$(git --no-pager show --root --format=fuller HEAD)
  fi
  DIFF_TRUNC=0
  if [ "${#DIFF}" -gt 20000 ]; then DIFF="${DIFF:0:20000}"; DIFF_TRUNC=1; fi
  REVIEW_PROMPT="$REVIEW_HEADER

Repo courant : $(pwd) (branche $(git symbolic-ref --short HEAD 2>/dev/null || echo detached)).
Diff du dernier commit a reviewer :
------------------8<------------------
$DIFF
------------------8<------------------
$([ "$DIFF_TRUNC" = 1 ] && echo "(DIFF TRONQUE - ouvre les fichiers pertinents via Read pour le detail.)")"

  # FIX 1 : purge du cache modeles Codex AVANT chaque appel 'codex exec' (meme
  # garde que le bloc audit -- evite le bug CLI "supports_reasoning_summaries").
  rm -f "$HOME/.codex/models_cache.json" 2>/dev/null || true
  if ! codex exec -s read-only --skip-git-repo-check "$REVIEW_PROMPT" > "$REVIEW_CODEX" 2>>"$LOG"; then
    echo "[$(date -u +%FT%TZ)] iter $i: review codex rc non-zero" >> "$LOG"
  fi

  # FIX 2 : bruit CLI du cache fuite dans REVIEW_CODEX -> infra_fail, PAS une
  # review valide (sinon le bruit etait traite comme finding/round consomme
  # pour du simple bruit infra). Meme logique backoff/infra_fails que le bloc
  # audit et que la garde vide ci-dessous.
  if codex_cache_bug_in_file "$REVIEW_CODEX"; then
    infra_fails=$((infra_fails+1))
    echo "[$(date -u +%FT%TZ)] iter $i: codex cache bug detecte -> traite comme infra_fail, pas comme review (infra_fails=$infra_fails/$MAX_INFRA_FAILS)" >> "$LOG"
    if [ "$infra_fails" -gt "$MAX_INFRA_FAILS" ]; then
      echo "WAITING_INFRA" > "$STATE_FILE"
      echo "[$(date -u +%FT%TZ)] $MAX_INFRA_FAILS echecs infra consecutifs -> STATE=WAITING_INFRA -> arret" >> "$LOG"
      exit 0
    fi
    apply_backoff "$infra_fails"
    continue
  fi

  # D-005 : un reviewer muet = echec infra (pas de relance immédiate admise).
  if [ ! -s "$REVIEW_CODEX" ]; then
    infra_fails=$((infra_fails+1))
    echo "[$(date -u +%FT%TZ)] iter $i: review codex vide, infra_fails=$infra_fails/$MAX_INFRA_FAILS" >> "$LOG"
    if [ "$infra_fails" -gt "$MAX_INFRA_FAILS" ]; then
      echo "WAITING_INFRA" > "$STATE_FILE"
      echo "[$(date -u +%FT%TZ)] $MAX_INFRA_FAILS echecs infra consecutifs -> STATE=WAITING_INFRA -> arret" >> "$LOG"
      exit 0
    fi
    apply_backoff "$infra_fails"
    continue
  fi
  infra_fails=0
  # Si un finding P1/High est relevé, il restera dans les fichiers de review ; le BUILD_PROMPT
  # de la prochaine itération ordonne à GLM de le fixer d'abord. Pas de relance immédiate ici.
  sleep 5
  done
  echo "[$(date -u +%FT%TZ)] MAX_ITERS atteint -> arret pilote" >> "$LOG"
}

# Exécute le pilote seulement s'il est invoqué directement (pas lorsqu'il est sourcé par les tests).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
