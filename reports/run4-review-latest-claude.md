AUDIT_REPAIR_NEEDED (phase P1, round 5)
--- Codex audit ---
PHASE_P1_FAIL

## P1

- [P1] L’injection n’est pas fail-closed pour tout `rc!=0` : le driver accepte `rc=2` avec stderr vide et continue, au lieu d’écrire `MEMORY_SYSTEM_FAIL` et s’arrêter. Le test entérine ce contournement, donc ne détecterait pas cette régression. [run_run4_autonomous.sh:796](/Users/jocelyngrosjean/factory-run4-memory/run_run4_autonomous.sh:796) [tests/test_injection_failclosed.bash:229](/Users/jocelyngrosjean/factory-run4-memory/tests/test_injection_failclosed.bash:229)
