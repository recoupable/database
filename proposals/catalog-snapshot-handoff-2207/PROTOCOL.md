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
bound. The receipt is source retention, never working controls saved or approval.
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
