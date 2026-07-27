## LEÇONS PERTINENTES (mémoire Run 4 — auto-injectées)

- Source : `memory/lessons.jsonl` (18 leçons au total).
- Critère : correspondance par mot-clé/catégorie sur `trigger_pattern` (stdlib, pas d'embeddings, pas de ML).
- Tâche analysée : « # TASK SPEC — Mini lock_manager.py (spécification neutre pour ablation A/B)

> Spec volontairement NEUTRE : décrit le COMPORTEMENT attendu, pas les
> pièges ... ».
- Sélection : 3 leçon(s) retenue(s) (score ≥ 1, tri score puis severity puis id).

### [P1] `L-20260727T150500Z-12` — concurrency
- **description** : Après os.fork(), l'enfant hérite par copy-on-write de _LOCK_FDS ET des fds ouverts : release_lock(chemin) dans l'enfant ferme le fd hérité → comme le flock suit la file description partagée parent/enfant, ça déverrouille aussi le PARENT.
- **déclencheur** : `os.fork; _LOCK_FDS hérité; release_lock enfant; flock partagé parent/enfant; register_at_fork`
- **remède** : os.register_at_fork(after_in_child=…) ferme chaque fd tracké via os.close PUIS _LOCK_FDS.clear(), dans l'enfant seulement. close() sur le fd enfant ne ferme que la copie enfant ; le verrou parent reste intact.
- **preuve** : factory-run3-lab@fix-lock-flock-checkpoint-sha256:lock_manager.py:44 — test: test_zombie_lock.test_fork_child_does_not_inherit_lock_release (vrai os.fork, enfant _LOCK_FDS vide, parent toujours REFUSÉ à un 3e process)
- **score** : 2 — matchés : os.fork, register_at_fork

### [P1] `L-20260727T150500Z-01` — concurrency
- **description** : Verrou fichier par mécanisme PID-file + unlink/O_EXCL : fenêtre TOCTOU entre le unlink du verrou périmé et la création exclusive — deux process peuvent tous deux croire détenir le verrou.
- **déclencheur** : `lockfile PID-file; O_CREAT|O_EXCL; unlink lock; verrou fichier; check-then-set lock`
- **remède** : Remplacer par fcntl.flock(fd, LOCK_EX|LOCK_NB) sur un fichier PERSISTANT : atomique au niveau kernel, libéré par l'OS à la mort du process (plus de zombie, plus de TOCTOU). Le fichier de lock n'est JAMAIS unlink.
- **preuve** : factory-run3-lab@fix-lock-flock-checkpoint-sha256:lock_manager.py:100 — test: test_zombie_lock.test_three_processes_race (20 courses à 3 process, codes=[0,2,2] systématiques)
- **score** : 1 — matchés : verrou fichier

### [P2] `L-20260727T150500Z-07` — concurrency
- **description** : Variable globale _LOCK_FD (scalaire) pour le fd du verrou : un 2e acquire_lock sur un chemin différent écrase la référence au premier fd → flock du premier verrou perdu (fd orphan) et 2e verrou réutilise un fd qui n'est pas le sien.
- **déclencheur** : `_LOCK_FD global unique; verrou fichier; multi-lock; fd écrasé; second acquire`
- **remède** : Remplacer la globale scalaire par un dict indexé par chemin canonique (_LOCK_FDS[path] = fd) : un processus peut détenir plusieurs verrous indépendants.
- **preuve** : factory-run3-lab@fix-lock-flock-checkpoint-sha256:lock_manager.py:31 — test: test_zombie_lock.test_multi_lock_independent_paths (acquire A + acquire B, release A ne libère pas B)
- **score** : 1 — matchés : verrou fichier
