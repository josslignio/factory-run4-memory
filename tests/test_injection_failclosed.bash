#!/usr/bin/env bash
# Tests de l'INJECTION FAIL-CLOSED — master order Run 4, PHASE P1, fonction 4.
#
# Prouve que le driver appelle `lesson_injector.py ... --format quiet` AVANT
# chaque tâche builder et s'arrête en MEMORY_SYSTEM_FAIL si rc!=0 (et pas
# rc=2-clean). Le hook driver EXISTE DÉJÀ (garde P0 de la machine à états) :
# ce fichier AJOUTE le test formel qui le prouve (point 4 du brief P1).
#
# Trois niveaux de preuve :
#   1. STRUCTUREL : le driver source/câble exactement le hook (appel
#      lesson_injector.py --format quiet, branche MEMORY_SYSTEM_FAIL, exit 1,
#      et ce AVANT l'appel opencode run / build).
#   2. COMPORTEMENTAL injecteur : le VRAI lesson_injector.py renvoie rc=1 sur
#      une mémoire corrompue (le déclencheur que la branche driver attend),
#      rc=0 ou rc=2-clean sur une mémoire saine.
#   3. COMPORTEMENTAL contrat driver : on réplique le contrat EXACT du driver
#      (if rc=0 || (rc=2 && stderr vide) ... else MEMORY_SYSTEM_FAIL) sur des
#      rc/stderr contrôlés -> MEMORY_SYSTEM_FAIL est écrit exactement quand
#      le contrat l'exige.
#
# Source le pilote (garde BASH_SOURCE[0]} = $0). Stdlib bash + python3.
# Usage : bash tests/test_injection_failclosed.bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

source ./run_run4_autonomous.sh

pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 -> got [$2] want [$3]"; fi; }

TMP="$(mktemp -d)"
_cleanup_tmp() {  # NON récursif (règle 7 absolue) : fichiers directs + rmdir.
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  local f
  for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -f "$f" ] && rm -f "$f"
  done
  rmdir "$1" 2>/dev/null || true
}
trap '_cleanup_tmp "$TMP"' EXIT

STATE_FILE="$TMP/state"; LOG="$TMP/log"; PHASE_FILE="$TMP/phase"
RECEIPTS_DIR="$TMP/receipts"; mkdir -p "$RECEIPTS_DIR"
: > "$LOG"
DRV="run_run4_autonomous.sh"
INJ="factory/bin/lesson_injector.py"

# ====================================================================
# 1. PREUVE STRUCTURELLE : le hook est câblé EXACTEMENT comme le contrat.
# ====================================================================
# (a) le driver appelle bien lesson_injector.py AVEC --format quiet :
grep -qF 'python3 factory/bin/lesson_injector.py "healthcheck driver preflight" --format quiet' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: hook n appelle pas lesson_injector.py --format quiet"; }
# (b) la branche MEMORY_SYSTEM_FAIL existe et écrit dans STATE_FILE :
grep -qF 'echo "MEMORY_SYSTEM_FAIL" > "$STATE_FILE"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: branche MEMORY_SYSTEM_FAIL absente"; }
# (c) le hook EXIT 1 sur échec (arrêt, pas de continuation silencieuse) :
grep -qE 'lesson_injector rc=\$INJ_RC.*MEMORY_SYSTEM_FAIL.*arret' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: log + exit MEMORY_SYSTEM_FAIL absent"; }
# (d) le contrat rc=0 OU (rc=2 ET stderr vide) est bien la condition saine :
grep -qF '[ "$INJ_RC" -eq 0 ] || { [ "$INJ_RC" -eq 2 ] && [ ! -s "$INJ_ERR" ]; }' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: contrat rc=0 || (rc=2 && stderr vide) absent"; }
# (e) injecteur manquant -> MEMORY_SYSTEM_FAIL (jamais de repli silencieux) :
grep -qE 'if \[ ! -f "factory/bin/lesson_injector.py" \]' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: garde injecteur-manquant absente"; }
# (f) ORDRE : le hook mémoire court AVANT l'appel opencode run (build), pas après.
inj_line=$(grep -nF 'lesson_injector.py "healthcheck driver preflight" --format quiet' "$DRV" | head -1 | cut -d: -f1)
build_line=$(grep -nF 'opencode run --model zai-coding-plan/glm-5.2 "$CUR_PROMPT"' "$DRV" | head -1 | cut -d: -f1)
[ -n "$inj_line" ] && [ -n "$build_line" ] && [ "$inj_line" -lt "$build_line" ]
chk "hook_avant_build" "$?" "0"

# ====================================================================
# 2. PREUVE COMPORTEMENTALE — l'injecteur RÉEL renvoie les rc attendus.
#    C'est la condition que la branche driver (`if rc=0 || (rc=2 && stderr
#    vide)`) filtre. On utilise --memory pour pointer sur des mémoires de
#    test (la mémoire réelle du repo n'est JAMAIS touchée).
# ====================================================================

# --- (a) mémoire SAINE : le préflight healthcheck doit renvoyer 0 ou 2-clean.
#     Sur la vraie mémoire du repo (lecture seule), l'injecteur ne doit
#     JAMAIS renvoyer 1 (store sain). On accepte 0 (match) ou 2 sans stderr.
ERR_OK="$TMP/inj_ok_stderr"
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory memory/lessons.jsonl >/dev/null 2>"$ERR_OK"
RC_OK=$?
if [ "$RC_OK" -eq 0 ] || { [ "$RC_OK" -eq 2 ] && [ ! -s "$ERR_OK" ]; }; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: mémoire saine -> injector rc=$RC_OK (attendu 0 ou 2-clean)"
fi

# --- (b) mémoire CORROMPUE : l'injecteur doit renvoyer rc=1 (le déclencheur
#     exact de MEMORY_SYSTEM_FAIL côté driver). Stderr non vide.
CORRUPT="$TMP/corrupt.jsonl"
printf 'CECI N EST PAS DU JSON {{{\n' > "$CORRUPT"
ERR_BAD="$TMP/inj_bad_stderr"
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory "$CORRUPT" >/dev/null 2>"$ERR_BAD"
RC_BAD=$?
chk "corrupt_memory_rc1" "$RC_BAD" "1"
# stderr non vide (= panne réelle, pas un MEMORY_VALID_NO_MATCH) :
[ -s "$ERR_BAD" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: mémoire corrompue -> stderr vide"; }

# --- (c) schéma invalide (ligne JSON valide mais leçon cassée) -> rc=1 aussi.
BADSCHEMA="$TMP/badschema.jsonl"
printf '{"id":"x","date":"bad","source":"s","category":"other","trigger_pattern":"t","description":"d","fix_pattern":"f","severity":"P9","evidence":"a.py:1"}\n' > "$BADSCHEMA"
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory "$BADSCHEMA" >/dev/null 2>/dev/null
chk "bad_schema_rc1" "$?" "1"

# --- (d) mémoire ABSENTE -> rc=1 (le déclencheur MEMORY_SYSTEM_FAIL).
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory "$TMP/n_existe_pas.jsonl" >/dev/null 2>/dev/null
chk "missing_memory_rc1" "$?" "1"

# ====================================================================
# 3. PREUVE COMPORTEMENTALE — le contrat EXACT du driver répliqué.
#    On reproduit l'if/else du driver sur des (rc, stderr) contrôlés et on
#    vérifie qu'il écrit MEMORY_SYSTEM_FAIL exactement quand le contrat
#    l'exige. C'est la preuve que la BRANCHE driver ferait la bonne chose
#    pour chacun des rc produits ci-dessus.
# ====================================================================
# driver_contract : réplique fidèle de run_run4_autonomous.sh:1120-1127.
driver_contract() {
  # $1 = INJ_RC, $2 = chemin fichier stderr (vide => stderr vide).
  local INJ_RC="$1" INJ_ERR="$2" res="OK"
  if [ "$INJ_RC" -eq 0 ] || { [ "$INJ_RC" -eq 2 ] && [ ! -s "$INJ_ERR" ]; }; then
    res="OK"
  else
    res="MEMORY_SYSTEM_FAIL"
  fi
  printf '%s' "$res"
}
EMPTY_ERR="$TMP/empty_err"; : > "$EMPTY_ERR"
NONEMPTY_ERR="$TMP/nonempty_err"; printf 'boom\n' > "$NONEMPTY_ERR"

# rc=0 -> OK (leçons trouvées)
chk "contract_rc0_ok"            "$(driver_contract 0 "$EMPTY_ERR")"    "OK"
# rc=0 même avec stderr -> OK (rc=0 est sain par contrat)
chk "contract_rc0_ok_any_stderr" "$(driver_contract 0 "$NONEMPTY_ERR")" "OK"
# rc=2 stderr vide -> OK (MEMORY_VALID_NO_MATCH, cas légitime)
chk "contract_rc2_clean_ok"      "$(driver_contract 2 "$EMPTY_ERR")"    "OK"
# rc=2 stderr non vide -> FAIL (erreur argparse/CLI = panne)
chk "contract_rc2_dirty_fail"    "$(driver_contract 2 "$NONEMPTY_ERR")" "MEMORY_SYSTEM_FAIL"
# rc=1 -> FAIL (store corrompu / schéma invalide)
chk "contract_rc1_fail"          "$(driver_contract 1 "$EMPTY_ERR")"    "MEMORY_SYSTEM_FAIL"
chk "contract_rc1_dirty_fail"    "$(driver_contract 1 "$NONEMPTY_ERR")" "MEMORY_SYSTEM_FAIL"
# rc inattendu (127, 42...) -> FAIL
chk "contract_rc127_fail"        "$(driver_contract 127 "$EMPTY_ERR")"  "MEMORY_SYSTEM_FAIL"
chk "contract_rc42_fail"         "$(driver_contract 42 "$NONEMPTY_ERR")" "MEMORY_SYSTEM_FAIL"

# ====================================================================
# 4. PREUVE INTÉGRÉE — injecteur corrompu -> état MEMORY_SYSTEM_FAIL écrit.
#    On exécute le VRAI injecteur sur une mémoire corrompue puis on applique
#    la décision du driver (répliquée) et on écrit l'état : il doit valoir
#    exactement MEMORY_SYSTEM_FAIL (le driver écrirait ça puis exit 1).
# ====================================================================
RUN_ERR="$TMP/run_err"
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory "$CORRUPT" >/dev/null 2>"$RUN_ERR"
RUN_RC=$?
if [ "$RUN_RC" -eq 0 ] || { [ "$RUN_RC" -eq 2 ] && [ ! -s "$RUN_ERR" ]; }; then
  echo "RUNNING" > "$STATE_FILE"
else
  echo "MEMORY_SYSTEM_FAIL" > "$STATE_FILE"
fi
chk "corrupt_run_state_memfail" "$(cat "$STATE_FILE")" "MEMORY_SYSTEM_FAIL"

# symétriquement, une mémoire saine ne déclenche JAMAIS l'arrêt :
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory memory/lessons.jsonl >/dev/null 2>"$RUN_ERR"
RUN_RC=$?
if [ "$RUN_RC" -eq 0 ] || { [ "$RUN_RC" -eq 2 ] && [ ! -s "$RUN_ERR" ]; }; then
  echo "RUNNING" > "$STATE_FILE"
else
  echo "MEMORY_SYSTEM_FAIL" > "$STATE_FILE"
fi
[ "$(cat "$STATE_FILE")" = "RUNNING" ] && pass=$((pass+1)) \
  || { fail=$((fail+1)); echo "FAIL: mémoire saine a déclenché MEMORY_SYSTEM_FAIL"; }

# ====================================================================
# 5. DOCUMENTATION — le contrat est tracé fichier:ligne (règle 4, L-049).
#    Le driver documente lui-même la garde (commentaire MASTER_ORDER).
# ====================================================================
# ====================================================================
# 5. DOCUMENTATION — le contrat est tracé fichier:ligne (règle 4, L-049).
#    Le driver documente lui-même la garde (commentaire MASTER_ORDER).
# ====================================================================
grep -qE 'Garde m.moire fail-closed AVANT tout appel agent' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: documentation garde mémoire absente"; }

# ====================================================================
# 6. BORNE P1 « retrieval max 5 leçons » : le défaut CLI --top du driver
#    (qui n'a pas de --top explicite) est 5, et la sortie quiet est bornée
#    à 5 leçons même quand >5 matchent. Mémoire de test avec 10 leçons
#    toutes matchées par une tâche large (la mémoire réelle n'est pas touchée).
# ====================================================================
BOUND_MEM="$TMP/bound.jsonl"
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf '{"id":"L-20260730T000000Z-%02d","date":"2026-07-30","source":"p","category":"concurrency","trigger_pattern":"fork-os; lock-file","description":"d","fix_pattern":"f","severity":"P2","evidence":"a.py:1"}\n' "$i" >> "$BOUND_MEM"
done
# (a) illimité (--top 0) -> les 10 matchent (preuve que >5 matchent vraiment) :
N_UNLIM=$(python3 "$INJ" "fork-os lock-file concurrency" --format quiet --memory "$BOUND_MEM" --top 0 | grep -c .)
chk "bound_unlimited_10_match" "$N_UNLIM" "10"
# (b) DÉFAUT (pas de --top, comme le driver) -> borné à 5 :
N_DEFAULT=$(python3 "$INJ" "fork-os lock-file concurrency" --format quiet --memory "$BOUND_MEM" | grep -c .)
chk "bound_default_caps_at_5" "$N_DEFAULT" "5"
# (c) --top 3 -> exactement 3 (la borne est bien appliquée) :
N_TOP3=$(python3 "$INJ" "fork-os lock-file concurrency" --format quiet --memory "$BOUND_MEM" --top 3 | grep -c .)
chk "bound_top3_caps_at_3" "$N_TOP3" "3"

echo ""
echo "Injection fail-closed (P1 fonction 4): PASS=$pass FAIL=$fail"
exit $([ "$fail" = 0 ] && echo 0 || echo 1)
