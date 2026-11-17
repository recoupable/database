# Credit reservations (holds)

`20261010210500_credit_reservations.sql` adds the shared reserve/settle/release
primitive for AI work (recoupable/app#2105 milestone 1, reused by Context accounting
in recoupable/app#2123). It uses the existing `credits_usage` wallet and the
`usage_events` audit log through `record_credit_charge_once`. It adds no wallet,
balance column, price, ceiling, top-up, expiry or caller.

## Wallet invariant

- **Wallet balance:** `credits_usage.remaining_credits`, unchanged by shared holds.
  Released pack holds have already been deducted from this balance.
- **Outstanding holds:** the sum of `credits_held` for the owner's `held` rows.
- **Spendable:** wallet balance minus outstanding shared holds. Never subtract pack holds twice.

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
Every rejection these functions raise uses SQLSTATE `22023` and rolls back, so it is
definite for that call: nothing was written, and an unchanged replay fails the same way.

A `reused` receipt with status `held` goes to every duplicate delivery of the same
key, so a hold permits paid work but is not an execution lease. Duplicate deliveries
must be deduplicated by the caller's own attempt identity before provider dispatch;
settlement charges once either way.

## Activation prerequisites

This successor retains Database115's original migration unchanged and adds
`20261117000000_compose_credit_reservations.sql` after the released pack migration.
The added trigger checks all balance/owner updates and wallet deletion against open
shared holds. Unrelated metadata writes and legacy no-hold debit behavior are unchanged.
It uses a narrowly scoped SECURITY DEFINER function with pinned search path and no
direct EXECUTE grant, so a wallet writer cannot hide holds through its own RLS view.

Settlement closes its own hold before the charge within one transaction; a failed
charge restores that hold. Other holds remain protected. Successful reserve performs
a no-amount-change wallet update: this creates a row version that forces an old
repeatable-read writer to serialize/retry instead of missing a new hold.

Current released API refill/top-up/deduction callers are already atomic. The pack
migration's refill floor counts unconsumed pack holds. Preserve it; the old
Database101/API1009 prerequisite text is historical, not current implementation state.
Database88's one-wallet constraint remains separate; this migration does not apply it
or repair duplicates. Zero/multiple wallets still reject reservation operations.
No caller activation follows from these source changes. Review/release and verify
actual migrations/grants separately before any live use.

## Deliberately open

- **Legacy pre-dispatch authorization is not implemented.** The guard protects
  reserved funds at debit time, but legacy callers can already have incurred provider
  expense when a debit fails. It does not bound that exposure or activate paid work.
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
  Its UPDATE grant covers only the closing columns (`state`, `credits_charged`,
  `charge_event_id`, `closed_at`); owner, key and amount are immutable.
- **No listing API for open holds.** A worker that loses its key leaves the hold open.
  The service role can find open holds by reading `credit_reservations` where
  `state = 'held'` (indexed by account, ordered by `created_at`) and then settle or
  release them with the recorded key. An API or operator view is a later slice.

## Verification

Disposable cluster only (synthetic balances, Unix socket, no hosted credentials):

```sh
python3 -m unittest discover -s tests -p 'test_credit_reservations.py'
python3 -m unittest discover -s tests -p 'test_credit_reservation_composition.py'
```

The original nineteen-test baseline applies only the original reservation migration
and preserves its historical gap demonstration. It covers holds without debit, 12-way concurrent reservations against
one balance, concurrent duplicate reservations and settlements, lost-reply replay,
changed-input conflicts, settlement through the shared charge receipt, over-limit
settlement, release and its state transitions, missing reservations, per-owner
isolation, an atomic top-up concurrent with settlement, an atomic refill with an
outstanding hold, legacy debit concurrency (documenting that it ignores holds),
invalid inputs, missing/duplicate wallets, denied browser roles, denied service-role
deletes and immutable hold columns, and rollback. Locally passed on
PostgreSQL 15 and 17; CI runs 15 and 16. The fixture is the minimal legacy
schema plus the actual charge-receipt migration, not a replay of every migration.

The composition suite replays the actual charge, reservation, pack and corrective
migrations in order on a synthetic minimal schema. It checks shared/pack holds,
legacy and stable debits, actual refill/top-up RPCs, concurrent admission, settlement
with other holds, lost acknowledgements, rollback, owner isolation, wallet lifecycle,
RLS-hidden holds and the repeatable-read race. It is not a full production schema replay.

## Release

Apply through the normal database release workflow before deploying the API
adapters. Verify the table and function grants after release (service role only;
no browser grants). Do not exercise these functions against a real wallet to test
deployment. Rolling back the API stops new callers; keep the table and its rows.
