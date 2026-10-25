begin;
do $$
declare owner uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 case_id uuid:=gen_random_uuid(); second_case uuid:=gen_random_uuid(); source uuid:=gen_random_uuid(); version uuid:=gen_random_uuid();
 original_snapshot jsonb; new_version uuid:=gen_random_uuid(); foreign_source uuid:=gen_random_uuid(); foreign_version uuid:=gen_random_uuid(); snapshot jsonb; receipt jsonb; replay jsonb; second_page jsonb;
begin
 insert into public.accounts(id,name) values(owner,'Synthetic catalog workspace'),(member,'Synthetic member'),(outsider,'Other workspace');
 insert into public.account_organization_ids(account_id,organization_id) values(member,owner);
 insert into public.context_sources(id,owner_id,kind,source_url) values(source,owner,'provider_metadata','https://example.org/source'),(foreign_source,outsider,'provider_metadata','https://example.org/private');
 insert into public.context_source_versions(id,owner_id,source_id,fingerprint) values(version,owner,source,repeat('a',64)),(foreign_version,outsider,foreign_source,repeat('b',64));
 snapshot:=jsonb_build_object('schema_version',1,'case_id',case_id,'workspace_id',owner,'revision',0,'scope','Synthetic publishing review',
 'sources',jsonb_build_object('s1',jsonb_build_object('id','s1','version','v1','sha256',repeat('a',64),'status','active','locator','private.csv','context_source_version_id',version)),
 'assessments','{}'::jsonb,'findings',jsonb_build_object(
  'f1',jsonb_build_object('id','f1','stage','audit','status','open','cause_id','cause1','rule_version','v1','summary','PRIVATE INTERPRETATION','source_refs',jsonb_build_array(jsonb_build_object('source_id','s1','version','v1'))),
  'f2',jsonb_build_object('id','f2','stage','audit','status','open','cause_id','cause2','rule_version','v1','summary','Independent gap','evidence_gap','Missing contract','source_refs','[]'::jsonb),
  'f3',jsonb_build_object('id','f3','stage','audit','status','open','cause_id','cause1','rule_version','v1','summary','PRIVATE DEPENDENT','evidence_gap','Dependent result','source_refs','[]'::jsonb,'depends_on',jsonb_build_array('f1'))),
 'actions','{}'::jsonb,'attempts','{}'::jsonb,'outcomes','{}'::jsonb);
 snapshot:=jsonb_set(jsonb_set(snapshot,'{case_id}',to_jsonb(upper(case_id::text))),'{workspace_id}',to_jsonb(upper(owner::text)));
 begin
  perform public.save_context_catalog_case(member,owner,case_id,0,'bad-hash',jsonb_set(snapshot,'{sources,s1,sha256}',to_jsonb(repeat('d',64))));
  raise exception 'TEST_FAILURE: linked hash mismatch accepted';
 exception when sqlstate '22023' then null; end;
 original_snapshot:=snapshot;
 set local role service_role;
 receipt:=public.save_context_catalog_case(member,owner,case_id,0,'save-1',snapshot);
 if receipt->>'revision' is distinct from '1' or receipt->>'evidence_kind' is distinct from 'customer_assertion'
 or receipt->>'external_actions' is distinct from 'unsupported' or receipt->'snapshot'->>'revision' is distinct from '1'
 then raise exception 'Invalid saved case contract: %',receipt; end if;
 replay:=public.save_context_catalog_case(member,owner,case_id,0,'save-1',snapshot);
 if replay is distinct from receipt then raise exception 'Exact retry changed receipt'; end if;
 begin
  perform public.save_context_catalog_case(member,owner,case_id,0,'save-1',snapshot||'{"scope":"changed"}');
  raise exception 'TEST_FAILURE: altered replay accepted';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.save_context_catalog_case(member,owner,case_id,0,'stale',snapshot);
  raise exception 'TEST_FAILURE: stale writer accepted';
 exception when serialization_failure then null; end;
 begin
  perform public.read_context_catalog_case(outsider,outsider,case_id);
  raise exception 'TEST_FAILURE: foreign case readable';
 exception when insufficient_privilege then null; end;
 begin
  perform public.read_context_catalog_case(outsider,owner,case_id);
  raise exception 'TEST_FAILURE: outsider read workspace';
 exception when insufficient_privilege then null; end;
 begin
  perform public.save_context_catalog_case(member,owner,case_id,1,'foreign-source',jsonb_set(jsonb_set(jsonb_set(jsonb_set(snapshot,'{revision}','1'),'{sources,s1,version}','"foreign-v1"'),'{findings,f1,source_refs,0,version}','"foreign-v1"'),'{sources,s1,context_source_version_id}',to_jsonb(foreign_version)));
  raise exception 'TEST_FAILURE: foreign source accepted';
 exception when insufficient_privilege then null; end;
 snapshot:=jsonb_set(snapshot,'{revision}','1');
 receipt:=public.save_context_catalog_case(member,owner,case_id,1,'save-2',snapshot);
 if receipt->>'revision' is distinct from '2' then raise exception 'Second revision lost'; end if;
 if public.read_context_catalog_case(member,owner,case_id,1)->>'revision' is distinct from '1' then raise exception 'History overwritten'; end if;
 snapshot:=jsonb_set(jsonb_set(snapshot,'{revision}','0'),'{case_id}',to_jsonb(second_case));
 perform public.save_context_catalog_case(member,owner,second_case,0,'case-2',snapshot);
 receipt:=public.list_context_catalog_cases(member,owner,null,1);
 if receipt->>'has_more' is distinct from 'true' or receipt->>'next_id' is null then raise exception 'Paging missing cursor'; end if;
 second_page:=public.list_context_catalog_cases(member,owner,(receipt->>'next_id')::uuid,1);
 if jsonb_array_length(second_page->'cases')<>1 or second_page->'cases'->0->>'case_id' is not distinct from receipt->'cases'->0->>'case_id'
 then raise exception 'Paging repeated/lost case'; end if;
 begin
  perform public.list_context_catalog_cases(member,owner,gen_random_uuid(),1);
  raise exception 'TEST_FAILURE: invalid cursor accepted';
 exception when insufficient_privilege then null; end;
 reset role;
 -- New source version stays active while an older version is removed. The stale
 -- finding still depends on that older version, not whichever source is latest.
 insert into public.context_source_versions(id,owner_id,source_id,fingerprint) values(new_version,owner,source,repeat('c',64));
 snapshot:=public.read_context_catalog_case(member,owner,case_id)->'snapshot';
 snapshot:=jsonb_set(snapshot,'{sources,s1,version}','"v2"');
 snapshot:=jsonb_set(snapshot,'{sources,s1,sha256}',to_jsonb(repeat('c',64)));
 snapshot:=jsonb_set(snapshot,'{sources,s1,context_source_version_id}',to_jsonb(new_version));
 snapshot:=jsonb_set(snapshot,'{findings,f1,stale}','true');
 perform public.save_context_catalog_case(member,owner,case_id,2,'save-v2',snapshot);
 update public.context_source_versions set removed_at=now() where id=version;
 set local role service_role;
 receipt:=public.read_context_catalog_case(member,owner,case_id);
 if receipt::text like '%PRIVATE INTERPRETATION%' or receipt::text like '%PRIVATE DEPENDENT%'
  or receipt->'snapshot'->'sources'->'s1'->>'version' is distinct from 'v2'
  or receipt->'snapshot'->'findings'->'f2'->>'summary' is distinct from 'Independent gap'
 then raise exception 'Historical source removal leaked latest stale interpretation: %',receipt; end if;
 reset role;
 perform public.withdraw_context_source(owner,source);
 set local role service_role;
 receipt:=public.read_context_catalog_case(member,owner,case_id);
 if receipt->>'state' is distinct from 'partial' or receipt->>'snapshot_usable_for_save' is distinct from 'false'
 or receipt::text like '%PRIVATE INTERPRETATION%' or receipt::text like '%PRIVATE DEPENDENT%' or receipt::text like '%private.csv%'
 then raise exception 'Withdrawn derived source leaked: %',receipt; end if;
 if receipt->'snapshot'->'findings'->'f2'->>'summary' is distinct from 'Independent gap' then raise exception 'Unaffected work removed'; end if;
 if public.read_context_catalog_case(member,owner,case_id,1)::text like '%PRIVATE INTERPRETATION%' then raise exception 'Historical withdrawal leaked'; end if;
 replay:=public.save_context_catalog_case(member,owner,case_id,0,'save-1',original_snapshot);
 if replay->>'state' is distinct from 'partial' or replay::text like '%PRIVATE INTERPRETATION%'
 or replay::text like '%private.csv%' then raise exception 'Idempotent retry bypassed withdrawal'; end if;
 reset role;
 delete from public.account_organization_ids where account_id=member and organization_id=owner;
 begin
  perform public.read_context_catalog_case(member,owner,case_id);
  raise exception 'TEST_FAILURE: revoked member read';
 exception when insufficient_privilege then null; end;
 if has_function_privilege('authenticated','public.read_context_catalog_case(uuid,uuid,uuid,integer)','execute')
 or has_table_privilege('authenticated','public.context_catalog_case_revisions','select')
 or has_table_privilege('service_role','public.context_catalog_case_revisions','update') then raise exception 'Unexpected browser/history grants'; end if;
 raise notice 'PASS: service role, scope, source access, CAS, idempotency, immutable history, paging, selective/transitive withdrawal and revocation';
end $$;
rollback;
