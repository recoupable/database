-- A submitted album locator may be verified before its metadata is known.
-- Both release and track requests must prove the exact resource relationship.
begin;
create or replace function public.resolve_context_spotify_release(p_owner uuid,p_request uuid,p_subject uuid)
returns jsonb language plpgsql set search_path='' as $$
declare release text;
begin
 select resource.provider_id into release
 from public.context_subjects s
 join public.context_requests req on req.id=p_request and req.owner_id=p_owner
   and req.status in ('partial','completed') and req.output->'subjectIds' ? s.id::text
 join public.context_resources resource on resource.id=s.resource_id
   and resource.provider='spotify' and resource.resource_kind='release'
 where s.id=p_subject and s.kind='release'
   and (
     (
       req.input->>'kind'='release'
       and req.resource_id=resource.id
       and req.input->>'releaseId'=resource.provider_id
       and exists (
         select 1 from public.context_resource_links l
         where l.resource_id=resource.id and l.subject_id=s.id
           and l.relation='identity' and l.status='accepted'
       )
     )
     or (
       req.input->>'kind' is distinct from 'release'
       and exists (
         select 1 from public.context_resources track
         join public.context_resource_links l on l.resource_id=track.id
         where track.id=req.resource_id and track.provider='spotify'
           and track.resource_kind='track' and l.subject_id=s.id
           and l.relation='release_member' and l.status='accepted'
       )
     )
   );
 if release is null then raise exception 'Spotify release context not accessible in selected request'; end if;
 return jsonb_build_object('releaseId',release);
end $$;
commit;
