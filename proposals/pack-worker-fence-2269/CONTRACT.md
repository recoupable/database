# Paired execution and claim contract

Implemented as inactive proposal SQL; see [README](README.md) for qualification and rollout boundaries. Current production/legacy commands remain unfenced. The preceding investigation found delayed phase, finish, context, run, settle, claim, dispatch and same-attempt-resume writes could mutate newer work. The proposal addresses those source-contract counterexamples; local tests are not a claim of hosted enforcement.

## Identity and ownership

Existing jobs default to protocol 1. A new protocol-2 prepare is explicit; an existing legacy job cannot be adopted. A guarded legacy wrapper rejects protocol-2 jobs, including idempotency-key resolution, and retains the original command for protocol 1. The original command is renamed to a private internal function; service-role direct Pack INSERT/UPDATE/DELETE and internal-function execution are revoked. Current API Pack persistence uses the RPC, not raw table DML. A future rollout must inventory other callers before applying those grants.

Each newly accepted approval/resume creates an execution UUID and increasing job execution version. The transition request UUID and complete JSONB payload are retained. Source execution/version and creative revision are compare-and-set inputs. Resume also compares the original asset attempt/claim. Exact accepted transition replay returns its recorded result with `dispatch=false`; conflicting payload reuse refuses. Replay lookup precedes source-generation comparison, so an old accepted transition can be inspected without regaining write authority. An unseen stale resume cannot rotate a newer generation.

The workflow receives the original accepted execution as an immutable launch argument. `run` binds one actual Workflow ID, null-to-ID or same-ID only; workflow IDs are unique across executions. Preparation checks the original identity again after reading the job. Production compares actual Workflow metadata before claiming. No worker repairs a mismatch using a current-row identity.

A claim belongs to one execution and asset. New paid claims increment the existing attempt through the original command; uncertain resume preserves the paid attempt, billed credits and provider state but creates a new claim. Its immutable operation-ID array grants continuation of existing receipts. A deterministic claim request UUID is payload-bound. A repeated claim returns `claimed=false,replayed=true` and the API stops for reconciliation: an acknowledged old claim is not a second production permit.

## Atomic write rules

All commands recheck actor/org access; current organization membership is locked through the transaction. The lock order is job, then asset. Every worker validates revision, execution UUID/version and bound Workflow ID **before** expiry can settle/refund anything. Phase/finish additionally validate attempt/claim and retained execution association. Missing/null/wrong identities refuse as well as older valid identities.

| Command | Additional rule |
| --- | --- |
| `run` | Compare-and-set Workflow ID; cannot adopt another run. |
| `dispatch_uncertain` | Original generation required; a bound run is not overwritten. |
| `claim` | Original expected pending attempt; one claim per execution/asset. |
| `phase` | Full claim fence; provider intent, request identity and transition order immutable; receipt append acknowledged before accepted/complete write. |
| `finish_asset` | Full claim fence, including catch writes; exact completion replay only. An incomplete provider submission cannot become a confirmed failure. |
| `context` | Original execution plus expected context version; acknowledged updates advance that version. Foundation read-modify-write preserves original execution. |
| `settle` | Original execution; retained exact terminal replay, one refund. Different payload refuses. |
| `prepare` update, `estimate`, `export` | Expected revision; retry estimate also compares expected failed attempt. |
| `read` | Authorized current-row recovery may expire current work; it is not an old worker write permit. |

Stale refusal changes no Pack, wallet or usage state, including after the newer hold expires. A current admitted expiry settles once and records the terminal execution result. A subsequent worker call may receive a terminal refusal rather than a fresh permit; authorized read returns current state. Lost acknowledgements require reconciliation.

Provider registration occurs atomically with `submitting`, before external I/O. A duplicate registration reports `operation_created=false`; the API never submits on that response. Accepted request charging remains inside the original command and occurs once. Completed state requires prior accepted state and its charge; changed request IDs, input/model/price, regression and conflicting completed payloads refuse. Existing non-provider phase values also cannot be overwritten with a different value.

Allowed models and charges come from the quote's frozen execution configuration. Image slots are 0–3 for carousel, otherwise 0; motion is video-only. A retained ready foundation can select the quote's image-edit model for a dependent only when the supplied plan/asset digests match current durable context, job/owner/revision/quote match, the exact dependent attempt is bound, and the source artwork is completed. Original quote references otherwise determine image versus image-edit. No new rates are introduced.

## API failure boundary

Protocol 2 is an internal optional admission argument, never inferred from public request fields or environment flags. The existing public calls and legacy Workflow argument shapes remain unchanged. All normal and catch writes carry original fences. Receipt append has its own transaction and is acknowledged before an active phase write. A refused/uncertain write raises a fence error without provider resubmission or catch-path finish.

The Workflow SDK reconstructs step errors, so the protocol-2 workflow stops on **any** rejected step rather than relying on a custom error class crossing that boundary. Settlement uses the existing zero-retry bounded step outside the production catch path. A lost settlement acknowledgement causes one attempt, no automatic retry. The legacy workflow retains its existing handling. Unwired bounded/foundation adapters propagate the same original admission and attempt identities; they are not activated by this change.

## Evidence and limits

Actual PostgreSQL checks cover stale writers before/after expiry, same-attempt resume, transition/claim/completion/settlement replay and conflict, concurrent claim/intent registration, context CAS, atomic charge refusal, receipt retention/access/bounds and the existing legacy controls. The paired API-to-PG fixture covers real claim/intent/journal/charge/completion, claim replay refusal, mismatched actual Workflow identity, foundation-dependent image-edit and a committed acceptance surviving an actual phase refusal without catch finish or charge. Compiled local SDK checks cover step failure, lost settlement acknowledgement and terminal replay, with networking denied.

This does not cancel already-issued provider work, guarantee an external I/O fence stays current, attest provider responses, recover a response lost before durable recording, establish cache/QA freshness, or make legacy executions safe. Unknown intent cannot be automatically resubmitted. Operator reconciliation, rollout, hosted SQL, provider execution, paid runtime, renderer activation and customer outcomes remain outside this contribution.
