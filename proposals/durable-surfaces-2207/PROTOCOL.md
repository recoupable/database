# #2207 working-surface companion — offline technical proposal

Status: proposed, not activated. App contract [#2373](https://github.com/recoupable/app/pull/2373)
at `4d2fee41cdebcac8bcb878fd366702b5c5347cfe`; API inspected
`4ed1fdb1c4d1da38c0e179530205102f64d252c3`; Database base
`001cd115a605f2f69901802999db8220bab0cc45`. The local executable proof extends
this base's actual `proposals/chat-writer-fencing-636/migration.sql` without
changing it. `636` is that proposal's historical path, not a new issue.

This is a recommendation for root adoption before shared API/UI changes. Files
remain outside `supabase/migrations`. No production relation, grants, migration,
fence enrollment, route, caller or runtime flag is created by publishing them.
The SQL deliberately gives service_role no execute grant and installs a source
authorizer that always refuses. Harness-only authorization is synthetic.

## Placement decision

| Candidate                                                                | Consequence                                                                                                                                                                                            | Decision                                                            |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| Companion data part inside `chat_messages.parts`                         | Existing `persistAssistantMessage`, final `persistAssistantDataPart`, and update/upsert helpers replace the whole UIMessage. Requires every writer to merge correctly; stale blobs can erase controls. | Reject.                                                             |
| Columns on `chat_messages`                                               | Avoids parts overwrite, but cascade/suffix deletion loses receipts and deleted identities. Still needs a separate durable receipt/tombstone relation.                                                  | Reject as no smaller once deletion semantics are included.          |
| Generic Context brief/catalog artifact                                   | Purpose, identity and lifecycle differ; does not serialize with chat writers/deletes.                                                                                                                  | Reject; do not overload `save_brief` or make a second domain store. |
| Two private companion relations in existing disabled `chat_fence` schema | Reuses its chat lock, owner, enrollment and deleted-ID protection; keeps working data outside full-message replacements and keeps small receipts after message deletion.                               | Recommend.                                                          |

`working_surfaces` has one row per original assistant message, unique surface ID
within chat, exact original surface revision/workspace, database-local source-part
digest, immutable source-authority binding, current working revision, current
bounded controls and a deleted flag. No source snapshot copy or historical control
versions are stored. `working_surface_commands` stores chat/request identity,
message identity, command digest and a small original outcome receipt. It does not
retain prior control payloads. These are additions to the existing chat persistence
boundary, not a new service/database or approval for a production store.

Both reference `chat_fence.state`, not the deletable message row. A logical surface
delete clears controls but retains identity, minimal source-access binding and
receipts. Actual message deletion atomically marks the companion deleted; existing
636 tombstones prevent message-ID reuse. The enrolled parent cascade restrictions
remain in force. No generic hard-delete or retention policy is smuggled into this
proposal. A later controlled purge must handle source bindings, receipts, tombstones
and all referencing 636 state together; TTL deletion would break retry guarantees.

## Exact transaction and authority boundary

`chat_fence.working_surface_command(chat, authenticated_account, action, payload)`
is a private trusted-API interface. The service cannot call it in this proposal.
If later adopted, a separately reviewed grant and resource-authority integration
would be needed; publishing this source is neither approval nor activation.

Every operation uses READ COMMITTED and the 636 order:

1. Resolve chat's session; lock that session FOR SHARE and require its account to
   equal the server-authenticated effective account. Never accept actor authority
   from UI payload, widget state or model input.
2. Lock chat FOR UPDATE and recheck its session; lock enabled fence state FOR UPDATE.
3. Lock the existing companion row; for create lock the existing assistant message.
4. Invoke the fixed source-authority adapter; it locks current membership and source
   rows and checks the saved binding/proposed selected refs. No callable name or
   endpoint comes from the payload. Keep locks through commit/read result.
5. Compare receipt/precondition, mutate current state, store receipt and commit.

New create/save/delete mutations require idle fence phase. A null legacy stream
slot alone is not enough. Enabled 636 rules make writes from old epochs or closed
runs fail, and reject legacy direct message writes. Read/reconcile and exact known
retries may run while a new turn is active, after current authorization; they grant
no writer/run authority. State is never enrolled by a surface request.

The current-authority snapshot consists of the locked session owner, selected
workspace membership, source/version availability, and the exact saved binding
plus current/proposed selected refs. It is evaluated afresh even on retry/readback.
Delete is a removal-only authorization mode: it requires current session/workspace
membership and the exact stored identity, but does not require reading withdrawn
source content. Its receipt contains no controls/source body. Reconciliation derives
this mode from a stored deletion receipt, never a caller flag; other reads/retries
still require source access. Workspace revocation denies deletion and its retry too.

Do not invent a policy-version number or treat an earlier API check as a locked
snapshot. Existing Context `authorize_context_case_actor` / membership FOR SHARE
and source-before-document checks illustrate the concrete owning row sources.
A Context adapter must verify owner/subject/version relationships from existing
Context records, lock source IDs then version IDs in deterministic order, reject
withdrawn/removed versions, and authorize every selected exact ObjectRef. It must
compare the create binding against the actual message snapshot, not trust a supplied
list of allowed IDs. Personal workspace access still needs source ownership checks.

For catalog/Luminate lineage, the existing `getCatalogStreams` owner/catalog-link
checks are necessary but do not provide a withdrawal policy or a Context identity
join. Until an adapter supports that source kind, deny it. The current SQL adapter
always raises `0A000`; the harness replaces it with a visibly named synthetic
membership/source row and row lock. Thus this proof establishes serialization,
revocation-seam behavior and fail-closed wiring, NOT production source authorization.
Resolving the correct live mapping/withdrawal semantics remains domain-owner work;
placement/CAS/lock order are concrete technical choices, not questions for Sidney.

An adapter must not acquire session/chat locks after holding source locks. Existing
636 legacy triggers may acquire a message lock before the chat lock; mixed legacy
traffic can deadlock. PostgreSQL abort is a conflict, never success. Do not resolve
it by reacquiring a newer epoch or replaying a model/provider action. Enrollment
requires the existing approved drain/authority prerequisites, not this proposal.

## Command semantics

All payloads are JSON objects, at most 128 KiB in database JSONB text, unknown outer
fields reject. Full snapshot data part is bounded to 256 KiB; working controls to
64 KiB, eight selections and a nonempty displayName up to 160 characters. These are
explicit offline qualification limits, not an approved public API size SLA. API
must separately measure UTF-8 request size, enforce strict schema-v1 and recipe/
ObjectRef validation, safe integers/depth/JSON rules, and never truncate. SQL's
partial envelope checks do not replace the complete App/owning API schemas.

- `create`: `{message_id, request_id, expected_revision:0, workspace_id, surface_id,
surface_revision, authority_binding, work}`. Existing authorized assistant anchor
  must contain exactly one full snapshot whose ID/workspace/revision match. Existing
  or deleted companion and tombstoned message IDs refuse. Absent state becomes
  revision 1. A second create key cannot replace it. No message is created here.
- `save`: `{message_id, request_id, expected_revision:N, work}`. Live current state
  must be exactly N; increments once. Source identity/revision/binding cannot be
  changed. Recipe-declared compatible controls only; changed source gets a new
  assistant/surface, not revision reuse. No source facts are recalculated in SQL.
- `delete`: `{message_id, request_id, expected_revision:N}`. Marks N+1 deleted and
  clears working payload. It does not delete the original answer, call external
  tools or claim physical erasure of the conversation. New save/create fails.
- `head`: `{message_id}`. Authorized reopen discovery for a device with no local
  revision or request ID. Returns current tuple and working state, or not found.
  This is explicit latest-state discovery, never a substitute for exact follow-up.
- `read`: `{message_id, revision:N}`. Same current authority checks; returns only
  exact current N. If N+1 exists, conflict; no silently substituted latest state.
  There is no working revision history service.
- `reconcile`: `{request_id}`. Returns the original small receipt after current
  authorization. Missing receipt is P0002, not proof that a provider did not run or
  permission to replay anything. This operation has no external effects.

Mutation receipt: `{request_id,message_id,surface_id,surface_revision,revision,
deleted}`. It acknowledges the original operation, not the current head. Known
retries compare the entire command's digest before returning it, after authorization
and before current idle/CAS tests. A different action/payload under the same key
rejects. Reconcile after delete can return an earlier creation receipt; the consumer
must not interpret it as a presently live surface. Use authorized head for that.

Digests are SHA-256 over PostgreSQL JSONB text, computed entirely in the database.
They compare normalized JSON values within this protocol, not client bytes, an
ECMAScript canonicalizer, or portable Context source versions. API must send JSON,
not precomputed trusted digests. Lost acknowledgements reconcile original identity;
rollback stores neither state nor receipt. Controlled explicit retry uses the same
command; no automatic re-keying, provider call or workflow restart.

## All writer and delete paths

| Pinned API / database path                                             | Preservation rule                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `persistAssistantMessage` → `upsertChatMessage(update:true)`           | Unenrolled legacy behavior unchanged. Enrolled direct service writes denied by 636. Its required fenced replacement can update message parts, never companion state.                                                               |
| `persistAssistantDataPart` → `updateChatMessage` (auto-commit receipt) | Same rule. Do not replay the external commit to repair a failed save.                                                                                                                                                              |
| `persistLatestUserMessage` → insert-only upsert                        | No assistant companion; enrolled path must use captured 636 writer, fresh IDs for edited intent.                                                                                                                                   |
| `upsertChatMessages` → `scripts/backfill/migrateRoom.ts`               | Insert-only legacy backfill remains forbidden on enrolled chats. No borrowed current epoch.                                                                                                                                        |
| `createFencedMessageWriter` / 636 `write`, `update_parts`              | Source guard compares the complete saved snapshot data part's digest, rejecting changes/removal/duplicates even if other message parts may update. Controls live separately. Source guard is not same-turn stream merge semantics. |
| `deleteTrailingChatMessages` legacy direct DELETE                      | 636 guard denies enrolled deletion. No race workaround via direct helper.                                                                                                                                                          |
| 636 `delete`, `delete_edit`                                            | Same session/chat lock; per-message trigger marks companion deleted and clears controls in the same transaction. Existing tombstones reject stale/fresh-epoch reuse. Rollback restores message and companion together.             |
| Chat/session deletion or identity reassignment; TRUNCATE               | Existing enrolled guards deny cascade/reassignment/truncate. A future purge requires its own explicit contract; no silent bypass.                                                                                                  |

This extension's source trigger runs as invoker and inspects private state only for
the dedicated existing fence owner. Service/browser writers cannot borrow that role;
the existing guard rejects them. Privileged DDL/superuser bypass is outside the
runtime trust boundary. Create waits for existing internal writes under the shared
chat lock; after it commits the exact source part is immutable. Old message content
cannot clobber controls, and changing/removing source invalidates the write rather
than silently retargeting saved work.

## Management and UI acknowledgement

Rename is `save` of companion displayName, not `surface.title` or chat title.
Duplicate is a future orchestrated new assistant/message + surface + `create`, with
parent provenance and explicit current authorization. This proof does not implement
that multi-step transaction, cross-workspace copying, archive, or arbitrary plan edits.
Those require strict recipe/operation additions before runtime use; no existing
session archive shortcut (it can stop a sandbox). Source/working revisions remain
separate. Root/UI accepts this contract before implementing any shared controls.

A save captures immutable submitted content, local edit sequence, scope epoch,
operation ID and expected server revision. If draft B replaces submitted A while
saving, ack A only settles A, updates the known server base monotonically, and leaves
B untouched/unsaved. Scope/operation/content mismatch or older acknowledgement cannot
settle B or roll back a newer known server base. Unknown/conflict retains submission
and current draft; it does not auto-resubmit B. Test A pending → edit B → ack A,
out-of-order A/B acks, account switch, and lost ack followed by reconciliation.
This strengthens #2373 without changing its published head. The amendment received
independent contract review; runtime UI proof remains the UI owner's responsibility.

## Local proof and release boundary

Run on a machine with PostgreSQL binaries, using a disposable socket-only cluster:

```sh
PG_BIN=/opt/homebrew/opt/postgresql@17/bin python3 proposals/durable-surfaces-2207/test_mechanics.py
PG_BIN=/opt/homebrew/opt/postgresql@15/bin python3 proposals/durable-surfaces-2207/test_mechanics.py
```

Harness loads the actual session/chat migration and unchanged 636 SQL, then this
proposal; it verifies the default authorizer denies before replacing it in the
fixture and granting fixture-only execute. Tests cover create/CAS, exact and changed
retries, unknown outcome/readback, rollback, new-device head, exact stale read,
source/companion preservation, permission denial, source-revocation seam, logical
and anchor deletion, deleted-ID reuse, busy/size/shape limits and actual two-connection
lock waits. It does not replay all migrations or claim a live actor, deployed fence,
authenticated device, real source mapping, external action or user outcome.

Keep the source gate closed. Before adoption/activation, root must accept the
placement/API contract; API/Context must implement and independently qualify the
source adapter and strict schemas; existing fence authority/credential/drain gates
must be satisfied; Database owns separately reviewed migration, grants, rollback
and controlled purge design. No numeric retention, backup expiry, artifact identity
or source-withdrawal rule is invented here. Local proof results are recorded in the
PR handoff; do not infer production readiness from them.
