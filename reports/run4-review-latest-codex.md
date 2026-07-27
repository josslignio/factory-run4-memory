FIX_NEEDED

- `factory/bin/lesson_injector.py:270` — `--task-file` pointant vers un répertoire provoque une traceback `IsADirectoryError` au lieu du retour d’erreur contrôlé annoncé (`rc=1`). Reproduit avec `--task-file memory`.
- `factory/bin/lesson_injector.py:77` — même défaut pour `--memory memory` : traceback non gérée au lieu d’une `InjectionError`/sortie contrôlée.
