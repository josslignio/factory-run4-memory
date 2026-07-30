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
MAX_P0_REPAIR=30            # releve 30/07 (Jocelyn) : run jusqu au bout de P1 sans interruption artificielle -- reste fail-closed sur memoire corrompue/etat illegal
MAX_P1_REPAIR=30            # releve 30/07 (Jocelyn) : meme raison, coherence P0/P1
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

FINAL_AUDIT_PROMPT='Tu es un reviewer independant de Run 4, factory de Jocelyn. Ceci est la review FINALE avant merge. Ne review PAS seulement le dernier diff : audite l INTEGRALITE du code produit dans le repo courant (tous les fichiers factory/bin/*.py, memory/, tests). Cherche exhaustivement : validation de donnees manquante, gestion d erreurs incomplete, fuites de ressources, conditions de concurrence, cas limites. Verifie aussi que le resultat de l ablation A/B dans reports/RUN4_FINAL_REPORT.md est un chiffre reel trace a une execution reelle, pas invente. Tu disposes uniquement des outils Read/Grep/Glob (lecture seule). Rends un rapport complet dont la PREMIERE LIGNE est EXACTEMENT le token de verdict exige par la note de phase ci-dessus (rien d autre sur cette ligne), puis les findings tries par severite (P1/P2/P3), chaque finding trace fichier:ligne.'

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
  local ST0 OTHERS RESUME_PHASE
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
  elif ! read_phase >/dev/null; then
    echo "Phase inconnue dans $PHASE_FILE (ni P0 ni P1) -> refus fail-closed, aucune reinitialisation silencieuse." >&2
    exit 1
  fi
  start_heartbeat
  echo "[$(date -u +%FT%TZ)] === RUN4 DRIVER START (review Codex seul -- Claude retire 30/07, fixes D-001..D-005) ===" >> "$LOG"
  ensure_build_branch

  local infra_fails=0 audit_repairs=0
  local ST rc i DIFF DIFF_TRUNC REVIEW_PROMPT PID_CLAUDE PID_CODEX
  local PHASE PHASE_NOTE MAX_REPAIR CUR_PROMPT INJ_RC INJ_ERR TOKEN WT_DIRTY WT_STATE WT_DIFF_SHA
  local PREV_ST
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
        PHASE_NOTE="AUDIT DE PHASE P0 UNIQUEMENT : verifie que les 6 findings P0 (source-tag/evidence, finding vide fail-closed, ecriture concurrente bootstrap, credit fd comportemental, claim ablation honnete, machine a etats) sont fermes par des tests reels, et qu AUCUN changement de phase P1 (receipt, promotion automatique) n a ete introduit avant le checkpoint. PREMIERE LIGNE de ta reponse : EXACTEMENT PHASE_P0_PASS si tout est ferme et prouve, sinon EXACTEMENT PHASE_P0_FAIL suivi des findings."
        TOKEN="PHASE_P0_PASS"
        MAX_REPAIR="$MAX_P0_REPAIR"
      else
        PHASE_NOTE="AUDIT DE PHASE P1 : le checkpoint P0 est fige. Verifie les 4 fonctions Sharp Core (gate receipt reel, verdict codex artefact, promotion automatique verifiante, injection fail-closed) et les tests adversariaux associes. PREMIERE LIGNE de ta reponse : EXACTEMENT PHASE_P1_PASS si tout est branche et prouve, sinon EXACTEMENT PHASE_P1_FAIL suivi des findings."
        TOKEN="PHASE_P1_PASS"
        MAX_REPAIR="$MAX_P1_REPAIR"
      fi
      echo "[$(date -u +%FT%TZ)] iter $i: GLM se declare pret -> audit final phase $PHASE (Codex seul, reviewer independant, lecture seule -- Claude retire de la boucle de review sur demande explicite Jocelyn, economie de quota)" >> "$LOG"
      codex exec -s read-only --skip-git-repo-check "$PHASE_NOTE
$FINAL_AUDIT_PROMPT" > "$AUDIT_CODEX" 2>>"$LOG" \
        || echo "[$(date -u +%FT%TZ)] iter $i: audit codex rc non-zero" >> "$LOG"
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
          audit_repairs=0
          echo "RUNNING" > "$STATE_FILE"
          echo "[$(date -u +%FT%TZ)] audit P0 OK (Codex seul) -> checkpoint P0 fige dans $RECEIPTS_DIR/checkpoint_p0 -> PHASE=P1, STATE=RUNNING" >> "$LOG"
          continue
        fi
        echo "WAITING_HUMAN_BOSS_GO" > "$STATE_FILE"
        echo "[$(date -u +%FT%TZ)] audit P1 OK (Codex seul, PRET A MERGER) -> STATE=WAITING_HUMAN_BOSS_GO -> arret pilote" >> "$LOG"
        exit 0
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
  if [ "$PHASE" = "P1" ]; then CUR_PROMPT="$BUILD_PROMPT_P1"; else CUR_PROMPT="$BUILD_PROMPT_P0"; fi
  echo "[$(date -u +%FT%TZ)] iter $i (state=$ST, phase=$PHASE) -> GLM build (opencode, zai-coding-plan/glm-5.2 force)" >> "$LOG"
  # ADAPTE CETTE LIGNE si le smoke-test opencode montre une autre syntaxe (mais garde TOUJOURS --model zai-coding-plan/*) :
  if opencode run --model zai-coding-plan/glm-5.2 "$CUR_PROMPT" >> "$LOG" 2>&1; then
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

  if ! codex exec -s read-only --skip-git-repo-check "$REVIEW_PROMPT" > "$REVIEW_CODEX" 2>>"$LOG"; then
    echo "[$(date -u +%FT%TZ)] iter $i: review codex rc non-zero" >> "$LOG"
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
