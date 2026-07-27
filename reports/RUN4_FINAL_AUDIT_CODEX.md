PAS PRET

Aucun finding P1 identifié, mais les P2 ci-dessous bloquent le merge.

P2

- `factory/bin/lesson_extractor.py:301-323,478-480` — `--source-tag` modifie `source` après construction/validation, sans réécrire `evidence` ni revalider. Une leçon peut donc déclarer `source=run4` tout en traçant `run3:...` dans `evidence`; `--source-tag " "` permet même d’écrire un `source` vide/invalide.

- `factory/bin/lesson_extractor.py:176-183` — un bloc `[FINDING]…[/FINDING]` vide est silencieusement ignoré. Mélangé à des blocs valides, cela supprime un finding sans erreur, contraire au comportement fail-closed annoncé.

- `factory/bin/bootstrap_lessons.py:445-452,479-480` — écriture concurrente non sérialisée : tmp fixe partagé (`.tmp`) sans verrou. Deux bootstraps peuvent se voler le tmp; l’un peut finir en `FileNotFoundError`, non capturé par `main()`. La persistance canonique ne garantit donc ni succès contrôlé ni sérialisation.

- `factory/bin/ablation_checker.py:438-446` — L-16 crédite comme sûr n’importe quel `except OSError`, sans vérifier qu’il ferme réellement le FD. Exemple : `except OSError: return False` fuit le FD mais est compté « absent ». Cela fragilise la métrique A/B, cœur du rapport.

- `reports/RUN4_ABLATION_AB.md:131-150` — la trace est cohérente, mais l’affirmation « append-only/non modifiable » est faussement garantie : aucune commande ou script ne crée/appende le journal. La commande fournie ne fait qu’écrire le JSON sur stdout. Le journal reste un fichier éditable, sans hash des sources/checker ni mécanisme d’intégrité.

P3

- `factory/bin/lesson_schema.py:66-68,107-110` — la regex valide une forme, pas une date ISO-8601 réelle : `2026-99-99`, `2026-02-31`, `2026-01-01T99:99` passent.

- `factory/bin/lesson_injector.py:253-262,313-315` — `--top -1` est accepté et devient implicitement « illimité », alors que seule la valeur `0` est documentée ainsi; `--min-score` négatif n’est pas rejeté.

- `factory/bin/ablation_checker.py:457-460,514` — lecture UTF-8/E/S non protégée après `is_file()`: fichier supprimé, illisible ou non UTF-8 provoque une traceback au lieu d’un rc contrôlé.

Vérification A/B : les chiffres `A=5 / 1 P1`, `B=2 / 0 P1` de `reports/RUN4_FINAL_REPORT.md:36-37` sont cohérents avec le dernier bloc du journal (`ablation/ABLATION_RUN_LOG.txt:186-362`), les JSON archivés et les sources des deux bras. Je ne vois pas d’invention arithmétique. En revanche, la preuve historique d’une exécution réelle n’est pas inviolable : le journal est éditable et sa génération/appending n’est pas automatisée.
