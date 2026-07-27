FIX_NEEDED

- `factory/campaigns/CAMPAIGN_STATE:1` — état `READY_FOR_FINAL_AUDIT` non autorisé. Le master order n’autorise que `RUNNING`, `WAITING_INFRA`, `FAIL` ou `WAITING_HUMAN_BOSS_GO`; l’état final requis est `WAITING_HUMAN_BOSS_GO` (`MASTER_ORDER_RUN4_MEMORY.md:10,56`).
