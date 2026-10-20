# Identity-conflict inventory (read-only)

Sanitized companion to recoupable/app#2117 (child of epic #2116). It explains the
standalone audit script `supabase/audits/identity_conflict_inventory.sql`, the
conflict classes it counts, the proposed constraint and handling rule for each
class, the writer paths that can create those classes, the public/private storage
classification, and the schema-verification checklist. It contains no customer
content, no production identifiers and no production counts beyond those already
written into merged migration comments. Detailed findings for a real environment
stay private.

## What the script does

The script is not a migration and changes no schema: a baseline can be taken
before anything identity-related ships, with no release step and no new grant. It
runs as one `BEGIN READ ONLY` transaction that ends in `ROLLBACK`, so PostgreSQL
itself refuses any write. A `DO` block computes aggregate counts and hands the
report to the final `SELECT` through a transaction-local setting, which disappears
with the rollback. The single output row is one `jsonb` document of counts,
statuses and rule text only: no account IDs, names, URLs, ISRCs or provider IDs.
Classes whose source tables are absent report `not_applicable`, so the script is
also safe on fresh preview environments and partial fixtures.

```json
{
  "inventory_version": "identity-inventory-v1",
  "generated_at": "...",
  "mutations": "none",
  "transaction_read_only": "on",
  "bypasses_row_security": true,
  "server_version": "...",
  "migration_history": {"status": "present|not_present|denied", "applied": 0, "latest_version": "..."},
  "classes_with_findings": 0,
  "classes": {"<class>": {"status": "measured|not_applicable", "count": 0, "affected_rows": 0, "rule": "..."}}
}
```

`count` is the number of conflict groups (ids, accounts, resources, name groups or
roster rows, as the table below states); `affected_rows` is the number of link rows
a reviewer would have to look at.

### Running it

Locally, against disposable PostgreSQL with `initdb`, `pg_ctl` and `psql` on PATH.
The suite runs the script file with `psql` exactly as an operator would, seeds every
class synthetically and asserts exact counts, read-only behaviour, the row-security
flag and the research refusal for the duplicated-id class:

```sh
python3 -m unittest discover -s tests -p 'test_identity_conflict_inventory.py'
```

Against the intended environment, only an approved operator, over a connection
whose role can `SELECT` the legacy, catalog and Context tables and bypasses
row-level security (`service_role` or `postgres` on Supabase):

```sh
psql "$READ_ONLY_DATABASE_URL" -X -q -A -t -v ON_ERROR_STOP=1 \
  -f supabase/audits/identity_conflict_inventory.sql
```

A role subject to row-level security would see fewer rows and report silently
smaller counts, so the report states `bypasses_row_security`; a baseline is valid
only when it is `true`. `migration_history` reports `denied` instead of failing
when the role may not read `supabase_migrations.schema_migrations`; the deployed
revision must then be recorded from the database release process. Store the
returned document in the private operational report, not in this repository or in
an issue.

## Conflict classes, constraints and rules

Spotify artist IDs are case-sensitive. Every strict class extracts the id with the
same case-preserving expression that `onboard_spotify_artist` uses
(`20261008040000`), never `lower()`. The 2026-07-29 cleanup grouped on
`lower(profile_url)`, so the lowercase-folded view is its own class rather than being
mixed into the strict counts. One accepted identity per Context resource is already
enforced by the `context_one_accepted_identity` unique index from the foundation
migration, so the Context classes measure the directions that index cannot.

| Class (`count` / `affected_rows`) | Measures | Proposed production constraint | Conflict-handling rule | Compatibility rule |
| --- | --- | --- | --- | --- |
| `spotify_artist_ids_linked_to_multiple_accounts` (ids / account_socials rows; `multiple_graph_owners` = ids with more than one song_artists owner) | One Spotify artist id linked to several accounts through `account_socials` | One artist account per Spotify artist id (partial unique over the extracted id, once existing rows are resolved) | Quarantine for human review. Ids with several graph owners are never collapsed automatically; `onboard_spotify_artist` and `commit_spotify_context` already refuse them (the suite exercises the research refusal). | `account_artist_ids (account_id, artist_id)` stays unique; `song_artists` links stay on their current owner; catalog and measurement readers keep resolving through the existing social link until a reviewer repoints it. |
| `accounts_with_multiple_spotify_artist_socials` (accounts / rows) | One account carrying several Spotify artist ids | At most one Spotify artist id per artist account | Review; a genuine second profile needs an explicit decision, extra links are not dropped. | No reader assumes a single social per account today; a constraint must land after review, not before. |
| `spotify_artist_id_case_variants` (folded groups / socials rows) | Spellings that coincide only after lowercasing | Case-sensitive matching everywhere (already the rule in onboarding and research) | Review candidates; the original case of a lowercased id is unrecoverable and is never guessed. | Readers that still lowercase must be fixed before any constraint; see the writer inventory. |
| `spotify_artist_socials_without_uppercase` (socials rows / rows) | All-lowercase ids, possibly folded by the 2025-05-28 profile-url trigger before the Spotify exemption (`20260805190000` explains the window) | None; this is a verification queue | Re-verify against the provider before relying on the id; never rewrite in place. | None. |
| `context_identity_links_in_conflict_status` (resources / links) | Identity links recorded as `conflict` | Already enforced: a conflict is never promoted implicitly | A reviewer accepts one subject; nothing else changes the status. | Research keeps skipping the legacy lookup once an accepted identity exists; it does not read conflict rows. |
| `context_artist_subjects_with_multiple_accepted_resources` (subjects / links) | One artist subject accepted as the identity of several resources of the same provider and kind | One accepted resource per subject, provider and kind | Review as a possible duplicate profile. | Recording subjects are excluded: one ISRC on several provider track ids is normal. |
| `context_accepted_artist_identities_disagreeing_with_legacy_socials` (resources / legacy rows; `spotify_id_side` and `account_side` split the count) | Disagreement in either direction. Spotify-id side: the accepted id is linked to an account other than the subject's, or to several accounts. Account side: the subject's account carries Spotify artist socials and none of them is the accepted id, for example a social replaced after research | Both sides name the same single account | Disagreement blocks reuse of that identity until reviewed; nothing is attached, replaced or rewritten automatically. | Legacy writers that attach or replace socials after research can create this drift; the audit measures it, #2119 serializes it. |
| `context_accepted_artist_identities_without_legacy_social` (resources / links) | Accepted identity where neither the accepted id nor the subject's account has any legacy Spotify artist social | None; not a defect | Attachment candidate for the explicit onboarding path; nothing is attached without intent. | Explicit onboarding reuses the researched identity (`20261009190000`). An account that already carries a different Spotify id is counted as disagreeing instead, so following this rule can never add a second id to an account. |
| `name_only_artist_accounts_sharing_a_name` (name groups / accounts) | Rostered or attached artists without a Spotify artist social that share a trimmed, lowercased name | Names never identify artists; no name uniqueness | Never merged by name; a reviewer may link them to one subject with evidence. | Same-name creation remains allowed (professional roster confirmation already models this). The name-keyed catalog resolver listed below must stop matching by name before any rule relies on this class. |
| `rostered_artists_without_organization_attachment` (roster rows / artists) | A personal roster row whose account belongs to organizations the artist is attached to none of | None; a personal roster is a supported state | Organization attachment only through the explicit onboarding operation with membership checked in the transaction. | Existing personal rows are neither removed nor reinterpreted. |
| `organization_artists_without_member_roster` (attachments / artists) | An organization attachment no member rosters | None | Review for staleness; attachment is a business relationship and is not removed automatically. | Company roster readers must tolerate attachments without a member roster row. |
| `provider_track_values_mapped_to_multiple_songs` (values / mapping rows) | One `track_id` value on several ISRCs (`album_id` legitimately maps to many songs since `20260611120000`) | One provider track id per ISRC | Quarantine; research already refuses to attach such a track to a different ISRC. ISRCs are never invented or reassigned. | `songs.isrc` foreign keys, playcount and catalog readers keep working on the existing non-unique reverse index until resolved. |

Every rule names recoupable/app#2119 as the owner of enforcement, quarantine and
cleanup. This slice adds no constraint, trigger, backfill, merge or deletion.

There is no class for the 2026-07-29 cleanup manifests: `20260729210000` dropped
`zz_dupe_manifest_20260729` and `zz_cleanup_manifest_20260729b` after both cleanup
passes were verified, so no environment with the full migration history has them.

Two existing matchers differ and are left as they are for #2119 to reconcile:
`onboard_spotify_artist` accepts `intl-xx/` paths and `spotify:artist:` URIs;
`commit_spotify_context` matches only `open.spotify.com/artist/<id>` with an
optional trailing slash after stripping the query. The audit uses the broader
onboarding expression.

## Affected writer paths

Paths that insert, update or delete rows in `accounts`, `socials`,
`account_socials`, `account_artist_ids`, `artist_organization_ids`, `songs`,
`song_identifiers` or `song_artists`, found by searching each application for its
Supabase access-layer writers and their callers, then following callers until a
route, handler or tool (test files excluded; searched at api `c72887a` and app
`025342d`). Paths are relative to the api and app repositories. Directories such
as `lib/sites`, `lib/players`, `lib/fans`, `lib/transcribe`, `lib/composio`,
`lib/auth` and `lib/account` showed no writer for these tables in that search. Raw
SQL and RPC-side writes outside the access layers are covered only where named.

### api

| Category | Access-layer writers (`lib/supabase/...`) | Callers |
| --- | --- | --- |
| Roster and onboarding | `account_artist_ids/{upsertAccountArtistId,deleteAccountArtistId,updateAccountArtistPinById}`, `artist_organization_ids/addArtistToOrganization`, `artists/{onboardSpotifyArtist,createArtistWithRoster}` (RPC wrappers) | `lib/artists/{createArtistInDb,updateArtistHandler,deleteArtist,setAccountArtistPin}`, `lib/accounts/linkArtistToAccount`, `lib/organizations/addArtistToOrgHandler` |
| Catalog-to-roster side effect | `account_artist_ids/upsertAccountArtistId` through `lib/catalog/attachCanonicalArtistToAccount` | `lib/catalog/createCatalogHandler` and `lib/valuation/runValuationHandler`: creating a catalog or running a valuation resolves the dominant `song_artists` account of the claimed ISRCs and upserts it onto the caller's roster. This is the catalog-implies-roster coupling the epic's architecture gate asks to audit; #2119 decides whether it stays explicit. |
| Account provisioning | `accounts/{insertAccount,updateAccount,deleteAccountById}` | `lib/accounts/{createAccountHandler,getOrCreateAccountByEmail,updateAccountHandler}`, `getOrCreateAccountByEmail` from `lib/organizations/addOrgMemberHandler` and `lib/stripe/checkout/findOrCreateAccountForCheckout`, `lib/agents/createAccountWithEmail` (from `lib/agents/{handleNormalSignup,handleAgentPrefixSignup}` and `lib/privy/getOrCreateAccountIdByAuthToken`), `lib/organizations/createOrganizationHandler` |
| Name-keyed catalog association | `songs/getPreferredArtistAccountIds` matches `accounts.name` case-insensitively with `ilike` and creates an account per unmatched name | `lib/songs/linkSongsToArtists` (then `song_artists/insertSongArtists`), from `lib/songs/processSongsInput` and `lib/research/playcounts/mapUnmappedAlbumTracks`. This is the questionable name-based association path: it feeds `name_only_artist_accounts_sharing_a_name` and can link songs to a same-name account. |
| Profile and knowledge | `socials/upsertSocials`, `account_socials/{insertAccountSocial,deleteAccountSocial}`, `account_info/{insertAccountInfo,updateAccountInfo}` | `lib/artist/{updateArtistSocials,updateArtistProfile,deleteArtistSocialHandler}`, `lib/socials/upsertSocialsWithSnapshot`, `lib/apify/persistPostsForSocial`, `lib/apify/instagram/` |
| Catalog | `songs/{upsertSongs,updateSong}`, `song_identifiers/upsertSongIdentifiers`, `song_artists/insertSongArtists` | `lib/songs/{processSongsInput,linkSongsToArtists}`, `lib/artist/resolveSongArtwork`, `lib/research/playcounts/` |
| Funnel and valuation | as above | `lib/valuation/enrichSearchedArtistProfile` (and `runValuationHandler`, above) |
| Research (Context) | `context_requests/callContextRpc` → `commit_spotify_context` (SQL writes to `accounts`, `account_info`, `socials`, `account_socials`, `songs`, `song_identifiers`; roster inserts removed by `20261009190000`) | `lib/context/runContextRequest` |
| MCP | `accounts/updateAccount` and `account_info/updateAccountInfo` (artist profile edits) | `lib/mcp/oauth/createOAuthToolServices`. API-key requests provision accounts through `lib/mcp/verifyApiKey` → `lib/privy/getOrCreateAccountIdByAuthToken` → `lib/agents/createAccountWithEmail`. |
| Sites | none found for these tables | `lib/sites`, `lib/sites/production` read only in that search |

### app (chat)

| Category | Path | Notes |
| --- | --- | --- |
| Roster, organization and socials through the api | `lib/artists/{createRosterArtist,deleteArtist,deleteArtistSocial}`, `lib/saveArtist`, `hooks/useAddArtistToOrganization` | HTTP calls to the api (`/api/artists`, `/api/artists/{id}`, `/api/artists/{id}/socials/{socialId}`, `/api/organizations/artists`), so the api rows above apply. |
| Direct access-layer writers without live callers | `lib/supabase/account_artist_ids/{insertAccountArtistId,deleteAccountArtistId}`, `artist_organization_ids/addArtistToOrganization`, `socials/insertSocials`, `account_socials/{insertAccountSocial,deleteAccountSocial}`, `updateArtistSocials`, `artist/{createAccountInfo,updateArtistProfile,associateArtistWithAccount}`, `ensureArtistAccess`, `accounts/{createAccount,insertAccount,updateAccount,deleteAccountById,insertAccountWallet}` | No caller reaches them in that search: components import only the `ArtistProfile` type from `updateArtistProfile`, and the only other references are between these files. They bypass the api's identity rules, so #2119 should remove them or keep them unreachable before constraints ship. `app/api/in_process/` creates a Coinbase wallet (`cdp.evm.createAccount()`), not an `accounts` row. |

Live identity writes from the app therefore go through the api; the constraints
proposed above apply to both applications at once.

## Storage-path classification

Classified from the migrations in this repository and the api code map; no
customer content was read or copied.

| Classification | Paths |
| --- | --- |
| Public, shared identity and evidence | `socials`, `account_socials` (provider profile metadata), `context_resources`, `context_subjects`, `context_resource_links` (shared public identity, service-only grants, RLS enabled, foundation `20260920010000`) |
| Public storage buckets | `public-uploads`, `site-assets` (`public = true`; Sites assets and uploads) |
| Private, workspace-scoped | `context_requests` input/output, `context_sources`, `context_source_versions`, `context_results`, `context_documents` (owner-scoped), brief snapshots (`20260926170000`), campaign brief and supporting-text entries (`20260925120000`, `20260925130000`), songwriter and company name entries (`20260925100000`, `20260925110000`), guest workspaces (`20260920040000`), audio sources (`20260927090000`), company assessments (`20261010010000`) |
| Private storage buckets | `context-private` (restrictive server-only policy, foundation migration), private audio storage (`20260929070000`), `user-files` (`public = false`) |
| Legacy risk, not for company or contract documents | The permanent Arweave upload route (`api/lib/arweave/*`, reached today from the x402 image-generation route and the `account_info.knowledges` knowledge-base tools) and the `files` table keyed by `artist_account_id` with artist-scoped sharing columns (`20250910120000`). The epic's architecture gate forbids both as shortcuts for private documents. |
| Retained originals | Pending the open api#986–#991 and database#94/#95 series; nothing in this slice reads or references those tables. |

## Schema-verification checklist

For the intended environment, read-only, before any identity constraint ships:

1. Migration history: every file through `20261010100000_player_organization_contacts.sql` is applied; the audit's `migration_history.latest_version` reports the newest applied version when the role may read `supabase_migrations.schema_migrations` (`denied` is reported, not raised, otherwise). The audit itself adds nothing to that history.
2. Grants: the Context tables keep `service_role`-only grants; the onboarding RPCs (`onboard_spotify_artist`, `create_artist_with_roster`, `commit_spotify_context`) remain `SECURITY INVOKER` and `service_role`-only.
3. RLS: enabled on every Context evidence table and on the roster/membership tables, with no browser-role policies on Context tables.
4. Constraints relied on by the compatibility rules: `account_artist_ids_account_id_artist_id_key`, `artist_organization_ids_artist_id_organization_id_key` (`20260708200000`), `song_identifiers_song_platform_type_value_unique` plus the non-unique reverse index (`20260611120000`), `context_one_accepted_identity`, `socials_profile_url_key`.
5. Triggers: `clean_socials_profile_url` is the `20260805190000` version (Spotify host exempt from lowercasing; YouTube channel ids preserved).
6. CI matrices: `release-cases.yml`, `artist-onboarding.yml`, `release-players.yml`, `credit-charge-receipts.yml` and the new `identity-inventory.yml` pass on the PR head.

## Live access

No hosted database was read in this slice. The audit was implemented and
fixture-tested on disposable PostgreSQL 15 and 17 locally; CI runs it on 15 and 16.
The latest live verification of the deployed schema is the 2026-10-08 read-only
production prerequisite audit (database PR86, epic #2116), which confirmed
PostgreSQL 15.6, the prerequisite Context migrations, service-role grants and RLS
on the Context evidence tables. That audit counted no identity conflicts.
Production conflict counts remain unrecorded until an approved operator runs this
script read-only; the result belongs in the private operational report. No
migration or release step is needed first.

The only historical production measurements are comment lines in merged
migrations, all from one-off cleanups that pre-date the Context tables and all
grouped on `lower(profile_url)`, so they are not directly comparable with the
case-sensitive classes above:

- `20260707190000`: candidate funnel-minted duplicate roster rows measured on
  2026-07-08 before they were repointed.
- `20260729060000`: Spotify ids with more than one linked artist account measured
  on 2026-07-29 before the collapse.
- `20260729210000`: after both 2026-07-29 cleanup passes, "0 Spotify ids resolve to
  >1 artist", and the manifests were dropped. This is the prior baseline for
  `spotify_artist_ids_linked_to_multiple_accounts`.

## Boundaries

Implemented and fixture-tested only. Not connected to HTTP or MCP, and not a
migration: nothing is deployed, so the api and docs repositories are untouched. No
constraint, trigger, backfill, merge, deletion or production mutation. No
identifier is invented; unknown stays unknown and `not_applicable` and `denied`
remain distinct states.
