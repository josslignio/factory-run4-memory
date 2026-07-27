# DECISIONS AUTONOMOUS — Run 4 (Mémoire / Experience Compiler)

Journal des décisions prises en autonomie (sur ambiguïté → option la plus sûre,
réversible, fail-closed, puis CONTINUE — master order §AUTONOMIE TOTALE).

## D-001 — Branche de build `run4/build` (protection de `main`)
- **Contexte** : finding Codex #1 (`run_run4_autonomous.sh:55`) — lancé sur `main`,
  GLM pouvait y committer ; `main` n'était pas garanti `UNCHANGED` (règle 3).
- **Décision** : tous les commits produit vont sur la branche `run4/build`, créée
  à partir du commit bootstrap (`3fe6f09`). `main` reste pointé sur le bootstrap
  pendant tout le run (UNCHANGED). Le pilote vérifie/crée la branche avant
  d'invoquer GLM (voir `run_run4_autonomous.sh`). Aucun push/merge/tag/deploy.
- **Réversible** : oui (branche locale, `main` intacte).

## D-002 — Restriction technique des reviewers (lecture seule)
- **Contexte** : finding Claude #2 — `claude -p --dangerously-skip-permissions`
  sans restriction d'outils ; risque de violation de la règle 2 (séparation
  constructeur/contrôleur) si le reviewer édite des fichiers produit.
- **Décision** : le pilote passe `--allowedTools "Read Grep Glob"` à `claude`
  (reviewer) et `-s read-only` à `codex exec` (reviewer). Le diff du dernier
  commit est calculé par le pilote et injecté dans le prompt du reviewer, qui
  n'a donc besoin d'aucun outil d'écriture ni d'exécution shell. Fail-closed :
  même `--dangerously-skip-permissions` ne peut plus écrire (pas d'outil pour).
- **Réversible** : oui.

## D-003 — Contrat d'état du pilote (cohérence prompt vs lecture)
- **Contexte** : finding Claude #1 — le `BUILD_PROMPT` disait « écris
  `factory/campaigns/CAMPAIGN_STATE=READY_FOR_FINAL_AUDIT` » (syntaxe
  chemin=valeur) alors que le pilote lisait la valeur brute seule.
- **Décision** : double défense. (a) Le `BUILD_PROMPT` dit désormais d'écrire
  **uniquement la valeur** `READY_FOR_FINAL_AUDIT` (sans préfixe) dans le
  fichier. (b) Le lecteur du pilote strippe un éventuel préfixe `CAMPAIGN_STATE=`
  avant la comparaison (`case`). Tolérant à l'erreur, sans matcher un état
  inattendu (fail-closed : valeur inconnue → on continue le build).
- **Réversible** : oui.

## D-004 — Audit final : porte P1 avant WAITING_HUMAN_BOSS_GO
- **Contexte** : finding Codex #2 — le pilote passait à `WAITING_HUMAN_BOSS_GO`
  même si l'audit final relevait un P1/High.
- **Décision** : après les deux audits, le pilote scanne leur verdict. Si l'un
  contient `PAS PRET`/`P1`/`High`, les findings sont recopiés dans les fichiers
  de review de tranche et `STATE=RUNNING` (GLM les corrigera au prochain tour),
  dans la limite de `MAX_AUDIT_REPAIR=2` rounds ; au-delà → `FAIL`.
- **Réversible** : oui.

## D-005 — Backoff infra (max 3 retries 30/120/300s)
- **Contexte** : finding Codex #3 — échecs infra ignorés puis jusqu'à 300
  relances immédiates (viol de la règle 6).
- **Décision** : compteurs d'échecs `opencode`/reviewers ; backoff
  `[30,120,300]s` ; après 3 échecs consécutifs → `STATE=WAITING_INFRA`, arrêt.
- **Réversible** : oui.

## D-006 — Source des données de bootstrap (§1)
- **Contexte** : `~/factory-run3-lab` a un working tree vide (HEAD = `.gitkeep`)
  mais une branche `fix-lock-flock-checkpoint-sha256` contient le produit réel
  de Run #3 (`worker.py`, `lock_manager.py`, `anti_loop.py`, 3 tests,
  `RUN3_REPORT.md`).
- **Décision** : les leçons bootstrap de `memory/lessons.jsonl` sont extraites
  de ces fichiers à leur état final sur cette branche. Les `fichier:ligne` du
  champ `evidence` pointent vers `factory-run3-lab@fix-lock-flock-checkpoint-sha256:
  <file>:<line>` (état final vérifié), complétés du nom+ligne du test qui prouve
  le défaut ET le fix (sorties réelles collées dans `RUN3_REPORT.md`).
