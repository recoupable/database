# One wallet per billing account

Prerequisite for [shared AI accounting](https://github.com/recoupable/app/issues/2105)
and [Context spending limits](https://github.com/recoupable/app/issues/2123).

`20261009010000_credit_wallet_account_unique.sql` adds a unique constraint on
`credits_usage.account_id`. Concurrent inserts for one account cannot create
independent balances. An update cannot reassign a wallet to an account that
already has one. The constraint applies to all writers, including service-role
and legacy SQL paths. It changes no balances, receipts, pricing, grants or roles.
Existing nullable account IDs remain nullable; this does not authorize unassigned
wallets as payers. The charge receipt function requires a non-null account ID.

## Release checks

Before approval, inspect aggregate duplicate counts without returning identities
or balances:

```sql
SELECT count(*) AS duplicate_account_groups
FROM (
  SELECT account_id FROM public.credits_usage
  WHERE account_id IS NOT NULL
  GROUP BY account_id HAVING count(*) > 1
) duplicates;
```

This is a point-in-time check. The database validates again while installing the
constraint, closing the race with writers. Existing duplicates cause installation
to fail; no automatic deduplication, summed balances or row deletion is permitted.
Resolve any failure through separately reviewed evidence and a specific decision.

The migration takes an ACCESS EXCLUSIVE table lock to build a normal unique
index. It blocks reads (including balance queries) as well as writes while held;
a queued lock can also delay later queries. A five-second lock timeout and
thirty-second statement timeout bound the wait/work. The reviewed
production table was approximately 392 KiB on October 9 UTC, so an ordinary
transactional constraint is appropriate; recheck size and workload before rollout.
On timeout the transaction rolls back: do not assume the constraint exists or
deploy work that depends on it. Retry through the normal release process after
investigation, rather than increasing timeouts blindly.

After the approved merge and normal Supabase deployment, verify migration history
and `pg_constraint`/`pg_index` show the valid unique account constraint. Do not
insert production wallet fixtures or invoke a charge to prove installation.

## Local tests

```sh
python3 -m unittest discover -s tests -p 'test_credit_wallet_identity.py'
python3 -m unittest discover -s tests -p 'test_credit_charge_receipts.py'
```

Uses the existing disposable PostgreSQL fixture, synthetic owners and no hosted
credentials. Five assertions fail against the prior schema, including twelve
concurrent inserts all succeeding. Seven cases cover concurrent creation,
duplicate/reassignment rejection, rollback, existing debit/receipt compatibility,
failure without changing pre-existing duplicates, and preservation of valid rows
including negative/zero balances and nullable owners. Existing receipt tests keep
their pre-constraint fixture to preserve defense against legacy ambiguous rows.
This is not a full Supabase replay, hosted caller test or reservation test.

## Writer audit and remaining work

Inspected API release `348c481e` and database release `f446984`:

- `initializeAccountCredits` calls `insertCreditsUsage`, which returns null on
  insert failure. `checkAndResetCredits` already rereads after a failed initial
  insert; the constraint makes its concurrent-creation fallback enforceable.
- `grant_credits_with_audit` reads and then inserts when no wallet exists. A
  concurrent creation can now raise a uniqueness error and roll back its grant
  transaction instead of making another wallet. This change does not retry a grant.
- `checkAndResetCredits` can still write a refill using an earlier balance read.
  Two due refills can overwrite spending or a top-up between their reads/writes.
- `incrementRemainingCredits`, used by Stripe top-up handlers, and `deductCredits`
  still use read-modify-write arithmetic. Concurrent updates can lose changes.
- Existing audited debit and `record_credit_charge_once` use database arithmetic
  and serialize on the wallet row. The uniqueness constraint gives account-wide
  legacy writers one assigned row but does not make stale absolute writes safe.
- Auto-top-up settings and run timestamps use the generic account update helper.
  Holds must not trigger these purchase paths.

This is a scoped source audit, not an inventory of every external writer or proof
of hosted call behavior. No matching credit writers were found in the available
local Chat/Admin source search; those checkout contents do not establish complete
coverage of their released services.

Next: make refill decisions and balance arithmetic safe under concurrent changes,
then coordinate old spenders with reservations. Before paid Context activation,
request/pilot limits, retained settlement identity, separate provider expenses and
customer charges, and approved failure/cancellation policies remain required.
This constraint alone neither reserves credits nor prevents overspending.
