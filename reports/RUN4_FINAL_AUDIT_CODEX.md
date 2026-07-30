PHASE_P0_FAIL

### P1

- Changement P1 introduit avant checkpoint : le pilote implémente déjà les receipts et la promotion automatique P0→P1, en contradiction directe avec le périmètre P0-only. [run_run4_autonomous.sh](/Users/jocelyngrosjean/factory-run4-memory/run_run4_autonomous.sh:52), [run_run4_autonomous.sh](/Users/jocelyngrosjean/factory-run4-memory/run_run4_autonomous.sh:313), [run_run4_autonomous.sh](/Users/jocelyngrosjean/factory-run4-memory/run_run4_autonomous.sh:391), [run_run4_autonomous.sh](/Users/jocelyngrosjean/factory-run4-memory/run_run4_autonomous.sh:405)

- Une autre capacité explicitement P1 est déjà active avant le checkpoint : préflight d’injection fail-closed et état `MEMORY_SYSTEM_FAIL`. [run_run4_autonomous.sh](/Users/jocelyngrosjean/factory-run4-memory/run_run4_autonomous.sh:437)

- Le chiffre A/B n’est pas prouvé comme issu d’une exécution réelle du code actuellement audité : le seul journal est une recopie manuelle, non scellée, sans script producteur ; le rapport l’admet lui-même. Le dernier bloc est rattaché au commit `db8fcc7`, alors que le code courant a continué d’évoluer. [reports/RUN4_ABLATION_AB.md](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_ABLATION_AB.md:172), [reports/RUN4_ABLATION_AB.md](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_ABLATION_AB.md:190), [ablation/ABLATION_RUN_LOG.txt](/Users/jocelyngrosjean/factory-run4-memory/ablation/ABLATION_RUN_LOG.txt:186)

### P2

- La validation prétend vérifier une date ISO-8601, mais le regex accepte des dates calendaires impossibles (`2026-99-99`, `2026-02-31`, heure `29:99`). Cela laisse entrer des données invalides dans `memory/lessons.jsonl`. [lesson_schema.py](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_schema.py:66), [lesson_schema.py](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_schema.py:107)

- Un `lessons.jsonl` non UTF-8 produit un `UnicodeDecodeError` non capturé dans l’injecteur, contrairement à son contrat d’erreur contrôlée. [lesson_schema.py](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_schema.py:127), [lesson_injector.py](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_injector.py:81)

### P3

- Le rapport final présente un bilan de tests obsolète (`92 pytest`, `13/13 bash`) alors que le journal de décision revendique ensuite `133 pytest`, `66/66 bash`. Un rapport final ne doit pas conserver une preuve de test contradictoire. [RUN4_FINAL_REPORT.md](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_FINAL_REPORT.md:55), [DECISIONS_AUTONOMOUS.md](/Users/jocelyngrosjean/factory-run4-memory/DECISIONS_AUTONOMOUS.md:186)

Les correctifs P0 1, 2, 3, 4 et 6 sont bien implémentés avec tests ciblés : source-tag cohérent, bloc vide refusé, sous-processus concurrents bootstrap, mutants FD exécutés sous faux OS/fcntl, et garde de transition appelée par le pilote. Toutefois le passage de phase P1 déjà codé et l’absence de preuve d’exécution A/B liée au code courant interdisent le PASS.
