#!/usr/bin/env bash
# Pilote headless Run #4 (Mémoire / Experience Compiler).
# GLM (via opencode, zai-coding-plan) construit ; Claude ET Codex reviewent chaque tranche
# EN PARALLÈLE (deux avis indépendants) et font chacun l'audit final exhaustif.
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
#   D-004 (Codex#2) : audit final gating — P1 -> retour RUNNING (cap 2) au lieu de WAITING_HUMAN_BOSS_GO.
#   D-005 (Codex#3) : backoff infra 30/120/300s, max 3 échecs -> WAITING_INFRA.

set -u
REPO="$HOME/factory-run4-memory"
STATE_FILE="factory/campaigns/CAMPAIGN_STATE"
LOG="reports/run4-driver.log"
REVIEW_CLAUDE="reports/run4-review-latest-claude.md"
REVIEW_CODEX="reports/run4-review-latest-codex.md"
AUDIT_CLAUDE="reports/RUN4_FINAL_AUDIT_CLAUDE.md"
AUDIT_CODEX="reports/RUN4_FINAL_AUDIT_CODEX.md"

BUILD_BRANCH="run4/build"
MAX_ITERS=300
MAX_INFRA_FAILS=3            # D-005 : max 3 retries infra (règle 6)
BACKOFFS=(30 120 300)        # D-005 : backoff 30s/120s/300s
MAX_AUDIT_REPAIR=2          # D-004 : plafond de rounds de correction post-audit

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
  raw=${raw//[[:space:]]/}                 # retire tout whitespace
  raw=${raw#CAMPAIGN_STATE=}               # tolère un préfixe (ne matche jamais un état inconnu)
  printf '%s' "$raw"
}

BUILD_PROMPT='Continue Run 4 (Memoire / Experience Compiler) en AUTONOMIE TOTALE selon ~/factory-run4-memory/MASTER_ORDER_RUN4_MEMORY.md. Reprends au DERNIER commit, ne recommence RIEN de deja prouve. Si reports/run4-review-latest-claude.md OU reports/run4-review-latest-codex.md existe et contient un finding P1/High non resolu, fixe-le AVANT toute nouvelle capacite. Avance UNE tranche concrete (une sous-capacite de la §1 a §4), teste-la reellement, committe, puis termine ta reponse. Aucune question, aucun menu, ne t arrete a aucun checkpoint. INTERDIT: cleanup/rm large ou recursif. main INTACT, aucun push/merge/tag/deploy : travaille sur la branche run4/build. Quand TOUTES les capacites §1-§4 sont construites, testees et que le rapport d ablation A/B contient un resultat reel (chiffre, pas invente), ecris UNIQUEMENT la valeur READY_FOR_FINAL_AUDIT (sans prefixe, sans espaces, sans newline supplementaire) dans le fichier factory/campaigns/CAMPAIGN_STATE (en remplacement de la valeur RUNNING) et arrete-toi la. Sinon laisse la valeur RUNNING dans ce fichier.'

REVIEW_HEADER='Tu es un reviewer independant (jamais le builder) de Run 4, factory de Jocelyn. Review UNIQUEMENT le dernier commit du repo courant. Cherche : bugs reels reproduits, donnees inventees non tracees fichier:ligne, violations des INTERDITS ABSOLUS du master order. Tu disposes uniquement des outils Read/Grep/Glob (lecture seule) ; le diff du dernier commit t est fourni ci-dessous. Commence ta reponse par PASS ou FIX_NEEDED en premiere ligne, puis la liste des findings avec fichier:ligne si FIX_NEEDED, vide si PASS. Sois concis, ceci est une review de tranche, pas un audit complet.'

FINAL_AUDIT_PROMPT='Tu es un reviewer independant de Run 4, factory de Jocelyn. Ceci est la review FINALE avant merge. Ne review PAS seulement le dernier diff : audite l INTEGRALITE du code produit dans le repo courant (tous les fichiers factory/bin/*.py, memory/, tests). Cherche exhaustivement : validation de donnees manquante, gestion d erreurs incomplete, fuites de ressources, conditions de concurrence, cas limites. Verifie aussi que le resultat de l ablation A/B dans reports/RUN4_FINAL_REPORT.md est un chiffre reel trace a une execution reelle, pas invente. Tu disposes uniquement des outils Read/Grep/Glob (lecture seule). Rends un rapport complet avec un verdict global sur sa premiere ligne : PRET A MERGER ou PAS PRET, puis les findings tries par severite (P1/P2/P3), chaque finding trace fichier:ligne.'

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

# --- D-004 + fix audit final Claude (P1-2) : verdict d'audit STRICT. ---
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
  echo "[$(date -u +%FT%TZ)] === RUN4 DRIVER START (dual review Claude+Codex, fixes D-001..D-005) ===" >> "$LOG"
  ensure_build_branch

  local infra_fails=0 audit_repairs=0
  local ST rc i DIFF DIFF_TRUNC REVIEW_PROMPT PID_CLAUDE PID_CODEX

  for i in $(seq 1 $MAX_ITERS); do
  ST=$(read_state)
  case "$ST" in
    WAITING_HUMAN_BOSS_GO|WAITING_HUMAN|FAIL|DONE)
      echo "[$(date -u +%FT%TZ)] STATE=$ST -> arret pilote (iter $i)" >> "$LOG"; exit 0 ;;
    WAITING_INFRA)
      echo "[$(date -u +%FT%TZ)] STATE=WAITING_INFRA -> arret pilote (quota/reseau, iter $i)" >> "$LOG"; exit 0 ;;
    READY_FOR_FINAL_AUDIT)
      echo "[$(date -u +%FT%TZ)] iter $i: GLM se declare pret -> audit final Claude + Codex (independants, lecture seule)" >> "$LOG"
      claude -p "$FINAL_AUDIT_PROMPT" --dangerously-skip-permissions --allowedTools "Read Grep Glob" > "$AUDIT_CLAUDE" 2>>"$LOG" \
        || echo "[$(date -u +%FT%TZ)] iter $i: audit claude rc non-zero" >> "$LOG"
      codex exec -s read-only --skip-git-repo-check "$FINAL_AUDIT_PROMPT" > "$AUDIT_CODEX" 2>>"$LOG" \
        || echo "[$(date -u +%FT%TZ)] iter $i: audit codex rc non-zero" >> "$LOG"
      # D-004 : porte P1 avant WAITING_HUMAN_BOSS_GO (audit_ok défini au niveau top-level).
      if audit_ok "$AUDIT_CLAUDE" && audit_ok "$AUDIT_CODEX"; then
        echo "WAITING_HUMAN_BOSS_GO" > "$STATE_FILE"
        echo "[$(date -u +%FT%TZ)] audits OK (PRET A MERGER x2) -> STATE=WAITING_HUMAN_BOSS_GO -> arret pilote" >> "$LOG"
        exit 0
      fi
      audit_repairs=$((audit_repairs+1))
      if [ "$audit_repairs" -gt "$MAX_AUDIT_REPAIR" ]; then
        echo "FAIL" > "$STATE_FILE"
        echo "[$(date -u +%FT%TZ)] audits non-OK apres $MAX_AUDIT_REPAIR rounds de repair -> STATE=FAIL -> arret" >> "$LOG"
        exit 0
      fi
      # Router les findings d'audit vers les fichiers de review de tranche pour que GLM les corrige.
      { echo "AUDIT_REPAIR_NEEDED (round $audit_repairs)"; echo "--- Claude audit ---"; cat "$AUDIT_CLAUDE" 2>/dev/null; echo; echo "--- Codex audit ---"; cat "$AUDIT_CODEX" 2>/dev/null; } > "$REVIEW_CLAUDE"
      cp "$REVIEW_CLAUDE" "$REVIEW_CODEX"
      echo "RUNNING" > "$STATE_FILE"
      echo "[$(date -u +%FT%TZ)] audits non-OK (round $audit_repairs) -> findings routes vers review, STATE=RUNNING, boucle" >> "$LOG"
      continue ;;
  esac

  echo "[$(date -u +%FT%TZ)] iter $i (state=$ST) -> GLM build (opencode, zai-coding-plan/glm-5.2 force)" >> "$LOG"
  # ADAPTE CETTE LIGNE si le smoke-test opencode montre une autre syntaxe (mais garde TOUJOURS --model zai-coding-plan/*) :
  if opencode run --model zai-coding-plan/glm-5.2 "$BUILD_PROMPT" >> "$LOG" 2>&1; then
    infra_fails=0
  else
    rc=$?
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

  echo "[$(date -u +%FT%TZ)] iter $i -> review de tranche Claude + Codex (independants, en parallele, lecture seule)" >> "$LOG"

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

  claude -p "$REVIEW_PROMPT" --dangerously-skip-permissions --allowedTools "Read Grep Glob" > "$REVIEW_CLAUDE" 2>>"$LOG" &
  PID_CLAUDE=$!
  codex exec -s read-only --skip-git-repo-check "$REVIEW_PROMPT" > "$REVIEW_CODEX" 2>>"$LOG" &
  PID_CODEX=$!
  wait "$PID_CLAUDE" 2>/dev/null || echo "[$(date -u +%FT%TZ)] iter $i: review claude rc non-zero" >> "$LOG"
  wait "$PID_CODEX" 2>/dev/null || echo "[$(date -u +%FT%TZ)] iter $i: review codex rc non-zero" >> "$LOG"

  # D-005 : un reviewer muet = echec infra (pas de relance immédiate admise).
  if [ ! -s "$REVIEW_CLAUDE" ] || [ ! -s "$REVIEW_CODEX" ]; then
    infra_fails=$((infra_fails+1))
    echo "[$(date -u +%FT%TZ)] iter $i: review vide (claude=$( [ -s "$REVIEW_CLAUDE" ] && echo ok || echo vide ), codex=$( [ -s "$REVIEW_CODEX" ] && echo ok || echo vide )), infra_fails=$infra_fails/$MAX_INFRA_FAILS" >> "$LOG"
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
