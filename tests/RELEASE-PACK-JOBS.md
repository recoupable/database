# Private release-pack jobs

Apply `20261020150000_release_pack_jobs.sql` before deploying its API caller. It adds two private, service-only tables, one pack command RPC, a reservation-aware monthly floor, and atomic legacy balance adjustment/topup RPCs. No hosted data is changed by the test fixture.

```sh
# PostgreSQL 16/17 binaries must be on PATH; macOS example:
PATH=/opt/homebrew/opt/postgresql@17/bin:$PATH python3 -m unittest discover -s tests -p 'test_release_pack_jobs.py'
```

Focused real transaction checks cover account/org denial, browser-role denial, revision/idempotency, concurrent budget approval, provider-stage charge receipts, exactly-once refunds, monthly floor accounting with holds, concurrent topups, ambiguous workflow dispatch, expired-worker fencing and stale creative-context invalidation. The fixture creates and destroys its own local database on a Unix socket; it reads no hosted credentials.

The complete quote is reserved from available wallet credits at approval. Only accepted visual-provider stages consume the hold and create usage receipts; caption/audio analysis/review/composition are explicitly included at no additional customer charge and bounded by the API worker. Unused funds refund once. The monthly floor counts unconsumed holds as existing funds, preserving topped-up balances without minting credits when a hold is released after renewal. Legacy topups and unaudited deductions use row-locked atomic operations rather than writing a previously read balance.

`refill_credits_to_floor(uuid,bigint,timestamp)` and `increment_credits_atomic(uuid,bigint)` retain the pending database #101 / API #1009 contracts. This migration extends their floor semantics for pack holds; those older PRs must not later replace the hold-aware implementation. Generic opt-in reservations in database #115 are not activated here.

Ambiguous workflow submission retains its hold. The workflow records its own accepted run id. A two-hour production window fences stale workers and changes unfinished assets to confirmed failed (no provider submission intent) or uncertain (intent/accepted request persisted). Known accepted requests resume by their original request ids; an intent without a provider id never automatically resubmits. Reading the job releases abandoned unused holds after the window. An operator must reconcile an ambiguous provider intent before any new paid attempt.
