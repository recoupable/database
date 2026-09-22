-- Explicit, source-backed repair. Never rewrites historical evidence or infers an album from a track ID.
begin;
create table public.context_release_corrections (
 owner_id uuid not null,
 request_id uuid not null,
 legacy_subject_id uuid not null references public.context_subjects(id),
 canonical_subject_id uuid not null references public.context_subjects(id),
 source_result_id uuid not null references public.context_results(id),
 created_at timestamptz not null default now(),
 primary key(request_id,legacy_subject_id),
 foreign key(request_id,owner_id) references public.context_requests(id,owner_id)
);
alter table public.context_release_corrections enable row level security;
revoke all on public.context_release_corrections from public,anon,authenticated;
grant all on public.context_release_corrections to service_role;
create function public.correct_context_spotify_release(p_owner uuid,p_request uuid,p_subject uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; track text; candidates text[]; source public.context_results; album_resource uuid; canonical uuid; prior public.context_release_corrections;
begin
 select * into strict req from public.context_requests where owner_id=p_owner and id=p_request for update;
 if req.status not in ('partial','completed') then raise exception 'Metadata request not complete'; end if;
 select * into prior from public.context_release_corrections where owner_id=p_owner and request_id=p_request and legacy_subject_id=p_subject;
 if prior.canonical_subject_id is not null then return jsonb_build_object('subjectId',prior.canonical_subject_id,'reused',true); end if;
 if not(req.output->'subjectIds' ? p_subject::text) then raise exception 'Subject outside request'; end if;
 select r.provider_id into track from public.context_subjects s join public.context_resources r on r.id=s.resource_id where s.id=p_subject and s.kind='release' and r.provider='spotify' and r.resource_kind='track';
 if track is null then raise exception 'Expected legacy track-backed release'; end if;
 select array_agg(distinct r.raw_response->'release'->>'id') into candidates from public.context_results r join public.context_attempts a on a.id=r.attempt_id
 where r.owner_id=p_owner and r.subject_id=p_subject and a.request_id=p_request and r.topic='release_metadata' and r.status='accepted' and exists(select 1 from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id join public.context_sources src on src.id=v.source_id where rs.result_id=r.id and src.owner_id=p_owner and src.withdrawn_at is null)
 and r.raw_response->>'trackId'=track and r.raw_response->'raw'->>'id'=track
 and r.raw_response->'raw'->'album'->>'id'=r.raw_response->'release'->>'id'
 and r.raw_response->'release'->>'id' ~ '^[A-Za-z0-9]{22}$';
 if coalesce(cardinality(candidates),0)<>1 then raise exception 'Missing or ambiguous source-backed album identity'; end if;
 select r.* into strict source from public.context_results r join public.context_attempts a on a.id=r.attempt_id where r.owner_id=p_owner and r.subject_id=p_subject and a.request_id=p_request and r.topic='release_metadata' and r.status='accepted' and exists(select 1 from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id join public.context_sources src on src.id=v.source_id where rs.result_id=r.id and src.owner_id=p_owner and src.withdrawn_at is null) and r.raw_response->>'trackId'=track and r.raw_response->'raw'->>'id'=track and r.raw_response->'raw'->'album'->>'id'=candidates[1] and r.raw_response->'release'->>'id'=candidates[1] order by r.created_at desc limit 1;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url) values('spotify','release',candidates[1],'https://open.spotify.com/album/'||candidates[1]) on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into album_resource;
 insert into public.context_subjects(kind,resource_id) values('release',album_resource) on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into canonical;
 insert into public.context_resource_links(resource_id,subject_id,relation,status,evidence) select s.resource_id,canonical,'release_member','accepted',jsonb_build_object('sourceResultId',source.id) from public.context_subjects s where s.id=p_subject on conflict do nothing;
 perform public.save_context_metadata(p_owner,p_request,canonical,'release_metadata','https://open.spotify.com/album/'||candidates[1],source.raw_response->'release',source.created_at);
 insert into public.context_release_corrections(owner_id,request_id,legacy_subject_id,canonical_subject_id,source_result_id) values(p_owner,p_request,p_subject,canonical,source.id);
 update public.context_requests set output=jsonb_set(output,'{subjectIds}',(select jsonb_agg(distinct v) from jsonb_array_elements_text((output->'subjectIds')||jsonb_build_array(canonical::text)) v where v<>p_subject::text)),updated_at=now() where id=p_request;
 return jsonb_build_object('subjectId',canonical,'sourceResultId',source.id,'reused',false);
end $$;
revoke all on function public.correct_context_spotify_release(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.correct_context_spotify_release(uuid,uuid,uuid) to service_role;
commit;
