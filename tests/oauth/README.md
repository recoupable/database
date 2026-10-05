# OAuth provider store acceptance tests

Part of [Mono #209](https://github.com/recoupable/mono/issues/209), under [MCP OAuth epic #207](https://github.com/recoupable/mono/issues/207).

```sh
PG_BINDIR=/path/to/postgresql/bin tests/oauth/run.sh
```

Requires Python 3 and PostgreSQL server binaries. The runner creates a new temporary cluster with no TCP listener, uses an isolated Unix socket, applies only the OAuth migration, runs tests, then stops and removes that cluster. It never reads DATABASE_URL or connects to Supabase. The bootstrap roles are test-only. It does not prove compatibility with the entire Supabase migration history.

## Adapter contract

The API adapter must use a stable issuer/environment namespace and SHA-256 (or keyed, stable hashing) of provider identifiers before calling the RPCs. `payload` is an opaque text envelope: encrypt and authenticate the provider JSON using managed versioned keys, random nonces and associated data that binds namespace/model/id. This database migration cannot establish that a caller encrypted its payload; the adapter's encryption tests are a separate required gate.

- `oauth_store_upsert`: save ciphertext and secondary hashed indexes. `expires_in` is seconds (1 through 31 days), or null for non-expiring client registrations. A Grant binds to its own hashed ID. Existing grant binding and consumed marker cannot be overwritten by a stale save.
- `oauth_store_find`: look up by `id`, `uid`, or `user_code`. Returns ciphertext plus a database-authoritative consumed epoch, or null for expired, revoked, or absent records. The adapter must override any consumed marker in its decrypted JSON with this database value.
- `oauth_store_consume`: compare-and-set; only one caller gets true. The adapter MUST throw an invalid-grant error on false; ignoring the result would defeat the replay protection.
- `oauth_store_revoke_grant`: write a retained revocation marker and delete associated artifacts in the same transaction. Grant-scoped upserts take the same advisory lock and reject after revocation.
- `oauth_store_destroy`: delete a single artifact; destroying a Grant revokes its entire family.

RLS is enabled with no client policies. Functions are security-invoker, explicitly schema-qualified, and executable only by service_role. The service role has explicit table access. Database errors must fail authentication closed and be redacted by the adapter.

## Scope and release

This is a storage foundation. It does not enable OAuth, link Privy identities, create consent/connection records, issue credentials, cancel jobs, or change existing account permissions. Apply the migration before deploying an adapter that calls these functions. Keep production rollout gated by the epic's auth and client verification requirements.

Do not delete revocation markers until all potential associated artifacts and in-flight issuance windows have expired. A future bounded maintenance operation can purge expired artifacts; this PR does not add a scheduler. Revocation reads are authoritative, without positive auth caching.

Rollback: first disable OAuth issuance/callers. Do not drop tables holding active grants while clients still depend on them. Since this additive migration has no production callers yet, pre-launch rollback may drop the five functions and two new tables after confirming no OAuth deployment has been enabled. Never reset unrelated Supabase data.
