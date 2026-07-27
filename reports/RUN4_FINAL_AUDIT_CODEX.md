Verdict global : **PAS PRÊT À MERGER**.

J’ai audité `factory/bin/*.py`, `memory/`, `tests/` et les artefacts d’ablation. Aucun fichier n’a été modifié.

### P1

- Le livrable final obligatoire est absent : `reports/RUN4_FINAL_REPORT.md` n’existe pas. `reports/RUN4_ABLATION_AB.md` ne le remplace pas : il manque la synthèse des capacités et leurs statuts exigés. Référence : [MASTER_ORDER_RUN4_MEMORY.md:52](/Users/jocelyngrosjean/factory-run4-memory/MASTER_ORDER_RUN4_MEMORY.md:52).

- La métrique P1 de l’ablation est sémantiquement erronée : la règle L-13 classe tout `LOCK_UN` du fichier comme un défaut “dans l’enfant”, alors que le bras A l’emploie dans `release_lock`, précisément l’opération normale de libération. Le résultat `A: 2 P1` et le delta `2 → 0` ne constituent donc pas une preuve valide de l’effet mémoire. Références : [ablation_checker.py:328](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/ablation_checker.py:328), [arm_a_lock_manager.py:32](/Users/jocelyngrosjean/factory-run4-memory/ablation/arm_a_lock_manager.py:32), [RUN4_ABLATION_AB.md:44](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_ABLATION_AB.md:44).

### P2

- Les écritures de mémoire ne sont ni atomiques ni protégées contre deux processus. Un crash pendant `write_text()` peut tronquer `lessons.jsonl`; deux `--append` concurrents peuvent valider les mêmes IDs puis écrire tous deux, ou intercaler/perdre des données. Références : [bootstrap_lessons.py:443](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/bootstrap_lessons.py:443), [lesson_extractor.py:349](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:349), [lesson_extractor.py:364](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:364), [lesson_extractor.py:433](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:433).

- Plusieurs chemins CLI promis comme contrôlés laissent remonter des exceptions d’E/S ou de décodage : lecture de `--task-file`, lecture de l’entrée de l’extracteur, validation/écriture de la destination. Une permission refusée ou un fichier supprimé entre `is_file()` et `read_text()` produit une traceback. Références : [lesson_injector.py:274](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_injector.py:274), [lesson_injector.py:285](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_injector.py:285), [lesson_extractor.py:408](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:408), [lesson_extractor.py:412](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:412).

- Le schéma annonce `date: ISO8601`, mais ne valide que “chaîne non vide”. Des données telles que `date: n’importe quoi` passent la validation et entrent dans la mémoire. Références : [lesson_schema.py:45](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_schema.py:45), [lesson_schema.py:78](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_schema.py:78), [MASTER_ORDER_RUN4_MEMORY.md:25](/Users/jocelyngrosjean/factory-run4-memory/MASTER_ORDER_RUN4_MEMORY.md:25).

### P3

- `--source-tag` est exposé par l’extracteur mais n’est jamais appliqué ; l’option est trompeuse. Référence : [lesson_extractor.py:402](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:402).

- `rule_L10` est définie deux fois : la première implémentation est du code mort, ce qui augmente le risque de divergence lors d’une maintenance. Références : [ablation_checker.py:249](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/ablation_checker.py:249), [ablation_checker.py:280](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/ablation_checker.py:280).

### Ablation A/B

Le chiffre est bien reproductible comme sortie actuelle du checker : je l’ai ré-exécuté et les sorties correspondent octet pour octet aux archives :

- A : `total_defects=6`, `p1_defects=2`
- B : `total_defects=2`, `p1_defects=0`

Les archives correspondantes sont [arm_a_measurements.json](/Users/jocelyngrosjean/factory-run4-memory/ablation/arm_a_measurements.json) et [arm_b_measurements.json](/Users/jocelyngrosjean/factory-run4-memory/ablation/arm_b_measurements.json). La mémoire contient également 18 leçons JSONL valides et IDs uniques.

Cela prouve que le chiffre n’est pas inventé au sens “sortie actuelle du programme”, mais pas que la conclusion A/B est valide : la règle P1 L-13 gonfle artificiellement le bras A. De plus, le rapport final attendu est absent.

Je n’ai pas pu relancer `pytest` dans ce sandbox strictement lecture seule : pytest ne peut pas créer de répertoire temporaire. Cette limitation ne change pas les constats statiques ci-dessus.
