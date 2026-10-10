# Credit reservations (holds)

`20261010210500_credit_reservations.sql` adds the shared reserve/settle/release
primitive for AI work (recoupable/app#2105 milestone 1, reused by Context accounting
in recoupable/app#2123). It uses the existing `credits_usage` wallet and the
`usage_events` audit log through `record_credit_charge_once`. It adds no wallet,
balance column, price, ceiling, top-up, expiry or caller.

## Wallet invariant

- **Confirmed balance:** `credits_usage.remaining_credits`, unchanged by holds.
- **Outstanding holds:** the sum of `credits_held` for the owner's `held` rows.
- **Spendable:** confirmed balance minus outstanding holds.

A hold is a claim, not a temporary debit followed by a refund, so the monthly
refill, top-ups and auto-top-up never treat it as consumption. Every operation locks
the owner's single wallet row first (rejecting zero or multiple rows like
`record_credit_charge_once`), so holds serialize with each other, with charge
receipts and with the legacy wallet writers.

## Operations (service role only, security invoker)

| Function | Result |
| --- | --- |
| `reserve_credits_once(owner, key, credits)` | `held` (new hold), `reused` (same key and amount; reports saved status), or `insufficient` (nothing written). A changed amount conflicts. |
| `settle_credit_reservation(owner, key, credits, event)` | Charges the actual credits through `record_credit_charge_once` with the same key and closes the hold; the remainder is no longer held. An identical retry is `reused`; a changed amount or usage payload conflicts. Charging more than the hold, or a released hold, is rejected. |
| `release_credit_reservation(owner, key)` | Closes an unsettled hold without a charge or usage event; a retry is `reused`. Releasing a settled hold is rejected. |

The reservation ID (`hold-v1-…`) and the charge receipt ID (`charge-v1-…`) both
derive from the billing owner and operation key. A key identifies one chargeable
attempt: never generate a fresh key on retry and never reuse one for independent work.
A lost reply is ambiguous; replay the same call with the same key to learn the state.

## Deliberately open

- **Legacy debit writers do not consult holds.** `deduct_credits_with_audit`,
  `deduct_credits` and the API's read-modify-write `deductCredits` still debit the
  confirmed balance directly, so spendable credit can fall below zero while a hold
  is outstanding. Moving those callers onto reservations is a later slice.
- **No expiry.** Unknown provider exposure stays held until the trusted server
  settles or releases it. Do not add a time-based release that turns uncertain
  work into spendable credit.
- **Failure and cancellation billing are not decided here.** Release is for work
  known not to have incurred a charge (for example, cancelled before dispatch).
  Charging released or over-limit work needs an approved policy.
- Request/pilot ceilings, provider-expense versus customer-debit reporting and
  pricing versions are not stored here.
- Reservations must be retained like charge receipts. A purge would let a
  recycled key hold capacity again, so the service role has no DELETE/TRUNCATE.

## Verification

Disposable cluster only (synthetic balances, Unix socket, no hosted credentials):

```sh
python3 -m unittest discover -s tests -p 'test_credit_reservations.py'
```

Eighteen tests cover holds without debit, 12-way concurrent reservations against
one balance, concurrent duplicate reservations and settlements, lost-reply replay,
changed-input conflicts, settlement through the shared charge receipt, over-limit
settlement, release and its state transitions, missing reservations, per-owner
isolation, top-up concurrent with settlement, refill with an outstanding hold, legacy
debit concurrency (documenting that it ignores holds), invalid inputs,
missing/duplicate wallets, denied browser roles, denied service-role deletes and
rollback. Locally passed on
PostgreSQL 15 and 17; CI runs 15 and 16. The fixture is the minimal legacy
schema plus the actual charge-receipt migration, not a replay of every migration.

## Release

Apply through the normal database release workflow before deploying the API
adapters. Verify the table and function grants after release (service role only;
no browser grants). Do not exercise these functions against a real wallet to test
deployment. Rolling back the API stops new callers; keep the table and its rows.
