# Atomic wallet adjustments

`20261010212300_credit_wallet_atomic_adjustments.sql` adds two service-only,
security-invoker functions over the existing `credits_usage` balance. They replace
the two legacy API writers that wrote a balance read earlier, which could silently
drop a concurrent debit, top-up or grant:

- `refill_credits_to_floor(account, floor, expected_timestamp)` is the monthly plan
  refill. It locks the single wallet row and first checks that `"timestamp"` still
  equals the refill timestamp the caller read when it decided a refill was due. If
  another refill (or a grant, which restarts the clock) has moved it, the period is
  already settled: it returns `{state: superseded, remainingCredits, timestamp}` with
  the current values and changes nothing, so two callers that read the same stale
  row refill once and a debit taken in between is not resurrected. Otherwise it sets
  `remaining_credits = GREATEST(remaining_credits, floor)` and advances `"timestamp"`
  (stored in UTC) in one statement, returning `{state: raised|unchanged, ...}`. The
  timestamp advances on no-op refills too, so an account stops evaluating as
  refill-due.
- `increment_credits_atomic(account, delta)` is the Stripe top-up. It adds the delta
  in place and returns `{remainingCredits}`. It leaves the timestamp alone, as the
  legacy writer did, so a top-up never postpones the monthly refill.

Both reject a null owner, a null expected timestamp, a negative floor, a
non-positive delta and values beyond the safe integer range with SQLSTATE 22023.
They reject zero or multiple wallet rows visible at lookup without changing
anything; that does not stop a duplicate wallet from being inserted afterwards, which
is what the single-wallet constraint (database#88) prevents. They take the same row
lock as `record_credit_charge_once` and serialize with the legacy
`deduct_credits_with_audit` row update. No usage event
is written, no auto-top-up column is touched, and no new wallet, balance column or
ledger is created.

This is **not** a reservation, hold, settlement, request/pilot ceiling, price or
spending authorization, and it does not enable any paid Context or Sites caller. A
sound, lost-update-free balance is only the prerequisite for layering holds on it
later under app#2123 / app#2105. The legacy `deduct_credits` path and the API's
unaudited `deductCredits` read-modify-write (still used by research, content and
site-production charges) are unchanged: that writer can still overwrite a balance
these functions or any other writer changed after its read, and is the next slice.

## Verification

Run only against the disposable fixture (synthetic balances, Unix socket, no network
listener or hosted credentials):

```sh
python3 -m unittest discover -s tests -p 'test_credit_wallet_adjustments.py'
```

Ten tests cover twelve concurrent top-ups, floor raise/no-op with timestamp
advance, a second refill for the same period after a debit (superseded, debit kept;
a refill that observed the current PostgREST-serialized timestamp still applies), six
concurrent refills for one period (exactly one applies), a deterministic lost-top-up
reproduction (the refill blocks on an open top-up transaction and then keeps it),
refill concurrent with a charge receipt and a legacy debit, invalid inputs,
missing/duplicate wallets, denied browser roles and transaction rollback. The fixture adds the production `timestamp` column (without
time zone) to the minimal legacy schema; it is not a full migration replay.
Locally passed on PostgreSQL 15 and 17; CI (`credit-wallet-adjustments.yml`) covers
15/16 in a workflow file separate from the receipt checks.

## Release

Review and merge this database PR, apply through the documented database release
workflow, and verify both functions exist with service-role-only execute before
deploying the API change that calls them (the Stripe top-up and the monthly refill
switch to these RPCs; deploying the API first would fail those paths). An API
rollback keeps the functions in place; they are additive and have no effect until
called. Do not call them against a real wallet merely to test deployment.
