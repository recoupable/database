-- Disposable fixture only: catalog targets require a current selected-workspace link.
begin;
do $$
declare owner uuid:=gen_random_uuid(); catalog_key uuid:=gen_random_uuid(); request uuid; resource uuid; subject uuid; targets jsonb; page jsonb;
begin
 insert into public.accounts(id) values(owner);
 insert into public.catalogs(id,name) values(catalog_key,'Review catalog');
 insert into public.account_catalogs(account,catalog) values(owner,catalog_key);
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url) values('recoup','catalog',catalog_key::text,'urn:recoup:catalog:'||catalog_key::text) returning id into resource;
 insert into public.context_subjects(kind,catalog_id) values('catalog',catalog_key) returning id into subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,resource,'catalog-target-fixture',repeat('f',64),jsonb_build_object('kind','catalog','catalogId',catalog_key),'partial',jsonb_build_object('subjectIds',jsonb_build_array(subject))) returning id into request;
 targets:=public.list_context_request_targets(owner,request);
 if jsonb_array_length(targets)<>1 or targets->0->>'subjectId' is distinct from subject::text
    or targets->0->>'kind' is distinct from 'catalog'
    or targets->0->>'identityConfirmed' is distinct from 'true'
    or (targets->0->'availableFields' ? 'catalog_account_link') is not true
 then raise exception 'Catalog workspace identity was not verified'; end if;
 insert into public.songs(isrc) values('AAA000000001'),('AAA000000002'),('AAA000000003');
 insert into public.catalog_songs(catalog,song) values(catalog_key,'AAA000000001'),(catalog_key,'AAA000000002'),(catalog_key,'AAA000000003');
 page:=public.list_context_catalog_members(owner,request,subject,null,2);
 if page->'members' is distinct from '["AAA000000001","AAA000000002"]'::jsonb
  or page->>'nextCursor' is distinct from 'AAA000000002' or page->>'hasMore' is distinct from 'true'
 then raise exception 'First catalog page is incorrect'; end if;
 page:=public.list_context_catalog_members(owner,request,subject,page->>'nextCursor',2);
 if page->'members' is distinct from '["AAA000000003"]'::jsonb or page->>'hasMore' is distinct from 'false'
 then raise exception 'Second catalog page is incorrect'; end if;
 begin
  perform public.list_context_catalog_members(gen_random_uuid(),request,subject,null,2);
  raise exception 'TEST_FAILURE: wrong owner read catalog members';
 exception when no_data_found then null; end;
 if has_function_privilege('authenticated','public.list_context_catalog_members(uuid,uuid,uuid,text,integer)','execute') then raise exception 'Browser may read catalog members'; end if;
 delete from public.account_catalogs where account=owner and catalog=catalog_key;
 targets:=public.list_context_request_targets(owner,request);
 if targets->0->>'identityConfirmed' is distinct from 'false'
    or (targets->0->'availableFields' ? 'catalog_account_link') is true
 then raise exception 'Removed workspace catalog access still confirmed'; end if;
 begin
  perform public.list_context_catalog_members(owner,request,subject,null,2);
  raise exception 'TEST_FAILURE: removed workspace link still reads catalog members';
 exception when no_data_found then null; end;
end $$;
rollback;
