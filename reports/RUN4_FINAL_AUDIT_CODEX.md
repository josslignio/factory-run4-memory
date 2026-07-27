PAS PRET

Le résultat A/B est bien rattaché à une exécution réelle : la transcript du driver montre l’exécution du checker et produit A=5/P1=1, B=2/P1=0 ([reports/run4-driver.log:37620](/Users/jocelyngrosjean/factory-run4-memory/reports/run4-driver.log:37620)); ces valeurs correspondent aux archives ([ablation/arm_a_measurements.json:70](/Users/jocelyngrosjean/factory-run4-memory/ablation/arm_a_measurements.json:70), [ablation/arm_b_measurements.json:70](/Users/jocelyngrosjean/factory-run4-memory/ablation/arm_b_measurements.json:70)) et au rapport final ([reports/RUN4_FINAL_REPORT.md:36](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_FINAL_REPORT.md:36)). Ce n’est toutefois pas une preuve append-only : la création utilise une redirection écrasante `>` ([reports/run4-driver.log:37660](/Users/jocelyngrosjean/factory-run4-memory/reports/run4-driver.log:37660)).

P1

- Le checker peut déclarer à tort la fork-safety P1 correcte dès qu’il voit `os.register_at_fork(`, sans vérifier un callback `after_in_child`, ni qu’il ferme les FDs et vide le cache. Un hook no-op donne donc P1=0 malgré le défaut. C’est central à la métrique A/B. [factory/bin/ablation_checker.py:283](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/ablation_checker.py:283), [factory/bin/ablation_checker.py:286](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/ablation_checker.py:286), [tests/test_ablation_checker.py:223](/Users/jocelyngrosjean/factory-run4-memory/tests/test_ablation_checker.py:223)

P2

- `bootstrap_lessons.write_jsonl()` emploie un `.tmp` fixe, sans verrou. Deux bootstraps concurrents sur la même destination peuvent s’écraser, échouer ou publier un contenu inattendu. [factory/bin/bootstrap_lessons.py:445](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/bootstrap_lessons.py:445), [factory/bin/bootstrap_lessons.py:447](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/bootstrap_lessons.py:447), [factory/bin/bootstrap_lessons.py:452](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/bootstrap_lessons.py:452)

- Les erreurs d’écriture du bootstrap ne sont pas converties en erreur CLI contrôlée : `main()` appelle `write_jsonl()` sans `try/except`, donc disque plein, permission ou erreur de remplacement produisent une traceback. [factory/bin/bootstrap_lessons.py:479](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/bootstrap_lessons.py:479)

- `--source-tag` modifie `source` après validation, sans revalider ni reconstruire `evidence`. Un tag blanc produit une leçon invalide ; un tag non vide rend `source` contradictoire avec le préfixe de preuve conservé. [factory/bin/lesson_extractor.py:302](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:302), [factory/bin/lesson_extractor.py:476](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:476), [factory/bin/lesson_extractor.py:479](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_extractor.py:479)

- La validation ISO-8601 ne valide que la forme : `2026-13-45` ou `2026-02-31T29:99` passent. Le rapport affirme donc à tort que la date est « réellement validée ». [factory/bin/lesson_schema.py:66](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_schema.py:66), [factory/bin/lesson_schema.py:107](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_schema.py:107), [reports/RUN4_FINAL_REPORT.md:13](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_FINAL_REPORT.md:13)

- Les preuves de ligne L-16 sont décalées d’une ligne : le checker trouve `except BlockingIOError` mais publie la ligne précédente (`flock`). Cela casse la traçabilité annoncée des findings. [factory/bin/ablation_checker.py:360](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/ablation_checker.py:360), [factory/bin/ablation_checker.py:368](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/ablation_checker.py:368), [ablation/arm_a_measurements.json:66](/Users/jocelyngrosjean/factory-run4-memory/ablation/arm_a_measurements.json:66)

- L’affirmation « append-only » est fausse : aucun producteur ne protège ou n’append le fichier ; la transcript le crée par écrasement. [reports/RUN4_ABLATION_AB.md:8](/Users/jocelyngrosjean/factory-run4-memory/reports/RUN4_ABLATION_AB.md:8), [reports/run4-driver.log:37660](/Users/jocelyngrosjean/factory-run4-memory/reports/run4-driver.log:37660)

P3

- `--top` et `--min-score` acceptent des valeurs négatives sans validation ; `--top -1` est silencieusement interprété comme illimité, contrairement au contrat qui réserve ce rôle à `0`. [factory/bin/lesson_injector.py:253](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_injector.py:253), [factory/bin/lesson_injector.py:259](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_injector.py:259), [factory/bin/lesson_injector.py:175](/Users/jocelyngrosjean/factory-run4-memory/factory/bin/lesson_injector.py:175)

- Les tests ne couvrent ni la concurrence du bootstrap, ni la validation calendaire, ni `--source-tag`; les défauts ci-dessus peuvent donc repasser malgré la suite annoncée. [tests/test_lessons_bootstrap.py:104](/Users/jocelyngrosjean/factory-run4-memory/tests/test_lessons_bootstrap.py:104), [tests/test_lesson_extractor.py:285](/Users/jocelyngrosjean/factory-run4-memory/tests/test_lesson_extractor.py:285)

Le chiffre A/B est réel et cohérent pour les deux artefacts actuels, mais la robustesse du détecteur P1 et les incohérences de validation/traçabilité empêchent le merge final.
