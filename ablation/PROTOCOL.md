# PROTOCOLE D'ABLATION A/B — Run 4 §4 (FIGÉ AVANT EXÉCUTION)

> Master order Run 4 §4 : « Protocole à figer AVANT l'exécution (même
> discipline que M5 §16) ». Ce fichier est écrit et commité AVANT la
> production des deux bras (A sans mémoire, B avec mémoire). Il ne sera
> plus modifié après le commit de figage. Toute déviation sera consignée
> dans `reports/RUN4_ABLATION_AB.md` § « Déviations ».

## 1. TÂCHE SOUMISE AUX DEUX BRAS

Construction d'un mini-module `lock_manager.py` (verrou fichier +
sécurité fork) à partir de la spec neutre `ablation/TASK_SPEC.md`.
Tâche représentative et non triviale (même famille que le `lock_manager.py`
réel de Run #3 dont les 18 leçons du bootstrap sont extraites).

## 2. DEUX BRAS, UNE SEULE VARIABLE

- **Bras A (sans mémoire)** : le builder reçoit UNIQUEMENT le texte de
  `ablation/TASK_SPEC.md`. Il n'a PAS accès à `memory/lessons.jsonl`,
  ni aux `fix_pattern` des leçons. Sortie : `ablation/arm_a_lock_manager.py`.
- **Bras B (avec mémoire)** : le builder reçoit la MÊME spec + le bloc
  de leçons pertinentes produit par `factory/bin/lesson_injector.py`
  appliqué à la spec (sortie textuelle collée en tête du fichier source
  dans un bloc commentaire, pour traçabilité). Sortie :
  `ablation/arm_b_lock_manager.py`.

**Variable unique** : la présence ou non du bloc de leçons. Tout le reste
(spec, builder, environnement, durée) identique.

## 3. MÉTHODE DE MESURE — BUG DETECTOR DÉTERMINISTE

`factory/bin/ablation_checker.py` (stdlib uniquement) scanne chaque
artefact produit à la recherche des **anti-patterns concrets** couverts
par les leçons du bootstrap. Chaque anti-pattern est défini par une
règle déterministe (regex sur le source + absence/présence de tokens),
PAS par un jugement subjectif.

Pour chaque anti-pattern détecté, le checker enregistre :
- `lesson_id` (la leçon du bootstrap qui couvre ce défaut),
- `category` (concurrency / data-validation / resource-leak / ...),
- `severity` (P1/P2/P3),
- `evidence` (extrait du source + ligne),
- `status` : `present` (le défaut est là) | `absent` (correctement évité).

## 4. MÉTRIQUES OBJECTIVES (chiffres réels, pas inventés)

Pour chaque bras, le checker produit :
- `total_defects` : nombre d'anti-patterns `present` ;
- `distinct_categories_with_defect` : nombre de catégories distinctes
  touchées (concurrency, data-validation, resource-leak) ;
- `p1_defects` : nombre de défauts `present` de sévérité P1 ;
- `covered_lessons_avoided` : nombre de leçons du bootstrap dont le
  défaut associé est `absent` (i.e. correctement évité).

## 5. CRITÈRE DE VERDICT (honnête, figé à l'avance)

Le bras B est déclaré **meilleur** si, sur les métriques objectives :
- `p1_defects(B) < p1_defects(A)` ET
- `total_defects(B) < total_defects(A)`.

Sinon : verdict négatif honnête (la mémoire n'aide pas sur cette tâche,
on le dit clairement — même doctrine que le FAIL M5).

## 6. LIMITES AFFICHÉES (NON VÉRIFIÉ — transparence règle 4)

- **Single-agent** : en exécution headless autonome, le même agent GLM
  produit les deux bras. Le bras A ne peut pas être une amnésie parfaite
  (l'agent a extrait les leçons plus tôt dans le run). L'effet mesuré est
  donc un **minorant conservateur** : si même le même agent s'améliore
  quand on lui réinjecte les leçons sous les yeux, c'est un signal réel
  (faible mais honnête) ; si l'effet est nul malgré l'injection, c'est
  un échec honnête du mécanisme.
- **Detector statique** : le checker détecte les anti-patterns par
  scan de source, pas par exécution. Les défauts d'exécution non
  visibles dans le source (deadlock subtil, perf) ne sont PAS mesurés.
- **Pas de revue de tours** : la métrique « nombre de tours de review
  avant PASS » du master order §4 n'est PAS mesurable ici (pas de boucle
  reviewer en ablation). Remplacée par `p1_defects` + `total_defects`,
  proxies objectifs du même concept (« combien de bugs avant PASS »).

## 7. ORDRE DES OPÉRATIONS (non modifiable)

1. Commit figage protocole (ce fichier + TASK_SPEC.md + ablation_checker.py).
2. Build bras A (sans mémoire). Commit arm_a_lock_manager.py seul.
3. Injection des leçons sur la spec (capture de la sortie injector).
4. Build bras B (avec mémoire). Commit arm_b_lock_manager.py seul.
5. Exécution du checker sur les deux → JSON + Markdown.
6. Rédaction `reports/RUN4_ABLATION_AB.md` avec chiffres réels.
