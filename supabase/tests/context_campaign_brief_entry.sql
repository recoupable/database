-- Run after migrations in a disposable transaction and roll back fixture rows.
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); req jsonb; target jsonb;
 resource public.context_resources; saved public.context_results; source_id uuid;
 brief jsonb:='{"name":"  Release   campaign  ","goal":"Promote the single","audience":"Existing listeners","start_date":"2026-10-01","end_date":"2026-10-31"}'::jsonb;
begin
 insert into public.accounts(id,name) values(owner,'Campaign fixture'),(outsider,'Other fixture');
 req:=public.create_context_campaign_brief_request(owner,owner,brief,'campaign-entry');
 if req->>'status'<>'partial' or req->'input'->'brief'->>'name'<>'Release campaign'
  or req->'input'->>'identityConfirmed'<>'false' then raise exception 'Campaign brief was not saved unresolved'; end if;
 target:=public.list_context_campaign_request_target(owner,(req->>'id')::uuid);
 if target->>'kind'<>'campaign' or target->>'identityConfirmed'<>'false'
  or not (target->'availableFields' ? 'campaign_brief') then raise exception 'Campaign identity was incorrectly confirmed'; end if;
 select r.* into strict resource from public.context_resources r where r.id=(req->>'resource_id')::uuid;
 if resource.canonical_url like '%Release%' or resource.provider_id like '%Release%'
 then raise exception 'Private brief leaked into global resource'; end if;
 select r.* into strict saved from public.context_results r
 where r.owner_id=owner and r.subject_id=(target->>'subjectId')::uuid and r.topic='campaign_brief';
 if saved.evidence_kind<>'customer_assertion' or saved.normalized_response->'brief'->>'goal'<>'Promote the single'
 then raise exception 'Customer brief assertion missing'; end if;
 if (public.create_context_campaign_brief_request(owner,owner,brief,'campaign-entry')->>'id')<>req->>'id'
 then raise exception 'Replay created a second request'; end if;
 begin
  perform public.create_context_campaign_brief_request(owner,owner,brief||'{"goal":"Different"}'::jsonb,'campaign-entry');
  raise exception 'TEST_FAILURE: changed brief reused the key';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;
 begin
  perform public.create_context_campaign_brief_request(owner,owner,'{"name":"Plan","goal":"Launch","start_date":"2026-11-01","end_date":"2026-10-01"}'::jsonb,'invalid-date');
  raise exception 'TEST_FAILURE: reversed dates accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid campaign dates' then raise; end if;
 end;
 begin
  perform public.create_context_campaign_brief_request(owner,owner,brief||'{"claimed_release_id":"unverified"}'::jsonb,'invented-link');
  raise exception 'TEST_FAILURE: unverified subject link accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid campaign brief' then raise; end if;
 end;
 begin
  perform public.list_context_campaign_request_target(outsider,(req->>'id')::uuid);
  raise exception 'TEST_FAILURE: other workspace read target';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 select s.id into strict source_id from public.context_sources s
 join public.context_source_versions v on v.source_id=s.id
 join public.context_result_sources rs on rs.source_version_id=v.id and rs.result_id=saved.id
 where s.owner_id=owner;
 update public.context_sources set withdrawn_at=now() where id=source_id;
 begin
  perform public.list_context_campaign_request_target(owner,(req->>'id')::uuid);
  raise exception 'TEST_FAILURE: withdrawn source remained readable';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 if pg_catalog.has_function_privilege('authenticated','public.create_context_campaign_brief_request(uuid,uuid,jsonb,text)','EXECUTE')
  or pg_catalog.has_function_privilege('authenticated','public.list_context_campaign_request_target(uuid,uuid)','EXECUTE')
 then raise exception 'Browser role can execute campaign context functions'; end if;
end $$;
