# Exact catalog source handoff (2207) — inactive proposal

This extends the existing disabled chat-fence/working-surface boundary. It is not
mutable surface saving, a Context identity grant, a migration, or live storage.
Requires actual 636 and durable-surfaces-2207 proposal definitions. No SQL was run.

The authenticated development producer preserves its original canonical query,
periods, pagination, membership and complete retained observation tuples before
projection. Each source version is the original catalog/ISRC/date/provider/run/hash/
retrieved-at/value tuple, **not** a Context UUID. Null corrections remain null.
The envelope remains server-only durable workflow output, outside schema-v1 Surface.

A default-off API step may hand it to this RPC only after required fenced assistant
persistence and before fence release. Original actor/session/chat/message/epoch/
owner/run, immutable source revision 1, exact source bytes and surface bytes are
bound. Under those locks, the assistant must have a `message_epochs` row matching
its message ID, chat ID and current/captured epoch. Missing, foreign-chat or older
generation anchors fail before the source authorizer and before identical receipt
replay. An exact duplicate insert acknowledged by 636 does not adopt an old anchor
into a newer writer generation. The receipt is source retention, never working
controls saved or approval.
Same writer/exact bytes is idempotent. Different source/surface at the anchor is a
40001 conflict, never an overwrite. Session/chat/fence/message locks serialize
concurrent attempts. Deletes cascade source records with their message anchor;
updates cannot change the source surface after retention.

Current authorization remains a real prerequisite: authorize_catalog_surface_source
ALWAYS denies. Before activation it must be replaced with an independently reviewed
fixed adapter checking actor/workspace/catalog membership AND every original
observation's retained identity/current withdrawal policy in the same transaction.
It cannot trust JSON, fingerprint, a prior workflow check, or today's latest rows.
Missing/mismatched/withdrawn lineage must deny without returning new values. The
existing retained-source family proposals may supply those checks after qualification;
this proposal does not manufacture accepted Context results or weaken them.

No roles receive EXECUTE. No producer registry or enrollment is activated. The
public wrapper is defined solely to freeze the future RPC shape; source tests with
synthetic RPCs are not database mechanics proof. Real PostgreSQL concurrent/stale/
withdrawal/anchor-delete tests and security review remain required before adoption.

Raw legacy history currently lacks current-source checks. This retention slice does
not fix historical disclosure or authorize a new read endpoint. A future working-
surface operation must bind its authority_binding to this exact source record,
reauthorize under the source lock order, and apply existing controls CAS/receipts.
Read/export/model/history integration and scoped UI handoff must be reviewed together.
No auto-retry on transport ambiguity, no latest lookup, no provider recollection,
no private-to-public fallback. Failure after message persistence may leave an
assistant message without a retained-source receipt; that is NOT durable working
state and must never be promoted to saved controls.

## Anchor generation repair validation

`test_source_boundary.py` checks the actual three-part generation guard and its
position before source authorization and replay (five static tests). The guard
regression failed on the original proposal and passes with this repair.

`test_anchor_generation.py` adds five deferred disposable-PostgreSQL cases: current
epoch retention plus exact replay, old-epoch reused-message refusal before a denying
authorizer, old-epoch refusal before an existing identical receipt, missing epoch,
and foreign-chat epoch. It reuses the actual 636 fixture and both proposal files;
the synthetic source authorizer is only a mechanics seam, never real source proof.
The cases default to skipped and were not executed for this source-only repair.
Only separately authorized SQL qualification may set
`CATALOG_RETENTION_SQL_QUALIFICATION=1` and run them. No grants or adapter replacement
from that disposable test setup belong in the proposal or an activation plan.
