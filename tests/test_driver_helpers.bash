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

echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
