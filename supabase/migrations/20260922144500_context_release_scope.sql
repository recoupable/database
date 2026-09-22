-- Resolve provider identity only through a release subject attached to this owner's request.
begin;
create function public.resolve_context_spotify_release(p_owner uuid,p_request uuid,p_subject uuid)
returns jsonb language plpgsql set search_path='' as $$
declare release text;
begin
 select resource.provider_id into release
 from public.context_subjects s
 join public.context_requests r on r.id=p_request and r.owner_id=p_owner
   and r.status in ('partial','completed') and r.output->'subjectIds' ? s.id::text
 join public.context_resources resource on resource.id=s.resource_id
   and resource.provider='spotify' and resource.resource_kind='release'
 where s.id=p_subject and s.kind='release';
 if release is null then raise exception 'Spotify release context not accessible in selected request'; end if;
 return jsonb_build_object('releaseId',release);
end $$;
revoke all on function public.resolve_context_spotify_release(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.resolve_context_spotify_release(uuid,uuid,uuid) to service_role;
commit;
