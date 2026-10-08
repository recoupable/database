# Spotify onboarding transaction tests

Run against disposable local PostgreSQL, without hosted credentials:

```sh
python3 -m unittest discover -s tests -p 'test_spotify_onboarding.py'
```

`initdb`, `pg_ctl`, and `psql` must be on PATH from the same installation. The runner creates a temporary cluster with a Unix socket and no TCP listener, then stops and removes it. It uses synthetic records and a minimal fixture schema plus the actual profile-normalization trigger migrations; this is not a full Supabase migration replay or hosted verification.

Coverage: new/existing exact identity, case-sensitive namesakes, retries, 16 concurrent requests, ambiguous mappings, non-admin membership/revocation, lookup failure, attachment rollback, personal-to-organization attachment, supported Spotify URI and URL forms, unrelated hosts, execute privileges, normalized social persistence, and atomic name-only creation. GitHub Actions runs this suite on each PR.

## Release order and boundary

Preserve the existing `20261008010000_oauth_persistent_connections.sql` migration from main. Apply `20261008020000_onboard_artists_atomically.sql` and `20261008030000_onboarding_membership_lock_privilege.sql` before deploying the API consumer. It adds service-role-only, security-invoker functions. It does not clean up existing data, add global identity constraints, change canonical mappings, or assign catalog/publishing rights. Existing ambiguous mappings are rejected for review.

Before rollout, verify the target has the existing unique roster-pair constraints, test the function with the service role in an isolated environment, and confirm the API's normal membership authorization. Concurrent requests through this function are serialized; unrelated legacy writers do not acquire this lock and remain part of the broader identity work in recoupable/app#2119.

Hosted acceptance remains: authenticated UI request, API response, persisted organization membership readback, refresh/new-session/workspace switching, and a denied non-admin account. Local fixture success does not establish that the migration has been applied or that production is fixed.

The hosted preview initially rejected `FOR SHARE` because its service role had SELECT but no UPDATE privilege on memberships. The final migration grants UPDATE only on `updated_at`, which is sufficient for row locking. Tests mirror the observed table grants and verify that changing either membership identity is not permitted. No manual dashboard grant is required.
