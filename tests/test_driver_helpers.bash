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
# MAX_INFRA_FAILS=10, et un « cap 2 » repair contredisant MAX_*_REPAIR=30 :
# contradiction d'autorité À L'INTÉRIEUR du fichier du driver lui-même. On
# vérifie qu'aucune mention périmée d'un seuil de budget ne subsiste dans le
# driver (les chaînes exactes citées par l'audit), puis on généralise : tout
# seuil numérique « max N échecs » (infra) ou « cap N » (repair) présent dans
# un commentaire du driver DOIT valoir la constante correspondante. ---
for bad in 'max 2 repairs' 'max 3 retries' 'max 3 échecs' 'max 3 echecs' 'cap 2'; do
  if grep -qiF "$bad" "$REPO/run_run4_autonomous.sh"; then
    fail=$((fail+1)); echo "FAIL: driver contient l'autorité périmée '$bad' (contradictoire avec MAX_*_REPAIR=30 / MAX_INFRA_FAILS=10)"
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

# --- P0 finding 6 (round 16, contre-audit Codex PHASE_P0_FAIL) : l'AUTORITÉ
# UNIQUE documentée doit être EXTERNE au code ET cohérente. L'audit citait
# deux contradictions d'autorité désormais corrigées :
#   (a) MASTER_ORDER § AUTONOMIE énumérait un sous-ensemble de 4 états +
#       « après 2 repairs », en désaccord avec le § MACHINE À ÉTATS (8 états,
#       budgets de 30) — seconde autorité contradictoire.
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

echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
