-- Transactional metadata ingestion. Paid enrichments stay disabled until the
-- spending/reconciliation milestone; missing analysis is reported, never invented.
begin;
alter table public.context_requests add column claim_token uuid,
 add column lease_expires_at timestamptz, add column output jsonb, add column error text;
create unique index context_active_source_url on public.context_sources(owner_id,kind,source_url)
 where withdrawn_at is null and source_url is not null;

create function public.create_context_request(p_owner uuid,p_actor uuid,p_key text,p_fingerprint text,p_input jsonb,p_track text)
returns jsonb language plpgsql set search_path='' as $$
declare resource uuid; r public.context_requests;
begin
 if p_track !~ '^[A-Za-z0-9]{22}$' then raise exception 'Invalid Spotify ID' using errcode='22023'; end if;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','track',p_track,'https://open.spotify.com/track/'||p_track)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,p_fingerprint,p_input)
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict r from public.context_requests where owner_id=p_owner and idempotency_key=p_key;
 if r.input_fingerprint <> p_fingerprint then raise exception 'Idempotency key already used for different input' using errcode='22023'; end if;
 return to_jsonb(r) - 'claim_token';
end $$;

create function public.read_context_request(p_owner uuid,p_request uuid)
returns jsonb language sql set search_path='' as $$
 select to_jsonb(r)-'claim_token' from public.context_requests r where owner_id=p_owner and id=p_request;
$$;

create function public.claim_context_request(p_owner uuid,p_request uuid,p_token uuid)
returns boolean language plpgsql set search_path='' as $$
declare n integer;
begin
 update public.context_requests set status='running',claim_token=p_token,lease_expires_at=now()+interval '2 minutes',error=null,updated_at=now()
 where owner_id=p_owner and id=p_request and (status in ('queued','failed') or (status='running' and lease_expires_at<now()));
 get diagnostics n=row_count; return n=1;
end $$;

create function public.fail_context_request(p_owner uuid,p_request uuid,p_token uuid,p_error text)
returns boolean language plpgsql set search_path='' as $$
declare n integer;
begin
 update public.context_requests set status='failed',error=left(p_error,1000),lease_expires_at=null,updated_at=now()
 where owner_id=p_owner and id=p_request and claim_token=p_token and status='running';
 get diagnostics n=row_count; return n=1;
end $$;

-- Persist immutable source/result versions; identical current evidence is reused.
create function public.save_context_metadata(p_owner uuid,p_request uuid,p_subject uuid,p_topic text,p_url text,p_content jsonb,p_captured timestamptz default now())
returns uuid language plpgsql set search_path='' as $$
declare source uuid; version uuid; doc public.context_documents; v_attempt uuid; result uuid; v_fingerprint text;
begin
 v_fingerprint:=encode(sha256(convert_to(p_content::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,p_url,'provider_metadata')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content,retrieved_at)
 values(p_owner,source,v_fingerprint,p_content,p_captured) on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,p_subject,p_topic) on conflict do nothing;
 select * into strict doc from public.context_documents where owner_id=p_owner and subject_id=p_subject and topic=p_topic for update;
 if exists(select 1 from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id where rs.result_id=doc.current_result_id and v.retrieved_at>p_captured) then return doc.id; end if;
 if exists(select 1 from public.context_result_sources rs join public.context_results r on r.id=rs.result_id
   where r.id=doc.current_result_id and r.status='accepted' and rs.source_version_id=version) then return doc.id; end if;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,p_request,p_topic||':'||p_subject,1,'succeeded','spotify','spotify-metadata-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into v_attempt;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,v_attempt,p_subject,p_topic,v_fingerprint,'accepted','observation',p_content,p_content - 'raw',
 '{"extent":"partial","scope":"provider_metadata","audioAnalyzed":false}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,version);
 if not public.accept_context_result(p_owner,doc.id,result,doc.revision) then raise exception 'Context acceptance conflict'; end if;
 return doc.id;
end $$;

create function public.commit_spotify_context(p_owner uuid,p_request uuid,p_token uuid,p_payload jsonb)
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
    insert into public.socials(profile_url,username) values('https://open.spotify.com/artist/'||(artist->>'id'),artist->>'name') returning id into social;
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

create function public.read_context_documents(p_owner uuid,p_request uuid)
returns jsonb language sql set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'ownerId',d.owner_id,'subjectId',d.subject_id,'topic',d.topic,
 'version',d.revision,'resultId',r.id,'status',r.status,'evidenceKind',r.evidence_kind,'text',r.normalized_response::text,
 'sources',(select jsonb_agg(jsonb_build_object('versionId',v.id,'url',s.source_url,'retrievedAt',v.retrieved_at)) from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id join public.context_sources s on s.id=v.source_id where rs.result_id=r.id),
 'coverage',r.coverage->>'extent','sourceVersionIds',(select jsonb_agg(rs.source_version_id) from public.context_result_sources rs where rs.result_id=r.id))), '[]')
 from public.context_documents d join public.context_results r on r.id=d.current_result_id and r.owner_id=d.owner_id
 join public.context_requests q on q.id=p_request and q.owner_id=p_owner
 where d.owner_id=p_owner and d.subject_id::text in (select jsonb_array_elements_text(q.output->'subjectIds')) and r.status='accepted'
 and not exists(select 1 from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id
 join public.context_sources s on s.id=v.source_id where rs.result_id=r.id and (s.withdrawn_at is not null or v.removed_at is not null));
$$;

do $$ declare f text; begin
 foreach f in array array[
 'create_context_request(uuid,uuid,text,text,jsonb,text)','read_context_request(uuid,uuid)',
 'claim_context_request(uuid,uuid,uuid)','fail_context_request(uuid,uuid,uuid,text)',
 'save_context_metadata(uuid,uuid,uuid,text,text,jsonb,timestamptz)','commit_spotify_context(uuid,uuid,uuid,jsonb)','read_context_documents(uuid,uuid)'] loop
 execute 'revoke all on function public.'||f||' from public,anon,authenticated';
 execute 'grant execute on function public.'||f||' to service_role';
 end loop;
end $$;
commit;
