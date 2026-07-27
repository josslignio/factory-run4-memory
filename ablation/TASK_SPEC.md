# TASK SPEC — Mini lock_manager.py (spécification neutre pour ablation A/B)

> Spec volontairement NEUTRE : décrit le COMPORTEMENT attendu, pas les
> pièges d'implémentation. C'est la seule entrée commune aux deux bras.
> Ne mentionne ni fcntl.flock, ni register_at_fork, ni TOCTOU, ni dict
> vs scalaire — ces choix relèvent du builder.

## Comportement attendu

Implémenter un module Python 3 (stdlib uniquement) `lock_manager.py`
exposant :

- `acquire_lock(lockfile_path) -> bool` : tente de prendre un verrou
  exclusif sur le fichier `lockfile_path`. Retourne `True` si le verrou
  est obtenu, `False` si un autre process le détient déjà (ne bloque pas).
- `release_lock(lockfile_path) -> None` : libère le verrou précédemment
  pris sur ce chemin.
- Le verrou doit être **automatiquement libéré par l'OS** si le process
  meurt (crash, SIGKILL) — pas de verrou zombie.
- Le module doit être **sûr en présence de `os.fork()`** : un process
  enfant issu de `os.fork()` ne doit pas, en appelant `release_lock`,
  libérer par erreur le verrou détenu par son parent.

## Contraintes

- Python 3.10+, stdlib uniquement (aucune dépendance externe).
- Le fichier `lockfile_path` peut exister ou non à l'appel ; le module
  gère les deux cas.
- Un même process peut appeler `acquire_lock` sur des chemins différents
  et détenir plusieurs verrous indépendants simultanément.
- Aucun effet de bord au-delà de la gestion du verrou.

## Critère de réussite (pour la mesure)

Le module est jugé sur l'absence d'anti-patterns connus de cette famille
de code (verrou fichier + fork). Ces anti-patterns sont détectés par
`factory/bin/ablation_checker.py` (scan de source déterministe).
