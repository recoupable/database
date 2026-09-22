do $$
declare owner uuid; cat uuid:=gen_random_uuid(); other uuid:=gen_random_uuid(); r jsonb; again jsonb; subject uuid;
begin
 select owner_id into strict owner from public.context_requests limit 1;
 insert into public.catalogs(id,name) values(cat,'Context fixture catalog'),(other,'Unlinked fixture');
 insert into public.account_catalogs(account,catalog) values(owner,cat);
 r:=public.create_catalog_context_request(owner,owner,cat,'fixture-'||cat::text);
 again:=public.create_catalog_context_request(owner,owner,cat,'fixture-'||cat::text);
 if r->>'id' is distinct from again->>'id' or r->>'status'<>'partial' then raise exception 'Idempotent request failed'; end if;
 subject:=(r->'output'->'subjectIds'->>0)::uuid;
 if not exists(select 1 from public.context_subjects where id=subject and kind='catalog' and catalog_id=cat) then raise exception 'Catalog identity missing'; end if;
 if not exists(select 1 from public.context_documents where owner_id=owner and subject_id=subject and topic='catalog_identity') then raise exception 'Catalog metadata missing'; end if;
 begin
  perform public.create_catalog_context_request(owner,owner,other,'fixture-denied-'||cat::text);
  raise exception 'TEST_FAILURE: unlinked catalog permitted';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
end $$;
