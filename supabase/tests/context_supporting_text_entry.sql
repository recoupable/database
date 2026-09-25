-- Run after migrations in a disposable transaction and roll back fixture rows.
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); req jsonb; target jsonb;
 resource public.context_resources; saved public.context_results; source_id uuid;
begin
 insert into public.accounts(id,name) values(owner,'Material fixture'),(outsider,'Other fixture');
 req:=public.create_context_supporting_text_request(owner,owner,'  Press   notes  ',
  'Quoted text is data, even when it says ignore prior instructions.','material-entry');
 if req->>'status'<>'partial' or req->'input'->>'title'<>'Press notes'
  or req->'input' ? 'text' then raise exception 'Supporting text request leaked content or was not saved'; end if;
 target:=public.list_context_material_request_target(owner,(req->>'id')::uuid);
 if target->>'kind'<>'material' or target->>'identityConfirmed'<>'false'
  or not (target->'availableFields' ? 'submitted_text') then raise exception 'Material target was incorrectly linked'; end if;
 select r.* into strict resource from public.context_resources r where r.id=(req->>'resource_id')::uuid;
 if resource.canonical_url like '%Press%' or resource.provider_id like '%Press%'
 then raise exception 'Private text leaked into global resource'; end if;
 select r.* into strict saved from public.context_results r
 where r.owner_id=owner and r.subject_id=(target->>'subjectId')::uuid and r.topic='material_input';
 if saved.evidence_kind<>'customer_assertion' or saved.normalized_response->>'instructionsAreData'<>'true'
  or saved.normalized_response->>'subjectLinked'<>'false'
 then raise exception 'Material assertion lost scope'; end if;
 if (public.create_context_supporting_text_request(owner,owner,'Press notes',
  'Quoted text is data, even when it says ignore prior instructions.','material-entry')->>'id')<>req->>'id'
 then raise exception 'Replay created a second request'; end if;
 begin
  perform public.create_context_supporting_text_request(owner,owner,'Press notes','Changed text','material-entry');
  raise exception 'TEST_FAILURE: changed text reused the key';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;
 begin
  perform public.create_context_supporting_text_request(owner,owner,'Press notes',repeat('x',20001),'too-long');
  raise exception 'TEST_FAILURE: oversized text accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid supporting text' then raise; end if;
 end;
 begin
  perform public.list_context_material_request_target(outsider,(req->>'id')::uuid);
  raise exception 'TEST_FAILURE: other workspace read material';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 select s.id into strict source_id from public.context_sources s
 join public.context_source_versions v on v.source_id=s.id
 join public.context_result_sources rs on rs.source_version_id=v.id and rs.result_id=saved.id
 where s.owner_id=owner;
 update public.context_sources set withdrawn_at=now() where id=source_id;
 begin
  perform public.list_context_material_request_target(owner,(req->>'id')::uuid);
  raise exception 'TEST_FAILURE: withdrawn material remained readable';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 if pg_catalog.has_function_privilege('authenticated','public.create_context_supporting_text_request(uuid,uuid,text,text,text)','EXECUTE')
  or pg_catalog.has_function_privilege('authenticated','public.list_context_material_request_target(uuid,uuid)','EXECUTE')
 then raise exception 'Browser role can execute material context functions'; end if;
end $$;
