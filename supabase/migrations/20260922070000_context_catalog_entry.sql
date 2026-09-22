-- Catalog context identifies an existing authorized Recoup catalog, not ownership of its music.
begin;
alter table public.context_resources drop constraint context_resources_provider_check;
alter table public.context_resources add constraint context_resources_provider_check check(provider in ('spotify','youtube','recoup'));
alter table public.context_resources drop constraint context_resources_resource_kind_check;
alter table public.context_resources add constraint context_resources_resource_kind_check check(resource_kind in ('artist','track','release','video','catalog'));
alter table public.context_subjects add column catalog_id uuid references public.catalogs(id) on delete restrict;
create unique index context_subjects_catalog_id_key on public.context_subjects(catalog_id);
alter table public.context_subjects drop constraint context_subjects_kind_check;
alter table public.context_subjects add constraint context_subjects_kind_check check(kind in ('artist','recording','release','video','catalog'));
alter table public.context_subjects drop constraint context_subjects_check;
alter table public.context_subjects add constraint context_subjects_check check(
 (kind='artist' and artist_id is not null and song_isrc is null and resource_id is null and catalog_id is null) or
 (kind='recording' and song_isrc is not null and artist_id is null and resource_id is null and catalog_id is null) or
 (kind in ('release','video') and resource_id is not null and artist_id is null and song_isrc is null and catalog_id is null) or
 (kind='catalog' and catalog_id is not null and artist_id is null and song_isrc is null and resource_id is null)
);
create function public.create_catalog_context_request(p_owner uuid,p_actor uuid,p_catalog uuid,p_key text)
returns jsonb language plpgsql set search_path='' as $$
declare c public.catalogs; resource uuid; subject uuid; r public.context_requests; fingerprint text; uri text;
begin
 -- The API validates actor→workspace membership; this function also checks that workspace→catalog link.
 if not exists(select 1 from public.account_catalogs where account=p_owner and catalog=p_catalog) then raise exception 'Catalog not accessible in selected workspace'; end if;
 select * into strict c from public.catalogs where id=p_catalog;
 fingerprint:=encode(sha256(convert_to('catalog-v1:'||p_catalog::text,'UTF8')),'hex');
 uri:='urn:recoup:catalog:'||p_catalog::text;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url) values('recoup','catalog',p_catalog::text,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,fingerprint,jsonb_build_object('kind','catalog','catalogId',p_catalog)) on conflict(owner_id,idempotency_key) do nothing;
 select * into strict r from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if r.input_fingerprint<>fingerprint then raise exception 'Idempotency key already used for different input'; end if;
 if r.status in ('completed','partial','cancelled') then return to_jsonb(r)-'claim_token'; end if;
 insert into public.context_subjects(kind,catalog_id) values('catalog',p_catalog) on conflict(catalog_id) do update set catalog_id=excluded.catalog_id returning id into subject;
 perform public.save_context_metadata(p_owner,r.id,subject,'catalog_identity',uri,jsonb_build_object('catalogId',c.id,'name',c.name,'updatedAt',c.updated_at,'scope','workspace_private','rightsVerified',false));
 update public.context_requests set status='partial',output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',jsonb_build_array('Catalog member expansion and enrichment not run')),updated_at=now() where id=r.id returning * into r;
 return to_jsonb(r)-'claim_token';
end $$;
revoke all on function public.create_catalog_context_request(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.create_catalog_context_request(uuid,uuid,uuid,text) to service_role;
create function public.resolve_context_catalog(p_owner uuid,p_request uuid,p_subject uuid)
returns jsonb language plpgsql set search_path='' as $$
declare catalog uuid;
begin
 select s.catalog_id into catalog from public.context_subjects s
 join public.context_requests r on r.owner_id=p_owner and r.id=p_request and r.status in ('partial','completed') and r.output->'subjectIds' ? s.id::text
 join public.account_catalogs ac on ac.catalog=s.catalog_id and ac.account=p_owner
 where s.id=p_subject and s.kind='catalog';
 if catalog is null then raise exception 'Catalog context not accessible in selected workspace'; end if;
 return jsonb_build_object('catalogId',catalog);
end $$;
revoke all on function public.resolve_context_catalog(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.resolve_context_catalog(uuid,uuid,uuid) to service_role;
commit;
