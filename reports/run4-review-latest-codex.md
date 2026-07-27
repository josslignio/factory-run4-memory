FIX_NEEDED

- `reports/run4-review-latest-claude.md:1,5` — affirme à tort que le diff ne contient qu’une ligne `CAMPAIGN_STATE` et des vérifications 18/12 non tracées ; le commit ajoute en réalité 797 lignes. Donnée de review inventée, violation règle 4.
- `reports/run4-review-latest-claude.md:5` et `reports/run4-review-latest-codex.md:1` — rapports sans section finale « NON VÉRIFIÉ », violation absolue règle 4.
- `tests/fixtures/review_sample.txt:4,17-58` — se présente comme rapport « RÉEL » mais référence `fork_pool.py` et `temp_store.py` absents du commit ; findings non traçables/inventés.

## NON VÉRIFIÉ
- Préfixe FIX_NEEDED posé sans rejouer `pytest` depuis mon environnement : les chiffres de tests (25/25, 12/12) ne sont PAS re-vérifiés en direct ici, uniquement déduits du diff et des messages de commit.
- « 797 lignes » : chiffre lu sur le diff du commit `7275939` sans recomptage indépendant ligne par ligne au-delà du `--stat`.
- Absence d'autres P1 non couverts : non mesuré par relecture exhaustive commit-par-commit au-delà des deux derniers.

