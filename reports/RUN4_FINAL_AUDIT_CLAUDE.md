# PAS PRET

## Résumé du verdict

Le code produit (§1-§4 du master order) est globalement solide et l'ablation A/B est **réelle et vérifiée** (détail ci-dessous), mais le **gate de fin de campagne défini par le projet lui-même n'est pas satisfait par l'état actuellement committé du dépôt** — c'est à lui seul suffisant pour bloquer le merge, indépendamment des findings de code. Plusieurs findings P2 réels et non corrigés s'y ajoutent.

## Vérification de l'ablation A/B (exigence explicite de la tâche)

**Verdict : chiffres réels, tracés, reproductibles — pas inventés.**

- `ablation/arm_a_measurements.json`, `ablation/arm_b_measurements.json` et `ablation/ABLATION_RUN_LOG.txt` sont mutuellement cohérents à l'octet près (mêmes 8 findings par bras, mêmes stats : A=5 défauts/1 P1, B=2 défauts/0 P1).
- J'ai **re-dérivé à la main** les 8 règles de `factory/bin/ablation_checker.py` contre le code source réel de `ablation/arm_a_lock_manager.py` et `ablation/arm_b_lock_manager.py` : chaque statut `present`/`absent` et les totaux (5/1 vs 2/0) correspondent exactement à ce que produit la logique actuelle du checker — ce ne sont pas des chiffres copiés/collés arbitrairement.
- `ablation/ABLATION_RUN_LOG.txt:6` cite `Repo HEAD: 285199123058afb...` — ce hash court (`2851991`) correspond à un commit réellement présent dans l'historique de la branche (`2851991 restore executable bit`), preuve supplémentaire que la trace n'a pas été fabriquée hors contexte du dépôt.
- Limite trouvée au passage : la ligne d'`evidence` de la règle `rule_L16` (et le même calcul d'offset dans `rule_L09`/`rule_L13`) est **décalée d'une ligne** (voir P2 ci-dessous) — n'affecte pas les totaux ni le verdict, mais affaiblit la traçabilité fichier:ligne que le projet érige en règle absolue (règle 4).
- Non vérifié par moi (outils lecture seule) : je n'ai pas ré-exécuté `pytest`/le CLI moi-même. J'ai recompté à la main les méthodes de test des 4 fichiers `tests/*.py` (17+26+32+12 = **87**), cohérent avec le « 87 passed » annoncé — mais ce n'est qu'une reconstruction arithmétique, pas une exécution réelle de ma part.

## P1

- **`factory/campaigns/CAMPAIGN_STATE:1`** — la valeur committée est `READY_FOR_FINAL_AUDIT`. Or `MASTER_ORDER_RUN4_MEMORY.md:10` (marqué « non négociable ») énumère explicitement les **seuls** arrêts autorisés : `RUNNING`, `WAITING_INFRA`, `FAIL`, `WAITING_HUMAN_BOSS_GO`. `READY_FOR_FINAL_AUDIT` n'y figure pas, et `MASTER_ORDER_RUN4_MEMORY.md:56` exige explicitement `CAMPAIGN_STATE=WAITING_HUMAN_BOSS_GO` en fin de campagne. Déjà relevé indépendamment par les deux reviewers de tranche (`reports/run4-review-latest-codex.md:1-3` en `FIX_NEEDED`, `reports/run4-review-latest-claude.md` en PASS-avec-réserve) sans être résolu depuis.

- **Gate d'audit final non satisfait par l'état actuel du dépôt** — `run_run4_autonomous.sh:124-147` déclenche les deux audits finaux (Claude + Codex) précisément quand `CAMPAIGN_STATE=READY_FOR_FINAL_AUDIT`, et n'autorise `WAITING_HUMAN_BOSS_GO` que si `audit_ok()` (ligne 95-105 : verdict positif en 1ʳᵉ ligne, ni « PAS PRET » ni « PAS PRÊT ») passe sur LES DEUX fichiers. Or, dans l'état actuel du dépôt : `reports/RUN4_FINAL_AUDIT_CLAUDE.md` est **vide**, et `reports/RUN4_FINAL_AUDIT_CODEX.md:1` commence littéralement par `PAS PRET`, en citant des défauts (`--out` non sérialisé, contradiction du rapport d'ablation) qui sont **déjà corrigés** dans le code actuel — cet audit est donc à la fois négatif ET obsolète vis-à-vis du commit courant. Si le pilote évaluait `audit_ok()` maintenant, il refuserait de passer à `WAITING_HUMAN_BOSS_GO`. Le dépôt n'a donc, à ce jour, jamais atteint l'état terminal que le projet définit lui-même comme prêt à merger.

## P2

- **`factory/bin/lesson_extractor.py:477-480`** — `--source-tag` réécrit `l["source"]` **après** que `build_lesson()`/`validate_lesson()` ait déjà tourné, sans reconstruire `evidence` (qui embarque le `source` d'origine en préfixe, `lesson_extractor.py:302`) ni re-valider. Un tag composé uniquement d'espaces (`--source-tag " "`) est truthy en Python donc appliqué, produisant une leçon avec un `source` vide en pratique qui contourne le contrôle « champ non vide » du schéma ; tout tag non trivial rend `source` et le préfixe tracé dans `evidence` contradictoires. Aucun test ne couvre `--source-tag` (absent de `tests/test_lesson_extractor.py`). C'est exactement le défaut relevé par un round d'audit antérieur (voir `DECISIONS_AUTONOMOUS.md`) et il n'a pas été traité — seul le « jamais appliqué » a été corrigé, pas la cohérence avec `evidence`.

- **`factory/bin/ablation_checker.py:368-369` (`rule_L16`) et le même calcul dans `rule_L09`/`rule_L13`** — le numéro de ligne d'evidence est **décalé d'une ligne** (`code[: code.find("def acquire_lock")].count("\n")` compte les retours à la ligne AVANT la ligne `def`, alors que `body` commence juste APRÈS elle). Confirmé concrètement : `ablation/arm_a_measurements.json:66` et `ablation/arm_b_measurements.json:66` pointent tous deux vers la ligne du `fcntl.flock(...)` alors que le vrai `except BlockingIOError:` matché est la ligne suivante. N'affecte pas le statut present/absent ni les totaux (vérifié par ma retracée manuelle), mais casse la garantie « toute affirmation tracée fichier:ligne » (règle 4) sur cette règle précise. Aucun test n'asserte sur le numéro de ligne exact, d'où le passage inaperçu.

- **`factory/bin/ablation_checker.py:122-126` (`rule_L01`) et `:286-294` (`rule_L12`)** — heuristiques faibles, déjà signalées par un round d'audit Codex antérieur et toujours non corrigées : `rule_L01` marque le défaut TOCTOU « absent » dès qu'un `fcntl.flock(` apparaît N'IMPORTE OÙ dans le fichier, même uniquement dans `release_lock` sans jamais protéger `acquire_lock` ; `rule_L12` marque le défaut fork-safety « absent » dès qu'un `os.register_at_fork(` est présent, même avec un hook no-op qui ne fait ni `close` ni `clear`. Pour les deux fichiers réellement mesurés ici (`arm_a`/`arm_b`) j'ai vérifié à la main que ça ne fausse pas le résultat actuel, mais la prétention du détecteur à mesurer objectivement « l'absence d'anti-patterns connus » (`ablation/TASK_SPEC.md:35-37`) est plus fragile que présentée pour un usage futur/générique.

- **`factory/bin/bootstrap_lessons.py:447-452`** — `write_jsonl` utilise un nom `.tmp` **fixe** (`out_path.with_suffix(".tmp")`) sans flock, exactement le pattern de course qui a causé le bug P1 déjà trouvé-et-corrigé dans `lesson_extractor.py` (voir `DECISIONS_AUTONOMOUS.md` D-008/repair round 1). Deux bootstraps concurrents sur le même `--out` peuvent s'écraser silencieusement. De plus, `main()` (ligne 479-480) n'entoure pas l'appel à `write_jsonl` d'un `try/except` : une erreur disque (plein/permissions) remonte en traceback nue au lieu du `rc=1` contrôlé désormais garanti ailleurs dans la même codebase.

## P3

- **`factory/bin/lesson_schema.py:66-68` (`DATE_RE`)** — valide la FORME d'une date ISO8601, pas sa validité calendaire (`"2026-13-45"`, `"2026-02-31T29:99"` passent `validate_lesson`). `reports/RUN4_FINAL_REPORT.md:13` affirme « la date est maintenant réellement validée ISO8601 » — vrai seulement pour du texte non daté du tout, pas pour une date syntaxiquement plausible mais calendairement invalide ; l'affirmation est donc légèrement survendue.

- **`factory/bin/ablation_checker.py:385-387` (`check_file`)** — `path.read_text(encoding="utf-8")` n'est pas protégé ; un fichier source non-UTF8 ou illisible lève une exception non capturée, en contradiction avec le contrat documenté du module (`ablation_checker.py:27` : « rc=0 toujours »).

- **`factory/bin/lesson_schema.py` (`load_jsonl`)** — quand `validate_lesson(obj)` échoue (severity/category/date/id/evidence invalide), le message d'erreur ne porte pas le numéro de ligne JSONL (contrairement à la branche `JSONDecodeError` qui, elle, le fait) — complique le diagnostic sur une mémoire volumineuse.

- **`DECISIONS_AUTONOMOUS.md`** — deux entrées portent le même identifiant `D-008` (« Stop-words pour `_split_triggers` » et « Repair audit round 1 »), erreur de numérotation mineure dans un fichier dont la fonction est justement d'être un registre de décisions fiable.

## Ce qui va bien (pour situer le verdict)

Le cœur technique — `lesson_schema.py`, `lesson_extractor.py` (sérialisation flock+mkstemp du `--out`/`--append` vérifiée en lecture, gestion d'erreurs contrôlée), `lesson_injector.py`, le bootstrap de 18 leçons tracées à `factory-run3-lab@fix-lock-flock-checkpoint-sha256`, et la preuve d'ablation A/B elle-même — est cohérent, testé, et honnête sur ses limites (section NON VÉRIFIÉ présente et sincère dans `RUN4_FINAL_REPORT.md` et `RUN4_ABLATION_AB.md`). Les problèmes bloquants ici sont essentiellement (a) le gate de process/état de campagne pas encore refermé, et (b) des défauts P2 réels mais localisés, pas une remise en cause de l'architecture.
