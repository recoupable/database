# Pack receipt journal contract

The inactive implementation has exactly two receipt tables, alongside the execution/claim history required by the fence. It is operational evidence, not a wallet, charge ledger or authority to spend. Existing mutable `provider_state`, charge events and Context lifecycle records cannot substitute for this history without losing original association or inventing unrelated identities.

## Frozen operation

`release_pack_provider_operations` is inserted in the successful fenced `submitting` transaction. It records database UUID/time, owner/job/asset, creative revision, original execution UUID/version, actual Workflow ID, claim/paid attempt, phase, provider (`fal`), model, input SHA-256 and quoted credit charge. Foreign keys retain parent/history rows; the command binds all owner and identity fields from its locked rows. No worker has direct table write permission.

Unique `(owner_id, asset_id, attempt, phase)` permits one operation per paid phase. Registration returns `operation_created`; only a newly acknowledged intent permits submission. Resume keeps that operation and paid attempt and grants the new claim an immutable operation-ID continuation array. An original claim may append only to its original operation; a continuation may append only to its explicitly linked operations. Neither grants current job mutation. A fresh approved paid retry uses a new attempt.

The command bounds phase slots: image 0–3 for carousel, otherwise image 0, and motion only for video; thus no more than five operation slots per paid attempt. Model/input hash/charge are frozen and validated against the quoted configuration. Evidence append cannot create attempts, operations, continuation grants, holds or charges.

## Bounded observations

`release_pack_provider_observations` has primary key `(operation_id, kind)`, where kind is accepted, completed, failed or first conflict; at most four rows per operation. Payloads are at most 1024 bytes. Accepted/completed/failed accept only:

- `kind` and `request_id` (1–200 ASCII letters, digits, underscore or hyphen).
- Optional `output_sha256`, 64 lowercase hexadecimal characters, completed only.
- Required failed `reason_code`: `provider_failed`, `response_invalid` or `result_unavailable`.

No raw results, content, prompts, URLs, headers, tokens, filenames, exception text or arbitrary extension fields. Unknown fields/type/size violations are rejected, never truncated. API builds this allowlist; SQL validates it independently. Output SHA is metadata, not proof of retained output or validated content. Provider identities are internal locators, not public progress fields.

Acceptance precedes terminal observation. Exact payload replay returns `state=reused` and preserves the original timestamp. Changed payload in an occupied slot, differing request identity or conflicting success/failure preserves the original and appends at most one conflict row containing kind and canonical old/new payload hashes. Repeating that same conflict returns `conflict`; further distinct conflicts return `conflict_unretained_capacity`. No extra row or false retention claim is made. Invalid/unauthorized requests cannot consume that slot.

## Authority and transactions

Append/read ports run as dedicated `NOLOGIN pack_receipt_port`, with fixed `pg_catalog` search path and schema-qualified objects. It can SELECT operation/claim/job identity and SELECT/INSERT observations; it cannot update Pack, claim, wallet, hold or usage state. Narrow functions recheck actor/org membership and effective ownership. PUBLIC/browser execution is revoked, and service role gets function execution only. RLS is defense in depth, not a substitute for function authorization. The access helper locks current membership for the transaction.

Append authorizes the original execution/claim or exact stored continuation, then serializes observations using a transaction-scoped operation advisory lock. It never invokes the Pack command or expiry recovery. A late original receipt therefore cannot mutate a newer hold. This trusted service boundary is not cryptographic provider attestation.

Ordering:

1. Fenced intent and operation commit before submit. Failed/uncertain/duplicate registration does not submit.
2. Accepted or completed observation commits in a separate RPC before its active phase write.
3. If that phase refuses or rolls back, the committed observation survives. The API stops without catch finish/settle or another provider submission.
4. An unacknowledged append is uncertain; exact replay/readback can establish retention, but this slice does not add an automatic reconciliation worker. A crash before first durable receipt remains a loss window. The original intent blocks automatic resubmission.

Conflict responses commit their bounded row; invalid/unauthorized input raises without inserting. There is no append-then-raise stale check in the same transaction that would erase the evidence.

The owner-scoped read port validates job and cursor ownership and returns at most 100 operation rows with nested observations, ordered by UUID. Pagination traverses the retained rows visible to each read, not a multi-call frozen snapshot; restart from the first page when reconciling newly registered operations. It is internal and unmounted, with no public receipt route.

## Retention and qualification

No TTL, pruning job, worker update/delete port or cascading parent deletion. Retain operations, observations and continuation history for the Pack lifetime, including after settlement/retry. Parent deletion is RESTRICT; any owner-data deletion requires a separately authorized administrative process. Growth is bounded per approved paid attempt, not falsely bounded per owner lifetime. Access revocation hides retained history without erasing it.

Actual proposal tests register operations and continuation grants through the real fenced command, append via a separate service-role transaction, and then deliver an actual refused stale write. They check unchanged Pack/wallet/usage snapshots, bounded concurrent conflicts, owner/claim mismatch, pagination, redaction, privilege denial and same-attempt continuation. The paired API integration uses the same proposal files. These are disposable local PostgreSQL checks, not seeded-history-only mechanics, hosted qualification or live provider evidence.
