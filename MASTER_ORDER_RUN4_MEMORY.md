# MASTER ORDER RUN 4 — MÉMOIRE (EXPERIENCE COMPILER)
> Ordre d'exécution canonique. À coller dans un nouveau repo dédié `factory-run4-memory`, exécuté en autonomie totale headless (voir `run_run4_autonomous.sh`). Remplace tout ordre précédent sur ce repo.

## OBJECTIF ET NATURE DE LA CAMPAGNE
Construire l'**Experience Compiler** : un système qui capture les leçons tirées des échecs de build/review (bugs trouvés, corrigés, patterns récurrents) sous une forme structurée et réutilisable, puis les réinjecte automatiquement dans les futurs master orders pour éviter de refaire les mêmes classes d'erreurs. Preuve exigée par ablation A/B chiffrée : la mémoire doit démontrer une amélioration mesurable, pas juste exister.

Rien de tout ceci ne remplace un jugement humain — c'est un accélérateur de rappel, pas une automatisation de la décision.

## AUTONOMIE TOTALE — LE RUN NE S'ARRÊTE JAMAIS POUR DEMANDER (non négociable)
NE POSE JAMAIS de question à l'humain. N'utilise JAMAIS d'outil de question/clarification/menu. Sur TOUTE ambiguïté → choisis l'option la plus sûre, réversible, fail-closed, écris-la dans `DECISIONS_AUTONOMOUS.md`, et CONTINUE. Les SEULS arrêts autorisés sont les états machine explicites de `CAMPAIGN_STATE` définis par l'**AUTORITÉ UNIQUE** « MACHINE À ÉTATS » ci-dessous (liste complète des états, transitions légales et budgets `MAX_*_REPAIR`). Aucune autre section n'énumère d'état ni de budget : toute liste ailleurs serait une seconde autorité contradictoire et a été retirée (contre-audit : cette ligne listait jadis un sous-ensemble de 4 états et « 2 repairs », en désaccord avec la liste de 8 états et les budgets exécutés — seul tranche le § MACHINE À ÉTATS).

## RÈGLES ABSOLUES (héritées, non négociables)
1. stdlib Python uniquement. Aucune dépendance externe, aucune clé API payante, coût additionnel strictement nul.
2. Un seul writer actif à la fois. Le provider qui construit ne review jamais son propre travail (séparation constructeur/contrôleur).
3. Aucun `merge`/`push`/`tag`/`deploy` vers `main` sans GO explicite de Jocelyn. `main` reste `UNCHANGED` pendant tout le run.
4. Toute affirmation tracée fichier:ligne (L-049). Chaque rapport finit par une section NON VÉRIFIÉ honnête (L-041) — jamais de chiffre inventé, "non mesuré" sinon.
5. Un finding de review, même mineur, est documenté ; un finding P1/High reproduit est fixé avant de continuer (même doctrine que Run #3).
6. Budget de réparation : `MAX_P0_REPAIR=6`, `MAX_P1_REPAIR=6` par phase, `MAX_INFRA_FAILS=10` retries infra (backoff 30s/120s/300s) — repair redescendu le 30/07 après une dérive de 16+ rounds, tout en conservant la tolérance aux hoquets infra. Autorité UNIQUE détaillée § « MACHINE À ÉTATS » et constantes dans `run_run4_autonomous.sh` : aucune autre valeur ailleurs (sinon contradiction d'autorité). Commit à chaque sous-capacité.
7. INTERDIT : toute commande cleanup/rm large ou récursive.

## 1. SCHÉMA DE LA MÉMOIRE
Créer `memory/lessons.jsonl` (une leçon par ligne, JSON) avec le schéma :
```json
{
  "id": "L-<timestamp>-<seq>",
  "date": "ISO8601",
  "source": "run3-lab | run4-memory | <repo>",
  "category": "concurrency | data-validation | resource-leak | migration-safety | doc-sync | cli-validation | other",
  "trigger_pattern": "mots-clés / signature de code qui rend cette leçon pertinente (ex: 'fcntl.flock', 'checkpoint JSON', 'os.fork')",
  "description": "le défaut observé, en une phrase factuelle",
  "fix_pattern": "le remède générique appliqué, réutilisable",
  "severity": "P1 | P2 | P3",
  "evidence": "fichier:ligne + test qui prouve le défaut ET le fix"
}
```
**Bootstrap réel, pas synthétique** : la toute première tâche consiste à dépouiller les rapports de review réels de Run #3 (fournis en annexe du repo, à copier depuis `factory-run3-lab` en lecture seule) et à en extraire au moins 15 leçons réelles avec preuve fichier:ligne — ce sont des données réelles déjà produites cette nuit, pas des exemples inventés.

## 2. EXTRACTEUR DE LEÇONS
`factory/bin/lesson_extractor.py` : prend un rapport de review (texte structuré finding par finding) en entrée, produit une ou plusieurs entrées `lessons.jsonl` normalisées. Déterministe, pas de LLM dans le chemin d'extraction structurelle (parsing de texte structuré uniquement) — si le format d'entrée nécessite une interprétation sémantique, documenter explicitement où un LLM intervient et pourquoi (L-049).

## 3. RÉCUPÉRATEUR / INJECTEUR DE LEÇONS
`factory/bin/lesson_injector.py` : prend une description de tâche ou un chemin de fichier en entrée, retourne les leçons pertinentes (correspondance par mot-clé/catégorie sur `trigger_pattern` — pas d'embeddings, pas de dépendance ML, stdlib uniquement) formatées en un bloc de texte prêt à coller en tête d'un master order. Test : injecte une tâche connue pour matcher au moins 3 leçons du bootstrap, vérifie que les bonnes leçons remontent et pas d'autres.

## 4. PREUVE PAR ABLATION A/B (le cœur de la preuve du run)
Protocole à figer AVANT l'exécution (même discipline que M5 §16) :
- Choisir une tâche de construction représentative et non triviale (ex: reconstruire un mini-module de verrouillage similaire à `lock_manager.py`, à partir d'une spec neuve, avec un builder GLM frais).
- **Bras A (sans mémoire)** : GLM reçoit uniquement la spec de la tâche, aucune leçon injectée.
- **Bras B (avec mémoire)** : GLM reçoit la même spec + le bloc de leçons pertinentes de l'étape 3.
- Mesurer objectivement pour chaque bras : nombre de tours de review avant PASS propre, nombre de catégories de bugs distinctes trouvées, nombre de bugs appartenant à une catégorie déjà couverte par une leçon existante (ces bugs-là ne devraient PAS apparaître dans le bras B).
- Verdict honnête : si le bras B n'est pas meilleur, le rapport le dit clairement — pas de résultat inventé (même doctrine que le FAIL de M5).

## 5. RAPPORT FINAL
`reports/RUN4_FINAL_REPORT.md` : nombre de leçons dans la base, résultat brut de l'ablation A/B (chiffres réels, pas d'arrondi favorable), statut de chaque capacité (PROUVÉ PAR EXÉCUTION / NON PROUVÉ / BLOQUÉ), section NON VÉRIFIÉ.

## 6. FIN DE CAMPAGNE
`main = UNCHANGED`, aucun push/tag/deploy. État final : `CAMPAIGN_STATE=WAITING_HUMAN_BOSS_GO`. Attends le GO explicite de Jocelyn avant tout merge.

---
*Rappel process (rituel de review, appliqué automatiquement par le driver headless — voir `run_run4_autonomous.sh`) : GLM construit une tranche → commit → Codex review cette tranche (diff uniquement, rapide) → si Codex relève un P1/High reproduit, GLM le fixe avant de continuer → à la toute fin du run, Codex fait un audit exhaustif indépendant de l'intégralité du code produit (pas juste le dernier diff) avant de passer en `WAITING_HUMAN_BOSS_GO`. (Relevé 30/07 Jocelyn : Claude retiré de la boucle de review/audit pour économie de quota — Codex seul, reviewer indépendant en lecture seule.) Ni Claude ni Codex ne construisent jamais — seul GLM écrit du code produit (séparation constructeur/contrôleur stricte, règle 2).*

---

## MACHINE À ÉTATS — AUTORITÉ UNIQUE (mise à jour preflight du 29/07/2026, contre-relecture GPT intégrée)

Cette section est la SEULE autorité des états, phases et transitions du pilote `run_run4_autonomous.sh`. Toute valeur ou transition non listée ici est illégale et doit échouer fail-closed (le pilote ne répare jamais silencieusement un état invalide).

### Fichiers d'état
- `factory/campaigns/CAMPAIGN_STATE` — état du run.
- `factory/campaigns/CAMPAIGN_PHASE` — phase courante : `P0` (réparation des 6 défauts du cœur) ou `P1` (Sharp Core minimal). Aucune autre valeur. Jamais réinitialisée silencieusement.
- `factory/campaigns/PILOT_HEARTBEAT` — JSON écrit toutes les 60 s par une boucle de fond indépendante des appels agents (timestamp, pid, state, phase, iter). Preuve de vie, PAS preuve de réussite.
- `factory/campaigns/PILOT_ITER` — numéro d'itération courant (consommé par le heartbeat).
- `$HOME/.factory-receipts/factory-run4-memory/` — receipts hors du repo : `resume_receipt.json`, `checkpoint_p0/` (checkpoint.json + copie de l'audit Codex + son SHA-256), verrou `driver.lock.d/`. Séparés du worktree et protégés par le séquencement, mais PAS tamper-proof face à un processus du même utilisateur macOS (limite V1 assumée et documentée).

### États autorisés (autorité unique, appliquée par `state_kind` dans `run_run4_autonomous.sh`)
Tout état lu dans `CAMPAIGN_STATE` hors de cette liste est `illegal` : le pilote s'arrête en **fail-closed** (jamais de réparation silencieuse en `RUNNING`). La fonction `state_kind` du pilote est l'implémentation exacte de cette liste (testée par `tests/test_driver_helpers.bash`).
- `RUNNING` → `build` (construction).
- `READY_FOR_FINAL_AUDIT` (transition interne, écrite par le builder en fin de phase) → `audit` (Codex seul — Claude retiré de la boucle 30/07).
- `WAITING_INFRA` → `infra_stop` (arrêt quota/réseau).
- `WAITING_HUMAN_BOSS_GO` (terminal succès, fin de run) ; `WAITING_HUMAN` (terminal : attente humaine générique).
- `FAIL` (terminal échec, après épuisement du budget de repair).
- `DONE` (terminal succès, campagne complète).
- `MEMORY_SYSTEM_FAIL` (terminal : mémoire de leçons invalide ou injecteur en panne — aucun agent n'est appelé dans cet état).

### Transitions légales
- `RUNNING → READY_FOR_FINAL_AUDIT` (builder, fin de phase) → audit simple Codex (Claude retire de la boucle 30/07, tokens exacts en première ligne : `PHASE_P0_PASS`/`PHASE_P0_FAIL` en P0, `PHASE_P1_PASS`/`PHASE_P1_FAIL` en P1).
- Audit P0 PASS (Codex seul) → checkpoint P0 figé (commit, worktree, SHA-256 de l'audit) → `CAMPAIGN_PHASE=P1`, budget de repair réinitialisé, `RUNNING`.
- Audit P1 PASS (Codex seul) → `WAITING_HUMAN_BOSS_GO` → arrêt. La suite (merge) est 100 % humaine.
- Audit non-PASS → repair round (budget : `MAX_P0_REPAIR=6`, `MAX_P1_REPAIR=6` par phase) ; budget épuisé → `FAIL`.
- Audit/review indisponible, vide, au verdict invalide ou illisible → retry infra (`MAX_INFRA_FAILS=10`, backoff 30s/120s/300s) ; budget infra épuisé depuis `READY_FOR_FINAL_AUDIT` → `WAITING_INFRA`.
- `FAIL → RUNNING` : UNIQUEMENT via `RESUME_AFTER_FAIL=1` explicite, avec `resume_receipt.json` écrit (old_state, new_state, phase, commit, timestamp, reason). Reprise phase-aware : phase absente → reprise legacy en P0 (loggée) ; phase P0 → reprise P0 ; phase P1 → reprise P1 SEULEMENT si le checkpoint P0 se re-vérifie (hashes recalculés) ; phase inconnue ou checkpoint invalide → refus.
- Mémoire de leçons : avant chaque itération builder, `lesson_injector.py --format quiet` est exécuté. Contrat strict : rc=0, ou rc=2 avec stderr vide (= mémoire valide, aucune leçon pertinente). Tout autre résultat → `MEMORY_SYSTEM_FAIL`. Note documentée : en V1, les reviewers de tranche reçoivent le diff, pas d'injection de leçons — la garde mémoire couvre le chemin builder.

### Verrou d'exécution
Verrou atomique par `mkdir` (`driver.lock.d/` avec pid + commit), détenu toute la vie du driver, libéré par trap EXIT. C'est la SEULE autorité anti-double-pilote (`pgrep` est un diagnostic non bloquant). Verrou présent avec PID actif → refus. Verrou stale (PID inactif) → refus avec instruction de suppression manuelle, jamais d'auto-nettoyage (risque de PID recyclé).
