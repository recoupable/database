-- A campaign brief may name channels and already-saved workspace subjects it promotes. Each link is
-- checked only against a completed or partial Context request in the same workspace; nothing fetches a
-- URL, infers ownership or rights, or generates a site. Briefs without the new keys keep the v1 fingerprint.
begin;
create or replace function public.create_context_campaign_brief_request(
 p_owner uuid,p_actor uuid,p_brief jsonb,p_key text
) returns jsonb language plpgsql set search_path='' as $$
declare normalized jsonb; name_text text; goal_text text; audience_text text; start_text text; end_text text;
 channels jsonb:='[]'; channel jsonb; channel_text text; promoted jsonb:='[]'; link jsonb; link_kind text;
 fingerprint_version text; gaps jsonb;
 input_hash text; opaque text; uri text; resource uuid; subject uuid; req public.context_requests;
 source uuid; source_version uuid; document public.context_documents; attempt_key uuid; result uuid;
 snapshot jsonb; snapshot_hash text; stored public.context_requests; stored_links jsonb:='[]';
begin
 -- Null-safe type checks: a missing brief, name, goal or link id must fail closed, not compare as NULL.
 if jsonb_typeof(p_brief) is distinct from 'object' or exists(
  select 1 from jsonb_object_keys(p_brief) as field(key)
  where field.key not in ('name','goal','audience','start_date','end_date','channels','promoted'))
 then raise exception 'Invalid campaign brief'; end if;
 if jsonb_typeof(p_brief->'name') is distinct from 'string' or jsonb_typeof(p_brief->'goal') is distinct from 'string'
  or (p_brief ? 'audience' and jsonb_typeof(p_brief->'audience')<>'string')
  or (p_brief ? 'start_date' and jsonb_typeof(p_brief->'start_date')<>'string')
  or (p_brief ? 'end_date' and jsonb_typeof(p_brief->'end_date')<>'string')
 then raise exception 'Invalid campaign brief'; end if;
 name_text:=p_brief->>'name'; goal_text:=p_brief->>'goal'; audience_text:=p_brief->>'audience';
 if name_text ~ '[[:cntrl:]]' or goal_text ~ '[[:cntrl:]]' or audience_text ~ '[[:cntrl:]]'
 then raise exception 'Invalid campaign brief'; end if;
 name_text:=pg_catalog.btrim(pg_catalog.regexp_replace(name_text,'[[:space:]]+',' ','g'));
 goal_text:=pg_catalog.btrim(pg_catalog.regexp_replace(goal_text,'[[:space:]]+',' ','g'));
 if length(name_text) not between 2 and 200 or length(goal_text) not between 2 and 2000
  or length(coalesce(audience_text,''))>500 then raise exception 'Invalid campaign brief'; end if;
 start_text:=p_brief->>'start_date'; end_text:=p_brief->>'end_date';
 if (start_text is not null and (start_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or start_text::date::text<>start_text))
  or (end_text is not null and (end_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or end_text::date::text<>end_text))
  or (start_text is not null and end_text is not null and end_text::date<start_text::date)
 then raise exception 'Invalid campaign dates'; end if;
 -- Channels are names. Links and file references belong to saved subjects and material, never here.
 if p_brief ? 'channels' then
  if jsonb_typeof(p_brief->'channels')<>'array' or jsonb_array_length(p_brief->'channels')>10
  then raise exception 'Invalid campaign brief'; end if;
  for channel in select value from jsonb_array_elements(p_brief->'channels') loop
   if jsonb_typeof(channel)<>'string' then raise exception 'Invalid campaign brief'; end if;
   channel_text:=channel#>>'{}';
   if channel_text ~ '[[:cntrl:]]' then raise exception 'Invalid campaign brief'; end if;
   channel_text:=pg_catalog.btrim(pg_catalog.regexp_replace(channel_text,'[[:space:]]+',' ','g'));
   -- Rejects obvious links: scheme URLs, URI schemes (mailto:, spotify:, file:), www. hosts, and absolute,
   -- home or drive paths. Not a full URL or file detector; names are never fetched. "X" is a valid channel.
   if length(channel_text) not between 1 and 60
    or channel_text ~* '(://|^(www\.|/|\\|~/)|^[a-z][a-z0-9+.-]*:[^[:space:]])'
    or exists(select 1 from jsonb_array_elements_text(channels) as existing(name) where lower(existing.name)=lower(channel_text))
   then raise exception 'Invalid campaign brief'; end if;
   channels:=channels||to_jsonb(channel_text);
  end loop;
 end if;
 -- A promoted target is a subject this workspace already saved through its own request. It stays a
 -- candidate: no ownership, rights, roster or catalog interest is implied.
 if p_brief ? 'promoted' then
  if jsonb_typeof(p_brief->'promoted')<>'array' or jsonb_array_length(p_brief->'promoted')>20
  then raise exception 'Invalid campaign brief'; end if;
  -- A retry of a brief already saved under this key replays its stored links, even if a target request
  -- was cancelled since; the fingerprint check below still rejects any changed brief. New keys re-check.
  select * into stored from public.context_requests where owner_id=p_owner and idempotency_key=p_key;
  if stored.status in ('completed','partial','cancelled')
   and jsonb_typeof(stored.input->'brief'->'promoted') is not distinct from 'array'
  then stored_links:=stored.input->'brief'->'promoted'; end if;
  for link in select value from jsonb_array_elements(p_brief->'promoted') loop
   if jsonb_typeof(link)<>'object'
    or exists(select 1 from jsonb_object_keys(link) as field(key) where field.key not in ('request_id','subject_id'))
    or jsonb_typeof(link->'request_id') is distinct from 'string' or jsonb_typeof(link->'subject_id') is distinct from 'string'
    or (link->>'request_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or (link->>'subject_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or exists(select 1 from jsonb_array_elements(promoted) as existing(entry)
     where existing.entry->>'request_id'=lower(link->>'request_id') and existing.entry->>'subject_id'=lower(link->>'subject_id'))
   then raise exception 'Invalid campaign brief'; end if;
   select existing.entry->>'kind' into link_kind from jsonb_array_elements(stored_links) as existing(entry)
   where existing.entry->>'request_id'=lower(link->>'request_id') and existing.entry->>'subject_id'=lower(link->>'subject_id');
   if link_kind is null then
    select s.kind into link_kind from public.context_requests r
    join public.context_subjects s on s.id=(link->>'subject_id')::uuid
    where r.id=(link->>'request_id')::uuid and r.owner_id=p_owner and r.status in ('partial','completed')
     and r.output->'subjectIds' ? s.id::text and s.kind in ('artist','recording','release','catalog');
   end if;
   if link_kind is null then raise exception 'Invalid promoted subject'; end if;
   promoted:=promoted||jsonb_build_object('request_id',(link->>'request_id')::uuid,'subject_id',(link->>'subject_id')::uuid,
    'kind',link_kind,'assertion','promoted_candidate','ownership_verified',false);
  end loop;
 end if;
 normalized:=jsonb_build_object('name',name_text,'goal',goal_text);
 if audience_text is not null then normalized:=normalized||jsonb_build_object('audience',pg_catalog.btrim(audience_text)); end if;
 if start_text is not null then normalized:=normalized||jsonb_build_object('start_date',start_text); end if;
 if end_text is not null then normalized:=normalized||jsonb_build_object('end_date',end_text); end if;
 if jsonb_array_length(channels)>0 then normalized:=normalized||jsonb_build_object('channels',channels); end if;
 if jsonb_array_length(promoted)>0 then normalized:=normalized||jsonb_build_object('promoted',promoted); end if;
 -- Earlier briefs were fingerprinted without link keys; an unlinked brief must replay under its old key.
 fingerprint_version:=case when normalized ? 'channels' or normalized ? 'promoted' then 'campaign-brief-v2:' else 'campaign-brief-v1:' end;
 input_hash:=encode(sha256(convert_to(fingerprint_version||normalized::text,'UTF8')),'hex');
 opaque:=encode(sha256(convert_to('campaign-input-v1:'||p_owner::text||':'||p_key,'UTF8')),'hex');
 uri:='urn:recoup:campaign-input:'||opaque;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('recoup','campaign_input',opaque,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,input_hash,jsonb_build_object('kind','campaign','brief',normalized,'identityConfirmed',false))
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict req from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if req.input_fingerprint<>input_hash or req.resource_id<>resource
 then raise exception 'Idempotency key already used for different input'; end if;
 if req.status in ('completed','partial','cancelled') then return to_jsonb(req)-'claim_token'; end if;
 insert into public.context_subjects(kind,resource_id) values('campaign',resource)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into subject;
 snapshot:=jsonb_build_object('brief',normalized,'submittedBy',p_actor,'identityConfirmed',false,'scope','workspace_private');
 snapshot_hash:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,uri,'customer')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
 values(p_owner,source,snapshot_hash,snapshot)
 on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into source_version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,subject,'campaign_brief') on conflict do nothing;
 select * into strict document from public.context_documents
 where owner_id=p_owner and subject_id=subject and topic='campaign_brief' for update;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,req.id,'campaign_brief:'||subject,1,'succeeded','user_submission','campaign-brief-v2','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into attempt_key;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,attempt_key,subject,'campaign_brief',snapshot_hash,'accepted','customer_assertion',snapshot,snapshot,
  '{"extent":"partial","scope":"submitted_brief","identityConfirmed":false}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,source_version);
 if not public.accept_context_result(p_owner,document.id,result,document.revision)
 then raise exception 'Campaign brief acceptance conflict'; end if;
 gaps:=jsonb_build_array('Promoted subject ownership and rights not verified','Supplied assets not inventoried');
 if not normalized ? 'promoted' then gaps:=gaps||to_jsonb('No promoted subjects linked'::text); end if;
 update public.context_requests set status='partial',
  output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',gaps),
  updated_at=now() where id=req.id returning * into req;
 return to_jsonb(req)-'claim_token';
end $$;
revoke all on function public.create_context_campaign_brief_request(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.create_context_campaign_brief_request(uuid,uuid,jsonb,text) to service_role;
commit;
