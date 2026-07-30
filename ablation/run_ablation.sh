#!/usr/bin/env bash
# Exécute RÉELLEMENT la mesure d'ablation A/B (Run 4 §4) et APPEND
# automatiquement un bloc daté à ablation/ABLATION_RUN_LOG.txt, puis
# rafraîchit ablation/arm_{a,b}_measurements.json.
#
# Pourquoi ce script existe (P0 finding 5 + contre-audit Codex P1 #1) :
# le rapport reports/RUN4_ABLATION_AB.md admettait qu'AUCUN script
# n'écrivait le journal et que son contenu était recopié manuellement —
# il ne pouvait donc PAS établir que les chiffres avaient été EXÉCUTÉS,
# seulement qu'ils étaient reproductibles. Ce script prouve l'exécution :
# chaque appel ré-exécute le checker déterministe sur les deux bras et
# consigne la sortie datée (UTC + hash HEAD du repo) dans le journal.
#
# HONNÊTETÉ (limite V1 assumée, cohérente avec reports/RUN4_ABLATION_AB.md
# §8) : le journal reste APPEND-ONLY PAR CONVENTION D'ÉCRITURE (ce script
# n'utilise que '>>', jamais '>' ni truncate). Il n'est PAS tamper-evident
# et n'est PAS scellé cryptographiquement : le hash HEAD consigné est un
# repère de REPRODUCTIBILITÉ (quel commit a produit la mesure), PAS une
# garantie d'intégrité. AUCUN chaînage cryptographique n'est construit
# (hors périmètre stdlib/honnête de Run 4, explicitement refusé par le
# master order P0 finding 5).
#
# Usage : bash ablation/run_ablation.sh
# Stdlib uniquement (bash + python3). Aucune dépendance externe (règle 1).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$REPO/factory/bin/ablation_checker.py"
ARM_A="$REPO/ablation/arm_a_lock_manager.py"
ARM_B="$REPO/ablation/arm_b_lock_manager.py"
# Sorties surchargeables par env (pour tests/test_ablation_runner.py : permet
# de ré-exécuter le script SANS polluer le journal/JSON commités). Défaut =
# chemins commités du repo.
LOG="${RUN_ABLATION_LOG:-$REPO/ablation/ABLATION_RUN_LOG.txt}"
JSON_A="${RUN_ABLATION_JSON_A:-$REPO/ablation/arm_a_measurements.json}"
JSON_B="${RUN_ABLATION_JSON_B:-$REPO/ablation/arm_b_measurements.json}"

for f in "$CHECKER" "$ARM_A" "$ARM_B"; do
  if [ ! -f "$f" ]; then
    echo "run_ablation: fichier manquant : $f" >&2
    exit 1
  fi
done

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(uname -srm 2>/dev/null || echo unknown)"
PY_VER="$(python3 -V 2>&1 || echo python?)"
HEAD="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo NO-GIT)"

# Chemins RELATIFS au repo pour le checker : l'evidence consignée reste
# portable (ex: 'ablation/arm_a_lock_manager.py:19 ...') et identique à la
# commande de reproduction documentée dans reports/RUN4_ABLATION_AB.md.
cd "$REPO" || { echo "run_ablation: REPO $REPO inaccessible" >&2; exit 1; }
OUT_A="$(python3 factory/bin/ablation_checker.py ablation/arm_a_lock_manager.py --json 2>/dev/null)" || {
  echo "run_ablation: échec checker bras A (rc=$?)" >&2; exit 1; }
OUT_B="$(python3 factory/bin/ablation_checker.py ablation/arm_b_lock_manager.py --json 2>/dev/null)" || {
  echo "run_ablation: échec checker bras B (rc=$?)" >&2; exit 1; }

# Rafraîchit les JSON archivés (mesure courante, écrasement légitime — ce
# ne sont pas des traces d'exécution, mais les derniers chiffres mesurés ;
# la trace horodatée, elle, vit dans ABLATION_RUN_LOG.txt en append-only).
printf '%s\n' "$OUT_A" > "$JSON_A"
printf '%s\n' "$OUT_B" > "$JSON_B"

# Résumé chiffré (p1/total/catégories) extrait du JSON par python3 stdlib.
read -r TA PA CA TB PB CB <<EOF2
$(python3 - "$JSON_A" "$JSON_B" <<'PY'
import json, sys
def s(p):
    d = json.load(open(p))
    st = d["stats"]
    return st["total_defects"], st["p1_defects"], st["distinct_categories_with_defect"]
a, b = s(sys.argv[1]), s(sys.argv[2])
print(*a, *b)
PY
)
EOF2

# Append-only (convention d'écriture) : on construit le bloc en mémoire
# puis on l'append en une seule redirection '>>'.
{
  printf '\n===== RUN %s =====\n' "$TS"
  printf '# Execution automatique via ablation/run_ablation.sh\n'
  printf '# Repo HEAD: %s\n' "$HEAD"
  printf '# Hote: %s\n' "$HOST"
  printf '# Python: %s\n' "$PY_VER"
  printf -- '--- python3 factory/bin/ablation_checker.py ablation/arm_a_lock_manager.py --json ---\n'
  printf '%s\n' "$OUT_A"
  printf -- '--- python3 factory/bin/ablation_checker.py ablation/arm_b_lock_manager.py --json ---\n'
  printf '%s\n' "$OUT_B"
  printf -- '--- stats summary ---\n'
  printf 'BRAS A (sans memoire): total_defects=%s p1_defects=%s categories=%s\n' "$TA" "$PA" "$CA"
  printf 'BRAS B (avec memoire): total_defects=%s p1_defects=%s categories=%s\n' "$TB" "$PB" "$CB"
  if [ "$PB" -lt "$PA" ] && [ "$TB" -lt "$TA" ]; then
    printf 'VERDICT: bras B meilleur (p1 %s->%s, total %s->%s)\n' "$PA" "$PB" "$TA" "$TB"
  else
    printf 'VERDICT: pas damelioration (p1 %s->%s, total %s->%s)\n' "$PA" "$PB" "$TA" "$TB"
  fi
} >> "$LOG"

echo "run_ablation: mesure executee et journal ajoutee (RUN $TS, HEAD ${HEAD:0:12})."
echo "  BRAS A: total=$TA p1=$PA  |  BRAS B: total=$TB p1=$PB"
exit 0
