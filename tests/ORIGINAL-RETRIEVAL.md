# Retained original lookup (internal only)

Depends on Database #94's registration/receipt migration. The initial migration
is unchanged; this forward-only function uses the existing receipt reader to
check actor/workspace access, retained source/version identity, withdrawal,
removal and mutation. Its row locks remain held in the same transaction while
`get_context_original_retrieval` returns that exact version's private path.

The return is a server-only tuple: existing receipt fields plus bucket and
storage_path. Browser roles cannot execute it. The ordinary receipt reader still
withholds paths. Do not put this internal response into a public HTTP/MCP result.
No new rows, accepted enrichment, identity, rights, signing or provider calls.
Service-role infrastructure remains trusted, as with existing Context RPCs.

A future server adapter must validate owner/receipt/source/version/path metadata,
load and verify the actual private bytes against fingerprint/size/type, then
recheck the current receipt/access/withdrawal before delivery or a brief signed
URL. This function neither checks storage contents nor makes objects immutable.
Its locks end at transaction completion; authorization is not a permanent grant.
Signed bearer URLs cannot promise immediate revocation after issuance and must
never be persisted as evidence. No original acquisition/retrieval caller yet.

Seven new transaction cases plus one inherited release-case execution cover
exact receipt/location readback, fresh owner/member sessions, foreign existing
and missing receipts, revoked membership, withdrawal/removal, path/content/digest
mutation, exact version history and both browser-role denials. The combined
original receipt/retrieval suite runs 26 executions per PostgreSQL version.
Six new cases failed before implementation; all data are synthetic in disposable
clusters. No hosted bytes, URLs or business rows are exercised. Bounded staging,
immutable object acquisition and safe orphan reconciliation remain required.

Run with PostgreSQL executables on PATH:

```sh
python3 -m unittest discover -s tests -p 'test_original_*.py'
```
