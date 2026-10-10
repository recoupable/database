-- Read-only identity-conflict inventory (recoupable/app#2117, child of #2116).
--
-- One service-only, security-invoker, STABLE function that returns aggregate
-- counts for the identity-conflict classes the Context Engine must not inherit
-- silently: duplicated provider artist mappings, questionable name-keyed
-- associations, incomplete organization attachments, provider track values on
-- several recordings, and disagreements between accepted Context identities and
-- the legacy social links. It returns counts only: no account IDs, names, URLs,
-- ISRCs or provider IDs ever leave the database through this function.
--
-- It never writes. It adds no constraint, trigger, backfill, merge or cleanup;
-- enforcement and quarantine of each class stay with recoupable/app#2119.
-- Classes whose source tables are absent report status 'not_applicable', so the
-- function is safe on fresh preview environments and partial fixtures.
--
-- Spotify artist IDs are case-sensitive. Extraction uses the exact, case-preserving
-- expression from onboard_spotify_artist (20261008040000), never lower(); the
-- 2026-07-29 cleanup grouped on lower(profile_url), so the lowercase-folded view
-- is reported as its own class instead of being mixed into the strict counts.
begin;

create or replace function public.read_context_identity_conflict_inventory()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  c_spotify_artist constant text :=
    '^(?:(?:https?://)?open[.]spotify[.]com/(?:intl-[a-z]{2}/)?artist/|spotify:artist:)([A-Za-z0-9]{22})(?:[/?#].*)?$';
  v_has_socials boolean := to_regclass('public.socials') is not null
    and to_regclass('public.account_socials') is not null;
  v_has_song_artists boolean := to_regclass('public.song_artists') is not null;
  v_has_roster boolean := to_regclass('public.accounts') is not null
    and to_regclass('public.account_artist_ids') is not null
    and to_regclass('public.artist_organization_ids') is not null
    and to_regclass('public.account_organization_ids') is not null;
  v_has_context boolean := to_regclass('public.context_resources') is not null
    and to_regclass('public.context_subjects') is not null
    and to_regclass('public.context_resource_links') is not null;
  v_has_song_identifiers boolean := to_regclass('public.song_identifiers') is not null;
  v_has_dupe_manifest boolean := to_regclass('public.zz_dupe_manifest_20260729') is not null;
  v_has_cleanup_manifest boolean := to_regclass('public.zz_cleanup_manifest_20260729b') is not null;
  a_count bigint := 0; a_rows bigint := 0; a_owners jsonb := to_jsonb('not_applicable'::text);
  b_count bigint := 0; b_rows bigint := 0;
  c_count bigint := 0; c_rows bigint := 0;
  c2_count bigint := 0; c2_rows bigint := 0;
  d1_count bigint := 0; d1_rows bigint := 0;
  d2_count bigint := 0; d2_rows bigint := 0;
  d3_count bigint := 0; d3_rows bigint := 0;
  e_count bigint := 0; e_rows bigint := 0;
  f_count bigint := 0; f_rows bigint := 0;
  g_count bigint := 0; g_rows bigint := 0;
  g2_count bigint := 0; g2_rows bigint := 0;
  h_count bigint := 0; h_rows bigint := 0;
  i_dupe bigint := 0; i_cleanup bigint := 0;
  v_owners bigint;
  m_count bigint; m_latest text;
  v_history jsonb;
  v_classes jsonb;
  v_findings integer;
begin
  -- (a)-(c2): legacy Spotify artist socials. Only links to accounts count; an
  -- orphan socials row plays no part in identity resolution.
  if v_has_socials then
    with links as (
      select substring(s.profile_url from c_spotify_artist) as spotify_id, s.id as social_id, ac.account_id
      from public.socials s
      join public.account_socials ac on ac.social_id = s.id
      where substring(s.profile_url from c_spotify_artist) is not null
    ),
    by_id as (
      select spotify_id, count(*) as link_rows, count(distinct account_id) as accounts
      from links group by spotify_id
    ),
    by_account as (
      select account_id, count(*) as link_rows, count(distinct spotify_id) as ids
      from links group by account_id
    ),
    by_folded as (
      select lower(spotify_id) as folded, count(distinct spotify_id) as spellings, count(distinct social_id) as socials
      from links group by lower(spotify_id)
    )
    select (select count(*) from by_id where accounts > 1),
           (select coalesce(sum(link_rows), 0)::bigint from by_id where accounts > 1),
           (select count(*) from by_account where ids > 1),
           (select coalesce(sum(link_rows), 0)::bigint from by_account where ids > 1),
           (select count(*) from by_folded where spellings > 1),
           (select coalesce(sum(socials), 0)::bigint from by_folded where spellings > 1),
           (select count(distinct social_id) from links where spotify_id = lower(spotify_id)),
           (select count(*) from links where spotify_id = lower(spotify_id))
      into a_count, a_rows, b_count, b_rows, c_count, c_rows, c2_count, c2_rows;

    -- The 2026-07-29 "ambiguous, needs a human" class: a duplicated id whose
    -- linked accounts include more than one song_artists graph owner.
    if v_has_song_artists then
      with links as (
        select substring(s.profile_url from c_spotify_artist) as spotify_id, ac.account_id
        from public.socials s
        join public.account_socials ac on ac.social_id = s.id
        where substring(s.profile_url from c_spotify_artist) is not null
      ),
      duplicated as (
        select spotify_id from links group by spotify_id having count(distinct account_id) > 1
      )
      select count(*) into v_owners
      from duplicated d
      where (select count(distinct l.account_id) from links l
             where l.spotify_id = d.spotify_id
               and exists (select 1 from public.song_artists sa where sa.artist = l.account_id)) > 1;
      a_owners := to_jsonb(v_owners);
    end if;
  end if;

  -- (d1)-(e): Context identities. One accepted identity per resource is already
  -- enforced by the context_one_accepted_identity index, so the measurable
  -- classes are recorded conflicts, one artist subject accepted for several
  -- resources, and accepted identities that disagree with legacy socials.
  if v_has_context then
    select count(distinct l.resource_id), count(*) into d1_count, d1_rows
    from public.context_resource_links l
    where l.relation = 'identity' and l.status = 'conflict';

    with accepted as (
      select l.subject_id, r.provider, r.resource_kind, count(*) as links
      from public.context_resource_links l
      join public.context_subjects s on s.id = l.subject_id and s.kind = 'artist'
      join public.context_resources r on r.id = l.resource_id
      where l.relation = 'identity' and l.status = 'accepted'
      group by l.subject_id, r.provider, r.resource_kind
      having count(*) > 1
    )
    select count(*), coalesce(sum(links), 0)::bigint into d2_count, d2_rows from accepted;

    if v_has_socials then
      with accepted as (
        select r.id as resource_id, r.provider_id, s.artist_id
        from public.context_resource_links l
        join public.context_subjects s on s.id = l.subject_id and s.kind = 'artist'
        join public.context_resources r on r.id = l.resource_id
          and r.provider = 'spotify' and r.resource_kind = 'artist'
        where l.relation = 'identity' and l.status = 'accepted'
      ),
      legacy as (
        select substring(so.profile_url from c_spotify_artist) as spotify_id, ac.account_id
        from public.socials so
        join public.account_socials ac on ac.social_id = so.id
        where substring(so.profile_url from c_spotify_artist) is not null
      ),
      compared as (
        select a.resource_id,
               count(lg.account_id) as legacy_rows,
               count(distinct lg.account_id) as legacy_accounts,
               coalesce(bool_or(lg.account_id = a.artist_id), false) as legacy_includes_subject
        from accepted a
        left join legacy lg on lg.spotify_id = a.provider_id
        group by a.resource_id, a.artist_id
      )
      select count(*) filter (where legacy_accounts > 1 or (legacy_accounts = 1 and not legacy_includes_subject)),
             coalesce(sum(legacy_rows) filter (where legacy_accounts > 1 or (legacy_accounts = 1 and not legacy_includes_subject)), 0)::bigint,
             count(*) filter (where legacy_accounts = 0),
             count(*) filter (where legacy_accounts = 0)
        into d3_count, d3_rows, e_count, e_rows
      from compared;
    end if;
  end if;

  -- (f)-(g2): roster and organization attachment.
  if v_has_roster then
    if v_has_socials then
      with artists as (
        select artist_id from public.account_artist_ids where artist_id is not null
        union
        select artist_id from public.artist_organization_ids where artist_id is not null
      ),
      named as (
        select a.id, lower(btrim(a.name)) as folded
        from public.accounts a
        join artists ar on ar.artist_id = a.id
        where a.name is not null and btrim(a.name) <> ''
          and not exists (
            select 1 from public.account_socials ac
            join public.socials so on so.id = ac.social_id
            where ac.account_id = a.id and substring(so.profile_url from c_spotify_artist) is not null)
      ),
      namesakes as (
        select folded, count(*) as members from named group by folded having count(*) > 1
      )
      select count(*), coalesce(sum(members), 0)::bigint into f_count, f_rows from namesakes;
    end if;

    with members as (
      select account_id, organization_id from public.account_organization_ids
      where account_id is not null and organization_id is not null
    )
    select count(*), count(distinct r.artist_id) into g_count, g_rows
    from public.account_artist_ids r
    where r.artist_id is not null
      and exists (select 1 from members m where m.account_id = r.account_id)
      and not exists (
        select 1 from members m
        join public.artist_organization_ids ao on ao.organization_id = m.organization_id and ao.artist_id = r.artist_id
        where m.account_id = r.account_id);

    select count(*), count(distinct ao.artist_id) into g2_count, g2_rows
    from public.artist_organization_ids ao
    where not exists (
      select 1 from public.account_organization_ids m
      join public.account_artist_ids r on r.account_id = m.account_id and r.artist_id = ao.artist_id
      where m.organization_id = ao.organization_id);
  end if;

  -- (h): one provider track value on several recordings. Album ids legitimately
  -- map to many songs (20260611120000), so only track_id is a conflict class.
  if v_has_song_identifiers then
    with shared as (
      select platform, value, count(distinct song) as songs, count(*) as mapping_rows
      from public.song_identifiers
      where identifier_type = 'track_id'
      group by platform, value
      having count(distinct song) > 1
    )
    select count(*), coalesce(sum(mapping_rows), 0)::bigint into h_count, h_rows from shared;
  end if;

  -- (i): the one-off 2026-07-29 cleanup manifests, where they exist.
  if v_has_dupe_manifest then
    select count(*) into i_dupe from public.zz_dupe_manifest_20260729;
  end if;
  if v_has_cleanup_manifest then
    select count(*) into i_cleanup from public.zz_cleanup_manifest_20260729b;
  end if;

  -- Deployed migration history, when the invoker may read it. Even the name
  -- lookup needs USAGE on the schema, so the whole block reports 'denied'.
  begin
    if to_regclass('supabase_migrations.schema_migrations') is not null then
      execute 'select count(*), max(version) from supabase_migrations.schema_migrations' into m_count, m_latest;
      v_history := jsonb_build_object('status', 'present', 'applied', m_count, 'latest_version', m_latest);
    else
      v_history := jsonb_build_object('status', 'not_present');
    end if;
  exception when insufficient_privilege then
    v_history := jsonb_build_object('status', 'denied');
  end;

  v_classes := jsonb_build_object(
    'spotify_artist_ids_linked_to_multiple_accounts', jsonb_build_object(
      'status', case when v_has_socials then 'measured' else 'not_applicable' end,
      'count', a_count, 'affected_rows', a_rows, 'multiple_graph_owners', a_owners,
      'rule', 'Each Spotify artist id resolves to one artist account. Existing duplicates are quarantined for human review; ids with several song_artists graph owners are never collapsed automatically. Enforcement is owned by recoupable/app#2119; onboarding and research already refuse ambiguous ids.'),
    'accounts_with_multiple_spotify_artist_socials', jsonb_build_object(
      'status', case when v_has_socials then 'measured' else 'not_applicable' end,
      'count', b_count, 'affected_rows', b_rows,
      'rule', 'One artist account carries at most one Spotify artist id. Extra links are reviewed, not dropped; a genuine second profile needs an explicit decision. Owned by recoupable/app#2119.'),
    'spotify_artist_id_case_variants', jsonb_build_object(
      'status', case when v_has_socials then 'measured' else 'not_applicable' end,
      'count', c_count, 'affected_rows', c_rows,
      'rule', 'Spotify ids are matched case-sensitively. Spellings that only coincide after lowercasing are review candidates; the original case of a lowercased id is not recoverable and is never guessed. Owned by recoupable/app#2119.'),
    'spotify_artist_socials_without_uppercase', jsonb_build_object(
      'status', case when v_has_socials then 'measured' else 'not_applicable' end,
      'count', c2_count, 'affected_rows', c2_rows,
      'rule', 'An all-lowercase Spotify artist id may have been folded by the 2025-05-28 profile-url trigger before the Spotify exemption. Re-verify against the provider before relying on it; never rewrite it in place. Owned by recoupable/app#2119.'),
    'context_identity_links_in_conflict_status', jsonb_build_object(
      'status', case when v_has_context then 'measured' else 'not_applicable' end,
      'count', d1_count, 'affected_rows', d1_rows,
      'rule', 'A recorded conflict stays a conflict until a reviewer accepts one subject. Nothing promotes it implicitly. Owned by recoupable/app#2119.'),
    'context_artist_subjects_with_multiple_accepted_resources', jsonb_build_object(
      'status', case when v_has_context then 'measured' else 'not_applicable' end,
      'count', d2_count, 'affected_rows', d2_rows,
      'rule', 'One artist subject is the accepted identity of at most one resource per provider and kind. Additional resources are reviewed as possible duplicate profiles. Owned by recoupable/app#2119.'),
    'context_accepted_artist_identities_disagreeing_with_legacy_socials', jsonb_build_object(
      'status', case when v_has_context and v_has_socials then 'measured' else 'not_applicable' end,
      'count', d3_count, 'affected_rows', d3_rows,
      'rule', 'An accepted Context identity and the legacy social links for the same Spotify id must name the same single account. Disagreement blocks reuse of that identity until reviewed; neither side is rewritten automatically. Owned by recoupable/app#2119.'),
    'context_accepted_artist_identities_without_legacy_social', jsonb_build_object(
      'status', case when v_has_context and v_has_socials then 'measured' else 'not_applicable' end,
      'count', e_count, 'affected_rows', e_rows,
      'rule', 'Not a defect: an accepted identity whose account has no legacy Spotify social is an attachment candidate for the explicit onboarding path. Nothing is attached without intent. Owned by recoupable/app#2119.'),
    'name_only_artist_accounts_sharing_a_name', jsonb_build_object(
      'status', case when v_has_roster and v_has_socials then 'measured' else 'not_applicable' end,
      'count', f_count, 'affected_rows', f_rows,
      'rule', 'Names never identify people or artists. Same-name name-only accounts are never merged by name; a reviewer may link them to one subject with evidence. Owned by recoupable/app#2119.'),
    'rostered_artists_without_organization_attachment', jsonb_build_object(
      'status', case when v_has_roster then 'measured' else 'not_applicable' end,
      'count', g_count, 'affected_rows', g_rows,
      'rule', 'A personal roster row is a supported state, not a defect. Organization attachment happens only through the explicit onboarding operation with membership checked in the transaction. Owned by recoupable/app#2119.'),
    'organization_artists_without_member_roster', jsonb_build_object(
      'status', case when v_has_roster then 'measured' else 'not_applicable' end,
      'count', g2_count, 'affected_rows', g2_rows,
      'rule', 'An organization attachment that no member rosters is reviewed for staleness; it is not removed automatically, because attachment is a business relationship. Owned by recoupable/app#2119.'),
    'provider_track_values_mapped_to_multiple_songs', jsonb_build_object(
      'status', case when v_has_song_identifiers then 'measured' else 'not_applicable' end,
      'count', h_count, 'affected_rows', h_rows,
      'rule', 'One provider track id maps to one ISRC. Existing multi-ISRC values are quarantined; research already refuses to attach such a track to a different ISRC. ISRCs are never invented or reassigned. Owned by recoupable/app#2119.'),
    'legacy_cleanup_manifest_rows', jsonb_build_object(
      'status', case when v_has_dupe_manifest or v_has_cleanup_manifest then 'present' else 'not_present' end,
      'count', i_dupe + i_cleanup, 'affected_rows', i_dupe + i_cleanup,
      'dupe_manifest_rows', i_dupe, 'cleanup_manifest_rows', i_cleanup,
      'rule', 'The 2026-07-29 manifests are historical evidence of a one-off mutation and are kept read-only. They are not replayed, extended or used as a target list. Owned by recoupable/app#2119.')
  );

  select count(*) into v_findings
  from jsonb_each(v_classes) c
  where (c.value ->> 'count')::bigint > 0;

  return jsonb_build_object(
    'inventory_version', 'identity-inventory-v1',
    'generated_at', now(),
    'mutations', 'none',
    'server_version', current_setting('server_version'),
    'migration_history', v_history,
    'classes_with_findings', v_findings,
    'classes', v_classes);
end;
$$;

revoke all on function public.read_context_identity_conflict_inventory() from public, anon, authenticated;
grant execute on function public.read_context_identity_conflict_inventory() to service_role;
comment on function public.read_context_identity_conflict_inventory() is
  'Service-only, read-only aggregate inventory of identity conflicts for recoupable/app#2117. Returns counts only and never writes.';

commit;
