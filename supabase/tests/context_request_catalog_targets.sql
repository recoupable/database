-- Disposable fixture only: catalog targets require a current selected-workspace link.
begin;
do $$
declare owner uuid:=gen_random_uuid(); catalog_key uuid:=gen_random_uuid(); request uuid; resource uuid; subject uuid; targets jsonb;
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
 delete from public.account_catalogs where account=owner and catalog=catalog_key;
 targets:=public.list_context_request_targets(owner,request);
 if targets->0->>'identityConfirmed' is distinct from 'false'
    or (targets->0->'availableFields' ? 'catalog_account_link') is true
 then raise exception 'Removed workspace catalog access still confirmed'; end if;
end $$;
rollback;
