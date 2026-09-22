-- Map only artist subjects linked to this request and selected workspace.
begin;
create function public.resolve_context_artist(p_owner uuid,p_request uuid,p_subject uuid)
returns jsonb language plpgsql set search_path='' as $$
declare artist uuid;
begin
 select s.artist_id into artist from public.context_subjects s
 join public.context_requests r on r.owner_id=p_owner and r.id=p_request and r.status in ('partial','completed') and r.output->'subjectIds' ? s.id::text
 where s.id=p_subject and s.kind='artist' and (
 exists(select 1 from public.account_artist_ids a where a.account_id=p_owner and a.artist_id=s.artist_id) or
 exists(select 1 from public.artist_organization_ids a where a.organization_id=p_owner and a.artist_id=s.artist_id));
 if artist is null then raise exception 'Artist context not accessible in selected workspace'; end if;
 return jsonb_build_object('artistId',artist);
end $$;
revoke all on function public.resolve_context_artist(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.resolve_context_artist(uuid,uuid,uuid) to service_role;
commit;
