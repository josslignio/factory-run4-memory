#!/usr/bin/env bash
# Tests de conformite spec — P0 reprise Run 4, items 5 & 6 (bash).
#   - Item 5 (honetete rapport ablation) : append-only par convention,
#     NON tamper-evident, NON crypto-seelle ; PAS de chainage crypto ;
#     runner reellement executable.
#   - Item 6 (machine a etats) : autorite unique documentee (MASTER_ORDER),
#     pas de reparation silencieuse (fail-closed reel via le garde de prod).
# Source le pilote (garde BASH_SOURCE). Usage : bash tests/test_p0_reprise.bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 -> got [$2] want [$3]"; fi; }
has(){ if grep -qiE "$2" "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3 absent (/$2/)"; fi; }

# ==================================================================== Item 5
REPORT="reports/RUN4_ABLATION_AB.md"
RUNNER="ablation/run_ablation.sh"
has "$REPORT" "par convention"                         "5a append-only par convention"
has "$REPORT" "n.est PAS tamper-evident|NON tamper-evident" "5b NON tamper-evident"
has "$REPORT" "n.est PAS cryptographiquement scell|NON .*scell" "5c NON crypto-seelle"
has "$REPORT" "Aucun cha.nage cryptographique"         "5d aucun chainage crypto"
if grep -iE "scell" "$REPORT" | grep -ivqE "pas|non|n'|jamais|ne |n’est"; then
  fail=$((fail+1)); echo "FAIL: 5e mention de scellement NON niee"
else pass=$((pass+1)); fi
# Runner : append (>>) pour le log, aucun chainage crypto.
chk "5f runner_append_only" "$(grep -cE '>>[[:space:]]*"?\$?LOG' "$RUNNER" | head -1)" "1"
if grep -qiE "import hashlib|hmac|prev_hash|next_hash|chain_hash|merkle" "$RUNNER"; then
  fail=$((fail+1)); echo "FAIL: 5g runner construit un chainage crypto"
else pass=$((pass+1)); fi
# Execution REELLE du runner (env overrides -> fichiers committes intacts).
TMP="$(mktemp -d)"
_cleanup_tmp() {  # NON recursif (regle 7 absolue) : fichiers directs + rmdir.
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  local f
  for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -f "$f" ] && rm -f "$f"
  done
  rmdir "$1" 2>/dev/null || true
}
trap '_cleanup_tmp "${TMP:-}"; _cleanup_tmp "${TMP2:-}"' EXIT
RL="$TMP/runlog.txt"
RUN_ABLATION_LOG="$RL" RUN_ABLATION_JSON_A="$TMP/a.json" RUN_ABLATION_JSON_B="$TMP/b.json" \
  bash "$RUNNER" >/dev/null 2>&1
chk "5h runner_real_exec_rc0" "$?" "0"
has "$RL" "BRAS A .sans memoire."   "5i runlog bras A"
has "$RL" "BRAS B .avec memoire."   "5j runlog bras B"

# ==================================================================== Item 6
source ./run_run4_autonomous.sh
TMP2="$(mktemp -d)"
STATE_FILE="$TMP2/state"; LOG="$TMP2/log"; PHASE_FILE="$TMP2/phase"
: > "$LOG"

MO="MASTER_ORDER_RUN4_MEMORY.md"
grep -qiE "MACHINE . ÉTATS.*AUTORIT" "$MO" && pass=$((pass+1)) \
  || { fail=$((fail+1)); echo "FAIL: 6a section autorite unique absente"; }
for s in RUNNING READY_FOR_FINAL_AUDIT WAITING_INFRA WAITING_HUMAN_BOSS_GO \
         WAITING_HUMAN FAIL DONE MEMORY_SYSTEM_FAIL; do
  grep -qF "\`$s\`" "$MO" && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL: 6b etat $s absent du MASTER_ORDER"; }
done

# state_kind : autorite unique des VALEURS
chk "kind_RUNNING"         "$(state_kind RUNNING)"                "build"
chk "kind_READY_FOR_AUDIT" "$(state_kind READY_FOR_FINAL_AUDIT)"  "audit"
chk "kind_WAITING_INFRA"   "$(state_kind WAITING_INFRA)"          "infra_stop"
chk "kind_FAIL"            "$(state_kind FAIL)"                   "terminal"
chk "kind_DONE"            "$(state_kind DONE)"                   "terminal"
chk "kind_MEMORY_FAIL"     "$(state_kind MEMORY_SYSTEM_FAIL)"     "terminal"
chk "kind_bogus_illegal"   "$(state_kind BOGUS)"                  "illegal"
chk "kind_empty_illegal"   "$(state_kind '')"                     "illegal"

# legal_transition : autorite unique des TRANSITIONS
chk "tr_legal_R_to_READY"  "$(legal_transition RUNNING READY_FOR_FINAL_AUDIT)" "legal"
chk "tr_legal_READY_to_GO" "$(legal_transition READY_FOR_FINAL_AUDIT WAITING_HUMAN_BOSS_GO)" "legal"
chk "tr_illegal_R_to_GO"   "$(legal_transition RUNNING WAITING_HUMAN_BOSS_GO)"  "illegal"
chk "tr_illegal_READY_to_INFRA" "$(legal_transition READY_FOR_FINAL_AUDIT WAITING_INFRA)" "illegal"
chk "tr_illegal_bogus"     "$(legal_transition BOGUS RUNNING)"                 "illegal"

# Garde REEL de production : fail-closed, jamais de reparation silencieuse.
( enforce_legal_transition_or_die RUNNING WAITING_HUMAN_BOSS_GO ) 2>/dev/null
chk "6c guard_illegal_exit1" "$?" "1"
( enforce_legal_transition_or_die RUNNING READY_FOR_FINAL_AUDIT ) 2>/dev/null
chk "6d guard_legal_exit0" "$?" "0"

echo ""
echo "P0 reprise (bash items 5-6): PASS=$pass FAIL=$fail"
exit $([ "$fail" = 0 ] && echo 0 || echo 1)
