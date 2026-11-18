# Inactive Pack worker-fence proposal

Status: local paired implementation for review, 2026-11-18. **Do not apply to a hosted database.** These files are deliberately outside `supabase/migrations` and are not referenced by deployment runners. They do not change deployed behavior.

The paired API branch is `codex/pack-worker-fence-2269` in `recoupable/api`. Its protocol-2 admission is internal and dormant; public REST/MCP callers continue to use protocol 1. Root owns paired acceptance, merge and any later rollout. Legacy workers do not gain a stale-worker guarantee from this proposal.

## Files and local qualification

- `schema.sql`: protocol ownership, execution/claim history, the two receipt tables and guarded legacy wrapper.
- `command.sql`: generation, workflow, claim and context fences; intent registration and existing-accounting composition.
- `receipts.sql`: separately committed, redacted observation append/read ports.
- `test_contract.py` and `test_extended.py`: actual command calls on disposable PostgreSQL, using the repository's existing synthetic fixture.
- `CONTRACT.md` and `RECEIPTS.md`: implemented behavior and remaining boundaries.

Run with PostgreSQL 17 tools on PATH:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 proposals/pack-worker-fence-2269/test_extended.py
```

The fixture applies the existing Pack schema and then these three proposal files, in the order above, only to its owned temporary Unix-socket cluster. It uses no TCP listener or hosted credentials and cleans up its own cluster. The suite covers 11 protocol-2 cases and the existing 11 legacy controls. The paired API provides an additional runner that exercises real API production helpers against these exact SQL files; provider, media and caption effects are synthetic. Its compiled Workflow SDK fixture verifies failure/replay behavior separately.

## Delivery and activation boundary

Baseline: Database `1b892dd2671ba7e15e0c44b690fbfbe515b59fbd`; paired API `bb542a9924ba531e422b3cd229e75a8bdb1892da`. No historical migration is changed. Migration filename/ownership work in Database PRs #125/#135 and reservation composition in #134/#135 remain separate. Existing Pack accounting remains the implementation called internally; no new wallet, rates or reservation model is introduced.

Before any rollout, a separately reviewed change must reconcile the current database head and migration ownership, convert this proposal into an ordered migration, verify deployed schema/permissions, inventory and drain or reconcile legacy in-flight executions, qualify the intended authenticated runtime, and explicitly admit new protocol-2 launches. This PR does none of those things. The renderer and foundation/scheduler candidates remain unwired. App 2269 remains open.
