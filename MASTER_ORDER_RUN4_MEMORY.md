# MASTER ORDER RUN 4 — MÉMOIRE (EXPERIENCE COMPILER)
> Ordre d'exécution canonique. À coller dans un nouveau repo dédié `factory-run4-memory`, exécuté en autonomie totale headless (voir `run_run4_autonomous.sh`). Remplace tout ordre précédent sur ce repo.

## OBJECTIF ET NATURE DE LA CAMPAGNE
Construire l'**Experience Compiler** : un système qui capture les leçons tirées des échecs de build/review (bugs trouvés, corrigés, patterns récurrents) sous une forme structurée et réutilisable, puis les réinjecte automatiquement dans les futurs master orders pour éviter de refaire les mêmes classes d'erreurs. Preuve exigée par ablation A/B chiffrée : la mémoire doit démontrer une amélioration mesurable, pas juste exister.

Rien de tout ceci ne remplace un jugement humain — c'est un accélérateur de rappel, pas une automatisation de la décision.

## AUTONOMIE TOTALE — LE RUN NE S'ARRÊTE JAMAIS POUR DEMANDER (non négociable)
NE POSE JAMAIS de question à l'humain. N'utilise JAMAIS d'outil de question/clarification/menu. Sur TOUTE ambiguïté → choisis l'option la plus sûre, réversible, fail-closed, écris-la dans `DECISIONS_AUTONOMOUS.md`, et CONTINUE. Les SEULS arrêts autorisés sont des états machine explicites dans `CAMPAIGN_STATE` : `RUNNING`, `WAITING_INFRA` (quota/réseau indisponible), `FAIL` (échec dur après 2 repairs), `WAITING_HUMAN_BOSS_GO` (uniquement en fin de run, mission prouvée ou honnêtement bloquée).

## RÈGLES ABSOLUES (héritées, non négociables)
1. stdlib Python uniquement. Aucune dépendance externe, aucune clé API payante, coût additionnel strictement nul.
2. Un seul writer actif à la fois. Le provider qui construit ne review jamais son propre travail (séparation constructeur/contrôleur).
3. Aucun `merge`/`push`/`tag`/`deploy` vers `main` sans GO explicite de Jocelyn. `main` reste `UNCHANGED` pendant tout le run.
4. Toute affirmation tracée fichier:ligne (L-049). Chaque rapport finit par une section NON VÉRIFIÉ honnête (L-041) — jamais de chiffre inventé, "non mesuré" sinon.
5. Un finding de review, même mineur, est documenté ; un finding P1/High reproduit est fixé avant de continuer (même doctrine que Run #3).
6. Max 2 repairs par capacité. Max 3 retries infra (30s/120s/300s). Commit à chaque sous-capacité.
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
*Rappel process (rituel de review, appliqué automatiquement par le driver headless — voir `run_run4_autonomous.sh`) : GLM construit une tranche → commit → Claude ET Codex review cette tranche EN PARALLÈLE, chacun indépendamment (diff uniquement, rapide) → si l'un des deux relève un P1/High reproduit, GLM le fixe avant de continuer → à la toute fin du run, Claude ET Codex font CHACUN un audit exhaustif indépendant de l'intégralité du code produit (pas juste le dernier diff) avant de passer en `WAITING_HUMAN_BOSS_GO`. Ni Claude ni Codex ne construisent jamais — seul GLM écrit du code produit (séparation constructeur/contrôleur stricte, règle 2).*
