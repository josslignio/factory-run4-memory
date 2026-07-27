PAS PRET

### P1

- `factory/bin/lesson_extractor.py:468-480` — `--out` n’est pas sérialisé. Deux extracteurs concurrents peuvent tous deux valider l’absence de collision, écrire le même fichier temporaire fixe (`.jsonl.tmp`) et faire un `os.replace`; un résultat peut écraser silencieusement l’autre. Perte de données possible.

- `reports/RUN4_ABLATION_AB.md:73-77` — le rapport final se contredit : le tableau corrigé annonce A=5 défauts/1 P1, mais l’analyse affirme encore A=6 défauts/2 P1. Les JSON archivés confirment bien 5/1 et 2/0, mais ne constituent pas une trace d’exécution horodatée/non modifiable. Avec les outils lecture seule, je peux confirmer la cohérence statique des artefacts, pas prouver qu’ils résultent d’une exécution réelle. L’exigence de traçabilité de l’ablation n’est donc pas satisfaite.

### P2

- `factory/bin/lesson_extractor.py:470,480,487,497` — les erreurs de destination ne sont pas capturées : JSONL existant corrompu, répertoire à la place du fichier, permission refusée, disque plein, ou collision détectée sous le verrou provoquent un traceback au lieu d’un `rc=1` contrôlé.

- `factory/bin/lesson_extractor.py:449-451` — `--source-tag` remplace `source` après validation sans reconstruire `evidence` ni revalider. Un tag blanc produit une leçon invalide; un tag différent rend `source` et le préfixe de preuve contradictoires.

- `factory/bin/lesson_schema.py:66-68,107-110` — la « validation ISO8601 » n’est qu’une regex : elle accepte des dates/heures inexistantes (`2026-99-99`, `2026-02-31T29:99`). Cela contredit la validation stricte annoncée.

- `factory/bin/ablation_checker.py:122-126,286-291,343-346` — plusieurs règles P1 concluent à tort qu’un défaut est absent sur simple présence de token. Un `flock` uniquement dans `release_lock`, un `register_at_fork(after_in_child=noop)`, ou un hook enfant ne faisant ni `close` ni `clear`, sont tous crédités comme sûrs. Les tests ne couvrent pas ces faux négatifs (`tests/test_ablation_checker.py:198-256`). La métrique est correcte pour les deux sources actuelles après lecture, mais le détecteur ne justifie pas l’affirmation générale de « défauts objectivement éliminés ».

- `reports/RUN4_ABLATION_AB.md:6,101-102` — annonce « 15/15 OK », alors que `tests/test_ablation_checker.py` contient 17 tests. La documentation d’audit est stale.

### P3

- `factory/bin/bootstrap_lessons.py:445-452,479-480` — fichier temporaire fixe et absence de verrou : deux bootstrap concurrents peuvent se gêner; une erreur d’E/S laisse aussi un traceback et potentiellement un `.tmp`.

- `factory/bin/ablation_checker.py:385-387` — lecture UTF-8 non protégée; `UnicodeDecodeError`/erreur d’E/S contredit le contrat « rc=0 toujours ».

- `factory/bin/lesson_schema.py:127-136` — une erreur de validation de schéma ne reçoit pas le numéro de ligne JSONL, ce qui complique la correction d’une mémoire volumineuse.

Les nombres actuellement archivés sont cohérents entre eux : A=5 / 1 P1 et B=2 / 0 P1. Ils doivent toutefois être ré-exécutés, avec sortie datée conservée, et le rapport contradictoire doit être corrigé avant merge.
