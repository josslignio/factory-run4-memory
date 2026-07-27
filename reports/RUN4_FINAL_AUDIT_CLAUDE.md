PAS PRET

# Audit final indépendant — Run 4 (Experience Compiler)

Périmètre : intégralité du code produit (`factory/bin/*.py`, `memory/`,
`tests/`, `ablation/`, `run_run4_autonomous.sh`), pas seulement le dernier
diff. Toutes les affirmations ci-dessous ont été vérifiées par exécution
réelle (tests relancés, checker relancé, fichiers source lus directement),
pas supposées depuis les rapports précédents.

## Verdict

**PAS PRET.** Deux findings P1 bloquants : un livrable exigé par le master
order est absent, et le mécanisme d'audit lui-même (le gate qui autorise le
passage à `WAITING_HUMAN_BOSS_GO`) a un défaut reproduit qui peut le faire
passer à tort.

---

## P1 — bloquants

### P1-1 — `reports/RUN4_FINAL_REPORT.md` (exigé par le master order §5) n'existe pas
- **Fichier concerné** : absent du dépôt. `git log --all -- reports/RUN4_FINAL_REPORT.md`
  ne renvoie AUCUN commit — ce fichier n'a jamais existé.
- **Exigence violée** : `MASTER_ORDER_RUN4_MEMORY.md:53` — « `reports/RUN4_FINAL_REPORT.md` :
  nombre de leçons dans la base, résultat brut de l'ablation A/B (…), statut
  de chaque capacité (PROUVÉ PAR EXÉCUTION / NON PROUVÉ / BLOQUÉ), section
  NON VÉRIFIÉ. »
- **Ce qui existe à la place** : `reports/RUN4_ABLATION_AB.md` couvre bien
  le résultat brut de l'ablation A/B (§4) avec une section NON VÉRIFIÉ, mais
  ne contient NULLE PART un statut PROUVÉ PAR EXÉCUTION / NON PROUVÉ / BLOQUÉ
  pour chacune des capacités §1 (bootstrap), §2 (extracteur), §3 (injecteur),
  §4 (ablation) — c'est-à-dire la synthèse même que le master order demande
  comme livrable final. Le total de leçons en base (18) n'y est pas non plus
  affiché comme métrique de synthèse (il n'apparaît qu'indirectement, ex.
  `ablation/arm_B_INJECTED_LESSONS.md:3`).
- **Preuve que ce n'est pas un détail** : `run_run4_autonomous.sh:74`
  (`FINAL_AUDIT_PROMPT`, le prompt même qui a produit ce fichier d'audit)
  demande explicitement de « vérifier que le résultat de l'ablation A/B dans
  `reports/RUN4_FINAL_REPORT.md` est un chiffre réel » — le pilote headless
  ne peut donc pas remplir sa propre instruction d'audit, puisque le fichier
  qu'il cite n'existe pas.
- **Scénario de défaillance concret** : la campagne est en
  `CAMPAIGN_STATE=READY_FOR_FINAL_AUDIT` (`factory/campaigns/CAMPAIGN_STATE:1`)
  et pourrait atteindre `WAITING_HUMAN_BOSS_GO` sans que le document de
  synthèse exigé — celui qui est censé donner à Jocelyn le statut PROUVÉ/NON
  PROUVÉ/BLOQUÉ de chaque capacité en un coup d'œil — n'ait jamais été écrit.

### P1-2 — Le gate `audit_ok()` du pilote peut valider à tort un audit négatif (reproduit)
- **Fichier:ligne** : `run_run4_autonomous.sh:91-95`.
```bash
audit_ok() {
  [ -s "$1" ] || return 1
  grep -qi "PRET A MERGER" "$1" || return 1
  return 0
}
```
- **Défaut** : ce gate cherche la locution cible n'importe où dans le
  fichier, sans exiger qu'elle soit sur la première ligne (verdict) ni
  vérifier l'absence de « PAS PRET ». Or `FINAL_AUDIT_PROMPT`
  (`run_run4_autonomous.sh:74`) demande explicitement à l'auditeur d'écrire
  « PRÊT A MERGER ou PAS PRET » — un auditeur honnête qui rend un verdict
  négatif est susceptible de justifier son verdict en citant la locution
  cible dans sa prose (ex. « le module doit encore être corrigé avant d'être
  PRÊT A MERGER »), ce qui fait matcher le grep.
- **Reproduit en direct** (commande exécutée pendant cet audit) :
  ```
  $ printf 'PAS PRET\n\nExplication: le module doit encore etre corrige avant d etre <locution-cible>.\n' > /tmp/fake_bad_audit.md
  $ source run_run4_autonomous.sh; audit_ok /tmp/fake_bad_audit.md; echo $?
  0
  ```
  (`<locution-cible>` = la chaîne exacte de `run_run4_autonomous.sh:93`,
  volontairement non recopiée verbatim ici pour ne pas déclencher à tort ce
  même gate si ce fichier d'audit lui est un jour passé — voir ironie du
  bug.) `audit_ok` renvoie `0` (succès) alors que le verdict réel du fichier
  est `PAS PRET` en première ligne.
- **Impact** : ceci défait directement l'intention de la décision `D-004`
  (« porte P1 avant `WAITING_HUMAN_BOSS_GO` », `DECISIONS_AUTONOMOUS.md:37-44`)
  — le pilote pourrait annoncer à Jocelyn que la campagne est prête à merger
  alors que l'un des deux audits indépendants a explicitement dit le
  contraire.
- **Fix suggéré (non appliqué — hors périmètre construction pour un
  reviewer)** : ne tester que la première ligne non vide du fichier
  (`head -1`), et/ou rejeter explicitement si « PAS PRET » apparaît en
  première ligne, plutôt qu'un grep pleine-page.

---

## P2

### P2-1 — `lesson_extractor.py --append` : race TOCTOU sans verrou sur un fichier partagé
- **Fichier:ligne** : `factory/bin/lesson_extractor.py:449-461` (chemin
  `--append` de `main()`), s'appuyant sur `_read_existing_ids` (ligne 349)
  et `_append_jsonl` (ligne 364).
- **Défaut** : `main()` lit les ids existants (ligne 451:
  `_, existing_ids = _read_existing_ids(app_path)`), vérifie l'absence de
  collision (lignes 452-459), puis écrit (ligne 461: `_append_jsonl(...)`),
  sans aucun verrou fichier (`fcntl.flock`) entre la lecture et l'écriture.
  Deux invocations concurrentes du même processus (ou deux processus
  distincts) sur le même `lessons.jsonl` peuvent toutes deux lire le même
  état "pas de collision" puis toutes deux écrire, produisant potentiellement
  des lignes entrelacées ou des ids dupliqués non détectés.
- **Pourquoi ce n'est pas juste théorique ici** : le message d'erreur du
  module affirme explicitement une garantie qu'il ne tient pas — ligne 457,
  `"... RIEN n'a été écrit (atomicité)"` — cette « atomicité » ne protège
  que contre une collision détectée par CE process lisant AVANT d'écrire ;
  ce n'est pas une atomicité vis-à-vis d'écrivains concurrents. Or c'est
  précisément la classe de défaut (TOCTOU sur fichier partagé) que
  `memory/lessons.jsonl` documente déjà elle-même comme leçon L-01
  (`lockfile PID-file… fenêtre TOCTOU`, `memory/lessons.jsonl` ligne 1) —
  l'extracteur n'applique pas sa propre leçon capturée.
- **Mitigation actuelle** : la règle 2 du master order (« un seul writer
  actif à la fois ») limite le risque réel dans le run headless actuel (le
  pilote garantit un seul GLM actif), mais ce n'est pas une garantie du
  code lui-même, et `lesson_extractor.py` est conçu comme un outil
  réutilisable au-delà de ce run (aucune restriction d'usage documentée
  contre les appels concurrents).

## P3

### P3-1 — `ablation_checker.py` : `rule_L10` définie deux fois (code mort)
- **Fichier:ligne** : `factory/bin/ablation_checker.py:249-278` (première
  définition) et `:280-310` (seconde définition, strictement
  byte-identique). La seconde écrase silencieusement la première dans le
  namespace du module ; `RULES` (ligne 373) référence donc bien une version
  fonctionnelle — aucun bug de comportement aujourd'hui, les deux étant
  identiques.
- **Risque** : reste de copier-coller non nettoyé (probablement un fix
  appliqué deux fois par inadvertance) ; si quelqu'un corrige un jour la
  seconde définition sans toucher la première (ou l'inverse selon l'ordre
  de lecture), la divergence serait silencieuse.

### P3-2 — Détection lexicale stricte, non documentée pour un cas précis
- **Fichier:ligne** : `factory/bin/ablation_checker.py:122`
  (`rule_L01`, `re.search(r"\bfcntl\.flock\s*\(", code)`).
- **Limite** : ne détecte que l'appel qualifié `fcntl.flock(`. Un code
  utilisant `from fcntl import flock` puis un appel nu `flock(...)` serait
  scoré comme défaut `present` (TOCTOU) alors que le flock est bien utilisé
  — faux positif. `rule_L13` (LOCK_UN, ligne 332) n'a pas ce problème car
  elle matche le token nu. La section NON VÉRIFIÉ de
  `reports/RUN4_ABLATION_AB.md` (§6/§7) documente déjà la limite générale
  « détecteur statique », mais pas cette fragilité lexicale précise.
  Impact réel nul sur cette ablation (les deux bras utilisent `fcntl.flock(`
  qualifié), mais affecterait la fiabilité d'une réutilisation future du
  checker sur du code stylistiquement différent.

### P3-3 — `date` non déterministe par défaut dans un module qui se revendique déterministe
- **Fichier:ligne** : `factory/bin/lesson_extractor.py:308-309`
  (`block.get("date", "").strip() or _dt.datetime.now(_dt.timezone.utc)...`).
- **Détail** : si le bloc `[FINDING]` n'a pas de champ `date:` optionnel, la
  leçon produite prend l'heure courante — non reproductible d'une exécution
  à l'autre pour un input identique. Le module s'auto-décrit ligne 8 comme
  « Déterministe, pas de LLM dans le chemin d'extraction » ; le champ `date`
  est la seule sortie non déterministe. Impact faible : `date` n'entre ni
  dans le calcul d'id, ni dans le matching de l'injecteur, ni dans la
  détection de collision (qui se fait sur `id`).

---

## Ce qui a été vérifié et est solide (pas seulement affirmé)

- **84/84 tests réels** : `python3 -m pytest tests/ -v` relancé pendant cet
  audit → `84 passed in 0.04s` (exact, aucun skip). `bash
  tests/test_driver_helpers.bash` relancé → `PASS=13 FAIL=0`.
- **Ablation A/B reproductible, pas inventée** : rejoué indépendamment
  `python3 factory/bin/ablation_checker.py ablation/arm_a_lock_manager.py
  --json` et le même pour le bras B ; sortie diffée octet-pour-octet contre
  `ablation/arm_a_measurements.json` / `arm_b_measurements.json` →
  identique. Les chiffres cités dans `reports/RUN4_ABLATION_AB.md`
  (6 défauts/2 P1 bras A → 2 défauts/0 P1 bras B) sont donc réels et
  rejouables, pas des affirmations non vérifiées.
- **Traçabilité du bootstrap (D-006) vérifiée par lecture directe** :
  `~/factory-run3-lab@fix-lock-flock-checkpoint-sha256` existe réellement ;
  les 18 `fichier:ligne` cités dans `factory/bin/bootstrap_lessons.py`
  (`lock_manager.py:31/44/92/100/142`, `worker.py:46/69/103/110/125/145/169/225`,
  `anti_loop.py:45`, `RUN3_REPORT.md:42`) correspondent bien au contenu réel
  de cette branche à ces lignes précises — vérifié ligne par ligne, ce ne
  sont pas des exemples inventés.
- **Séparation constructeur/contrôleur et protection de `main`** :
  `main` reste au commit bootstrap (jamais avancé), tout le travail produit
  est sur `run4/build` ; aucune dépendance externe (imports stdlib
  uniquement dans tous les fichiers `factory/bin/*.py` vérifiés) ; aucune
  commande destructrice trouvée dans le code produit.
- **Les 3 findings P1 Codex historiques (IsADirectoryError) sont bien fixés
  et couverts par test** : `tests/test_lesson_injector.py` —
  `test_task_file_directory_returns_1`, `test_memory_directory_returns_1`,
  `TestMemory.test_directory_memory_raises_injection_error` — les trois
  passent réellement.

## NON VÉRIFIÉ

- Le pilote `run_run4_autonomous.sh` n'a pas été rejoué en conditions
  réelles de bout en bout (appels `opencode`/`claude`/`codex` live) ; seuls
  les helpers isolés (`read_state`, `backoff_secs`, `audit_ok`) ont été
  testés directement, hors boucle complète `main()`.
- La race TOCTOU décrite en P2-1 n'a pas été démontrée sous charge
  concurrente réelle (deux process simultanés) ; l'analyse repose sur
  lecture de code (séquence lire-puis-écrire sans verrou), pas sur une
  collision effectivement provoquée.
- `reports/run4-driver.log` (≈690 Ko) n'a pas été lu intégralement ligne
  par ligne ; seuls son existence, son rôle (log régénéré, exclu par
  `.gitignore`) et un usage indirect via les tests ont été vérifiés.
- Aucune vérification de conformité légale/licences n'a été effectuée
  (hors périmètre de cet audit technique).
