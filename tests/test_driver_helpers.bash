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
trap 'rm -rf "$TMP"' EXIT
STATE_FILE="$TMP/state"
LOG="$TMP/log"
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
chk "tr_ready_to_bossgo"     "$(legal_transition READY_FOR_FINAL_AUDIT WAITING_HUMAN_BOSS_GO)"  "legal"
chk "tr_ready_to_fail"       "$(legal_transition READY_FOR_FINAL_AUDIT FAIL)"                  "legal"
chk "tr_fail_to_running"     "$(legal_transition FAIL RUNNING)"                                "legal"
# transitions ILLÉGALES (cœur du finding : un builder NE PEUT PAS écrire un
# état terminal depuis RUNNING, ni sauter audit->infra, ni repartir d'un
# terminal sans RESUME_AFTER_FAIL explicite) :
chk "tr_run_to_bossgo_BAD"       "$(legal_transition RUNNING WAITING_HUMAN_BOSS_GO)"            "illegal"
chk "tr_run_to_done_BAD"         "$(legal_transition RUNNING DONE)"                             "illegal"
chk "tr_run_to_whuman_BAD"       "$(legal_transition RUNNING WAITING_HUMAN)"                    "illegal"
chk "tr_run_to_fail_BAD"         "$(legal_transition RUNNING FAIL)"                             "illegal"
chk "tr_ready_to_infra_BAD"      "$(legal_transition READY_FOR_FINAL_AUDIT WAITING_INFRA)"      "illegal"
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
# transition illégale : READY_FOR_FINAL_AUDIT -> WAITING_INFRA (saut interdit).
( enforce_legal_transition_or_die READY_FOR_FINAL_AUDIT WAITING_INFRA )
chk "prod_guard_illegal_ready_to_infra_exit1" "$?" "1"
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

echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
