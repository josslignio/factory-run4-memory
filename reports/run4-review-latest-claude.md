18 leçons confirmées, 12 tests verts confirmés. Le commit lui-même (une seule ligne dans `CAMPAIGN_STATE`) est cohérent avec les états valides définis au master order (§AUTONOMIE : RUNNING/WAITING_INFRA/FAIL/WAITING_HUMAN_BOSS_GO). Aucune anomalie sur cette tranche.

PASS

(Rien à signaler : diff = une seule ligne `RUNNING` ajoutée à `factory/campaigns/CAMPAIGN_STATE`, état valide au regard du master order. Les chiffres invoqués dans le message de commit — 18 leçons, 12 tests verts — sont vérifiés réels : `memory/lessons.jsonl` contient bien 18 lignes et `pytest tests/test_lessons_bootstrap.py` passe 12/12. Aucune donnée inventée, aucune violation des interdits absolus détectée dans cette tranche.)
