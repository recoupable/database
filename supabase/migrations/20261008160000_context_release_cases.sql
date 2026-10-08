-- Additive metadata review only. No rights, provider writes or spend authority.
begin;
create table public.context_release_case_reviews (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.accounts(id),
 request_id uuid not null,
 actor_id uuid not null references public.accounts(id),
 idempotency_key text not null check(idempotency_key ~ '^[A-Za-z0-9._:-]{1,128}$'),
 fingerprint text not null check(fingerprint ~ '^[a-f0-9]{64}$'),
 decision text not null check(decision in ('reviewed','needs_changes')),
 note text not null check(length(note)<=2000),
 snapshot jsonb not null check(jsonb_typeof(snapshot)='object' and octet_length(snapshot::text)<=1048576),
 policy_version text not null default 'workspace-member-metadata-review-v1',
 created_at timestamptz not null default now(),
 foreign key(request_id,owner_id) references public.context_requests(id,owner_id),
 unique(owner_id,idempotency_key)
);
create index context_release_case_reviews_request on public.context_release_case_reviews(owner_id,request_id,created_at desc,id);
alter table public.context_release_case_reviews enable row level security;
revoke all on public.context_release_case_reviews from public,anon,authenticated,service_role;
grant select,insert on public.context_release_case_reviews to service_role;

-- Membership is checked again inside the transaction and locked through commit.
-- This policy permits metadata review only, never legal or external-action approval.
create function public.authorize_context_case_actor(p_actor uuid,p_owner uuid)
returns void language plpgsql set search_path='' as $$
begin
 if p_actor is null or p_owner is null then raise exception 'Case access denied' using errcode='42501'; end if;
 if p_actor<>p_owner then
  perform 1 from public.account_organization_ids where account_id=p_actor and organization_id=p_owner for share;
  if not found then raise exception 'Case access denied' using errcode='42501'; end if;
 end if;
end $$;

create function public.list_context_release_cases(p_actor uuid,p_owner uuid,p_after uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare cursor_row public.context_requests; items jsonb; more boolean;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_after is not null then
  select * into strict cursor_row from public.context_requests where id=p_after and owner_id=p_owner and input->>'kind'='release';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('request_id',q.id,'url',q.input->>'url','created_at',q.created_at,'status',q.status) order by q.created_at desc,q.id desc),'[]'::jsonb)
 into items from (select * from public.context_requests where owner_id=p_owner and input->>'kind'='release'
  and (p_after is null or (created_at,id)<(cursor_row.created_at,cursor_row.id)) order by created_at desc,id desc limit 51) q;
 more:=jsonb_array_length(items)>50;
 if more then items:=items-50; end if;
 return jsonb_build_object('cases',items,'has_more',more,'next_id',case when more then items->49->>'request_id' end);
end $$;

create function public.read_context_release_case(p_actor uuid,p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject uuid; page jsonb; identities jsonb; observed public.context_results;
 tracks jsonb:='[]'; manifest jsonb:='[]'; body jsonb; v_fingerprint text; latest jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.id is null or req.input->>'kind' is distinct from 'release' or req.status not in ('partial','completed')
  or jsonb_typeof(req.output->'subjectIds') is distinct from 'array' or jsonb_array_length(req.output->'subjectIds')<>1
 then raise exception 'Case is unavailable' using errcode='42501'; end if;
 subject:=(req.output->'subjectIds'->>0)::uuid;
 -- Follow the existing source-before-document lock order for review consistency.
 perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 join public.context_result_sources rs on rs.source_version_id=v.id and rs.owner_id=v.owner_id
 join public.context_results r on r.id=rs.result_id and r.owner_id=rs.owner_id
 join public.context_attempts a on a.id=r.attempt_id and a.owner_id=r.owner_id
 where r.owner_id=p_owner and r.subject_id=subject and a.request_id=p_request
  and r.topic in ('spotify_release_context','spotify_release_track_isrcs') order by s.id,v.id for share of s,v;
 perform 1 from public.context_documents where owner_id=p_owner and subject_id=subject
  and topic in ('spotify_release_context','spotify_release_track_isrcs') order by id for share;
 page:=public.list_context_release_track_slots(p_owner,p_request,subject,-1,100);
 identities:=public.review_context_release_track_identities(p_owner,p_request,subject);
 if page->>'sourceResultId' is not null then
  select * into strict observed from public.context_results where id=(page->>'sourceResultId')::uuid and owner_id=p_owner;
  -- Project only reviewed metadata fields. Do not expose raw provider payloads.
  select coalesce(jsonb_agg(jsonb_build_object('slot_index',x.value->'slotIndex','spotify_track_id',x.value->>'spotifyTrackId',
   'title',observed.normalized_response->'tracks'->((x.value->>'slotIndex')::integer)->>'name',
   'disc_number',x.value->'discNumber','track_number',x.value->'trackNumber',
   'credited_artists',coalesce((select jsonb_agg(jsonb_build_object('name',artist->>'name','spotify_artist_id',artist->>'id'))
     from jsonb_array_elements(observed.normalized_response->'tracks'->((x.value->>'slotIndex')::integer)->'artists') artist),'[]'::jsonb)) order by (x.value->>'slotIndex')::integer),'[]'::jsonb)
  into tracks from jsonb_array_elements(page->'slots') x;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('document_id',d.id,'document_revision',d.revision,'result_id',r.id,'source_version_id',v.id,
  'source_url',s.source_url,'retrieved_at',v.retrieved_at) order by d.id,v.id),'[]'::jsonb) into manifest
 from public.context_documents d join public.context_results r on r.id=d.current_result_id and r.owner_id=d.owner_id
 join public.context_result_sources rs on rs.result_id=r.id and rs.owner_id=r.owner_id
 join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id and v.removed_at is null
 join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id and s.withdrawn_at is null
 where d.owner_id=p_owner and d.subject_id=subject and r.status='accepted'
  and r.id::text in (page->>'sourceResultId',identities->>'resultId');
 body:=jsonb_build_object('contract_version','release-case-v1','operation','release_metadata_reconciliation',
  'request_id',p_request,'subject_id',subject,'title',observed.normalized_response->'album'->>'name',
  'release_url','https://open.spotify.com/album/'||(page->>'releaseId'),'readiness',case when page->>'state'='ready' then 'partial' else 'blocked' end,
  'tracks',tracks,'track_page',page,'identity_observations',identities,'evidence_manifest',manifest,
  'gaps',jsonb_build_array('Only saved Spotify observations are supported; cross-source comparison is unavailable.',
    'Composition, songwriter, publisher, contracts and approved-master evidence are not yet linked.'),
  'reviewable',page->>'state'='ready' and page->>'hasMore'='false' and jsonb_array_length(manifest)>0,
  'capabilities',jsonb_build_object('distribute','unsupported','register_rights','unsupported','collect_royalties','unsupported'),
  'cost',jsonb_build_object('provider_calls',0,'model_calls',0,'infrastructure_cost','unmeasured'));
 v_fingerprint:=encode(sha256(convert_to(body::text,'UTF8')),'hex');
 select jsonb_build_object('id',v.id,'decision',v.decision,'created_at',v.created_at,'stale',v.fingerprint<>v_fingerprint)
 into latest from public.context_release_case_reviews v where v.owner_id=p_owner and v.request_id=p_request order by v.created_at desc,v.id desc limit 1;
 return body||jsonb_build_object('fingerprint',v_fingerprint,'latest_review',latest);
end $$;

create function public.read_context_release_case_review(p_actor uuid,p_owner uuid,p_review uuid)
returns jsonb language plpgsql set search_path='' as $$
declare saved public.context_release_case_reviews; unavailable boolean; current_case jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into saved from public.context_release_case_reviews where id=p_review and owner_id=p_owner;
 if saved.id is null then raise exception 'Case review unavailable' using errcode='42501'; end if;
 perform 1 from public.context_requests where id=saved.request_id and owner_id=p_owner for share;
 unavailable:=not exists(select 1 from public.context_requests where id=saved.request_id and owner_id=p_owner and status in ('partial','completed'));
 perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 where v.owner_id=p_owner and v.id in (select (value->>'source_version_id')::uuid from jsonb_array_elements(saved.snapshot->'evidence_manifest'))
 order by s.id,v.id for share of s,v;
 unavailable:=unavailable or exists(select 1 from jsonb_array_elements(saved.snapshot->'evidence_manifest') item
  where not exists(select 1 from public.context_source_versions v join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
   join public.context_result_sources rs on rs.source_version_id=v.id and rs.owner_id=v.owner_id
   join public.context_results r on r.id=rs.result_id and r.owner_id=rs.owner_id
   where v.id=(item->>'source_version_id')::uuid and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null
    and r.id=(item->>'result_id')::uuid and r.status='accepted'));
 if not unavailable then current_case:=public.read_context_release_case(p_actor,p_owner,saved.request_id); end if;
 return jsonb_build_object('id',saved.id,'created_at',saved.created_at,'actor_id',saved.actor_id,'decision',saved.decision,
  'policy_version',saved.policy_version,'state',case when unavailable then 'unavailable' else 'saved' end,
  'stale',case when unavailable then null else current_case->>'fingerprint'<>saved.fingerprint end,
  'snapshot',case when unavailable then null else saved.snapshot end,'note',case when unavailable then null else saved.note end);
end $$;

create function public.review_context_release_case(p_actor uuid,p_owner uuid,p_request uuid,p_fingerprint text,p_decision text,p_note text,p_key text)
returns jsonb language plpgsql set search_path='' as $$
declare saved public.context_release_case_reviews; current_case jsonb; saved_id uuid;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$' or p_fingerprint is null or p_fingerprint !~ '^[a-f0-9]{64}$'
  or p_decision is null or p_decision not in ('reviewed','needs_changes') or p_note is null or length(p_note)>2000
 then raise exception 'Invalid metadata review' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_owner::text||':case-review:'||p_key,0));
 select * into saved from public.context_release_case_reviews where owner_id=p_owner and idempotency_key=p_key;
 if saved.id is not null then
  if saved.actor_id<>p_actor or saved.request_id<>p_request or saved.fingerprint<>p_fingerprint or saved.decision<>p_decision or saved.note<>p_note
  then raise exception 'Review key already used for different input' using errcode='22023'; end if;
  return public.read_context_release_case_review(p_actor,p_owner,saved.id);
 end if;
 current_case:=public.read_context_release_case(p_actor,p_owner,p_request);
 if current_case->>'fingerprint'<>p_fingerprint then raise exception 'Evidence changed; reload before reviewing' using errcode='40001'; end if;
 if current_case->>'reviewable'<>'true' then raise exception 'Case evidence is not ready for review' using errcode='22023'; end if;
 insert into public.context_release_case_reviews(owner_id,request_id,actor_id,idempotency_key,fingerprint,decision,note,snapshot)
 values(p_owner,p_request,p_actor,p_key,p_fingerprint,p_decision,p_note,current_case-'latest_review') returning id into saved_id;
 return public.read_context_release_case_review(p_actor,p_owner,saved_id);
end $$;

do $$ declare f text; begin
 foreach f in array array['authorize_context_case_actor(uuid,uuid)','list_context_release_cases(uuid,uuid,uuid)',
 'read_context_release_case(uuid,uuid,uuid)','read_context_release_case_review(uuid,uuid,uuid)',
 'review_context_release_case(uuid,uuid,uuid,text,text,text,text)'] loop
 execute 'revoke all on function public.'||f||' from public,anon,authenticated';
 execute 'grant execute on function public.'||f||' to service_role';
 end loop;
end $$;
commit;
