-- Conflicting track-to-recording evidence is quarantined instead of discarded.
-- A Spotify track already mapped to a different ISRC through legacy song_identifiers saves a
-- 'conflict' identity link from the track to the existing recording subject (created if absent)
-- carrying both ISRCs and the provider source attribution. An accepted identity link to another
-- recording is reported unchanged and never downgraded. The request fails with
-- output.identityConflicts and an identity_conflict error; no songs, identifiers, observed
-- recording, release or artist subjects, artists or documents are written.
-- Resolution: a later verified observation accepted for the same track promotes a matching
-- conflict link to 'accepted' (keeping its evidence under resolvedConflict) and marks the
-- track's other open conflict links 'rejected' with the superseding ISRC. A non-accepted link
-- that still blocks acceptance raises instead of completing without an accepted identity.
-- No automatic merge/split or cleanup. The rest of the non-conflict path is unchanged from
-- 20261009190000_context_research_without_roster.sql.
begin;
create or replace function public.commit_spotify_context(p_owner uuid,p_request uuid,p_token uuid,p_payload jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; resource public.context_resources; recording uuid; release_subject uuid; album_resource uuid; album_id text;
 social uuid; artist_resource uuid; artist_subject uuid; artist_account uuid; candidates uuid[]; artist jsonb;
 subjects uuid[]:='{}'; credits jsonb:='[]'; pos integer:=0; gaps jsonb:='[]'; topic text; isrc text;
 conflict_isrcs text[]; conflict_links uuid[]:='{}'; existing_isrc text; conflict_subject uuid; conflict_link uuid;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for update;
 if req.status<>'running' or req.claim_token is distinct from p_token then raise exception 'Worker no longer owns request'; end if;
 select * into strict resource from public.context_resources where id=req.resource_id;
 if resource.provider<>'spotify' or resource.resource_kind<>'track' then raise exception 'Spotify track resource required'; end if;
 album_id:=p_payload->'release'->>'id';
 if album_id is null or album_id !~ '^[A-Za-z0-9]{22}$' then raise exception 'Verified Spotify album identifier required'; end if;
 if resource.provider_id is distinct from p_payload->>'trackId' then raise exception 'Recording mismatch'; end if;
 isrc:=p_payload->>'isrc';
 if isrc is null or isrc !~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$' then raise exception 'Verified ISRC required'; end if;
 -- Existing conflicting track identifiers are never overwritten. The conflicting evidence is
 -- quarantined for review before any songs, identifiers, subjects or artists are written.
 select coalesce(array_agg(distinct x.song order by x.song),'{}') into conflict_isrcs from (
  select si.song from public.song_identifiers si
   where si.platform='spotify' and si.identifier_type='track_id' and si.value=resource.provider_id and si.song<>isrc
  union
  select s.song_isrc from public.context_resource_links l join public.context_subjects s on s.id=l.subject_id
   where l.resource_id=resource.id and l.relation='identity' and l.status='accepted' and s.kind='recording' and s.song_isrc<>isrc
 ) x;
 select coalesce(array_agg(l.id order by l.id),'{}') into conflict_links
  from public.context_resource_links l join public.context_subjects s on s.id=l.subject_id
  where l.resource_id=resource.id and l.relation='identity' and l.status='accepted'
   and (s.kind<>'recording' or s.song_isrc is distinct from isrc);
 if cardinality(conflict_isrcs)>0 or cardinality(conflict_links)>0 then
  foreach existing_isrc in array conflict_isrcs loop
   -- The existing songs row is guaranteed by the song_identifiers/context_subjects foreign keys.
   insert into public.context_subjects(kind,song_isrc) values('recording',existing_isrc)
    on conflict(song_isrc) do update set song_isrc=excluded.song_isrc returning id into conflict_subject;
   -- Shared provider evidence only; the private request references the link through its output.
   -- An accepted mapping is never downgraded and reviewed rows keep their evidence.
   insert into public.context_resource_links as cl(resource_id,subject_id,relation,status,evidence)
    values(resource.id,conflict_subject,'identity','conflict',jsonb_build_object(
     'observedIsrc',isrc,'existingIsrc',existing_isrc,'providerId',resource.provider_id,
     'sourceUrl',resource.canonical_url,'retrievedAt',coalesce((p_payload->>'retrievedAt')::timestamptz,now()),
     'observedTitle',p_payload->>'title'))
    on conflict(resource_id,subject_id,relation) do update set evidence=excluded.evidence where cl.status='conflict'
    returning cl.id into conflict_link;
   if conflict_link is null then
    select l.id into conflict_link from public.context_resource_links l
     where l.resource_id=resource.id and l.subject_id=conflict_subject and l.relation='identity';
   end if;
   if conflict_link is not null and not (conflict_link=any(conflict_links)) then
    conflict_links:=array_append(conflict_links,conflict_link);
   end if;
  end loop;
  update public.context_requests set status='failed',
   error='identity_conflict: This Spotify track is already mapped to a different ISRC. The conflicting evidence was saved for review and nothing was accepted; retry this request after the mapping is resolved.',
   output=jsonb_build_object('identityConflicts',jsonb_build_array(jsonb_build_object('providerId',resource.provider_id,
    'observedIsrc',isrc,'existingIsrcs',to_jsonb(conflict_isrcs),'linkIds',to_jsonb(conflict_links))),
    'subjectIds','[]'::jsonb,'artists','[]'::jsonb,'gaps','[]'::jsonb,'providerCostMicros',0,'model',null),
   lease_expires_at=null,updated_at=now() where id=p_request;
  return public.read_context_request(p_owner,p_request);
 end if;
 -- Older installations require lyrics; production stores lyrics in context instead.
 if exists(select 1 from information_schema.columns where table_schema='public' and table_name='songs' and column_name='lyrics') then
  execute 'insert into public.songs(isrc,name,album,lyrics) values($1,$2,$3,$4) on conflict do nothing' using isrc,p_payload->>'title',coalesce(p_payload->'release'->>'title',''),'';
 else
  insert into public.songs(isrc,name,album) values(isrc,p_payload->>'title',p_payload->'release'->>'title') on conflict do nothing;
 end if;
 insert into public.song_identifiers(song,platform,identifier_type,value)
 select isrc,'spotify','track_id',resource.provider_id where not exists(select 1 from public.song_identifiers si where si.song=isrc and si.platform='spotify' and si.identifier_type='track_id' and si.value=resource.provider_id);
 insert into public.context_subjects(kind,song_isrc) values('recording',isrc) on conflict(song_isrc) do update set song_isrc=excluded.song_isrc returning id into recording;
 -- A quarantined link confirmed by this verified observation becomes the accepted identity.
 insert into public.context_resource_links as cl(resource_id,subject_id,relation,status,evidence)
 values(resource.id,recording,'identity','accepted',jsonb_build_object('isrc',isrc)) on conflict(resource_id,subject_id,relation)
 do update set status='accepted',evidence=jsonb_build_object('isrc',isrc,'resolvedConflict',cl.evidence) where cl.status='conflict';
 if not exists(select 1 from public.context_resource_links l where l.resource_id=resource.id and l.subject_id=recording
  and l.relation='identity' and l.status='accepted') then
  raise exception 'Conflicting recording identity: a reviewed identity link blocks this recording';
 end if;
 -- The accepted identity supersedes this track's other open conflicts; their evidence is kept.
 update public.context_resource_links cl set status='rejected',evidence=cl.evidence||jsonb_build_object(
  'resolution','superseded_by_accepted_identity','acceptedIsrc',isrc,'resolvedAt',now())
  where cl.resource_id=resource.id and cl.relation='identity' and cl.status='conflict' and cl.subject_id<>recording;
 -- A single is also represented by a Spotify album container. Track and album IDs are distinct.
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','release',album_id,'https://open.spotify.com/album/'||album_id)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into album_resource;
 insert into public.context_subjects(kind,resource_id) values('release',album_resource)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into release_subject;
 insert into public.context_resource_links(resource_id,subject_id,relation,status,evidence) values(resource.id,release_subject,'release_member','accepted',coalesce(p_payload->'releaseTrack','{}'::jsonb)) on conflict(resource_id,subject_id,relation) do update set evidence=excluded.evidence;
 subjects:=array[recording,release_subject];
 for artist in select value from jsonb_array_elements(p_payload->'artists') order by value->>'id' loop
  if artist->>'id' !~ '^[A-Za-z0-9]{22}$' then raise exception 'Invalid artist identity'; end if;
  -- Lock in provider-ID order so collaborations cannot deadlock each other.
  insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
  values('spotify','artist',artist->>'id','https://open.spotify.com/artist/'||(artist->>'id'))
  on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into artist_resource;
  select s.id,s.artist_id into artist_subject,artist_account from public.context_resource_links l join public.context_subjects s on s.id=l.subject_id
   where l.resource_id=artist_resource and l.relation='identity' and l.status='accepted';
  if artist_subject is null then
   select array_agg(distinct ac.account_id) into candidates from public.socials s join public.account_socials ac on ac.social_id=s.id
    where regexp_replace(regexp_replace(s.profile_url,'^https?://',''),'[?#].*$','') in ('open.spotify.com/artist/'||(artist->>'id'),'open.spotify.com/artist/'||(artist->>'id')||'/');
   if cardinality(candidates)>1 then raise exception 'Conflicting artist identity'; end if;
   artist_account:=candidates[1];
   if artist_account is null then
    insert into public.accounts(name) values(artist->>'name') returning id into artist_account;
    insert into public.account_info(account_id) values(artist_account);
    -- A provider profile may exist before an artist account is attached to it.
    -- Reuse it, including legacy protocol/query/trailing-slash URL variants.
    select s.id into social from public.socials s
     where regexp_replace(regexp_replace(s.profile_url,'^https?://',''),'[?#].*$','') in ('open.spotify.com/artist/'||(artist->>'id'),'open.spotify.com/artist/'||(artist->>'id')||'/')
     order by s.id limit 1 for update;
    if social is null then
     insert into public.socials(profile_url,username)
      values('https://open.spotify.com/artist/'||(artist->>'id'),artist->>'name')
      on conflict(profile_url) do update set profile_url=excluded.profile_url returning id into social;
    end if;
    insert into public.account_socials(account_id,social_id) values(artist_account,social);
   end if;
   insert into public.context_subjects(kind,artist_id) values('artist',artist_account)
   on conflict(artist_id) do update set artist_id=excluded.artist_id returning id into artist_subject;
   insert into public.context_resource_links(resource_id,subject_id,relation,status) values(artist_resource,artist_subject,'identity','accepted');
  end if;
  -- Keep credited identities/evidence; research never enrolls contributors.
  select ordinality-1 into pos from jsonb_array_elements(p_payload->'artists') with ordinality where value->>'id'=artist->>'id';
  insert into public.context_resource_links(resource_id,subject_id,relation,status,credit_order)
   values(resource.id,artist_subject,'credited_artist','accepted',pos) on conflict do nothing;
  subjects:=array_append(subjects,artist_subject);
  credits:=credits||jsonb_build_array(jsonb_build_object('providerId',artist->>'id','subjectId',artist_subject,'artistId',artist_account,'order',pos));
  perform public.save_context_metadata(p_owner,p_request,artist_subject,'artist_metadata','https://open.spotify.com/artist/'||(artist->>'id'),artist,coalesce((p_payload->>'retrievedAt')::timestamptz,now()));
 end loop;
 perform public.save_context_metadata(p_owner,p_request,recording,'recording_metadata',resource.canonical_url,p_payload - 'release' - 'retrievedAt',coalesce((p_payload->>'retrievedAt')::timestamptz,now()));
 perform public.save_context_metadata(p_owner,p_request,release_subject,'release_metadata','https://open.spotify.com/album/'||album_id,p_payload->'release',coalesce((p_payload->>'retrievedAt')::timestamptz,now()));
 for topic in select jsonb_array_elements_text(coalesce(req.input->'topics','["release_metadata","artist_metadata","catalog_metadata","lyrics","song_summary","artwork_branding","artist_research"]')) loop
  if topic not in ('release_metadata','artist_metadata') then
   gaps:=gaps||jsonb_build_array(jsonb_build_object('topic',topic,'status','unavailable','reason','Enrichment is not enabled in the metadata pilot. No analysis was inferred.'));
  end if;
 end loop;
 update public.context_requests set status=case when jsonb_array_length(gaps)=0 then 'completed' else 'partial' end,
 output=jsonb_build_object('subjectIds',subjects,'artists',credits,'gaps',gaps,'providerCostMicros',0,'model',null),
 lease_expires_at=null,updated_at=now() where id=p_request;
 return public.read_context_request(p_owner,p_request);
end $$;
revoke all on function public.commit_spotify_context(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.commit_spotify_context(uuid,uuid,uuid,jsonb) to service_role;
commit;
