#!/usr/bin/env bash
# Tests unitaires des helpers du pilote Run 4 (D-001..D-005 + fix-of-fix read_state).
# Source le pilote SANS lancer main() (le pilote a un garde `${BASH_SOURCE[0]} = $0`).
# Stdlib uniquement (bash + coreutils). Aucune dépendance externe.
#
# Usage : bash tests/test_driver_helpers.bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

source ./run_run4_autonomous.sh

TMP="$(mktemp -d)"
_cleanup_tmp() {  # NON recursif (regle 7 absolue) : fichiers directs + rmdir.
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  local f
  for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -f "$f" ] && rm -f "$f"
  done
  rmdir "$1" 2>/dev/null || true
}
trap '_cleanup_tmp "$TMP"' EXIT
STATE_FILE="$TMP/state"
LOG="$TMP/log"
PHASE_FILE="$TMP/phase"
: > "$LOG"

pass=0; fail=0
chk() { # name got want
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: $1 -> got [$2] want [$3]"; fi
}

# --- D-003 : read_state (tolérant au préfixe CAMPAIGN_STATE=, whitespace, absent) ---
echo "READY_FOR_FINAL_AUDIT" > "$STATE_FILE"
chk "read_state_plain" "$(read_state)" "READY_FOR_FINAL_AUDIT"
echo "CAMPAIGN_STATE=READY_FOR_FINAL_AUDIT" > "$STATE_FILE"
chk "read_state_prefixed" "$(read_state)" "READY_FOR_FINAL_AUDIT"
printf "  RUNNING \n" > "$STATE_FILE"
chk "read_state_ws" "$(read_state)" "RUNNING"
: > "$STATE_FILE"
chk "read_state_empty" "$(read_state)" ""
rm -f "$STATE_FILE"
chk "read_state_missing" "$(read_state)" ""

# --- P0 finding 6 (audit FAIL 27/07, fail-open) : read_state NE DOIT PAS
# réparer silencieusement un état malformé. L'ancien ${raw//[[:space:]]/}
# retirait TOUT whitespace -> "RUN NING" (espace interne) devenait "RUNNING"
# -> state_kind renvoyait 'build' (fail-open). On exige désormais que l'espace
# interne soit PRÉSERVÉ -> state_kind tranche 'illegal' -> fail-closed. ---
printf "RUN NING\n" > "$STATE_FILE"
chk "read_state_preserves_internal_ws" "$(read_state)" "RUN NING"
chk "kind_internal_ws_is_illegal" "$(state_kind "$(read_state)")" "illegal"
# idem via le VRAI garde de production : un état à espace interne fait exit 1.
( enforce_legal_transition_or_die RUNNING "$(read_state)" )
chk "prod_guard_internal_ws_state_exit1" "$?" "1"

# --- P0 finding 6 (audit FAIL 27/07) : read_phase NE DOIT PAS réparer "P 1"
# en "P1" (fail-open -> entrée en P1 sans checkpoint valide). L'ancien
# `tr -d ' \r\n'` retirait l'espace interne -> "P1" accepté à tort. ---
printf "P 1\n" > "$PHASE_FILE"
read_phase >/dev/null
chk "read_phase_rejects_internal_ws" "$?" "1"
printf "P0\n" > "$PHASE_FILE"
chk "read_phase_accepts_trimmed_P0" "$(read_phase)" "P0"
printf "  P1 \n" > "$PHASE_FILE"
chk "read_phase_trims_borders_only" "$(read_phase)" "P1"


# --- D-005 : backoff_secs 30/120/300, capped, floor ---
chk "backoff_1" "$(backoff_secs 1)" "30"
chk "backoff_2" "$(backoff_secs 2)" "120"
chk "backoff_3" "$(backoff_secs 3)" "300"
chk "backoff_4_cap" "$(backoff_secs 4)" "300"
chk "backoff_0_floor" "$(backoff_secs 0)" "30"

# --- D-004 : audit_ok (PRET A MERGER requis, fichier vide/absant/PAS PRET rejetés) ---
echo "PRET A MERGER" > "$TMP/ok"
echo "PAS PRET, P1 trouvé" > "$TMP/bad"
audit_ok "$TMP/ok";      chk "audit_ok_passes_good"      "$?" "0"
audit_ok "$TMP/bad";     chk "audit_ok_rejects_bad"      "$?" "1"
audit_ok "$TMP/missing"; chk "audit_ok_rejects_missing"  "$?" "1"

# --- P0 finding 6 : state_kind — autorité UNIQUE des états. Aucun état invalide
# n'est traité silencieusement comme RUNNING (build) ; tout état non listé ->
# 'illegal' (le pilote fail-closed, ne répare jamais silencieusement). ---
chk "kind_RUNNING"          "$(state_kind RUNNING)"                "build"
chk "kind_READY_FOR_AUDIT"  "$(state_kind READY_FOR_FINAL_AUDIT)"  "audit"
chk "kind_WAITING_INFRA"    "$(state_kind WAITING_INFRA)"          "infra_stop"
chk "kind_WAITING_HUMAN_GO" "$(state_kind WAITING_HUMAN_BOSS_GO)"  "terminal"
chk "kind_WAITING_HUMAN"    "$(state_kind WAITING_HUMAN)"          "terminal"
chk "kind_FAIL"             "$(state_kind FAIL)"                   "terminal"
chk "kind_DONE"             "$(state_kind DONE)"                   "terminal"
chk "kind_MEMORY_FAIL"      "$(state_kind MEMORY_SYSTEM_FAIL)"     "terminal"
# états illégaux -> 'illegal' (JAMAIS 'build' = jamais silencieusement RUNNING) :
chk "kind_empty"            "$(state_kind '')"                     "illegal"
chk "kind_bogus"            "$(state_kind BOGUS_STATE)"            "illegal"
chk "kind_lowercase"        "$(state_kind running)"                "illegal"
chk "kind_spaced"           "$(state_kind ' RUNNING')"             "illegal"
chk "kind_typo"             "$(state_kind READY)"                  "illegal"
chk "kind_unnormalized"     "$(state_kind 'CAMPAIGN_STATE=RUNNING')" "illegal"

# --- P0 finding 6 (transitions légales) : legal_transition — AUTORITÉ UNIQUE
# des transitions. state_kind valide les VALEURS, legal_transition valide les
# TRANSITIONS. Le pilote ne répare jamais silencieusement un état invalide :
# toute transition non listée -> 'illegal' -> main() fail-closed. ---
# transitions légales documentées (MASTER_ORDER § MACHINE À ÉTATS) :
chk "tr_id_running"          "$(legal_transition RUNNING RUNNING)"                             "legal"
chk "tr_id_ready"            "$(legal_transition READY_FOR_FINAL_AUDIT READY_FOR_FINAL_AUDIT)" "legal"
chk "tr_id_fail"             "$(legal_transition FAIL FAIL)"                                   "legal"
chk "tr_run_to_ready"        "$(legal_transition RUNNING READY_FOR_FINAL_AUDIT)"               "legal"
chk "tr_run_to_infra"        "$(legal_transition RUNNING WAITING_INFRA)"                       "legal"
chk "tr_run_to_memfail"      "$(legal_transition RUNNING MEMORY_SYSTEM_FAIL)"                  "legal"
chk "tr_ready_to_running"    "$(legal_transition READY_FOR_FINAL_AUDIT RUNNING)"               "legal"
chk "tr_ready_to_infra"      "$(legal_transition READY_FOR_FINAL_AUDIT WAITING_INFRA)"         "legal"
chk "tr_ready_to_bossgo"     "$(legal_transition READY_FOR_FINAL_AUDIT WAITING_HUMAN_BOSS_GO)"  "legal"
chk "tr_ready_to_fail"       "$(legal_transition READY_FOR_FINAL_AUDIT FAIL)"                  "legal"
chk "tr_fail_to_running"     "$(legal_transition FAIL RUNNING)"                                "legal"
# transitions ILLÉGALES (cœur du finding : un builder NE PEUT PAS écrire un
# état terminal depuis RUNNING, ni sauter audit->memory-fail, ni repartir d'un
# terminal sans RESUME_AFTER_FAIL explicite) :
chk "tr_run_to_bossgo_BAD"       "$(legal_transition RUNNING WAITING_HUMAN_BOSS_GO)"            "illegal"
chk "tr_run_to_done_BAD"         "$(legal_transition RUNNING DONE)"                             "illegal"
chk "tr_run_to_whuman_BAD"       "$(legal_transition RUNNING WAITING_HUMAN)"                    "illegal"
chk "tr_run_to_fail_BAD"         "$(legal_transition RUNNING FAIL)"                             "illegal"
chk "tr_ready_to_memfail_BAD"    "$(legal_transition READY_FOR_FINAL_AUDIT MEMORY_SYSTEM_FAIL)" "illegal"
chk "tr_ready_to_done_BAD"       "$(legal_transition READY_FOR_FINAL_AUDIT DONE)"               "illegal"
chk "tr_fail_to_ready_BAD"       "$(legal_transition FAIL READY_FOR_FINAL_AUDIT)"               "illegal"
chk "tr_bossgo_to_running_BAD"   "$(legal_transition WAITING_HUMAN_BOSS_GO RUNNING)"            "illegal"
chk "tr_done_to_running_BAD"     "$(legal_transition DONE RUNNING)"                             "illegal"
chk "tr_unknown_from_BAD"        "$(legal_transition BOGUS RUNNING)"                            "illegal"
chk "tr_unknown_to_BAD"          "$(legal_transition RUNNING BOGUS)"                            "illegal"

# --- P0 finding 6 : test RÉEL du garde de production (contre-audit Codex
# PHASE_P0_FAIL : « la machine à états n'est pas testée par une exécution
# réelle de main() »). On appelle le VRAI enforce_legal_transition_or_die —
# la fonction que main() utilise EN TÊTE DE BOUCLE — dans un sous-shell pour
# capturer son code de sortie. Plus aucune reproduction locale du garde :
# c'est le code de production qui s'exécute. Une transition légale -> exit 0
# (acceptée) ; une transition illégale -> exit 1 (fail-closed, le pilote ne
# répare JAMAIS silencieusement un état invalide). ---
# transition légale : RUNNING -> READY_FOR_FINAL_AUDIT (builder déclare fin).
( enforce_legal_transition_or_die RUNNING READY_FOR_FINAL_AUDIT )
chk "prod_guard_legal_transition_exit0" "$?" "0"
# transition légale identité : RUNNING -> RUNNING.
( enforce_legal_transition_or_die RUNNING RUNNING )
chk "prod_guard_identity_exit0" "$?" "0"
# transition illégale : RUNNING -> WAITING_HUMAN_BOSS_GO (un builder injecte
# un terminal succès en plein build -> le vrai garde de main() doit REFUSER,
# pas un arrêt muet).
( enforce_legal_transition_or_die RUNNING WAITING_HUMAN_BOSS_GO )
chk "prod_guard_illegal_transition_exit1" "$?" "1"
# transition légale : l'audit final épuise ses retries infra.
( enforce_legal_transition_or_die READY_FOR_FINAL_AUDIT WAITING_INFRA )
chk "prod_guard_legal_ready_to_infra_exit0" "$?" "0"
# état illégal depuis n'importe où : BOGUS -> RUNNING.
( enforce_legal_transition_or_die BOGUS RUNNING )
chk "prod_guard_illegal_from_bogus_exit1" "$?" "1"

# preuve structurelle : main() doit RÉELLEMENT appeler le garde de production
# en tête de boucle (sinon le garde est mort-né — précisément le finding
# « les tests ne couvrent jamais les transitions réelles de main »). On exige
# la forme d'appel exacte.
if grep -q 'enforce_legal_transition_or_die "$PREV_ST" "$ST"' "$REPO/run_run4_autonomous.sh"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: main() n'appelle pas enforce_legal_transition_or_die (garde de transition absent)"
fi

# --- P0 finding 6 (autorité UNIQUE cohérente) : les budgets documentés dans
# MASTER_ORDER_RUN4_MEMORY.md DOIVENT correspondre aux constantes du driver
# run_run4_autonomous.sh. Une contradiction (ex: « Max 2 repairs » dans une
# règle absolue vs MAX_*_REPAIR=30 dans le code) violait « une seule autorité
# documentée ». On extrait chaque budget des deux sources et on compare. ---
drv_p0=$(grep -oE 'MAX_P0_REPAIR=[0-9]+' "$REPO/run_run4_autonomous.sh" | head -1 | cut -d= -f2)
drv_p1=$(grep -oE 'MAX_P1_REPAIR=[0-9]+' "$REPO/run_run4_autonomous.sh" | head -1 | cut -d= -f2)
drv_infra=$(grep -oE 'MAX_INFRA_FAILS=[0-9]+' "$REPO/run_run4_autonomous.sh" | head -1 | cut -d= -f2)
mo_p0=$(grep -oE 'MAX_P0_REPAIR=[0-9]+' "$REPO/MASTER_ORDER_RUN4_MEMORY.md" | head -1 | cut -d= -f2)
mo_p1=$(grep -oE 'MAX_P1_REPAIR=[0-9]+' "$REPO/MASTER_ORDER_RUN4_MEMORY.md" | head -1 | cut -d= -f2)
mo_infra=$(grep -oE 'MAX_INFRA_FAILS=[0-9]+' "$REPO/MASTER_ORDER_RUN4_MEMORY.md" | head -1 | cut -d= -f2)
chk "authority_budget_p0_coherent"    "$drv_p0"    "$mo_p0"
chk "authority_budget_p1_coherent"    "$drv_p1"    "$mo_p1"
chk "authority_budget_infra_coherent" "$drv_infra" "$mo_infra"
# plus aucune contradiction « Max 2 repairs »/« Max 3 retries » héritée dans
# le MASTER_ORDER (l'ancienne règle absolue contredisait le driver réel) :
if grep -qE 'Max 2 repairs|Max 3 retries' "$REPO/MASTER_ORDER_RUN4_MEMORY.md"; then
  fail=$((fail+1)); echo "FAIL: MASTER_ORDER contient encore 'Max 2 repairs'/'Max 3 retries' (autorité non cohérente)"
else
  pass=$((pass+1))
fi

# --- P0 finding 6 (round 3, contre-audit Codex PHASE_P0_FAIL) : l'AUTORITÉ
# UNIQUE s'applique AUSSI aux COMMENTAIRES du pilote, pas seulement à
# MASTER_ORDER ni aux constantes. L'audit round 2 citait un commentaire du
# driver (« max 3 échecs » run_run4_autonomous.sh:26) qui contredisait
# MAX_INFRA_FAILS=10, et un « cap 2 » repair contredisant le budget courant :
# contradiction d'autorité À L'INTÉRIEUR du fichier du driver lui-même. On
# vérifie qu'aucune mention périmée d'un seuil de budget ne subsiste dans le
# driver (les chaînes exactes citées par l'audit), puis on généralise : tout
# seuil numérique « max N échecs » (infra) ou « cap N » (repair) présent dans
# un commentaire du driver DOIT valoir la constante correspondante. ---
for bad in 'max 2 repairs' 'max 3 retries' 'max 3 échecs' 'max 3 echecs' 'cap 2'; do
  if grep -qiF "$bad" "$REPO/run_run4_autonomous.sh"; then
    fail=$((fail+1)); echo "FAIL: driver contient l'autorité périmée '$bad' (contradictoire avec les constantes MAX_*_REPAIR / MAX_INFRA_FAILS)"
  else
    pass=$((pass+1))
  fi
done
# Generalisation : tout « max <N> échecs » dans le driver doit egaliser
# MAX_INFRA_FAILS ; tout « cap <N> » repair doit egaliser MAX_P0_REPAIR.
drv_infra_mentions=$(grep -oiE 'max[[:space:]]+[0-9]+[[:space:]]+échecs' "$REPO/run_run4_autonomous.sh" | grep -oE '[0-9]+' || true)
if [ -z "$drv_infra_mentions" ]; then
  pass=$((pass+1))   # aucune mention infra explicite : pas de contradiction possible
else
  for n in $drv_infra_mentions; do
    chk "driver_comment_infra_threshold_matches_constant($n)" "$n" "$drv_infra"
  done
fi
drv_cap_mentions=$(grep -oiE 'cap[[:space:]]+[0-9]+' "$REPO/run_run4_autonomous.sh" | grep -oE '[0-9]+' || true)
if [ -z "$drv_cap_mentions" ]; then
  pass=$((pass+1))   # aucune mention « cap N » : pas de contradiction possible
else
  for n in $drv_cap_mentions; do
    chk "driver_comment_repair_cap_matches_constant($n)" "$n" "$drv_p0"
  done
fi
# Les valeurs de l'autorite documentaire doivent egaler les constantes
# reellement executees (regression du master reste a 30 alors que le driver=6).
grep -qF "MAX_P0_REPAIR=$drv_p0" "$REPO/MASTER_ORDER_RUN4_MEMORY.md"; chk "master_p0_budget_matches_driver" "$?" "0"
grep -qF "MAX_P1_REPAIR=$drv_p1" "$REPO/MASTER_ORDER_RUN4_MEMORY.md"; chk "master_p1_budget_matches_driver" "$?" "0"
grep -qF "MAX_INFRA_FAILS=$drv_infra" "$REPO/MASTER_ORDER_RUN4_MEMORY.md"; chk "master_infra_budget_matches_driver" "$?" "0"

# --- P0 finding 6 (round 16, contre-audit Codex PHASE_P0_FAIL) : l'AUTORITÉ
# UNIQUE documentée doit être EXTERNE au code ET cohérente. L'audit citait
# deux contradictions d'autorité désormais corrigées :
#   (a) MASTER_ORDER § AUTONOMIE énumérait un sous-ensemble de 4 états +
#       « après 2 repairs », en désaccord avec le § MACHINE À ÉTATS (8 états,
#       budgets exécutés) — seconde autorité contradictoire.
#   (b) le driver étiquetait la garde mémoire « P1.4 cote driver » alors que
#       le § MACHINE À ÉTATS (point « Mémoire de leçons ») en fait une garde
#       P0 — seconde autorité contradictoire.
# On verrouille les deux corrections + la cohérence croisée état<->doc. ---
# (a1) plus aucune contradiction « après 2 repairs » dans MASTER_ORDER :
if grep -qE 'après 2 repairs|apres 2 repairs' "$REPO/MASTER_ORDER_RUN4_MEMORY.md"; then
  fail=$((fail+1)); echo "FAIL: MASTER_ORDER contient encore 'après 2 repairs' (autorité budget contradictoire)"
else
  pass=$((pass+1))
fi
# (a2) la section AUTONOMIE ne doit PLUS énumérer un sous-ensemble d'états
#      (seconde autorité) : on extrait sa 1ère ligne et on exige qu'elle
#      DEFÉRE au § MACHINE À ÉTATS plutôt que de lister RUNNING/WAITING_INFRA/
#      FAIL/WAITING_HUMAN_BOSS_GO comme « SEULS arrêts ».
if grep -E 'Les SEULS arrêts' "$REPO/MASTER_ORDER_RUN4_MEMORY.md" | grep -qE 'MACHINE À ÉTATS|AUTORITÉ UNIQUE'; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: section AUTONOMIE ne défère pas à l'autorité MACHINE À ÉTATS (énumération contradictoire)"
fi
# (a3) non-régression : la section AUTONOMIE ne liste plus les 4 états en
#      guise de « SEULS » (on vérifie l'absence du pattern 'RUNNING',
#      'WAITING_INFRA' ... sur la ligne 'SEULS arrêts').
seulsl=$(grep -E 'Les SEULS arrêts' "$REPO/MASTER_ORDER_RUN4_MEMORY.md" || true)
if printf '%s' "$seulsl" | grep -qE 'RUNNING.*WAITING_INFRA.*FAIL'; then
  fail=$((fail+1)); echo "FAIL: section AUTONOMIE énumère encore un sous-ensemble d'états (seconde autorité)"
else
  pass=$((pass+1))
fi
# (b1) plus aucune étiquette « P1.4 cote driver » (seconde autorité) :
if grep -qE 'P1\.4 cote driver|P1\.4 côté driver' "$REPO/run_run4_autonomous.sh"; then
  fail=$((fail+1)); echo "FAIL: driver étiquette encore la garde mémoire 'P1.4 cote driver' (autorité contradictoire)"
else
  pass=$((pass+1))
fi
# (b2) la garde mémoire du driver défère désormais au § MACHINE À ÉTATS :
if grep -qE 'MASTER_ORDER § MACHINE À ÉTATS.*Mémoire de leçons|Mémoire de leçons.*MASTER_ORDER § MACHINE À ÉTATS' "$REPO/run_run4_autonomous.sh"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: la garde mémoire du driver ne référence pas l'autorité MASTER_ORDER § MACHINE À ÉTATS"
fi

# (c) cohérence croisée : chacun des 8 états canoniques doit être (i) reconnu
#     par state_kind (action définie, pas 'illegal') ET (ii) documenté dans le
#     § MACHINE À ÉTATS du MASTER_ORDER. Réciproquement, aucun état reconnu en
#     dehors de ces 8 (déjà couvert par les kind_*_BAD ci-dessus). ---
CANONICAL_STATES="RUNNING READY_FOR_FINAL_AUDIT WAITING_INFRA WAITING_HUMAN_BOSS_GO WAITING_HUMAN FAIL DONE MEMORY_SYSTEM_FAIL"
for s in $CANONICAL_STATES; do
  act="$(state_kind "$s")"
  if [ "$act" = "illegal" ]; then
    fail=$((fail+1)); echo "FAIL: état canonique $s non reconnu par state_kind (illegal)"
  else
    pass=$((pass+1))
  fi
  if grep -qF "\`$s\`" "$REPO/MASTER_ORDER_RUN4_MEMORY.md"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: état canonique $s absent du MASTER_ORDER (autorité doc incomplète)"
  fi
done

# ====================================================================
# FIX 1+2+3 (post-mortem 30/07 : bug CLI Codex « failed to load models cache:
# missing field supports_reasoning_summaries » + boucle sur finding identique).
# Regression reelle : le bruit d'erreur CLI fuyait DANS AUDIT_CODEX/REVIEW_CODEX
# et etait compte comme un VRAI audit/review non-PASS -> audit_repairs++ (round
# de repair reel consomme pour du simple bruit infra), jusqu'a des dizaines de rounds et
# plusieurs heures / quota Codex perdus. Ces tests prouvent que desormais :
# (FIX 2/a) un output contenant le bruit CLI -> infra_fail, audit_repairs intact ;
# (FIX 3/b) deux audits IDENTIQUES consecutifs -> FAIL immediat (avant plafond).
# ====================================================================

# --- FIX 1 : purge du cache Codex AVANT CHAQUE 'codex exec'. Il y a exactement
# 2 appels 'codex exec' (audit final + review de tranche) -> exactement 2 purges,
# chacune precedant lexicalement son appel (intercalage p1 < c1 < p2 < c2). ---
DRV="$REPO/run_run4_autonomous.sh"
purge_lines=($(grep -nF 'rm -f "$HOME/.codex/models_cache.json"' "$DRV" | cut -d: -f1))
codex_lines=($(grep -nE 'codex exec -s read-only' "$DRV" | cut -d: -f1))
chk "fix1_two_cache_purges"  "${#purge_lines[@]}" "2"
chk "fix1_two_codex_exec"    "${#codex_lines[@]}" "2"
# intercalage strict : purge1 < codex1 < purge2 < codex2 (chaque codex exec est
# precede de sa purge, dans le bon bloc ; jamais de codex exec avant la 1re purge).
if [ "${#purge_lines[@]}" -eq 2 ] && [ "${#codex_lines[@]}" -eq 2 ] \
   && [ "${purge_lines[0]}" -lt "${codex_lines[0]}" ] \
   && [ "${codex_lines[0]}" -lt "${purge_lines[1]}" ] \
   && [ "${purge_lines[1]}" -lt "${codex_lines[1]}" ]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: FIX1 purge(s) cache non intercalees avant chaque codex exec (p=${purge_lines[*]} c=${codex_lines[*]})"
fi
# la purge doit etre silencieuse et ne jamais faire echouer le script :
grep -qF 'rm -f "$HOME/.codex/models_cache.json" 2>/dev/null || true' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: FIX1 purge cache non silencieuse/fail-safe"; }

# --- FIX 2 (a) : un output codex contenant le bruit CLI du cache est traite
# comme infra_fail, PAS comme un audit valide -> n'incremente PAS audit_repairs.
# Preuve unitaire par execution REELLE du predicat de production
# codex_cache_bug_in_file (source: pilote). ---
printf 'PHASE_P0_FAIL\nfactory/bin/x.py:42 bug reel\n' > "$TMP/clean_audit"
printf 'ERROR codex_models_manager::cache: failed to load models cache: missing field `supports_reasoning_summaries` at line 88 column 5\n' > "$TMP/bug_cache"
printf 'supports_reasoning_summaries absent du schema\nPHASE_P0_FAIL\n' > "$TMP/bug_field"
: > "$TMP/empty_audit"
chk "fix2_clean_audit_not_bug"   "$(codex_cache_bug_in_file "$TMP/clean_audit";   echo $?)" "1"
chk "fix2_bug_failedtoload_is_bug" "$(codex_cache_bug_in_file "$TMP/bug_cache";  echo $?)" "0"
chk "fix2_bug_supportsfield_is_bug" "$(codex_cache_bug_in_file "$TMP/bug_field"; echo $?)" "0"
chk "fix2_empty_not_bug"         "$(codex_cache_bug_in_file "$TMP/empty_audit";  echo $?)" "1"
chk "fix2_missing_not_bug"       "$(codex_cache_bug_in_file "$TMP/nope";         echo $?)" "1"
# Preuve comportementale : on rejoue la branche exacte du bloc audit avec un
# faux AUDIT_CODEX contenant le bruit CLI -> on entre dans infra_fail et on
# n'atteint JAMAIS l'increment audit_repairs (round de repair non consomme).
sim_ar=0; sim_inf=0
printf 'failed to load models cache: missing field `supports_reasoning_summaries`\n' > "$TMP/sim_audit"
if codex_cache_bug_in_file "$TMP/sim_audit"; then
  sim_inf=$((sim_inf+1))     # traite comme infra_fail (ce que fait main)
else
  sim_ar=$((sim_ar+1))       # branche VRAI audit non-PASS (inatteignable ici)
fi
chk "fix2_sim_buggy_increments_infra"     "$sim_inf" "1"
chk "fix2_sim_buggy_leaves_audit_repairs" "$sim_ar"  "0"
# Preuve structurelle : dans main(), la garde cache-bug du bloc audit est placee
# AVANT tout 'audit_repairs=$((audit_repairs+1))' (donc inatteignable si bug).
guard_line=$(grep -nF 'if codex_cache_bug_in_file "$AUDIT_CODEX"' "$DRV" | head -1 | cut -d: -f1)
inc_line=$(grep -nF 'audit_repairs=$((audit_repairs+1))' "$DRV" | head -1 | cut -d: -f1)
[ -n "$guard_line" ] && [ -n "$inc_line" ] && [ "$guard_line" -lt "$inc_line" ]
chk "fix2_cache_guard_before_audit_repairs_inc" "$?" "0"
grep -qF 'codex cache bug detecte -> traite comme infra_fail, pas comme audit' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: FIX2 ne logge pas le routage infra_fail (audit)"; }
grep -qF 'codex cache bug detecte -> traite comme infra_fail, pas comme review' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: FIX2 ne logge pas le routage infra_fail (review)"; }
# la garde cache-bug du bloc audit route bien vers infra_fails (PAS audit_repairs) :
audit_block_bug=$(grep -nE 'infra_fails=\$\(\(infra_fails\+1\)\)' "$DRV" | head -1 | cut -d: -f1)
[ -n "$audit_block_bug" ] && [ "$audit_block_bug" -gt "$guard_line" ] && [ "$audit_block_bug" -lt "$inc_line" ]
chk "fix2_infra_inc_between_guard_and_audit_inc" "$?" "0"

# --- FIX 3 (b) : deux audits Codex IDENTIQUES consecutifs declenchent FAIL
# IMMEDIATEMENT, sans attendre le plafond MAX_*_REPAIR. Preuve par execution
# REELLE du predicat audit_same_as_previous (source: pilote) + mecanisme de
# consignation SHA, sur 2 rounds simules avec le VRAI sha256_file. ---
STALL_TEST="$TMP/last_audit_P0.sha256"
rm -f "$STALL_TEST"
# round 1 : audit non-PASS, aucun SHA precedent -> pas stalled (cas normal).
# D-013-quater : le rapport d'audit utilise le format reel Codex (en-tete de
# severite "P1" sur sa propre ligne), car la signature de stall porte desormais
# sur le bloc P1/High extrait (stall_signature), pas sur le rapport entier.
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:42 : bug reel P1 non resolu\n' > "$TMP/audit_r1"
audit_same_as_previous "$STALL_TEST" "$TMP/audit_r1"
chk "fix3_round1_not_stalled" "$?" "1"
# main() consigne la signature (P1/High) du round courant pour la comparaison suivante :
printf '%s' "$(stall_signature "$TMP/audit_r1")" > "$STALL_TEST"
sim_round=1   # round 1 a incremente audit_repairs (cas normal, non stalled)
# round 2 : GLM n a RIEN change -> audit IDENTIQUE mot pour mot.
cp "$TMP/audit_r1" "$TMP/audit_r2"
audit_same_as_previous "$STALL_TEST" "$TMP/audit_r2"
chk "fix3_round2_identical_stalled" "$?" "0"
# D-013 : au 1er stall on NE FAIL PLUS immediatement (redirection chirurgical).
# Le FAIL intervient au PLUS TARD au 3e round Codex (1 normal + 1 stall + 1
# redirection), strictement AVANT le plafond budgetaire MAX_*_REPAIR :
plafond=$(grep -oE '^MAX_P0_REPAIR=[0-9]+' "$DRV" | head -1 | cut -d= -f2)
sim_fail_round=3
[ -n "$plafond" ] && [ "$sim_fail_round" -lt "$plafond" ]
chk "fix3_fail_at_most_round3_before_plafond($plafond)" "$?" "0"
# anti-faux-positif : deux audits avec un finding P1 DIFFERENT ne declenchent PAS le stall.
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:99 : autre finding P1 totalement different\n' > "$TMP/audit_r3"
audit_same_as_previous "$STALL_TEST" "$TMP/audit_r3"
chk "fix3_different_audit_not_stalled" "$?" "1"
# predicat robuste : pas de fichier memoire -> pas stalled (1er round d'une phase).
rm -f "$STALL_TEST"
audit_same_as_previous "$STALL_TEST" "$TMP/audit_r1"
chk "fix3_no_prev_file_not_stalled" "$?" "1"
# Preuve structurelle : main() appelle le VRAI comparateur de signature et ecrit
# FAIL + message exact, AVANT tout increment audit_repairs (FAIL prioritaire).
stall_call=$(grep -nF 'audit_signature_same_as_previous "$STALL_FILE" "$STALL_SIG"' "$DRV" | head -1 | cut -d: -f1)
[ -n "$stall_call" ] && [ "$stall_call" -lt "$inc_line" ]
chk "fix3_stall_call_before_audit_repairs_inc" "$?" "0"
# D-013 : message EXACT de FAIL fail-closed APRES redirection chirurgicale
# (l'ancien message FIX3 'meme finding P1 ... 2 rounds identiques' est remplacé
# par la 2e etape de la detection de stall bornee a 1 redirection).
grep -qF 'meme finding non resolu APRES tentative de redirection chirurgicale -> arret fail-closed, intervention humaine necessaire' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: D-013 message de FAIL apres redirection chirurgical absent"; }
# plus d'ancien mecanisme de diversification obsolete (remplace par D-013 :
# redirection chirurgical bornee a 1, qui N EST PAS une boucle deguisee) :
if grep -qiE 'diversified_attempt|STRATEGY_CHANGE_REQUIRED|tentative de strategie' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: ancien mecanisme de diversification obsolete toujours present (D-013 le remplace par 1 redirection bornee)"
else
  pass=$((pass+1))
fi

# ====================================================================
# D-013 (post-post-mortem 30/07) : detection de stall en 2 TEMPS, bornee a
# max 1 redirection chirurgicale. Remplace le FAIL immediat de FIX 3 au 1er
# stall par : (N) 1er stall -> extraction findings + redirection GLM (1 fois,
# flag redirect_attempt_PHASE.used) ; (N+1) stall encore identique OU flag
# present -> FAIL immediat ; (N+1) audit different -> reset flag, boucle normale.
# Tests (a)-(d) exiges par le brief : preuves REELLES via les predicats de prod
# (stall_action, extract_findings, build_redirect_prompt, audit_same_as_previous)
# + preuves structurelles sur le driver de production.
# ====================================================================

# --- (a) 1er stall (2 audits identiques, PAS de flag) -> redirection chirurgical
#     vers GLM, STATE=RUNNING, PAS de FAIL immediat. Preuve par execution REELLE
#     de stall_action (source: pilote) + extract_findings + build_redirect_prompt. ---
rm -f "$TMP/d013_a.used"
chk "d013_a_stall_noflag_redirect" "$(stall_action 0 "$TMP/d013_a.used")" "redirect"
chk "d013_a_notstall_normal"       "$(stall_action 1 "$TMP/d013_a.used")" "normal"
# extraction REELLE des findings depuis un faux AUDIT_CODEX :
printf 'PHASE_P0_FAIL\nfactory/bin/x.py:42 : bug reel P1 non resolu\nfactory/bin/y.sh:10 : autre finding\nbruit sans localisation exploitable\n' > "$TMP/d013_audit_a"
EXTRACTED="$(extract_findings "$TMP/d013_audit_a")"
printf '%s\n' "$EXTRACTED" | grep -qF 'factory/bin/x.py:42 : bug reel P1 non resolu' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 extract_findings ne capture pas x.py:42"; }
printf '%s\n' "$EXTRACTED" | grep -qF 'factory/bin/y.sh:10 : autre finding' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 extract_findings ne capture pas y.sh:10"; }
# la ligne sans localisation fichier:numero est ecartee (pas de bruit non exploitable) :
if printf '%s\n' "$EXTRACTED" | grep -qF 'bruit sans localisation exploitable'; then
  fail=$((fail+1)); echo "FAIL: d013 extract_findings garde du bruit sans localisation fichier:ligne"
else pass=$((pass+1)); fi
# fichier vide/absent -> extraction vide (pas de crash, redirection part en aveugle) :
chk "d013_extract_empty_returns_empty" "$(extract_findings "$TMP/d013_audit_vide_inexistant")" ""
# le REDIRECT_PROMPT contient les findings extraits + les instructions chirurgicales :
RP="$(build_redirect_prompt "$EXTRACTED")"
printf '%s' "$RP" | grep -qF 'factory/bin/x.py:42 : bug reel P1 non resolu' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 REDIRECT_PROMPT sans finding extrait"; }
printf '%s' "$RP" | grep -qiE 'DERNIERE tentative|patch MINIMAL et CHIRURGICAL|N ESSAIE PAS la meme chose' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 REDIRECT_PROMPT sans instructions chirurgicales"; }
# si aucun finding fichier:ligne, le prompt reste coherent (placeholder d ambiguite) :
RP_EMPTY="$(build_redirect_prompt '')"
printf '%s' "$RP_EMPTY" | grep -qiE 'ambiguit|ambigu' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 REDIRECT_PROMPT vide sans note d ambiguite"; }
# preuve structurelle (a) : la branche 'redirect)' route vers GLM via REVIEW_CODEX
# et maintient STATE=RUNNING (pas de FAIL immediat au 1er stall) :
grep -qF 'REDIRECT_CHIRURGICAL (phase $PHASE' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 branche redirect/REVIEW_CODEX absente du driver"; }
grep -qF 'redirection chirurgicale vers GLM (1 seule tentative' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 log de redirection STATE=RUNNING absent"; }
grep -qF 'commit_redirect "$RECEIPTS_DIR/pending_redirect_${PHASE}.txt" "$REDIRECT_FLAG"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 pose du flag redirect_attempt absente (commit_redirect transactionnel)"; }

# --- (b) apres redirection, audit SUIVANT encore identique (flag present) ->
#     FAIL immediat ; message exact exige present dans le driver. ---
touch "$TMP/d013_b.used"
chk "d013_b_stall_flag_fail" "$(stall_action 0 "$TMP/d013_b.used")" "fail"
# (b) preuve REELLE sur 3 rounds simules avec la VRAIE stall_signature (P1/High)
# + le VRAI predicat audit_same_as_previous, faithful au branchement de main() :
SF_B="$TMP/last_audit_P0_b.sha256"; rm -f "$SF_B" "$TMP/d013_b.used"
# round 1 : audit A non-PASS, pas de prev -> non stalled -> consigne signature(A).
# D-013-quater : format reel Codex (en-tete P1), signature = bloc P1 extrait.
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:42 : bug reel P1 non resolu\n' > "$TMP/d013_r1"
audit_same_as_previous "$SF_B" "$TMP/d013_r1"; chk "d013_b_r1_not_stalled" "$?" "1"
printf '%s' "$(stall_signature "$TMP/d013_r1")" > "$SF_B"
# round 2 : audit IDENTIQUE -> stalled, PAS de flag -> redirect (on pose le flag).
cp "$TMP/d013_r1" "$TMP/d013_r2"
audit_same_as_previous "$SF_B" "$TMP/d013_r2"; chk "d013_b_r2_stalled" "$?" "0"
chk "d013_b_r2_action_redirect" "$(stall_action 0 "$TMP/d013_b.used")" "redirect"
touch "$TMP/d013_b.used"   # main() pose le flag apres redirection
# round 3 : audit ENCORE IDENTIQUE -> stalled + flag present -> FAIL immediat.
cp "$TMP/d013_r1" "$TMP/d013_r3"
audit_same_as_previous "$SF_B" "$TMP/d013_r3"; chk "d013_b_r3_stalled_again" "$?" "0"
chk "d013_b_r3_action_fail" "$(stall_action 0 "$TMP/d013_b.used")" "fail"
# le FAIL arrive au round 3, AVANT le plafond MAX_*_REPAIR (jamais plus de 3) :
[ "3" -lt "$plafond" ]; chk "d013_b_fail_round3_before_plafond($plafond)" "$?" "0"

# --- (c) apres redirection, audit SUIVANT DIFFERENT -> normal, flag reset,
#     boucle standard avec budget audit_repairs. ---
touch "$TMP/d013_c.used"
chk "d013_c_diffaudit_normal_with_flag" "$(stall_action 1 "$TMP/d013_c.used")" "normal"
# (c) preuve REELLE : round 3 produit un audit B different de A -> non stalled,
# le flag (encore present) est reset par main(), nouvelle sequence possible.
SF_C="$TMP/last_audit_P0_c.sha256"; rm -f "$SF_C" "$TMP/d013_c.used"
# D-013-quater : format reel Codex (en-tete P1), signature = bloc P1 extrait.
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:42 : bug reel P1 non resolu\n' > "$TMP/d013_c_r1"
printf '%s' "$(stall_signature "$TMP/d013_c_r1")" > "$SF_C"
touch "$TMP/d013_c.used"   # round 2 a redirige
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:42 : PARTIELLEMENT corrige (progres reel)\n' > "$TMP/d013_c_r3"
audit_same_as_previous "$SF_C" "$TMP/d013_c_r3"; chk "d013_c_r3_not_stalled_progress" "$?" "1"
chk "d013_c_r3_action_normal" "$(stall_action 1 "$TMP/d013_c.used")" "normal"
# main() reset le flag sur progres reel -> une NOUVELLE sequence a droit a sa redirection :
grep -qF 'purge_file_logged "$REDIRECT_FLAG"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 reset du flag redirect_attempt absent du driver (purge_file_logged)"; }
grep -qF 'progres reel, reset du flag redirect_attempt, boucle normale (budget audit_repairs standard)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 log de reset flag (progres) absent"; }

# --- (d) JAMAIS 2 redirections consecutives pour le meme stall : le flag
#     empeche une 2e redirection, force le FAIL. Preuve par la table de decision
#     stall_action (stalled + flag = TOUJOURS fail, jamais redirect) + preuve
#     structurelle que le driver ne touche le flag QU'UNE fois (1 seul touch). ---
touch "$TMP/d013_d.used"
chk "d013_d_stalled_flag_forces_fail" "$(stall_action 0 "$TMP/d013_d.used")" "fail"
# apres reset (progres reel), une NOUVELLE sequence a droit a 1 redirection :
rm -f "$TMP/d013_d.used"
chk "d013_d_new_sequence_allows_redirect" "$(stall_action 0 "$TMP/d013_d.used")" "redirect"
# table de decision complete de stall_action (anti-regression) :
rm -f "$TMP/d013_tbl.used"
chk "d013_tbl_notstalled_noflag_normal"  "$(stall_action 1 "$TMP/d013_tbl.used")" "normal"
chk "d013_tbl_stalled_noflag_redirect"   "$(stall_action 0 "$TMP/d013_tbl.used")" "redirect"
touch "$TMP/d013_tbl.used"
chk "d013_tbl_notstalled_flag_normal"    "$(stall_action 1 "$TMP/d013_tbl.used")" "normal"
chk "d013_tbl_stalled_flag_fail"         "$(stall_action 0 "$TMP/d013_tbl.used")" "fail"
# preuve de bornage : EXACTEMENT 1 seul appel commit_redirect dans la branche
# redirect (pas de 2e engagement -> jamais de boucle de redirection deguisee) :
ncommit=$(grep -cF 'commit_redirect "$RECEIPTS_DIR/pending_redirect_${PHASE}.txt" "$REDIRECT_FLAG"' "$DRV")
chk "d013_only_one_commit_redirect" "$ncommit" "1"
# la redirection est immédiatement suivie d'un 'continue ;;' (sort d iteration,
# ne re-redirige JAMAIS dans la meme iteration) :
commit_line=$(grep -nF 'commit_redirect "$RECEIPTS_DIR/pending_redirect_${PHASE}.txt" "$REDIRECT_FLAG"' "$DRV" | head -1 | cut -d: -f1)
first_continue_after_commit=$(grep -nF 'continue ;;' "$DRV" | awk -F: -v t="$commit_line" '$1 > t {print $1; exit}')
[ -n "$commit_line" ] && [ -n "$first_continue_after_commit" ] && [ "$first_continue_after_commit" -gt "$commit_line" ]
chk "d013_redirect_branch_continues_no_loop" "$?" "0"
# la declaration du flag borne la portee (1 fichier par phase) :
grep -qF 'REDIRECT_FLAG="$RECEIPTS_DIR/redirect_attempt_${PHASE}.used"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013 REDIRECT_FLAG non declare dans le driver"; }
# anti-regression : aucun appel 'claude -p' reintroduit (Claude reste HORS du
# pilote, reviewer = Codex SEUL -- contrainte Jocelyn) :
if grep -qE 'claude[[:space:]]+-p|claude[[:space:]]+--print' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013 un appel 'claude -p' a ete reintroduit dans le pilote (interdit)"
else
  pass=$((pass+1))
fi

# ====================================================================
# D-013-bis (correctif de branchement, post-revue independante Codex b674838) :
# la redirection D-013 etait INERTE -- CUR_PROMPT etait JAMAIS alimente par
# REDIRECT_PROMPT (assigne statiquement depuis BUILD_PROMPT_P0/P1). Desormais
# build_cur_prompt(PHASE) lit RECEIPTS_DIR/pending_redirect_PHASE.txt et, s'il
# existe, PREPEND son contenu au BUILD_PROMPT standard. Ces tests verifient le
# CONTENU REEL de CUR_PROMPT produit par build_cur_prompt (pas seulement
# l'existence des fonctions D-013) : un cas ou pending_redirect existe, un cas
# ou il n existe pas.
# ====================================================================

# Preuves structurelles D-013-bis : le driver declare build_cur_prompt,
# l'utilise REELLEMENT pour assigner CUR_PROMPT, persiste le REDIRECT_PROMPT
# dans pending_redirect_PHASE.txt et purge ce fichier APRES l'appel opencode.
grep -qE '^build_cur_prompt\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis build_cur_prompt non defini"; }
grep -qF 'CUR_PROMPT="$(build_cur_prompt "$PHASE")"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis CUR_PROMPT n est pas assigne par build_cur_prompt (redirection inerte)"; }
grep -qF 'pending_redirect_${PHASE}.txt' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis fichier pending_redirect non reference dans le driver"; }
# la persistance dans la branche redirect (contenu du REDIRECT_PROMPT ecrit) :
# D-013-ter : la persistance se fait via commit_redirect (atomique + transactionnel)
# qui reçoit le contenu REDIRECT_PROMPT (test comportemental dédié section D-013-ter).
grep -qF 'commit_redirect "$RECEIPTS_DIR/pending_redirect_${PHASE}.txt" "$REDIRECT_FLAG" "$REDIRECT_PROMPT"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis branche redirect ne persiste pas REDIRECT_PROMPT (commit_redirect)"; }
# la purge APRES l appel opencode run (usage unique) : un seul rm du fichier, et
# il suit lexicalement l appel opencode (jamais avant -> pas de purge prematuree).
nrmpending=$(grep -cF 'pending_redirect_${PHASE}.txt' "$DRV")
[ "$nrmpending" -ge 2 ] && pass=$((pass+1)) \
  || { fail=$((fail+1)); echo "FAIL: d013bis pending_redirect insuffisamment reference (persist+purge)"; }
opencode_line=$(grep -nF 'opencode run --model zai-coding-plan/glm-5.2 "$CUR_PROMPT"' "$DRV" | head -1 | cut -d: -f1)
purge_line=$(grep -nF 'purge_file_logged "$_prf"' "$DRV" | head -1 | cut -d: -f1)
[ -n "$opencode_line" ] && [ -n "$purge_line" ] && [ "$purge_line" -gt "$opencode_line" ]
chk "d013bis_purge_after_opencode" "$?" "0"
# D-013-ter : la section critique est encadree par enter/exit_scoped_purge autour
# d'opencode (sinon le scoped trap serait mort-ne) -- enter AVANT, exit APRES purge.
enter_line=$(grep -nF 'enter_scoped_purge "$_prf"' "$DRV" | head -1 | cut -d: -f1)
exit_line=$(grep -nF 'exit_scoped_purge' "$DRV" | awk -F: -v t="$purge_line" '$1 > t {print $1; exit}')
[ -n "$enter_line" ] && [ -n "$exit_line" ] && [ "$enter_line" -lt "$opencode_line" ] && [ "$exit_line" -gt "$purge_line" ]
chk "d013ter_scope_wraps_opencode" "$?" "0"
# plus d assignation statique de CUR_PROMPT depuis BUILD_PROMPT seul (l ancien
# bug) -- preuve que la redirection n est plus inerte :
if grep -qF 'CUR_PROMPT="$BUILD_PROMPT_P1"; else CUR_PROMPT="$BUILD_PROMPT_P0"' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013bis ancienne assignation statique CUR_PROMPT toujours presente (redirection inerte)"
else pass=$((pass+1)); fi

# --- Test de CONTENU REEL (cas 1) : pending_redirect EXISTE -> CUR_PROMPT
#     contient le contenu de redirection EN TETE, suivi du BUILD_PROMPT (en
#     PLUS, jamais a la place). build_cur_prompt lit RECEIPTS_DIR global, qu on
#     surcharge proprement vers un temp (sauvegarde/restauration). ---
D013BIS_DIR="$TMP/receipts_d013bis"; mkdir -p "$D013BIS_DIR"
SAVED_RECEIPTS_DIR="$RECEIPTS_DIR"
RECEIPTS_DIR="$D013BIS_DIR"
# on persiste un contenu de redirection distinctif dans pending_redirect_P0.txt :
printf 'REDIR_SENTINEL_42 : corrige factory/bin/x.py:42 chirurgicalement\n' > "$RECEIPTS_DIR/pending_redirect_P0.txt"
CUR0="$(build_cur_prompt P0)"
# le contenu de redirection est BIEN present dans CUR_PROMPT (redirection effective) :
printf '%s' "$CUR0" | grep -qF 'REDIR_SENTINEL_42 : corrige factory/bin/x.py:42 chirurgicalement' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis cas1 contenu de redirection absent de CUR_PROMPT"; }
# le BUILD_PROMPT_P0 standard est AUSSI present (concatene, jamais remplace) :
printf '%s' "$CUR0" | grep -qF 'PHASE P0 UNIQUEMENT' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis cas1 BUILD_PROMPT_P0 absent du CUR_PROMPT concatene"; }
# la redirection PRECEDE le build (redirection d abord, build ensuite) -- via
# position du prefixe :
case "$CUR0" in
  REDIR_SENTINEL_42*) chk "d013bis_cas1_redirect_precedes_build" "prefix" "prefix" ;;
  *) chk "d013bis_cas1_redirect_precedes_build" "no-prefix" "prefix" ;;
esac
# le contenu de redirection n apparait qu UNE seule fois (pas de duplication) :
[ "$(printf '%s' "$CUR0" | grep -cF 'REDIR_SENTINEL_42')" -eq 1 ]
chk "d013bis_cas1_redirect_once" "$?" "0"

# --- Test de CONTENU REEL (cas 2) : pending_redirect ABSENT -> CUR_PROMPT egal
#     EXACTEMENT au BUILD_PROMPT seul (aucune redirection, aucun prefixe parasite,
#     aucun bruit). Verifie P0 et P1. ---
rm -f "$RECEIPTS_DIR/pending_redirect_P0.txt" "$RECEIPTS_DIR/pending_redirect_P1.txt"
CUR0_NO="$(build_cur_prompt P0)"
[ "$CUR0_NO" = "$BUILD_PROMPT_P0" ]
chk "d013bis_cas2_no_redirect_equals_build_p0" "$?" "0"
CUR1_NO="$(build_cur_prompt P1)"
[ "$CUR1_NO" = "$BUILD_PROMPT_P1" ]
chk "d013bis_cas2_no_redirect_equals_build_p1" "$?" "0"

# isolation cross-phase : un pending_redirect P1 ne fuite PAS vers build_cur_prompt P0.
printf 'REDIR_SENTINEL_P1_ONLY\n' > "$RECEIPTS_DIR/pending_redirect_P1.txt"
CUR0_ISOL="$(build_cur_prompt P0)"
if printf '%s' "$CUR0_ISOL" | grep -qF 'REDIR_SENTINEL_P1_ONLY'; then
  fail=$((fail+1)); echo "FAIL: d013bis build_cur_prompt P0 lit le pending_redirect P1 (fuite cross-phase)"
else pass=$((pass+1)); fi
# et build_cur_prompt P1 lit bien le sien (+ BUILD_PROMPT_P1 en plus) :
CUR1_HAS="$(build_cur_prompt P1)"
printf '%s' "$CUR1_HAS" | grep -qF 'REDIR_SENTINEL_P1_ONLY' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis build_cur_prompt P1 ne lit pas son pending_redirect"; }
printf '%s' "$CUR1_HAS" | grep -qF 'PHASE P1' \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013bis build_cur_prompt P1 sans BUILD_PROMPT_P1 concatene"; }

# restauration du RECEIPTS_DIR global (proprete, autres tests non impactes).
RECEIPTS_DIR="$SAVED_RECEIPTS_DIR"

# ====================================================================
# D-013-ter (audit défensif complet de la mécanique stall/redirect) :
# (1) purge crash-safe de pending_redirect pendant opencode run via scoped trap
#     (save/restore EXIT/INT/TERM/HUP, sans remplacer le trap global de main) ;
# (2) même traitement crash-safe pour redirect_attempt_PHASE.used et
#     last_audit_PHASE.sha256 (exposition équivalente : écritures atomiques +
#     purges loggées) ;
# (3) écritures atomiques tmp-puis-mv de pending_redirect / last_audit ;
# (4) suppression des 'rm -f ... 2>/dev/null' muets -> purge_file_logged
#     (logging explicite, fail-closed sur echec d'ecriture) ;
# (5) transaction atomique (pending_redirect + redirect_attempt) -> aucune
#     interruption entre les deux écritures ne laisse d'état inconsistent.
# Tests RÉELS (nominal + simulation crash/interruption) + régression nominale.
# Ne touche ni stall_action, ni build_cur_prompt, ni FIX1/2/3, ni D-001..D-012,
# ni la machine à états (vérifié par les tests structurels ci-dessus, intacts).
# ====================================================================

# --- preuves structurelles : les helpers D-013-ter existent dans le driver. ---
grep -qE '^atomic_write_exact\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013ter atomic_write_exact non defini"; }
grep -qE '^purge_file_logged\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013ter purge_file_logged non defini"; }
grep -qE '^enter_scoped_purge\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013ter enter_scoped_purge non defini"; }
grep -qE '^exit_scoped_purge\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013ter exit_scoped_purge non defini"; }
grep -qE '^commit_redirect\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013ter commit_redirect non defini"; }

# --- (3) atomic_write_exact : nominal + byte-exact + échec rc=1 + pas de tmp. ---
AWD="$TMP/d013ter_aw"; mkdir -p "$AWD"
atomic_write_exact "$AWD/exact" "deadbeef"; chk "d013ter_aw_ok_rc" "$?" "0"
chk "d013ter_aw_content" "$(cat "$AWD/exact")" "deadbeef"
# byte-exact : AUCUN newline ajouté (8 octets, pas 9) -- critique pour le SHA.
[ "$(wc -c < "$AWD/exact" | tr -d ' ')" = "8" ]; chk "d013ter_aw_no_extra_newline" "$?" "0"
# aucun tmp résiduel (le tmp a été renommé par mv) :
[ ! -e "$AWD/exact.tmp.$$" ]; chk "d013ter_aw_no_tmp_residue" "$?" "0"
# échec : sous-répertoire inexistant -> printf échoue -> rc=1, rien créé, pas de tmp.
atomic_write_exact "$AWD/no_such_sub/x" "X"; chk "d013ter_aw_fail_rc1" "$?" "1"
[ ! -e "$AWD/no_such_sub" ]; chk "d013ter_aw_fail_no_partial" "$?" "0"
# l'échec est LOGGÉ (plus d'erreur muette) :
grep -q 'atomic_write_exact ECHEC sur '"$AWD"'/no_such_sub/x' "$LOG"; chk "d013ter_aw_fail_logged" "$?" "0"

# --- (4) purge_file_logged : nominal loggé + absent rc=0 + échec rc=1 loggé. ---
PFD="$TMP/d013ter_pf"; mkdir -p "$PFD"
echo "data" > "$PFD/target"
purge_file_logged "$PFD/target" "pf_label"; chk "d013ter_pf_remove_rc0" "$?" "0"
[ ! -e "$PFD/target" ]; chk "d013ter_pf_removed" "$?" "0"
grep -q 'purge pf_label : supprime' "$LOG"; chk "d013ter_pf_remove_logged" "$?" "0"
# fichier absent -> rc=0 (pas d'erreur), n'écrit rien :
purge_file_logged "$PFD/absent_xyz" "pf_absent"; chk "d013ter_pf_absent_rc0" "$?" "0"
# échec : purge d'un répertoire (rm -f sur un dir échoue) -> rc=1 + loggé.
mkdir -p "$PFD/adir"
purge_file_logged "$PFD/adir" "pf_fail_label"; chk "d013ter_pf_fail_rc1" "$?" "1"
grep -q 'purge pf_fail_label : ECHEC suppression' "$LOG"; chk "d013ter_pf_fail_logged" "$?" "0"
rmdir "$PFD/adir" 2>/dev/null || true

# --- (1) scoped trap : SIGTERM pendant la section critique purge le fichier
#     ET préserve le cleanup original (chaînage). Preuve RÉELLE par sous-shell.
#     D'abord : enter/exit restaur EXACTEMENT les traps (sans remplacer le global).
#     NB : les chemins de trace sont des GLOBALES (pas des locals de la fonction)
#     car cleanup() est appelée par le trap EXIT APRES le retour de la fonction --
#     les locals seraient déjà détruits. ---
_D013TER_TRACE=""; _D013TER_BEFORE=""; _D013TER_AFTER_ENTER=""; _D013TER_AFTER_EXIT=""
_d013ter_scoped_nominal() {
  local sf="$1"
  _D013TER_TRACE="$2/trace"; _D013TER_BEFORE="$2/before"
  _D013TER_AFTER_ENTER="$2/after_enter"; _D013TER_AFTER_EXIT="$2/after_exit"
  cleanup() { echo "cleanup_marker" >> "$_D013TER_TRACE"; }   # mimique du cleanup driver
  trap 'cleanup' EXIT
  trap 'exit 143' TERM INT HUP
  printf '%s\n' "$(trap -p EXIT TERM INT HUP)" > "$_D013TER_BEFORE"
  enter_scoped_purge "$sf"
  printf '%s\n' "$(trap -p EXIT)" > "$_D013TER_AFTER_ENTER"
  touch "$sf"
  exit_scoped_purge
  printf '%s\n' "$(trap -p EXIT TERM INT HUP)" > "$_D013TER_AFTER_EXIT"
}
SCD="$TMP/d013ter_scope"; mkdir -p "$SCD"; SNT="$SCD/sent"; : > "$SCD/trace"
( _d013ter_scoped_nominal "$SNT" "$SCD" )
# pendant la section, le trap EXIT contient la purge du fichier scoped :
grep -qF 'rm -f "$_SCP_FILE"' "$SCD/after_enter"; chk "d013ter_scoped_exit_augmented" "$?" "0"
# après exit_scoped_purge : restauration EXACTE (after_exit == before) :
[ "$(cat "$SCD/before")" = "$(cat "$SCD/after_exit")" ]; chk "d013ter_scoped_restore_exact" "$?" "0"
# le cleanup original a tourné au exit normal du sous-shell (chaînage préservé) :
grep -q cleanup_marker "$SCD/trace"; chk "d013ter_scoped_chains_cleanup_normal" "$?" "0"

# --- (1 suite) SIGTERM PENDANT la section -> fichier purgé + cleanup chaîné. ---
_d013ter_scoped_crash() {
  local sf="$1"
  _D013TER_TRACE="$2/trace"; _D013TER_READY="$2/ready"
  cleanup() { echo "cleanup_marker" >> "$_D013TER_TRACE"; }
  trap 'cleanup' EXIT
  trap 'exit 143' TERM INT HUP
  enter_scoped_purge "$sf"
  touch "$sf"
  echo ready > "$_D013TER_READY"
  sleep 3   # fenêtre = appel opencode run pendant lequel le kill arrive
  exit_scoped_purge
}
SNT2="$SCD/sent2"
( _d013ter_scoped_crash "$SNT2" "$SCD" ) &
CRASH_BG=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCD/ready" ] && break; sleep 0.2; done
[ -f "$SCD/ready" ] && kill -TERM "$CRASH_BG" 2>/dev/null
wait "$CRASH_BG" 2>/dev/null
# le fichier scoped est PURGÉ malgré le SIGTERM pendant la section :
[ ! -e "$SNT2" ]; chk "d013ter_scoped_sigterm_purges_file" "$?" "0"
# le cleanup original a QUAND MÊME tourné (chaînage via exit143 -> EXIT scoped) :
grep -q cleanup_marker "$SCD/trace"; chk "d013ter_scoped_sigterm_chains_cleanup" "$?" "0"

# --- (5) transaction commit_redirect : nominal + échec + crash entre les 2
#     écritures -> ROLLBACK (ni pending ni flag ni tmp -> état CONSISTANT). ---
CRD="$TMP/d013ter_cr"; mkdir -p "$CRD"
# nominal : pending + flag cohérents, rc 0, contenu correct, pas de tmp.
commit_redirect "$CRD/pending.txt" "$CRD/flag.used" "CONTENU_REDIRECT_42"; chk "d013ter_cr_ok_rc" "$?" "0"
chk "d013ter_cr_pending_content" "$(cat "$CRD/pending.txt")" "CONTENU_REDIRECT_42"
[ -e "$CRD/flag.used" ]; chk "d013ter_cr_flag_created" "$?" "0"
[ ! -e "$CRD/pending.txt.tmp.$$" ]; chk "d013ter_cr_no_tmp" "$?" "0"
# échec d'écriture (sous-répertoire inexistant) -> rc=1, NI pending NI flag NI tmp.
commit_redirect "$CRD/no_sub/p.txt" "$CRD/no_sub/f.used" "X"; chk "d013ter_cr_fail_rc1" "$?" "1"
[ ! -e "$CRD/no_sub" ]; chk "d013ter_cr_fail_no_partial" "$?" "0"
# preuve structurelle : commit_redirect installe un rollback EXIT couvrant les
# 3 artefacts (pending + tmp + flag) -> interruption = rollback complet.
grep -qF 'rm -f "$CR_PENDING" "$CR_TMP" "$CR_FLAG"' "$DRV"; chk "d013ter_cr_rollback_covers_all" "$?" "0"
# preuve structurelle : ordre pending-pUIS-flag dans commit_redirect (le mv du
# pending précède lexicalement le touch du flag).
_cr_mv=$(grep -nF 'mv -f "$CR_TMP" "$pending"' "$DRV" | head -1 | cut -d: -f1)
_cr_touch=$(grep -nF 'touch "$flag"' "$DRV" | head -1 | cut -d: -f1)
[ -n "$_cr_mv" ] && [ -n "$_cr_touch" ] && [ "$_cr_mv" -lt "$_cr_touch" ]; chk "d013ter_cr_pending_before_flag" "$?" "0"

# simulation crash ENTRE le mv du pending et le touch du flag : on reproduit la
# MÊME section critique (même scoped rollback trap) à la main, on envoie SIGTERM
# après le mv et avant le touch, puis on vérifie le rollback (rien ne reste).
_d013ter_cr_midcrash() {
  local pending="$1" flag="$2" out="$3"
  trap ':' EXIT
  trap 'exit 143' TERM INT HUP
  # reproduit commit_redirect jusqu'au point de crash :
  CR_SAVED="$(trap -p EXIT INT TERM HUP)"
  CR_PENDING="$pending"; CR_TMP="${pending}.tmp.$$"; CR_FLAG="$flag"
  trap 'rm -f "$CR_PENDING" "$CR_TMP" "$CR_FLAG" 2>/dev/null || true' EXIT
  printf '%s\n' "PENDING" > "$CR_TMP" && mv -f "$CR_TMP" "$pending"
  echo ready > "$out/cr_ready"
  sleep 3   # <- SIGTERM arrive ici : pending existe, flag PAS ENCORE touché
  touch "$flag"   # atteint seulement sans signal
  # mimique de _cr_restore (sortie normale de commit_redirect) : on restaure les
  # traps originaux pour que la sortie NORMALE conserve pending+flag (et thus
  # prouve que le test ne passe QUE si le signal a effectivement déclenché le rollback).
  local line
  trap - EXIT INT TERM HUP
  while IFS= read -r line; do [ -n "$line" ] && eval "$line"; done <<D013TERMID
$CR_SAVED
D013TERMID
}
MIDP="$CRD/mid_p.txt"; MIDF="$CRD/mid_f.used"; : > "$CRD/cr_ready" 2>/dev/null || true; rm -f "$CRD/cr_ready"
( _d013ter_cr_midcrash "$MIDP" "$MIDF" "$CRD" ) &
MID_BG=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$CRD/cr_ready" ] && break; sleep 0.2; done
[ -f "$CRD/cr_ready" ] && kill -TERM "$MID_BG" 2>/dev/null
wait "$MID_BG" 2>/dev/null
# après rollback : NI pending NI flag NI tmp -> état CONSISTANT (rien).
[ ! -e "$MIDP" ]; chk "d013ter_cr_midcrash_no_pending" "$?" "0"
[ ! -e "$MIDF" ]; chk "d013ter_cr_midcrash_no_flag" "$?" "0"
_tmpc=0; for _t in "$CRD"/*.tmp.*; do [ -e "$_t" ] && _tmpc=$((_tmpc+1)); done
chk "d013ter_cr_midcrash_no_tmp" "$_tmpc" "0"

# --- (2) traitement crash-safe pour redirect_attempt + last_audit :
#     écritures atomiques + purges loggées (exposition équivalente couverte). ---
grep -qF 'atomic_write_exact "$STALL_FILE"' "$DRV"; chk "d013ter_last_audit_atomic" "$?" "0"
grep -qF 'purge_file_logged "$RECEIPTS_DIR/last_audit_P0.sha256"' "$DRV"; chk "d013ter_last_audit_p0_purge_logged" "$?" "0"
grep -qF 'purge_file_logged "$RECEIPTS_DIR/last_audit_P1.sha256"' "$DRV"; chk "d013ter_last_audit_p1_purge_logged" "$?" "0"
# le flag redirect_attempt est engagé via la transaction commit_redirect (couvert
# ci-dessus) et reset via purge_file_logged (déjà vérifié par d013 structurel) :
grep -qF 'purge_file_logged "$REDIRECT_FLAG"' "$DRV"; chk "d013ter_flag_reset_logged" "$?" "0"
# plus AUCUN 'rm -f ... 2>/dev/null' muet ciblant ces fichiers d'état :
if grep -qE 'rm -f .*(pending_redirect_\$\{PHASE\}|last_audit_P[01]\.sha256).*2>/dev/null' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013ter un 'rm -f ... 2>/dev/null' muet cible encore un fichier d etat redirection"
else pass=$((pass+1)); fi
# l'échec d'écriture du pending en branche redirect est fail-closed (FAIL) :
grep -qF 'echec ecriture atomique (pending_redirect/redirect_attempt) -> STATE=FAIL fail-closed' "$DRV"; chk "d013ter_redirect_write_fail_closed" "$?" "0"
# le sha de last_audit est écrit SANS newline parasite (audit_same_as_previous byte-exact) :
# preuve intégrée au miroir sha ci-dessus via atomic_write_exact ; on vérifie ici
# que le driver n'utilise plus de 'printf > "$STALL_FILE"' direct (non atomique) :
if grep -qF 'printf '"'"'%s'"'"' "$(sha256_file "$AUDIT_CODEX")" > "$STALL_FILE"' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013ter last_audit toujours ecrit en ecriture directe non atomique"
else pass=$((pass+1)); fi

# --- régression : la redirection nominale fonctionne TOUJOURS (commit_redirect
#     produit un pending lisible par build_cur_prompt, + BUILD_PROMPT concaténé). ---
RGD="$TMP/d013ter_reg"; mkdir -p "$RGD"
_SAVED_RR="$RECEIPTS_DIR"; RECEIPTS_DIR="$RGD"
commit_redirect "$RECEIPTS_DIR/pending_redirect_P0.txt" "$RECEIPTS_DIR/redirect_attempt_P0.used" "REGRESSION_REDIRECT_SENTINEL"
_REGCUR="$(build_cur_prompt P0)"
printf '%s' "$_REGCUR" | grep -qF 'REGRESSION_REDIRECT_SENTINEL'; chk "d013ter_regression_redirect_visible" "$?" "0"
printf '%s' "$_REGCUR" | grep -qF 'PHASE P0 UNIQUEMENT'; chk "d013ter_regression_build_appended" "$?" "0"
[ -e "$RECEIPTS_DIR/redirect_attempt_P0.used" ]; chk "d013ter_regression_flag_set" "$?" "0"
RECEIPTS_DIR="$_SAVED_RR"

# ====================================================================
# D-013-quater (granularite de la detection de stall) : la signature de stall
# portait sur le RAPPORT ENTIER (sha256_file $AUDIT_CODEX) -> faux negatif (un
# meme finding P1/High persistant noye dans un rapport qui change par ailleurs
# -> pas de stall -> boucle jusqu au plafond) ET faux positif (2 rapports
# identiques sans AUCUN P1/High -> stall/FAIL cosmetique sur du P2). Desormais
# la signature (stall_signature) ne porte QUE sur les findings P1/High extraits
# (extract_p1_high_findings). Perimetre strict : ces 2 fonctions +
# audit_same_as_previous + le site d ecriture du SHA. Ni stall_action, ni
# build_cur_prompt, ni FIX1/2/3, ni D-001..D-013-ter, ni la machine a etats ne
# sont modifies (preuve structurelle : sections ci-dessus intactes, 0 nouveau FAIL).
# ====================================================================

# --- preuves structurelles : les helpers D-013-quater existent dans le driver. ---
grep -qE '^extract_p1_high_findings\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013q extract_p1_high_findings non defini"; }
grep -qE '^stall_signature\(\)' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013q stall_signature non defini"; }
# audit_same_as_previous compare desormais via stall_signature (P1/High), PAS via
# sha256_file sur le rapport entier :
grep -qF 'cur="$(stall_signature "$cur_file")"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013q audit_same_as_previous n utilise pas stall_signature"; }
if grep -qF '[ "$prev" = "$(sha256_file "$cur_file")" ]' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013q audit_same_as_previous compare encore le rapport entier (sha256_file)"
else pass=$((pass+1)); fi
# audit_same_as_previous distingue l echec parser (rc 2) du non-stall normal (rc 1) :
grep -qF 'cur="$(stall_signature "$cur_file")" || return 2' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013q audit_same_as_previous ne distingue pas l echec parser (return 2)"; }
# le site d ecriture du SHA consigne stall_signature (P1/High) via la variable
# STALL_SIG (calcul puis ecriture atomique separates, propagation de l echec) :
grep -qF 'STALL_SIG="$(stall_signature "$AUDIT_CODEX")"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: d013q le site d ecriture du SHA n utilise pas stall_signature"; }
if grep -qF 'atomic_write_exact "$STALL_FILE" "$(sha256_file "$AUDIT_CODEX")"' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013q le site d ecriture consigne encore le rapport entier"
else pass=$((pass+1)); fi

# --- (1) FAUX NEGATIF CORRIGE : deux rapports avec le MEME finding P1/High mais
#     un texte different ailleurs (autre finding P2, reformulation) -> la nouvelle
#     comparaison DOIT detecter un stall (signature P1/High identique). Preuve
#     par execution REELLE de stall_signature + audit_same_as_previous. ---
QD="$TMP/d013q"; mkdir -p "$QD"
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:42 : bug reel P1 non resolu\n\nP2\n\n- detail cosmetique round N\n' > "$QD/r1_fn"
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:42 : bug reel P1 non resolu\n\nP2\n\n- AUTRE reformulation differente au round N+1\n' > "$QD/r2_fn"
# meme bloc P1 -> signature identique malgre un rapport global different :
[ "$(stall_signature "$QD/r1_fn")" = "$(stall_signature "$QD/r2_fn")" ]; chk "d013q_fn_same_p1_same_sig" "$?" "0"
# preuve que le rapport global DIFFERE bien (sha du rapport entier !=) :
[ "$(sha256_file "$QD/r1_fn")" != "$(sha256_file "$QD/r2_fn")" ]; chk "d013q_fn_whole_report_actually_differs" "$?" "0"
# replay fidele du branchement main() : on consigne signature(r1), puis on
# compare r2 -> stall detecte (alors qu avec l ancien sha du rapport entier il
# ne le serait PAS -> c est le faux negatif des 29 rounds, desormais corrige).
SFN="$QD/last_audit_P0_fn.sha256"; rm -f "$SFN"
printf '%s' "$(stall_signature "$QD/r1_fn")" > "$SFN"
audit_same_as_previous "$SFN" "$QD/r2_fn"; chk "d013q_fn_stall_detected_on_same_p1" "$?" "0"
# contre-preuve : avec l ANCIEN comportement (sha rapport entier) ce cas n etait
# PAS stalled -> on le montre explicitement pour caracteriser la correction :
printf '%s' "$(sha256_file "$QD/r1_fn")" > "$SFN"
audit_same_as_previous "$SFN" "$QD/r2_fn"; chk "d013q_fn_old_behavior_would_miss_it" "$?" "1"

# --- (2) FAUX POSITIF CORRIGE : deux rapports avec des findings P2 IDENTIQUES
#     mais AUCUN P1/High -> ne doit PAS declencher stall/FAIL (absence de finding
#     critique = etat distinct, pas un blocage recurrent). ---
printf 'PHASE_P0_FAIL\n\nP2\n\n- detail cosmetique identique fichier:ligne\n' > "$QD/r1_fp"
cp "$QD/r1_fp" "$QD/r2_fp"
# aucun P1/High -> signature vide :
[ -z "$(stall_signature "$QD/r1_fp")" ]; chk "d013q_fp_no_p1_empty_sig" "$?" "0"
# replay fidele : main() consigne la signature (vide) au round N, puis compare au
# round N+1 (P2 identiques) -> PAS stalled (l absence de P1/High neutralise la
# comparaison, meme si les 2 rapports sont byte-identiques).
SFP="$QD/last_audit_P0_fp.sha256"; rm -f "$SFP"
# round N : pas de prev -> non stalled -> main() consigne signature vide.
audit_same_as_previous "$SFP" "$QD/r1_fp"; chk "d013q_fp_r1_not_stalled" "$?" "1"
printf '%s' "$(stall_signature "$QD/r1_fp")" > "$SFP"   # consigne vide (comportement main)
# round N+1 : P2 identiques, signature vide -> prev vide -> PAS stalled.
audit_same_as_previous "$SFP" "$QD/r2_fp"; chk "d013q_fp_r2_identical_p2_not_stalled" "$?" "1"
# stall_action reflète bien 'normal' (pas de FAIL) sur ce non-stall :
rm -f "$QD/fp.used"
chk "d013q_fp_action_normal_no_fail" "$(stall_action 1 "$QD/fp.used")" "normal"

# --- (3) CAS NOMINAL : deux rapports avec un finding P1/High DIFFERENT -> pas de
#     stall (progres reel, comportement normal). ---
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/x.py:42 : bug A non resolu\n' > "$QD/r1_nom"
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/y.sh:99 : bug B different (autre point)\n' > "$QD/r2_nom"
[ "$(stall_signature "$QD/r1_nom")" != "$(stall_signature "$QD/r2_nom")" ]; chk "d013q_nom_diff_p1_diff_sig" "$?" "0"
SFNOM="$QD/last_audit_P0_nom.sha256"; rm -f "$SFNOM"
printf '%s' "$(stall_signature "$QD/r1_nom")" > "$SFNOM"
audit_same_as_previous "$SFNOM" "$QD/r2_nom"; chk "d013q_nom_different_p1_not_stalled" "$?" "1"

# --- (4) CAS MULTI-FINDINGS : rapport avec plusieurs findings P1/High, la
#     concatenation est STABLE et DETERMINISTE entre deux appels sur le meme
#     rapport (meme entree -> meme sortie). ---
printf 'PHASE_P1_FAIL\n\nP1\n\n- premier P1 factory/a.py:1\n\nP2\n\n- mineur ignore\n\nP1\n\n- second P1 factory/b.py:2\n\nHigh\n\n- high severity factory/c.py:3\n\nP3\n\n- ignore aussi\n' > "$QD/multi"
# determinisme : deux appels successifs -> signature identique.
m1="$(stall_signature "$QD/multi")"; m2="$(stall_signature "$QD/multi")"
[ -n "$m1" ]; chk "d013q_multi_sig_nonempty" "$?" "0"
[ "$m1" = "$m2" ]; chk "d013q_multi_deterministic" "$?" "0"
# seuls les blocs P1/High sont extraits (P2/P3 ecartes), dans l ordre d apparition :
EXM="$(extract_p1_high_findings "$QD/multi")"
printf '%s\n' "$EXM" | grep -qF -- '- premier P1 factory/a.py:1' && pass=$((pass+1)) \
  || { fail=$((fail+1)); echo "FAIL: d013q multi n extrait pas le 1er P1"; }
printf '%s\n' "$EXM" | grep -qF -- '- second P1 factory/b.py:2' && pass=$((pass+1)) \
  || { fail=$((fail+1)); echo "FAIL: d013q multi n extrait pas le 2e P1"; }
printf '%s\n' "$EXM" | grep -qF -- '- high severity factory/c.py:3' && pass=$((pass+1)) \
  || { fail=$((fail+1)); echo "FAIL: d013q multi n extrait pas le High"; }
if printf '%s\n' "$EXM" | grep -qF 'mineur ignore'; then
  fail=$((fail+1)); echo "FAIL: d013q multi extrait un bloc P2 (doit etre ecarte)"
else pass=$((pass+1)); fi
# l ordre d apparition est respecte (stable) : a.py avant b.py avant c.py.
# La sortie JSON est mono-ligne : on compare les positions (index de caractere)
# de chaque marqueur dans la chaine extraite, pas les numeros de ligne.
a=$(printf '%s' "$EXM" | awk -v m='a.py:1' '{print index($0,m)}')
b=$(printf '%s' "$EXM" | awk -v m='b.py:2' '{print index($0,m)}')
c=$(printf '%s' "$EXM" | awk -v m='c.py:3' '{print index($0,m)}')
[ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$c" -gt 0 ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
chk "d013q_multi_stable_appearance_order" "$?" "0"

# --- D-013-quater FIX (revue Codex du commit precedent) : 3 correctifs cibles.
#     (a) [P1] le parser ne reconnaissait qu'une ligne EXACTEMENT "P1"/"High" ->
#         "## P1", "[P1] Titre", "### High" donnaient une signature vide et un
#         finding critique recurrent ne declenchait jamais redirect/FAIL.
#     (b) [P2] les en-tetes etaient supprimes avant concatenation -> deux blocs
#         distincts "P1->A"+"P1->B" produisaient la MEME signature qu un seul
#         bloc "P1->A+B" (perte des frontieres, vrai changement masque en stall).
#     (c) un echec du parser n etait pas propage -> on pouvait decider un stall
#         sur une signature incalculable. Desormais rc=1 remonte a l appelant. ---

# (a-fix) en-tetes markdown / entre crochets reconnus (sinon signature vide ->
#     finding critique recurrent jamais detecte). Preuve REELLE sur les 3 formes
#     legitimes produites par Codex.
printf 'PHASE_P0_FAIL\n\n## P1\n\n- finding markdown factory/a.py:1\n' > "$QD/md_p1"
printf 'PHASE_P0_FAIL\n\n### High\n\n- high markdown factory/c.py:3\n' > "$QD/md_high"
printf 'PHASE_P0_FAIL\n\n[P1] Titre du finding\n\n- finding bracket factory/d.py:4\n' > "$QD/brk_p1"
[ -n "$(extract_p1_high_findings "$QD/md_p1")" ];  chk "d013q_fix_md_p1_detected"     "$?" "0"
[ -n "$(extract_p1_high_findings "$QD/md_high")" ]; chk "d013q_fix_md_high_detected"   "$?" "0"
[ -n "$(extract_p1_high_findings "$QD/brk_p1")" ];  chk "d013q_fix_bracket_p1_detected" "$?" "0"
# chaque forme extrait bien le finding (pas juste un en-tete vide) :
extract_p1_high_findings "$QD/md_p1"  | grep -qF 'finding markdown factory/a.py:1'; chk "d013q_fix_md_p1_content" "$?" "0"
extract_p1_high_findings "$QD/md_high" | grep -qF 'high markdown factory/c.py:3';    chk "d013q_fix_md_high_content" "$?" "0"
extract_p1_high_findings "$QD/brk_p1"  | grep -qF 'finding bracket factory/d.py:4';  chk "d013q_fix_bracket_p1_content" "$?" "0"
# sans verdict PHASE_*_FAIL, un titre Markdown sans severite ne cree aucun payload :
printf '## Synthese\n\n- pas un finding de severite\n' > "$QD/md_nosev"
[ -z "$(extract_p1_high_findings "$QD/md_nosev")" ]; chk "d013q_fix_md_non_severity_not_extracted" "$?" "0"

# --- D-013-quater FIX round 2 (revue Codex) : 2 nouveaux correctifs P1. ---
# (a2-fix) [P1] "## Highlights" ne doit PAS matcher "High"+"lights" (prefixe
#     libre). Sinon signature critique non vide sans finding reel -> faux
#     positif de stall/FAIL. Extraction DOIT rester vide.
printf 'P2\n\n## Highlights\n\n- texte non-finding quelconque\n' > "$QD/highlights"
HL="$(extract_p1_high_findings "$QD/highlights")"
[ -z "$HL" ]; chk "d013q_fix2_highlights_not_high" "$?" "0"
# variante : "## Highlander" et "High" isole nu reconnu (controle frontieres) :
printf '## Highlander\n\n- encore un faux positif potentiel\n' > "$QD/highlander"
[ -z "$(extract_p1_high_findings "$QD/highlander")" ]; chk "d013q_fix2_highlander_not_high" "$?" "0"
printf 'High\n\n- vrai high nu factory/h.sh:9\n' > "$QD/high_bare"
HB="$(extract_p1_high_findings "$QD/high_bare")"
[ -n "$HB" ]; chk "d013q_fix2_high_bare_still_detected" "$?" "0"
printf '%s' "$HB" | grep -qF 'vrai high nu factory/h.sh:9'; chk "d013q_fix2_high_bare_content" "$?" "0"
# (b2-fix) [P1] un sous-titre PLUS profond que le header de severite ("## P1"
#     puis "### ...") ne doit PAS vider le bloc : le contenu qui suit est un
#     finding reel a extraire (sinon faux negatif -> stall jamais declenche).
printf '## P1\n\n### Empty input crashes\n\nThe extractor fails on empty input factory/e.py:7.\n' > "$QD/subtitle"
SB="$(extract_p1_high_findings "$QD/subtitle")"
[ -n "$SB" ]; chk "d013q_fix2_subtitle_block_not_emptied" "$?" "0"
printf '%s' "$SB" | grep -qF 'The extractor fails on empty input factory/e.py:7.'; chk "d013q_fix2_subtitle_desc_extracted" "$?" "0"
printf '%s' "$SB" | grep -qF '### Empty input crashes'; chk "d013q_fix2_subtitle_kept_in_block" "$?" "0"
# controle : un titre de meme rang ("##") ferme bien le bloc P1 (nouvelle section) :
printf '## P1\n\n- finding A factory/a.py:1\n\n## Autre section\n\n- ne doit pas fuir factory/z.py:9\n' > "$QD/samerank"
SR="$(extract_p1_high_findings "$QD/samerank")"
printf '%s' "$SR" | grep -qF 'finding A factory/a.py:1'; chk "d013q_fix2_samerank_keeps_finding" "$?" "0"
if printf '%s' "$SR" | grep -qF 'ne doit pas fuir factory/z.py:9'; then
  fail=$((fail+1)); echo "FAIL: d013q_fix2 un titre de meme rang laisse fuiter le contenu hors-bloc"
else pass=$((pass+1)); fi

# (b-fix) FRONTIERES preservees : deux blocs P1 distincts "A" puis "B" produisent
#     une signature DIFFERENTE d un seul bloc P1 fusionne "A\nB" (sinon un vrai
#     changement de structure des findings serait masque en stall). La sortie
#     JSON conserve les frontieres (un element par bloc).
printf 'P1\n\n- finding A factory/a.py:1\n\nP1\n\n- finding B factory/b.py:2\n' > "$QD/two_blocks"
printf 'P1\n\n- finding A factory/a.py:1\n- finding B factory/b.py:2\n' > "$QD/fused_block"
EX_TWO="$(extract_p1_high_findings "$QD/two_blocks")"
EX_FUSED="$(extract_p1_high_findings "$QD/fused_block")"
# deux blocs -> tableau JSON a 2 elements (1 virgule) ; fusionne -> 1 element (0).
nsep_two=$(printf '%s' "$EX_TWO" | tr -cd ',' | wc -c | tr -d ' ')
nsep_fused=$(printf '%s' "$EX_FUSED" | tr -cd ',' | wc -c | tr -d ' ')
[ "$nsep_two" -gt "$nsep_fused" ]; chk "d013q_fix_boundaries_more_elements_two" "$?" "0"
# les signatures DIFFERENT (changement de structure reellement detecte) :
[ "$(stall_signature "$QD/two_blocks")" != "$(stall_signature "$QD/fused_block")" ]; chk "d013q_fix_boundaries_signatures_differ" "$?" "0"
# contre-preuve : deux fois le meme rapport -> signature identique (deterministe).
[ "$(stall_signature "$QD/two_blocks")" = "$(stall_signature "$QD/two_blocks")" ]; chk "d013q_fix_boundaries_deterministic" "$?" "0"

# (c-fix) ECHEC du parser propage avec un rc DISTINCT (2) jusqu a l appelant.
# Fichier UTF-8 invalide -> read_text leve -> extract rc=1 -> signature/audit rc=2.
printf '\xff\xfe\xfd octets invalides\nP1\n- x\n' > "$QD/bad_utf8"
extract_p1_high_findings "$QD/bad_utf8" 2>/dev/null; chk "d013q_fix_extract_failure_rc" "$?" "1"
stall_signature "$QD/bad_utf8" 2>/dev/null; chk "d013q_fix_signature_failure_rc" "$?" "2"
# audit_same_as_previous propage aussi ce rc distinct (jamais confondu avec progres) :
SF_BAD="$QD/last_audit_bad.sha256"; printf '%s' "$(stall_signature "$QD/r1_fn")" > "$SF_BAD"
audit_same_as_previous "$SF_BAD" "$QD/bad_utf8" 2>/dev/null; chk "d013q_fix_audit_propagates_parser_failure" "$?" "2"

# ====================================================================
# D-013-quater FIX ROUND 3 : contrat de sortie reel, formats Markdown,
# prose "High", titre apres token nu, P0 critique, et erreur parser infra.
# ====================================================================

# (r3-1) FALLBACK contractuel : PHASE_P0_FAIL suivi directement de findings
# fichier:ligne, sans aucun header de severite, produit une signature stable.
printf 'PHASE_P0_FAIL\n\n- factory/bin/direct.py:17 : blocage sans etiquette\n' > "$QD/unlabeled_r1"
cp "$QD/unlabeled_r1" "$QD/unlabeled_r2"
UF1="$(extract_p1_high_findings "$QD/unlabeled_r1")"
printf '%s' "$UF1" | grep -qF '["- factory/bin/direct.py:17 : blocage sans etiquette"]'
chk "d013q_r3_unlabeled_payload_canonical_array" "$?" "0"
printf '%s' "$UF1" | grep -qF 'factory/bin/direct.py:17'; chk "d013q_r3_unlabeled_payload_content" "$?" "0"
USIG="$(stall_signature "$QD/unlabeled_r1")"
[ -n "$USIG" ]; chk "d013q_r3_unlabeled_signature_nonempty" "$?" "0"
USF="$QD/last_audit_unlabeled.sha256"; printf '%s' "$USIG" > "$USF"
audit_same_as_previous "$USF" "$QD/unlabeled_r2"; chk "d013q_r3_unlabeled_repeat_stalls" "$?" "0"
# Une modification du finding non etiquete reste un progres reel (signature diff).
printf 'PHASE_P0_FAIL\n\n- factory/bin/direct.py:18 : autre blocage\n' > "$QD/unlabeled_changed"
[ "$(stall_signature "$QD/unlabeled_r1")" != "$(stall_signature "$QD/unlabeled_changed")" ]
chk "d013q_r3_unlabeled_change_not_same_signature" "$?" "0"

# Le fallback n'est active QUE par le verdict contractuel exact de phase.
printf 'FIX_NEEDED\n\n- factory/bin/direct.py:17 : sans token phase\n' > "$QD/unlabeled_wrong_token"
[ -z "$(stall_signature "$QD/unlabeled_wrong_token")" ]; chk "d013q_r3_fallback_requires_phase_fail" "$?" "0"
# Le garde de protocole main distingue aussi PASS/FAIL exacts et ne repare pas
# silencieusement un token avec whitespace INTERNE.
phase_audit_has_token "$QD/unlabeled_r1" "PHASE_P0_FAIL"; chk "d013q_r3_fail_token_exact" "$?" "0"
printf 'PHASE_ P0_FAIL\n- finding\n' > "$QD/token_internal_space"
phase_audit_has_token "$QD/token_internal_space" "PHASE_P0_FAIL"; chk "d013q_r3_fail_token_internal_space_rejected" "$?" "1"

# (r3-1b) P2 explicite desactive le fallback : P2-only reste sans signature,
# meme si le rapport contient ensuite une phrase ordinaire commencant par High.
printf 'PHASE_P0_FAIL\n\nP2\n\n- detail cosmetique\n\nHigh confidence: les checks passent.\n' > "$QD/p2_high_prose"
[ -z "$(stall_signature "$QD/p2_high_prose")" ]; chk "d013q_r3_p2_high_prose_no_signature" "$?" "0"

# (r3-2) "High confidence" n'est jamais un header ; les formes structurelles
# restent reconnues (separateur explicite, bracket/bullet/gras).
printf 'High confidence: texte ordinaire hors audit.\n' > "$QD/high_confidence_plain"
[ -z "$(extract_p1_high_findings "$QD/high_confidence_plain")" ]; chk "d013q_r3_high_prose_not_header" "$?" "0"
printf '## High: panne critique\n\n- factory/h.py:3\n' > "$QD/high_colon"
printf '%s' "$(extract_p1_high_findings "$QD/high_colon")" | grep -qF 'panne critique'
chk "d013q_r3_high_colon_header" "$?" "0"
printf 'PHASE_P0_FAIL\n\n- **[P1] Crash liste gras**\n\n- factory/bold.py:4\n' > "$QD/bullet_bold"
printf '%s' "$(extract_p1_high_findings "$QD/bullet_bold")" | grep -qF 'Crash liste gras'
chk "d013q_r3_bullet_bold_header" "$?" "0"
printf '### P1 Titre sans deux-points\n\n- factory/numbered.py:5\n' > "$QD/p1_space_title"
printf '%s' "$(extract_p1_high_findings "$QD/p1_space_title")" | grep -qF 'Titre sans deux-points'
chk "d013q_r3_p1_space_title_header" "$?" "0"

# (r3-3) Token nu suivi d'un titre Markdown : le premier titre appartient au
# finding et ne flush pas le bloc vide.
printf 'P1\n\n### Empty input crashes\n\nDetails factory/nested.py:8.\n' > "$QD/bare_nested"
BN="$(extract_p1_high_findings "$QD/bare_nested")"
printf '%s' "$BN" | grep -qF '### Empty input crashes'; chk "d013q_r3_bare_nested_title_kept" "$?" "0"
printf '%s' "$BN" | grep -qF 'Details factory/nested.py:8.'; chk "d013q_r3_bare_nested_body_kept" "$?" "0"

# P0 est plus critique que P1 : il doit participer au stall au lieu d'etre
# silencieusement traite comme une frontiere non critique.
printf 'PHASE_P1_FAIL\n\n[P0] Corruption de donnees\n\n- factory/critical.py:1\n' > "$QD/p0_critical"
P0PAY="$(extract_p1_high_findings "$QD/p0_critical")"
printf '%s' "$P0PAY" | grep -qF 'Corruption de donnees'; chk "d013q_r3_p0_payload" "$?" "0"
[ -n "$(stall_signature "$QD/p0_critical")" ]; chk "d013q_r3_p0_signature_nonempty" "$?" "0"

# (r3-4) main calcule UNE signature, intercepte l'erreur parser AVANT
# stall_action, la route en infra et preserve explicitement l'etat redirect.
n_main_sig=$(grep -cF 'STALL_SIG="$(stall_signature "$AUDIT_CODEX")"' "$DRV")
chk "d013q_r3_main_single_signature_calculation" "$n_main_sig" "1"
parse_line=$(grep -nF 'if STALL_SIG="$(stall_signature "$AUDIT_CODEX")"; then' "$DRV" | head -1 | cut -d: -f1)
action_line=$(grep -nF 'case "$(stall_action "$STALL_RC" "$REDIRECT_FLAG")" in' "$DRV" | head -1 | cut -d: -f1)
[ -n "$parse_line" ] && [ -n "$action_line" ] && [ "$parse_line" -lt "$action_line" ]
chk "d013q_r3_parser_guard_before_stall_action" "$?" "0"
grep -qF 'audit Codex illisible (parser stall rc!=0) -> infra_fail, etat stall/redirect preserve' "$DRV"
chk "d013q_r3_parser_failure_logged_as_infra" "$?" "0"
# Le rc=2 n'est pas consommable par la table normal/progres : main intercepte
# par un continue dans la branche d'erreur avant tout reset de flag.
guard_block=$(sed -n "${parse_line},${action_line}p" "$DRV")
printf '%s' "$guard_block" | grep -qF 'apply_backoff "$infra_fails"'; chk "d013q_r3_parser_infra_backoff" "$?" "0"
printf '%s' "$guard_block" | grep -qF 'continue'; chk "d013q_r3_parser_infra_continue" "$?" "0"
# Les deux autres sorties non exploitables du reviewer final sont aussi infra,
# jamais des rounds de repair : fichier vide et token de verdict invalide.
empty_guard=$(grep -nF 'audit Codex vide -> infra_fail, aucun round de repair consomme' "$DRV" | head -1 | cut -d: -f1)
bad_token_guard=$(grep -nF 'verdict audit Codex invalide (attendu $TOKEN ou $FAIL_TOKEN en premiere ligne) -> infra_fail' "$DRV" | head -1 | cut -d: -f1)
[ -n "$empty_guard" ] && [ "$empty_guard" -lt "$inc_line" ]; chk "d013q_r3_empty_audit_infra_before_budget" "$?" "0"
[ -n "$bad_token_guard" ] && [ "$bad_token_guard" -lt "$inc_line" ]; chk "d013q_r3_bad_verdict_infra_before_budget" "$?" "0"

# ====================================================================
# D-013-quater FIX ROUND 4 : canonicalisation label/fallback et corruption
# du SHA precedent routee en infra sans reset du flag de redirection.
# ====================================================================

# (r4-1) Le label de severite est une presentation, pas le finding. Le meme
# contenu avec puis sans "P1" doit produire le meme payload/signature, afin
# qu'une variation de format du reviewer apres redirection reste un stall.
printf 'PHASE_P0_FAIL\n\nP1\n\n- factory/bin/direct.py:17 : blocage sans etiquette\n' > "$QD/labeled_same_as_fallback"
LFSIG="$(stall_signature "$QD/labeled_same_as_fallback")"
[ "$LFSIG" = "$USIG" ]; chk "d013q_r4_labeled_unlabeled_same_signature" "$?" "0"
[ "$(extract_p1_high_findings "$QD/labeled_same_as_fallback")" = "$UF1" ]
chk "d013q_r4_labeled_unlabeled_same_payload" "$?" "0"
R4FLAG="$QD/r4_format_redirect.used"; : > "$R4FLAG"
R4SHA="$QD/r4_format.sha256"; printf '%s' "$LFSIG" > "$R4SHA"
audit_signature_same_as_previous "$R4SHA" "$USIG"
chk "d013q_r4_format_change_detected_as_stall" "$?" "0"
chk "d013q_r4_format_change_after_redirect_fails" "$(stall_action 0 "$R4FLAG")" "fail"

# (r4-2) Seule l'ABSENCE du fichier precedent est un premier round (rc=1).
# Tout fichier present mais vide, malforme ou non-regulier est un etat corrompu
# (rc=2), jamais un faux progres susceptible de purger redirect_attempt.
R4MISSING="$QD/r4_missing.sha256"
audit_signature_same_as_previous "$R4MISSING" "$USIG"
chk "d013q_r4_missing_previous_is_first_round" "$?" "1"
R4EMPTY="$QD/r4_empty.sha256"; : > "$R4EMPTY"
audit_signature_same_as_previous "$R4EMPTY" "$USIG"
chk "d013q_r4_empty_previous_is_infra" "$?" "2"
R4BAD="$QD/r4_bad.sha256"; printf 'not-a-sha256\n' > "$R4BAD"
audit_signature_same_as_previous "$R4BAD" "$USIG"
chk "d013q_r4_malformed_previous_is_infra" "$?" "2"
R4DIR="$QD/r4_sha_directory"; mkdir "$R4DIR"
audit_signature_same_as_previous "$R4DIR" "$USIG"
chk "d013q_r4_nonregular_previous_is_infra" "$?" "2"
rmdir "$R4DIR"
R4DANGLING="$QD/r4_dangling.sha256"; ln -s "$QD/absent_target" "$R4DANGLING"
audit_signature_same_as_previous "$R4DANGLING" "$USIG"
chk "d013q_r4_dangling_previous_is_infra" "$?" "2"
rm -f "$R4DANGLING"
R4UPPER="$QD/r4_upper.sha256"; printf '%s' "$USIG" | tr '[:lower:]' '[:upper:]' > "$R4UPPER"
audit_signature_same_as_previous "$R4UPPER" "$USIG"
chk "d013q_r4_uppercase_valid_sha_matches" "$?" "0"

# La production intercepte explicitement rc=2 avant stall_action et continue
# dans la branche infra, en preservant les deux fichiers d'etat.
compare_line=$(grep -nF 'if audit_signature_same_as_previous "$STALL_FILE" "$STALL_SIG"; then' "$DRV" | head -1 | cut -d: -f1)
corrupt_guard_line=$(grep -nF 'if [ "$STALL_RC" -eq 2 ]; then' "$DRV" | head -1 | cut -d: -f1)
action_line=$(grep -nF 'case "$(stall_action "$STALL_RC" "$REDIRECT_FLAG")" in' "$DRV" | head -1 | cut -d: -f1)
[ -n "$compare_line" ] && [ -n "$corrupt_guard_line" ] && [ -n "$action_line" ] \
  && [ "$compare_line" -lt "$corrupt_guard_line" ] && [ "$corrupt_guard_line" -lt "$action_line" ]
chk "d013q_r4_corrupt_guard_before_stall_action" "$?" "0"
corrupt_guard_block=$(sed -n "${corrupt_guard_line},${action_line}p" "$DRV")
printf '%s' "$corrupt_guard_block" | grep -qF 'signature stall precedente invalide -> infra_fail, etat stall/redirect preserve'
chk "d013q_r4_corrupt_previous_logged_as_infra" "$?" "0"
printf '%s' "$corrupt_guard_block" | grep -qF 'apply_backoff "$infra_fails"'
chk "d013q_r4_corrupt_previous_backoff" "$?" "0"
printf '%s' "$corrupt_guard_block" | grep -qF 'continue'
chk "d013q_r4_corrupt_previous_continue" "$?" "0"
if printf '%s' "$corrupt_guard_block" | grep -qF 'purge_file_logged'; then
  fail=$((fail+1)); echo "FAIL: d013q_r4 la garde de corruption purge un etat stall/redirect"
else pass=$((pass+1)); fi

# --- (5) REGRESSION EXPLICITE : aucun fichier last_audit_${PHASE}.sha256 n est
#     jamais ecrit ou supprime en dehors de atomic_write_exact / purge_file_logged
#     (meme garde de securite qu en D-013-ter, etendue a l ecriture). ---
# (5a) pas de 'rm -f ... 2>/dev/null' muet ciblant un fichier d etat de stall
#      (garde D-013-ter, reaffirmee pour D-013-quater) :
if grep -qE 'rm -f .*(pending_redirect_\$\{PHASE\}|last_audit_P[01]\.sha256).*2>/dev/null' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013q un 'rm -f ... 2>/dev/null' muet cible encore un fichier d etat de stall"
else pass=$((pass+1)); fi
# (5b) aucune ecriture par redirection directe (printf/echo > $STALL_FILE ou
#      > last_audit_*.sha256) en dehors d atomic_write_exact : on interdit tout
#      '>' ou '>>' ciblant explicitement le fichier de stall.
if grep -nE '(>|>>)[[:space:]]*"?\$?STALL_FILE"?' "$DRV" | grep -qvE 'atomic_write_exact|purge_file_logged' \
   || grep -nE '(>|>>)[[:space:]]*"?\$RECEIPTS_DIR/last_audit_P[01]\.sha256"?' "$DRV" | grep -qvE 'atomic_write_exact|purge_file_logged'; then
  fail=$((fail+1)); echo "FAIL: d013q ecriture directe (redirection) sur last_audit hors atomic_write_exact/purge_file_logged"
else pass=$((pass+1)); fi
# (5c) atomic_write_exact est TOUJOURS l unique voie d ecriture du SHA de stall :
grep -qF 'atomic_write_exact "$STALL_FILE"' "$DRV"; chk "d013q_stall_write_via_atomic_only" "$?" "0"
# (5d) sha256_file n est plus utilise COMME CONTENU consigne pour le stall (il
#      reste legitime ailleurs : checkpoint_p0) -- on verifie l absence du motif
#      specifique au site de stall :
if grep -qF '"$(sha256_file "$AUDIT_CODEX")" > "$STALL_FILE"' "$DRV" \
   || grep -qF 'atomic_write_exact "$STALL_FILE" "$(sha256_file "$AUDIT_CODEX")"' "$DRV"; then
  fail=$((fail+1)); echo "FAIL: d013q le rapport entier est encore consigne comme SHA de stall"
else pass=$((pass+1)); fi

echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
