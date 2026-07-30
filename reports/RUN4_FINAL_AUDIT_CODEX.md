PHASE_P0_FAIL

P1

- La preuve exigée que l’ablation est issue d’une exécution réelle n’est pas vérifiable : le rapport affirme « chiffres réels » et « aucun chiffre inventé », mais admet que le journal est recopié manuellement, sans écriture automatique ni intégrité. Les JSON archivés ne sont donc que des snapshots non authentifiables. [reports/RUN4_ABLATION_AB.md](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_ABLATION_AB.md:9), [reports/RUN4_ABLATION_AB.md](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_ABLATION_AB.md:187), [reports/RUN4_FINAL_REPORT.md](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_FINAL_REPORT.md:31)

P2

- Le bilan de tests final est périmé et contredit les preuves ultérieures : il annonce 92 pytest et 13 checks bash, tandis que la décision finale revendique 133 pytest et 66/66 bash. Une preuve de clôture ne peut pas conserver deux états incompatibles. [reports/RUN4_FINAL_REPORT.md](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_FINAL_REPORT.md:55), [DECISIONS_AUTONOMOUS.md](/Users/jocelyngrosjean/factory-run4-memory/DECISIONS_AUTONOMOUS.md:186)

Les cinq autres points P0 sont correctement implémentés et couverts par les tests ciblés : source-tag/evidence, bloc vide, concurrence bootstrap multiprocessus, crédit FD comportemental avec mutants, et garde de transitions fail-closed. Aucun `run_gate.py`, outil de promotion, gate receipt ou promotion automatique n’est présent ; seules les consignes P1 et le mécanisme de checkpoint prévu sont dans le pilote.
