-- Reuse existing Spotify profiles without account links during context ingestion.
begin;
create or replace function public.commit_spotify_context(p_owner uuid,p_request uuid,p_token uuid,p_payload jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; resource public.context_resources; recording uuid; release_subject uuid;
 social uuid; artist_resource uuid; artist_subject uuid; artist_account uuid; candidates uuid[]; artist jsonb;
 subjects uuid[]:='{}'; credits jsonb:='[]'; pos integer:=0; gaps jsonb:='[]'; topic text; isrc text;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for update;
 if req.status<>'running' or req.claim_token is distinct from p_token then raise exception 'Worker no longer owns request'; end if;
 select * into strict resource from public.context_resources where id=req.resource_id;
 if resource.provider_id is distinct from p_payload->>'trackId' then raise exception 'Recording mismatch'; end if;
 isrc:=p_payload->>'isrc';
 if isrc is null or isrc !~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$' then raise exception 'Verified ISRC required'; end if;
 -- Existing conflicting track identifiers must never be overwritten.
 if exists(select 1 from public.song_identifiers where platform='spotify' and identifier_type='track_id' and value=resource.provider_id and song<>isrc)
 then raise exception 'Conflicting recording identity'; end if;
 -- Older installations require lyrics; production stores lyrics in context instead.
 if exists(select 1 from information_schema.columns where table_schema='public' and table_name='songs' and column_name='lyrics') then
  execute 'insert into public.songs(isrc,name,album,lyrics) values($1,$2,$3,$4) on conflict do nothing' using isrc,p_payload->>'title',coalesce(p_payload->'release'->>'title',''),'';
 else
  insert into public.songs(isrc,name,album) values(isrc,p_payload->>'title',p_payload->'release'->>'title') on conflict do nothing;
 end if;
 insert into public.song_identifiers(song,platform,identifier_type,value)
 select isrc,'spotify','track_id',resource.provider_id where not exists(select 1 from public.song_identifiers si where si.song=isrc and si.platform='spotify' and si.identifier_type='track_id' and si.value=resource.provider_id);
 insert into public.context_subjects(kind,song_isrc) values('recording',isrc) on conflict(song_isrc) do update set song_isrc=excluded.song_isrc returning id into recording;
 insert into public.context_resource_links(resource_id,subject_id,relation,status,evidence)
 values(resource.id,recording,'identity','accepted',jsonb_build_object('isrc',isrc)) on conflict(resource_id,subject_id,relation) do nothing;
 -- Release-specific presentation remains attached to the submitted track resource.
 insert into public.context_subjects(kind,resource_id) values('release',resource.id)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into release_subject;
 insert into public.context_resource_links(resource_id,subject_id,relation,status) values(resource.id,release_subject,'release_member','accepted') on conflict do nothing;
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
  insert into public.account_artist_ids(account_id,artist_id) values(req.created_by,artist_account) on conflict do nothing;
  if req.input->>'organization_id' is not null then
   insert into public.artist_organization_ids(artist_id,organization_id) values(artist_account,p_owner) on conflict do nothing;
  end if;
  select ordinality-1 into pos from jsonb_array_elements(p_payload->'artists') with ordinality where value->>'id'=artist->>'id';
  insert into public.context_resource_links(resource_id,subject_id,relation,status,credit_order)
   values(resource.id,artist_subject,'credited_artist','accepted',pos) on conflict do nothing;
  subjects:=array_append(subjects,artist_subject);
  credits:=credits||jsonb_build_array(jsonb_build_object('providerId',artist->>'id','subjectId',artist_subject,'artistId',artist_account,'order',pos));
  perform public.save_context_metadata(p_owner,p_request,artist_subject,'artist_metadata','https://open.spotify.com/artist/'||(artist->>'id'),artist,coalesce((p_payload->>'retrievedAt')::timestamptz,now()));
 end loop;
 perform public.save_context_metadata(p_owner,p_request,release_subject,'release_metadata',resource.canonical_url,p_payload - 'retrievedAt',coalesce((p_payload->>'retrievedAt')::timestamptz,now()));
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

commit;
