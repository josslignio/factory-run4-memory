# PRET A MERGER

## Audit final indépendant — Run 4 (Experience Compiler)

Périmètre couvert : `factory/bin/*.py` (lesson_schema, bootstrap_lessons, lesson_extractor, lesson_injector, ablation_checker), `memory/lessons.jsonl`, `tests/` (4 fichiers pytest + `test_driver_helpers.bash`), `ablation/` (arm_a/arm_b, PROTOCOL.md, TASK_SPEC.md, measurements JSON), `reports/RUN4_FINAL_REPORT.md` et `RUN4_ABLATION_AB.md`, `run_run4_autonomous.sh`, `MASTER_ORDER_RUN4_MEMORY.md`, `DECISIONS_AUTONOMOUS.md`. Lecture intégrale des fichiers, pas d'exécution (Read/Grep/Glob uniquement).

### Vérification spécifique demandée : le chiffre d'ablation A/B est-il réel ?

**Oui, confirmé par retraçage manuel ligne à ligne**, pas seulement par confiance dans le rapport :
- J'ai retracé à la main la logique déterministe des 8 règles de `factory/bin/ablation_checker.py` contre le code source réel de `ablation/arm_a_lock_manager.py` et `ablation/arm_b_lock_manager.py` (regex, calcul des numéros de ligne via `_line_of`/`_func_body`/offset docstring), et j'obtiens exactement les mêmes `status`, `evidence` (fichier:ligne + extrait de code) et `lesson_id` que ceux archivés dans `ablation/arm_a_measurements.json` et `ablation/arm_b_measurements.json` — y compris les décalages de ligne non triviaux dus au blanchiment des docstrings/commentaires (ex. L-16 : ligne 19 exacte, vérifiée par comptage de newlines).
- Les chiffres cités dans `reports/RUN4_FINAL_REPORT.md:35-36` et `reports/RUN4_ABLATION_AB.md:45-47` (`total_defects` 5→2, `p1_defects` 1→0) correspondent **exactement** aux stats des deux fichiers JSON archivés.
- Recoupement indépendant : `tests/test_ablation_checker.py` contient 17 `def test_`, `test_lesson_injector.py` 32, `test_lessons_bootstrap.py` 12, `test_lesson_extractor.py` 25 → **86 tests** au total, ce qui correspond exactement au « 86 passed » annoncé dans `RUN4_FINAL_REPORT.md:51`.
- La correction de la règle L-13 (le point central du contre-audit Codex précédent) est bien implémentée : `ablation_checker.py:297-346` ne marque `present` que si `LOCK_UN` apparaît **dans le corps du hook `after_in_child`** identifié via `os.register_at_fork(...)`, pas n'importe où dans le fichier — vérifié par lecture directe de la regex et par les tests `test_L13_lock_un_in_release_is_legitimate` / `test_L13_lock_un_in_child_hook_is_defect` (`tests/test_ablation_checker.py:177-183,248-251`).

**Conclusion : le chiffre d'ablation est réel, tracé à une exécution reproductible, pas inventé.**

### P1 — bloquants
Aucun. Les deux P1 des audits précédents (Claude et Codex) sont vérifiés corrigés :
- `reports/RUN4_FINAL_REPORT.md` existe et contient les 4 éléments exigés par `MASTER_ORDER_RUN4_MEMORY.md:53` (nombre de leçons=18, résultat brut A/B, statut par capacité §1-§4, section NON VÉRIFIÉ).
- `run_run4_autonomous.sh:95-105` (`audit_ok()`) n'accepte plus qu'un verdict positif sur la **première ligne uniquement**, et rejette explicitement `"PAS PRET"`/`"PAS PRÊT"` sur cette ligne — reproduit correctement par `tests/test_driver_helpers.bash:45-50` (`audit_ok_rejects_bad`).

### P2

**P2-1 — `factory/bin/lesson_extractor.py:468-502` : le chemin d'écriture destination (`--out`/`--append`) n'attrape aucune exception**
- Le seul `try/except (ExtractionError, LessonError)` de `main()` se referme à la ligne 452, **avant** le bloc « Destination » (lignes 458-506). Les appels `_read_existing_ids()` (470, 487), `_write_jsonl_fresh()` (480) et `_append_jsonl()` (497) ne sont protégés par aucun `try/except` dans `main()`.
- Conséquence concrète 1 : si le fichier destination (`memory/lessons.jsonl` ou tout autre `--append`/`--out`) est corrompu (une ligne JSON invalide, un id dupliqué), `_read_existing_ids` → `load_jsonl` lève `LessonError` — non rattrapée, traceback brut au lieu du `rc=1` propre promis par le module (comparer avec le message d'erreur soigné à la ligne 493 : `"RIEN n'a été écrit (atomicité)"`).
- Conséquence concrète 2, plus significative : `_append_jsonl` (ligne 373-395) fait *exactement ce que le commentaire ligne 374-377 promet* — sérialisation par `fcntl.flock` exclusif, re-vérification des collisions **sous verrou** (ligne 383-388). Mais si cette re-vérification sous verrou détecte une vraie collision concurrente (deux process qui appendent au même instant avec le même `extraction-ts`), elle lève `LessonError` (ligne 386-388) — qui remonte **non rattrapée** jusqu'à `sys.exit(main())` (ligne 512) et produit un traceback Python brut au lieu du message contrôlé. Le mécanisme anti-collision fonctionne (rien n'est écrit à tort), mais le comportement de sortie n'est pas celui documenté.
- Ni `tests/test_lesson_extractor.py::TestAppendIntegration` ni aucun autre test n'exerce ce chemin sous verrou avec collision réelle (seul le pré-check hors-verrou de `main()`, ligne 489-496, est testé) — le gap n'est donc pas couvert par la suite de 86 tests.
- Pas de corruption de données (l'écriture n'a pas lieu avant la levée de l'exception), mais c'est une lacune réelle de « gestion d'erreurs incomplète » sur le chemin critique qui protège `memory/lessons.jsonl`.

### P3

**P3-1 — `factory/bin/bootstrap_lessons.py:479-482` : écriture non protégée**
`write_jsonl(LESSONS, out)` dans `main()` n'est entourée d'aucun `try/except` ; une `OSError` (permission, disque plein pendant `os.fsync`) produit un traceback brut plutôt qu'un `rc=1` contrôlé. Impact limité (script bootstrap one-shot, environnement contrôlé).

**P3-2 — `factory/bin/ablation_checker.py:385-388` (`check_file`) : lecture non protégée contredit le docstring**
`path.read_text(encoding="utf-8")` peut lever `UnicodeDecodeError` non rattrapée, alors que le module s'auto-décrit ligne 27-28 comme « rc=0 toujours (le checker ne « fail » pas ; il mesure) ». Impact nul sur l'ablation actuelle (les deux fichiers arm_a/arm_b sont de l'UTF-8 propre), risque uniquement en cas de réutilisation future sur du code source à l'encodage inattendu.

**P3-3 (rappel, déjà honnêtement documenté, pas un nouveau défaut)** — les règles structurelles `rule_L07`/`rule_L09` du checker restent scope-fragiles en général (matching sur toute assignation `x[k]=` ou tout `\bin\b`/`.get(` du corps de fonction, pas strictement lié au cache du verrou) ; déjà reconnu dans `ablation/PROTOCOL.md:73-75` et l'audit Codex précédent (P3-2). Aucun impact sur les chiffres mesurés ici (vérifié par retraçage manuel ci-dessus).

### Ce qui est solide et vérifié directement
- 18 leçons dans `memory/lessons.jsonl` (compté), toutes conformes au schéma, source traçable `factory-run3-lab@fix-lock-flock-checkpoint-sha256`.
- `rule_L10` n'est plus dupliquée (une seule définition, ligne 249) — le P3 de l'audit Codex précédent est corrigé.
- Séparation constructeur/contrôleur respectée, aucune dépendance externe (stdlib uniquement) dans tous les fichiers `factory/bin/*.py` lus.
- `tests/fixtures/review_sample.txt` correctement labellisée comme fixture synthétique (D-007), pas présentée comme un rapport réel.
- Les fichiers `lesson_injector.py` et `lesson_schema.py` gèrent proprement toutes les erreurs d'E/S/schéma que j'ai pu tracer (répertoire au lieu de fichier, mémoire illisible, date non-ISO8601) — aucun gap trouvé dans ces deux modules.

### NON VÉRIFIÉ par cet audit
- Pas d'exécution réelle de `pytest`/`bash tests/` (outils Read/Grep/Glob uniquement) — la conformité des 86 tests + 13 checks bash au comportement réel du code est déduite par lecture, pas rejouée.
- La collision concurrente réelle sous verrou (P2-1) n'a pas été provoquée avec deux process réels — le gap est démontré par lecture de code (absence de try/except), pas par reproduction en direct.
- `reports/run4-driver.log` non lu intégralement ; `run_run4_autonomous.sh` non rejoué en conditions réelles (appels `opencode`/`claude`/`codex` live).
