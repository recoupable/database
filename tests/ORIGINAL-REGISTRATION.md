# Private original registration receipts

Run `python3 -m unittest discover -s tests -p 'test_original*.py'`
with PostgreSQL binaries on PATH. Fifteen registration cases plus two inherited release executions
run in a disposable cluster; no hosted bytes, identities or balances are used.
CI covers PostgreSQL15/16; local checks also cover17.

The migration adds service-only invoker register/read RPCs using existing
customer sources and source versions. The selected owner is freshly authorized
for registration, receipt read and replay. A stable logical source UUID differs
from the SHA256 byte version and owner-scoped retry key. Equal retry payload
returns the original receipt; changes conflict. New bytes at a new private key
retain old versions. Removed/withdrawn evidence and modified retained metadata
are denied. Receipt rows cannot be updated/deleted by the service role.

This trusts byte metadata from the server verifier; SQL does not fetch or hash
storage objects. No public caller may submit a path/digest and claim verification.
It creates no accepted result, observed identity, rights approval or artist.
Responses omit storage paths and raw contents. The uploaded contents remain
unreviewed customer evidence; a byte hash does not prove contractual accuracy.

Object paths cannot be rebound to different sources/bytes through these RPCs.
This is metadata binding, not proof that storage cannot be overwritten: future
upload must use immutable version-bound keys, enforce acquisition limits and
handle staging/orphans. Original retrieval must recheck current scope, withdrawal
and bytes before minting any short-lived URL. No upload or signed-read surface
is added here. Raw legacy service-table writers remain outside this operation;
read guards reject inconsistent content/path/digest metadata.

Before approved rollout audit current source/version schema, actor authorization,
lock/table prerequisites and normal migration integration. Verify service-only
permissions and migration body afterward. No production rollout or actual
customer registration is claimed by local/CI/preview results.

The forward-only `20261009230100` migration adds a partial owner/storage-path
index for retained object conflict probes. It excludes versions without objects.
No constant-time lookup or production index performance is claimed. Earlier
preview-applied original-registration and neutral-path migrations are unchanged.

`20261009230200` serializes source creation among callers of this RPC after the
owner retry lock. Raw service-table writers do not participate in that lock. A forced cross-owner race returns one saved receipt and one controlled
access denial; source IDs cannot be claimed across owners. Removal coverage restores
content and proves the receipt readable before testing removal denial on read/replay.
Index build timeouts remain bounded (5s lock/30s statement): production size and
lock preflight is required before approved rollout, and a timeout aborts rather
than permitting an unbounded writer block. This is not proof of production scale.

Forward-only `20261009230300` makes source-lock acquisition nonblocking: a
contended source returns the existing controlled unavailable denial immediately.
A held-lock fixture failed before this change and passes afterward. Migration
SET LOCAL timeouts apply only to migration execution, not later RPC invocations.
Owner advisory and row locks still use the caller session timeout; this change
does not claim a whole-operation runtime bound or protection from raw writers.
