# Spotify onboarding transaction tests

Run against disposable local PostgreSQL, without hosted credentials:

```sh
python3 -m unittest discover -s tests -p 'test_spotify_onboarding.py'
```

`initdb`, `pg_ctl`, and `psql` must be on PATH from the same installation. The runner creates a temporary cluster with a Unix socket and no TCP listener, then stops and removes it. It uses synthetic records and a minimal fixture schema plus the actual profile-normalization trigger migrations; this is not a full Supabase migration replay or hosted verification.

Coverage: new/existing exact identity, case-sensitive namesakes, retries, 16 concurrent requests, ambiguous mappings, non-admin membership/revocation, lookup failure, attachment rollback, personal-to-organization attachment, supported Spotify URI and URL forms, unrelated hosts, execute privileges, normalized social persistence, and atomic name-only creation. GitHub Actions runs this suite on each PR.

## Release order and boundary

Preserve the existing `20261008010000_oauth_persistent_connections.sql` migration from main. Apply `20261008020000_onboard_artists_atomically.sql` and `20261008030000_onboarding_membership_lock_privilege.sql`, then `20261008040000_recheck_spotify_social_owner.sql` before deploying the API consumer. It adds service-role-only, security-invoker functions. It does not clean up existing data, add global identity constraints, change canonical mappings, or assign catalog/publishing rights. Existing ambiguous mappings are rejected for review.

Before rollout, verify the target has the existing unique roster-pair constraints, test the function with the service role in an isolated environment, and confirm the API's normal membership authorization. Concurrent requests through this function are serialized; unrelated legacy writers do not acquire this lock and remain part of the broader identity work in recoupable/app#2119.

Hosted acceptance remains: authenticated UI request, API response, persisted organization membership readback, refresh/new-session/workspace switching, and a denied non-admin account. Local fixture success does not establish that the migration has been applied or that production is fixed.

The hosted preview initially rejected `FOR SHARE` because its service role had SELECT but no UPDATE privilege on memberships. The final migration grants UPDATE only on `updated_at`, which is sufficient for row locking. Tests mirror the observed table grants and verify that changing either membership identity is not permitted. No manual dashboard grant is required.

CI pins Ubuntu 24.04 and PostgreSQL 16; local validation also covers PostgreSQL 17. The final migration rejects a social row claimed by a legacy writer between lookup and insertion; a retry resolves the committed owner. It cannot serialize all future writes by unrelated legacy code.

## Manual professional roster

Run `python3 -m unittest discover -s tests -p 'test_professional_roster.py'` for eleven isolated tests covering new/existing records, both roles, explicit confirmation, same-name ambiguity, concurrent retries, revoked access including replay, cross-workspace denial, rollback, client-role denial, and pagination.

Apply migrations `20261008050000` through `20261008050300` before the API and app consumers. This slice requires the existing membership-lock privilege from `20261008030000`. Professional records and request receipts are organization-private with RLS, service-role-only table access, and membership-checked invoker RPCs. The fixture models the hosted service role's BYPASSRLS attribute.

An operator confirmation is a scoped assertion, not globally verified identity. New records create no login account; existing IDs can only be reused inside their organization. Roles create no publishing, royalty, catalog, or company authority. There is no automatic name merge, enrichment, personal-context import, or cross-organization identity linkage. Submitted-name Context intake remains separate.

Replaying the same organization/actor/key and normalized input returns the saved response after a fresh access check. A changed request conflicts. A deliberate new key can create a same-name person after explicit confirmation; the system does not claim names uniquely identify people. No production records are changed by these tests.


Research-to-roster isolation: see [RESEARCH-ROSTER.md](RESEARCH-ROSTER.md) for the
real transaction suite, preserved evidence, explicit enrollment and deployment limits.

## Organization-owned player fan contacts

Run `python3 -m unittest discover -s tests -p 'test_player_org_fans.py'` on disposable local PostgreSQL. The suite applies the actual `20261010100000_player_organization_contacts.sql` migration to legacy synthetic fan data and exercises backfill, stable relationship/session IDs, latest non-null contact profiles, parallel sign-ins, separate provider identities despite identical emails, cross-workspace isolation, browser-role denial and existing playback/reporting behavior. CI runs both player suites on PostgreSQL 15 and 16.

Rollout: apply the contact migration before deploying API readers of `contact_id` / `player_fan_contacts`. Existing `connect_player_fan` callers continue working through the new trigger. Artist relationships keep their original IDs; sessions and events are not reassigned. Workspace contacts never merge by email/name or across owners. The migration locks player_fans while backfilling and installing its composite identity FK; new connections can wait briefly during deployment. On API rollback, retain the additive contact schema and trigger so previously deployed capture still maintains contacts. Do not drop the new contacts or remove relationship/session history as a rollback shortcut. Live post-deployment verification is still required.

## Songwriter identity resolution

Run `python3 -m unittest discover -s tests -p 'test_songwriter_identity_resolution.py'` on
disposable local PostgreSQL (on macOS set a valid locale first, for example `LC_ALL=C`, or the
disposable postmaster refuses to start). The suite applies the Context foundation and release
prerequisites, the catalog and songwriter-name entry migrations, the professional roster table
and confirmation RPC, then `20261010213600_context_songwriter_identity_resolution.sql`.

Coverage: a saved songwriter-name request is linked to one explicitly selected organization
professional and its target reads `identityConfirmed: true` with the professional ID; exact
replays and sixteen parallel identical calls yield one receipt; the same key for a different
request, professional or actor conflicts; a second professional for a resolved request is
rejected rather than overwritten; a professional from another workspace or an unknown ID is
denied; revoked and never-granted membership are denied, including replay; same-name
professionals remain candidates until an ID is selected; unready, withdrawn and invalid-key
requests are rejected; browser roles cannot read or execute; and a failed receipt insert rolls
back the request output update.

Apply the migration after `20260925100000_context_songwriter_name_entry.sql` and
`20261008050000`–`20261008050300` and before the API consumer. The receipt table is
organization-private with RLS and service-role select/insert only; the invoker RPC rechecks
membership, locks the request and the professional, and changes only the request output
(`resolvedProfessionalId`, gap removed). It creates no professional, roster member, login
account, enrichment or rights. Local fixture success is not hosted verification.
