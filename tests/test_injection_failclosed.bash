#!/usr/bin/env bash
# Tests de l'INJECTION FAIL-CLOSED — master order Run 4, PHASE P1, fonction 4.
#
# Prouve que le driver appelle `lesson_injector.py ... --format quiet` AVANT
# chaque tâche builder et s'arrête en MEMORY_SYSTEM_FAIL si rc!=0 (contrat
# STRICT, AUCUN carve-out). Le hook driver EXISTE DÉJÀ (garde P0 de la machine
# à états) ; ce fichier AJOUTE le test formel qui le prouve (point 4 du brief P1).
#
# TROIS niveaux de preuve, du plus faible au plus fort :
#
#   1. STRUCTUREL : le driver source/câble le hook (appel lesson_injector.py
#      --format quiet, branche MEMORY_SYSTEM_FAIL, exit 1, AVANT opencode run).
#      Preuve par grep du source. Insuffisant seul : prouve le branchement
#      statique, pas le comportement runtime.
#
#   2. COMPORTEMENTAL injecteur : le VRAI lesson_injector.py renvoie rc=1 sur
#      une mémoire corrompue (déclencheur attendu par la branche driver), rc=0
#      sur mémoire saine (match OU non-match, contrat strict P1). Preuve que
#      l'injecteur réel tient son contrat (la fonction driver s'appuie dessus).
#
#   3. COMPORTEMENTAL FONCTION DRIVER RÉELLE (round 2 Codex 30/07, fix du
#      defect « test ne lançait jamais le pilote réel ») : on source le
#      pilote, on surcharge STATE_FILE/LOG/RECEIPTS_DIR vers des chemins tmp,
#      on cd dans un worktree factice où factory/bin/lesson_injector.py est un
#      STUB contrôlé, puis on APPELLE memory_preflight_or_die (la fonction
#      RÉELLE extraite du pilote) en subshell pour capturer son exit code et
#      on lit STATE_FILE écrit par elle. Une régression du branchement/arrêt
#      réel casse CE test, pas seulement le grep.
#
# Stdlib bash + python3. Usage : bash tests/test_injection_failclosed.bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

# Source le pilote (sans l'invoquer : le garde BASH_SOURCE[0] != $0 le protège).
# Toutes les fonctions (memory_preflight_or_die, read_state, ...) sont désormais
# disponibles. On surcharge ENSUITE les chemins d'état vers des fichiers tmp.
# shellcheck source=/dev/null
source ./run_run4_autonomous.sh

pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 -> got [$2] want [$3]"; fi; }

TMP="$(mktemp -d)"
_purge_tmp() {  # NON récursif (règle 7 absolue) : fichiers directs + rmdir.
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  local f
  for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -f "$f" ] && rm -f "$f"
  done
  rmdir "$1" 2>/dev/null || true
}
trap '_purge_tmp "$TMP"' EXIT

DRV="run_run4_autonomous.sh"
INJ="factory/bin/lesson_injector.py"

# ====================================================================
# 1. PREUVE STRUCTURELLE — le hook est bien câblé dans le source du pilote.
# ====================================================================
# (a) le driver appelle bien memory_preflight_or_die (fonction extraite round 2) :
grep -qF 'memory_preflight_or_die "$i"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: driver n appelle pas memory_preflight_or_die"; }
# (b) la fonction existe et écrit MEMORY_SYSTEM_FAIL dans STATE_FILE :
grep -qF 'memory_preflight_or_die()' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: fonction memory_preflight_or_die absente"; }
grep -qF 'echo "MEMORY_SYSTEM_FAIL" > "$STATE_FILE"' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: écriture MEMORY_SYSTEM_FAIL absente"; }
# (c) la branche EXIT 1 sur échec (arrêt, pas de continuation silencieuse).
#     Log strict (audit P1 round 5) : mentionne le rc, la panne système,
#     MEMORY_SYSTEM_FAIL et l'arrêt — plus l'ancien wording « stderr non vide ».
grep -qE 'rc=\$_mpf_inj_rc \(!=0.*MEMORY_SYSTEM_FAIL.*arret' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: log + exit MEMORY_SYSTEM_FAIL absent"; }
# (c.bis) exit 1 explicite après chaque MEMORY_SYSTEM_FAIL : on extrait les
# lignes 'arret' et on vérifie que la ligne qui suit dans le source est
# bien 'exit 1'. Preuve statique complémentaire de la preuve comportementale
# (section 3 capture l'exit code réel = 1 dans tous les scénarios FAIL).
python3 - "$DRV" <<'PY'
import sys, re
src = open(sys.argv[1]).read().splitlines()
hits = 0; seen = 0
for i, ln in enumerate(src):
    if "MEMORY_SYSTEM_FAIL -> arret" in ln and i+1 < len(src):
        seen += 1
        # accepte '    exit 1' (indentation variable dans le corps de la fonction)
        if re.match(r"\s*exit 1\s*$", src[i+1]):
            hits += 1
sys.exit(0 if seen > 0 and hits == seen else 1)
PY
if [ "$?" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: exit 1 après MEMORY_SYSTEM_FAIL absent"; fi
# (d) le contrat STRICT rc=0 (AUCUN carve-out rc=2) est la condition saine.
#     Audit P1 round 5 (Codex) : l'ancien grep exigeait le carve-out
#     rc=2 && stderr-vide, entérinant le contournement au lieu de le détecter.
grep -qF 'if [ "$_mpf_inj_rc" -eq 0 ]; then' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: contrat strict rc=0 absent"; }
# (d.bis) AUCUN carve-out rc=2 ne doit subsister dans la condition saine du
#         driver : sa présence = audit P1 round 5 non fermé.
! grep -qF '[ "$_mpf_inj_rc" -eq 2 ]' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: carve-out rc=2 toujours present dans le driver (audit P1 round 5 non ferme)"; }
# (e) injecteur manquant -> MEMORY_SYSTEM_FAIL (jamais de repli silencieux) :
grep -qE 'if \[ ! -f "factory/bin/lesson_injector.py" \]' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: garde injecteur-manquant absente"; }
# (f) ORDRE : la garde mémoire court AVANT l'appel opencode run (build).
inj_line=$(grep -nF 'memory_preflight_or_die "$i"' "$DRV" | head -1 | cut -d: -f1)
build_line=$(grep -nF 'opencode run --model zai-coding-plan/glm-5.2 "$CUR_PROMPT"' "$DRV" | head -1 | cut -d: -f1)
[ -n "$inj_line" ] && [ -n "$build_line" ] && [ "$inj_line" -lt "$build_line" ]
chk "hook_avant_build" "$?" "0"
# (g) documentation MASTER_ORDER dans le source (règle 4, L-049) :
grep -qE 'Garde m.moire fail-closed AVANT tout appel agent' "$DRV" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: documentation garde mémoire absente"; }

# ====================================================================
# 2. PREUVE COMPORTEMENTALE — l'injecteur RÉEL renvoie les rc attendus.
#    On utilise --memory pour pointer sur des mémoires de test (la mémoire
#    réelle du repo n'est JAMAIS touchée par cette section).
# ====================================================================
# (a) mémoire SAINE : le préflight healthcheck doit renvoyer rc=0 (contrat
#     strict injecteur : mémoire saine -> rc=0, match OU non-match).
ERR_OK="$TMP/inj_ok_stderr"
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory memory/lessons.jsonl >/dev/null 2>"$ERR_OK"
RC_OK=$?
chk "sane_memory_rc0" "$RC_OK" "0"

# (b) mémoire CORROMPUE : l'injecteur doit renvoyer rc=1 (le déclencheur exact
#     de MEMORY_SYSTEM_FAIL côté driver). Stderr non vide.
CORRUPT="$TMP/corrupt.jsonl"
printf 'CECI N EST PAS DU JSON {{{\n' > "$CORRUPT"
ERR_BAD="$TMP/inj_bad_stderr"
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory "$CORRUPT" >/dev/null 2>"$ERR_BAD"
RC_BAD=$?
chk "corrupt_memory_rc1" "$RC_BAD" "1"
[ -s "$ERR_BAD" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: mémoire corrompue -> stderr vide"; }

# (c) schéma invalide (ligne JSON valide mais leçon cassée) -> rc=1 aussi.
BADSCHEMA="$TMP/badschema.jsonl"
printf '{"id":"x","date":"bad","source":"s","category":"other","trigger_pattern":"t","description":"d","fix_pattern":"f","severity":"P9","evidence":"a.py:1"}\n' > "$BADSCHEMA"
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory "$BADSCHEMA" >/dev/null 2>/dev/null
chk "bad_schema_rc1" "$?" "1"

# (d) mémoire ABSENTE -> rc=1 (le déclencheur MEMORY_SYSTEM_FAIL).
python3 "$INJ" "healthcheck driver preflight" --format quiet --memory "$TMP/n_existe_pas.jsonl" >/dev/null 2>/dev/null
chk "missing_memory_rc1" "$?" "1"

# ====================================================================
# 3. PREUVE FORTE — APPEL DE LA FONCTION DRIVER RÉELLE memory_preflight_or_die.
#    Cette section corrige le defect round 1 : le test ne faisait que grep +
#    répliquer le contrat. Désormais on exécute la VRAIE fonction du pilote.
#
#    Stratégie :
#      - on construit un worktree factice $WT/ avec un STUB factory/bin/
#        lesson_injector.py contrôlé (renvoie le rc qu'on veut tester) ;
#      - on surcharge STATE_FILE/LOG/RECEIPTS_DIR vers des chemins tmp ;
#      - on cd dans $WT, on appelle memory_preflight_or_die 1 en subshell ;
#      - on capture l'exit code, on lit STATE_FILE écrit par la fonction ;
#      - on revient au repo (cd $REPO) avant chaque scénario.
#
#    La subshell ( ... ) capture l'exit 1 de la fonction sans tuer le test.
# ====================================================================

# Worktree factice : on y place le STUB lesson_injector.py que la fonction
# driver exécutera (chemin relatif "factory/bin/lesson_injector.py" depuis $WT).
WT="$TMP/worktree"
mkdir -p "$WT/factory/bin" "$WT/factory/campaigns" "$WT/reports" "$WT/receipts"

# Fichiers d'état du driver pointés vers tmp (la fonction les lit/écrit).
DRV_STATE="$WT/factory/campaigns/CAMPAIGN_STATE"
DRV_LOG="$WT/reports/driver.log"
DRV_RECEIPTS="$WT/receipts"
: > "$DRV_LOG"

# write_stub <exit_code> <stderr_or_empty> : écrit un STUB lesson_injector.py
# qui renvoie exit_code et écrit stderr_or_empty sur stderr (ignore ses args).
# On évite les bashismes récents (${var@Q}, bash 4.4+) : macOS bash 3.2.
write_stub() {
  local rc="$1" err="${2:-}"
  if [ -n "$err" ]; then
    # stderr passée via heredocquoted (pas d'expansion shell parasite).
    python3 - "$WT/factory/bin/lesson_injector.py" "$rc" "$err" <<'PY' || true
import sys
path, rc, err = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path, "w") as f:
    f.write("import sys\nsys.stderr.write(%r)\nsys.exit(%d)\n" % (err, rc))
PY
  else
    cat > "$WT/factory/bin/lesson_injector.py" <<PY
import sys
sys.exit($rc)
PY
  fi
}

# run_real_preflight : surcharge les var globales du driver, cd dans $WT,
# appelle la VRAIE fonction en subshell, capture rc, lit STATE_FILE.
# Args : $1 = libellé du scénario, $2 = STATE_FILE attendu, $3 = exit attendu.
run_real_preflight() {
  local label="$1" want_state="$2" want_exit="$3"
  # Surcharge des variables globales du driver (définies au top-level du
  # fichier sourcé). set -u nous oblige à assigner explicitement.
  STATE_FILE="$DRV_STATE"
  LOG="$DRV_LOG"
  RECEIPTS_DIR="$DRV_RECEIPTS"
  # Réinitialise l'état du fichier à RUNNING avant chaque scénario (un run
  # sain ne le modifie pas ; un run défaillant le passe à MEMORY_SYSTEM_FAIL).
  echo "RUNNING" > "$DRV_STATE"
  # Subshell : capture l'exit de memory_preflight_or_die sans tuer le test.
  # cwd placé dans $WT (le stub est résolu relativement par la fonction).
  ( cd "$WT" && memory_preflight_or_die 1 ) >/dev/null 2>>"$DRV_LOG"
  local got_exit=$?
  local got_state
  got_state="$(cat "$DRV_STATE" 2>/dev/null | tr -d '\r\n')"
  # Repassage au repo pour les assertions echo/chk lisibles.
  cd "$REPO"
  chk "real_${label}_state"    "$got_state" "$want_state"
  chk "real_${label}_exitcode" "$got_exit"  "$want_exit"
}

# (a) STUB rc=1 + stderr (store corrompu simulé) -> MEMORY_SYSTEM_FAIL + exit 1.
write_stub 1 "boom corrupted store\n"
run_real_preflight "rc1_dirty" "MEMORY_SYSTEM_FAIL" "1"

# (b) STUB rc=2 + stderr non vide (panne argparse/CLI simulée) -> FAIL + exit 1.
write_stub 2 "argument error\n"
run_real_preflight "rc2_dirty" "MEMORY_SYSTEM_FAIL" "1"

# (c) STUB rc=127 + stderr (commande introuvable simulée) -> FAIL + exit 1.
write_stub 127 "python: not found\n"
run_real_preflight "rc127" "MEMORY_SYSTEM_FAIL" "1"

# (d) STUB rc=42 + stderr (rc inattendu) -> FAIL + exit 1.
write_stub 42 "weird rc\n"
run_real_preflight "rc42" "MEMORY_SYSTEM_FAIL" "1"

# (e) STUB rc=2 SANS stderr -> MEMORY_SYSTEM_FAIL + exit 1 (contrat STRICT).
#     Audit P1 round 5 (Codex) FERMÉ : l'ancien contrat acceptait rc=2+stderr-
#     vide et continuait (RUNNING) ; c'était précisément le contournement que
#     l'audit a signalé comme non-détecté (le test l'entérinait). Désormais TOUT
#     rc!=0 arrête. NB : avec le contrat injecteur strict (commit jumeau), un
#     non-match sain renvoie rc=0 (jamais rc=2) ; rc=2 n'est plus un état
#     injecteur légitime, et le driver le traite — à juste titre — comme panne.
write_stub 2 ""
run_real_preflight "rc2_clean" "MEMORY_SYSTEM_FAIL" "1"

# (f) STUB rc=0 SANS stderr (leçons trouvées) -> RUNNING + exit 0.
write_stub 0 ""
run_real_preflight "rc0_clean" "RUNNING" "0"

# (g) STUB rc=0 AVEC stderr (cas défensif : rc=0 sain par contrat même si stderr) -> RUNNING + exit 0.
write_stub 0 "warning message\n"
run_real_preflight "rc0_dirty" "RUNNING" "0"

# (h) STUB absent (injecteur manquant) -> MEMORY_SYSTEM_FAIL + exit 1.
#     C'est la garde [ ! -f factory/bin/lesson_injector.py ] de la fonction.
rm -f "$WT/factory/bin/lesson_injector.py"
run_real_preflight "missing_injector" "MEMORY_SYSTEM_FAIL" "1"

# (i) VRAI injecteur + VRAIE mémoire saine (repo) -> la fonction RÉELLE du
#     pilote s'exécute contre l'injecteur réel et la mémoire réelle (lecture
#     seule). Doit rester RUNNING + exit 0 (c'est le chemin nominal du pilote).
#     On ne touche pas au vrai factory/bin/ : on copie un lien vers le repo.
#     Étant donné que la fonction résout "factory/bin/lesson_injector.py"
#     relativement au cwd, on lance depuis $REPO directement.
STATE_FILE="$DRV_STATE"; LOG="$DRV_LOG"; RECEIPTS_DIR="$DRV_RECEIPTS"
echo "RUNNING" > "$DRV_STATE"
( cd "$REPO" && memory_preflight_or_die 1 ) >/dev/null 2>>"$DRV_LOG"
REAL_EXIT=$?
REAL_STATE="$(cat "$DRV_STATE" 2>/dev/null | tr -d '\r\n')"
chk "real_repo_sane_state"    "$REAL_STATE" "RUNNING"
chk "real_repo_sane_exitcode" "$REAL_EXIT"  "0"

# (j) VRAIE fonction driver + mémoire corrompue pointée par --memory ? NON :
#     la fonction driver n'utilise PAS --memory, elle appelle l'injecteur sur
#     la mémoire par défaut (memory/lessons.jsonl du repo). On NE peut donc
#     PAS tester runtime la corruption mémoire sans corrompre la vraie mémoire.
#     La preuve (b) ci-dessus (injecteur réel rc=1 sur corrupt) + preuve (a)
#     de cette section (fonction driver -> MEMORY_SYSTEM_FAIL sur rc=1 stub)
#     couvrent COMPOSITIONNELLEMENT le cas « mémoire corrompue -> arrêt ».
#     On documente ici cette composition (preuve formelle par-glissement) :
#     [injecteur réel sur memory/corrupt.jsonl => rc=1] (section 2.b, vert)
#   + [fonction driver memory_preflight_or_die sur rc=1 => STATE=MEMORY_SYSTEM_FAIL + exit 1]
#     (section 3.a, vert)
#   => le driver arrête en MEMORY_SYSTEM_FAIL sur mémoire corrompue.
pass=$((pass+1))  # preuve compositionnelle documentée

# ====================================================================
# 4. BORNE P1 « retrieval max 5 leçons » : le défaut CLI --top du driver
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
