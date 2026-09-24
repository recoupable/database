-- Disposable fixture only: catalog targets require a current selected-workspace link.
begin;
do $$
declare owner uuid:=gen_random_uuid(); catalog_key uuid:=gen_random_uuid(); request uuid; resource uuid; subject uuid; targets jsonb; page jsonb; expansion jsonb; target_page jsonb; first_recording uuid; second_recording uuid;
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
 expansion:=public.expand_context_catalog_members(owner,request,subject,null,2);
 if jsonb_array_length(expansion->'members')<>2 or expansion->>'nextCursor' is distinct from 'AAA000000002'
 then raise exception 'First catalog expansion page is incorrect'; end if;
 first_recording:=(expansion->'members'->0->>'subjectId')::uuid;
 second_recording:=(expansion->'members'->1->>'subjectId')::uuid;
 if public.resolve_context_catalog_member_recording(owner,request,first_recording)->>'isrc' is distinct from 'AAA000000001'
 then raise exception 'Current catalog recording did not resolve'; end if;
 if not exists(select 1 from public.context_subjects where id=first_recording and kind='recording' and song_isrc='AAA000000001')
  or not exists(select 1 from public.context_request_catalog_members where request_id=request and catalog_subject_id=subject and recording_subject_id=first_recording and song_isrc='AAA000000001')
 then raise exception 'Expanded recording identity or request edge missing'; end if;
 if public.expand_context_catalog_members(owner,request,subject,null,2)->'members'->0->>'subjectId' is distinct from first_recording::text
 then raise exception 'Catalog expansion is not idempotent'; end if;
 expansion:=public.expand_context_catalog_members(owner,request,subject,'AAA000000002',2);
 if expansion->'members'->0->>'isrc' is distinct from 'AAA000000003'
  or (select count(*) from public.context_request_catalog_members where request_id=request)<>3
  or jsonb_array_length((select output->'subjectIds' from public.context_requests where id=request))<>1
 then raise exception 'Catalog expansion lost a member or changed the capped subject list'; end if;
 insert into public.songs(isrc) select 'BBB'||lpad(i::text,9,'0') from generate_series(1,101) i;
 insert into public.catalog_songs(catalog,song)
 select catalog_key,'BBB'||lpad(i::text,9,'0') from generate_series(1,101) i;
 expansion:=public.expand_context_catalog_members(owner,request,subject,'AAA000000003',100);
 if jsonb_array_length(expansion->'members')<>100 or expansion->>'hasMore' is distinct from 'true'
 then raise exception 'Large catalog first page did not stay bounded'; end if;
 expansion:=public.expand_context_catalog_members(owner,request,subject,expansion->>'nextCursor',100);
 if jsonb_array_length(expansion->'members')<>1 or expansion->>'hasMore' is distinct from 'false'
  or (select count(*) from public.context_request_catalog_members where request_id=request)<>104
  or jsonb_array_length((select output->'subjectIds' from public.context_requests where id=request))<>1
 then raise exception 'Large catalog expansion missed members or overflowed request subjects'; end if;
 target_page:=public.list_context_catalog_member_targets(owner,request,subject,null,100);
 if jsonb_array_length(target_page->'members')<>100 or target_page->>'hasMore' is distinct from 'true'
  or target_page->'members'->0->>'subjectId' is distinct from first_recording::text
  or target_page->'members'->0->>'identityConfirmed' is distinct from 'true'
  or target_page->'members'->0->'availableFields' is distinct from '["isrc"]'::jsonb
 then raise exception 'Expanded catalog planning targets are invalid'; end if;
 target_page:=public.list_context_catalog_member_targets(owner,request,subject,target_page->>'nextCursor',100);
 if jsonb_array_length(target_page->'members')<>4 or target_page->>'hasMore' is distinct from 'false'
 then raise exception 'Expanded catalog planning target cursor is invalid'; end if;
 insert into public.songs(isrc) values('DDD000000001');
 insert into public.catalog_songs(catalog,song) values(catalog_key,'DDD000000001');
 delete from public.catalog_songs where catalog=catalog_key and song='AAA000000002';
 target_page:=public.list_context_catalog_member_targets(owner,request,subject,null,100);
 if target_page->'members'->1->>'isrc' is distinct from 'AAA000000003'
  or target_page->'members' @> '[{"isrc":"DDD000000001"}]'::jsonb
 then raise exception 'Removed or unexpanded catalog member became a planning target'; end if;
 begin
  perform public.resolve_context_catalog_member_recording(owner,request,second_recording);
  raise exception 'TEST_FAILURE: removed catalog member still resolved';
 exception when no_data_found then null; end;
 begin
  perform public.list_context_catalog_members(gen_random_uuid(),request,subject,null,2);
  raise exception 'TEST_FAILURE: wrong owner read catalog members';
 exception when no_data_found then null; end;
 if has_function_privilege('authenticated','public.list_context_catalog_members(uuid,uuid,uuid,text,integer)','execute') then raise exception 'Browser may read catalog members'; end if;
 if has_function_privilege('authenticated','public.expand_context_catalog_members(uuid,uuid,uuid,text,integer)','execute')
  or has_function_privilege('authenticated','public.list_context_catalog_member_targets(uuid,uuid,uuid,text,integer)','execute')
  or has_function_privilege('authenticated','public.resolve_context_catalog_member_recording(uuid,uuid,uuid)','execute')
  or has_table_privilege('authenticated','public.context_request_catalog_members','select')
 then raise exception 'Browser may expand or inspect catalog members'; end if;
 if not has_function_privilege('service_role','public.expand_context_catalog_members(uuid,uuid,uuid,text,integer)','execute')
  or not has_table_privilege('service_role','public.context_request_catalog_members','insert')
 then raise exception 'Service cannot expand catalog members'; end if;
 insert into public.songs(isrc) values('CCC000000001');
 begin
  insert into public.context_request_catalog_members(request_id,owner_id,catalog_subject_id,recording_subject_id,catalog_id,song_isrc)
  values(request,owner,subject,first_recording,catalog_key,'CCC000000001');
  raise exception 'TEST_FAILURE: mismatched recording identity saved';
 exception when foreign_key_violation then null; end;
 delete from public.account_catalogs where account=owner and catalog=catalog_key;
 targets:=public.list_context_request_targets(owner,request);
 if targets->0->>'identityConfirmed' is distinct from 'false'
    or (targets->0->'availableFields' ? 'catalog_account_link') is true
 then raise exception 'Removed workspace catalog access still confirmed'; end if;
 begin
  perform public.list_context_catalog_members(owner,request,subject,null,2);
  raise exception 'TEST_FAILURE: removed workspace link still reads catalog members';
 exception when no_data_found then null; end;
 begin
  perform public.expand_context_catalog_members(owner,request,subject,null,2);
  raise exception 'TEST_FAILURE: removed workspace link still expands catalog members';
 exception when no_data_found then null; end;
 begin
  perform public.list_context_catalog_member_targets(owner,request,subject,null,2);
  raise exception 'TEST_FAILURE: removed workspace link still exposes catalog targets';
 exception when no_data_found then null; end;
 begin
  perform public.resolve_context_catalog_member_recording(owner,request,first_recording);
  raise exception 'TEST_FAILURE: removed workspace link still resolves recording';
 exception when no_data_found then null; end;
end $$;
rollback;
