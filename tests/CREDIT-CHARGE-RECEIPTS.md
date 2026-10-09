# Retry-safe charge receipts

`20261009000000_record_credit_charge_once.sql` adds an opt-in service-only function
using the existing `credits_usage` balance and `usage_events` audit log. It creates
no wallet, balance column or additional financial ledger. No existing caller changes.

The trusted server supplies the authorized billing owner, a stable work/attempt key,
a positive charge in existing credit units, and the existing usage details. A key
must identify one chargeable attempt; never generate a fresh key on retry or reuse
one for independent work. The receipt ID is derived from owner and key. A wallet
row lock covers lookup and the atomic debit/audit transaction. An exact
retry returns the original receipt; a changed amount or usage payload conflicts.
Separate billing owners cannot share receipts. Failure rolls back both writes.
Existing production has no unique account constraint on balance records. The new
function rejects zero/multiple records and debits only the exact locked row ID,
rather than using the legacy function that updates every matching account row.
This does not repair old duplicate records or change unrelated legacy writers.

This is a **post-work charge primitive**, not permission to start paid work. It
retains the existing debit behavior (including balances that can become negative).
It does not reserve funds, set request/pilot ceilings, choose prices, settle a hold,
trigger auto-top-up, or resolve provider expenses. Those remain prerequisites for
connecting Context or Sites. Never add this around an endpoint that already charges.
Before wiring callers, choose one charging owner per operation and integrate it with
the shared reservation and approved failure-billing policy in app#2105 / app#2123.

Receipts depend on retained, unchanged audit events. Do not delete/edit these events
or recycle operation keys; any future purge must preserve a durable deduplication
record. This migration does not alter existing audit permissions or introduce a new
retention policy. It cannot deduplicate legacy callers which generate fresh IDs.
A lost RPC response is ambiguous: retain the same key and reconcile, never repeat
provider work or silently create another charge identity.

## Verification

Run only against the disposable fixture (synthetic balances, Unix socket, no network
listener or hosted credentials):

```sh
python3 -m unittest discover -s tests -p 'test_credit_charge_receipts.py'
```

Eleven tests cover duplicate concurrent delivery, conflicting concurrent delivery,
replay after response loss, changed inputs, distinct keys/owners, invalid inputs,
missing/duplicate wallets, denied browser roles, transaction rollback, normalized defaults and
concurrent legacy debit. Locally passed on PostgreSQL 15 and 17; CI covers 15/16.
The fixture uses a minimal legacy schema plus the actual existing debit migration;
it is not a full replay of historical migrations.

Read-only production inspection on October 8 confirmed PostgreSQL 15.6, the audit
columns/types and primary key, service-role wallet read/update and audit read/insert grants,
and execution rights/body of the existing bigint debit function. The wallet primary
key is integer `id`; no unique account index is present. No balances were
read or changed and this migration has not been applied to production.

## Release

Review and merge the database PR, apply through the documented database release
workflow, and verify function identity/permissions before connecting an API caller.
The companion adapter is intentionally unused until shared spending controls are
complete. Do not call this function against a real wallet merely to test deployment.
An application rollback should stop new callers and preserve existing receipts.
