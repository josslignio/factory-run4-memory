#!/usr/bin/env bash
# Pilote headless Run #4 (Mémoire / Experience Compiler).
# GLM (via opencode, zai-coding-plan) construit ; Claude ET Codex reviewent chaque tranche
# EN PARALLÈLE (deux avis indépendants) et font chacun l'audit final exhaustif.
# Ne s'arrête jamais tout seul sauf état terminal.
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

set -u
cd ~/factory-run4-memory || { echo "Repo ~/factory-run4-memory introuvable — crée-le et colle MASTER_ORDER_RUN4_MEMORY.md dedans d'abord." >&2; exit 1; }
mkdir -p reports factory/campaigns memory
STATE_FILE="factory/campaigns/CAMPAIGN_STATE"
LOG="reports/run4-driver.log"
REVIEW_CLAUDE="reports/run4-review-latest-claude.md"
REVIEW_CODEX="reports/run4-review-latest-codex.md"
AUDIT_CLAUDE="reports/RUN4_FINAL_AUDIT_CLAUDE.md"
AUDIT_CODEX="reports/RUN4_FINAL_AUDIT_CODEX.md"
[ -f "$STATE_FILE" ] || echo RUNNING > "$STATE_FILE"
MAX_ITERS=300

BUILD_PROMPT='Continue Run 4 (Memoire / Experience Compiler) en AUTONOMIE TOTALE selon ~/factory-run4-memory/MASTER_ORDER_RUN4_MEMORY.md. Reprends au DERNIER commit, ne recommence RIEN de deja prouve. Si reports/run4-review-latest-claude.md OU reports/run4-review-latest-codex.md existe et contient un finding P1/High non resolu, fixe-le AVANT toute nouvelle capacite. Avance UNE tranche concrete (une sous-capacite de la §1 a §4), teste-la reellement, committe, puis termine ta reponse. Aucune question, aucun menu, ne t arrete a aucun checkpoint. INTERDIT: cleanup/rm large ou recursif. main INTACT, aucun push/merge/tag/deploy. Quand TOUTES les capacites §1-§4 sont construites, testees et que le rapport d ablation A/B contient un resultat reel (chiffre, pas invente), ecris factory/campaigns/CAMPAIGN_STATE=READY_FOR_FINAL_AUDIT au lieu de RUNNING et arrete-toi la. Sinon garde CAMPAIGN_STATE=RUNNING.'

REVIEW_PROMPT='Tu es un reviewer independant (jamais le builder) de Run 4, factory de Jocelyn. Review UNIQUEMENT le dernier commit (diff vs le commit precedent) du repo ~/factory-run4-memory. Cherche : bugs reels reproduits, donnees inventees non tracees fichier:ligne, violations des INTERDITS ABSOLUS du master order. Commence ta reponse par PASS ou FIX_NEEDED en premiere ligne, puis la liste des findings avec fichier:ligne si FIX_NEEDED, vide si PASS. Sois concis, ceci est une review de tranche, pas un audit complet.'

FINAL_AUDIT_PROMPT='Tu es un reviewer independant de Run 4, factory de Jocelyn. Ceci est la review FINALE avant merge. Ne review PAS seulement le dernier diff : audite l INTEGRALITE du code produit dans ~/factory-run4-memory (tous les fichiers factory/bin/*.py, memory/, tests). Cherche exhaustivement : validation de donnees manquante, gestion d erreurs incomplete, fuites de ressources, conditions de concurrence, cas limites. Verifie aussi que le resultat de l ablation A/B dans reports/RUN4_FINAL_REPORT.md est un chiffre reel trace a une execution reelle, pas invente. Rends un rapport complet avec un verdict global PRET A MERGER ou PAS PRET, findings tries par severite (P1/P2/P3), chaque finding trace fichier:ligne.'

echo "[$(date -u +%FT%TZ)] === RUN4 DRIVER START (dual review Claude+Codex) ===" >> "$LOG"

for i in $(seq 1 $MAX_ITERS); do
  ST=$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)
  case "$ST" in
    WAITING_HUMAN_BOSS_GO|WAITING_HUMAN|WAITING_INFRA|FAIL|DONE)
      echo "[$(date -u +%FT%TZ)] STATE=$ST -> arret pilote (iter $i)" >> "$LOG"; exit 0 ;;
    READY_FOR_FINAL_AUDIT)
      echo "[$(date -u +%FT%TZ)] iter $i: GLM se declare pret -> audit final Claude + Codex (independants)" >> "$LOG"
      claude -p "$FINAL_AUDIT_PROMPT" --dangerously-skip-permissions > "$AUDIT_CLAUDE" 2>>"$LOG"
      codex exec --skip-git-repo-check "$FINAL_AUDIT_PROMPT" > "$AUDIT_CODEX" 2>>"$LOG"
      echo "WAITING_HUMAN_BOSS_GO" > "$STATE_FILE"
      echo "[$(date -u +%FT%TZ)] audits finaux ecrits ($AUDIT_CLAUDE, $AUDIT_CODEX) -> STATE=WAITING_HUMAN_BOSS_GO -> arret pilote" >> "$LOG"
      exit 0 ;;
  esac

  echo "[$(date -u +%FT%TZ)] iter $i (state=$ST) -> GLM build (opencode, zai-coding-plan/glm-5.2 force)" >> "$LOG"
  # ADAPTE CETTE LIGNE si le smoke-test opencode montre une autre syntaxe (mais garde TOUJOURS --model zai-coding-plan/*) :
  opencode run --model zai-coding-plan/glm-5.2 "$BUILD_PROMPT" >> "$LOG" 2>&1 || echo "[$(date -u +%FT%TZ)] iter $i: opencode a retourne code non-zero (on continue)" >> "$LOG"

  echo "[$(date -u +%FT%TZ)] iter $i -> review de tranche Claude + Codex (independants, en parallele)" >> "$LOG"
  claude -p "$REVIEW_PROMPT" --dangerously-skip-permissions > "$REVIEW_CLAUDE" 2>>"$LOG" &
  PID_CLAUDE=$!
  # ADAPTE CETTE LIGNE si le smoke-test codex montre une autre syntaxe :
  codex exec --skip-git-repo-check "$REVIEW_PROMPT" > "$REVIEW_CODEX" 2>>"$LOG" &
  PID_CODEX=$!
  wait "$PID_CLAUDE" 2>/dev/null || echo "[$(date -u +%FT%TZ)] iter $i: review claude a retourne code non-zero (on continue)" >> "$LOG"
  wait "$PID_CODEX" 2>/dev/null || echo "[$(date -u +%FT%TZ)] iter $i: review codex a retourne code non-zero (on continue)" >> "$LOG"

  sleep 5
done
echo "[$(date -u +%FT%TZ)] MAX_ITERS atteint -> arret pilote" >> "$LOG"
