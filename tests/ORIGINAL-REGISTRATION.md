# Private original registration receipts

Run `python3 -m unittest discover -s tests -p 'test_original_registration.py'`
with PostgreSQL binaries on PATH. Eleven new cases plus one inherited release case
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

The separately reviewed [internal retrieval lookup](./ORIGINAL-RETRIEVAL.md)
reuses the receipt authority without exposing paths in ordinary receipt reads.
