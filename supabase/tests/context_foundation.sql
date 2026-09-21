-- Run after the migration in a disposable database; always rolls back fixtures.
begin;
do $$
declare
  owner_a uuid := gen_random_uuid(); owner_b uuid := gen_random_uuid();
  artist uuid := gen_random_uuid(); resource uuid; subject uuid; request uuid;
  attempt uuid; source uuid; source_version uuid; result uuid; document uuid;
begin
  insert into public.accounts(id,name) values(owner_a,'Context test A'),(owner_b,'Context test B'),(artist,'Context artist');
  insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
    values('spotify','track','CaseSensitiveId','https://open.spotify.com/track/CaseSensitiveId') returning id into resource;
  insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
    values('spotify','track','casesensitiveid','https://open.spotify.com/track/casesensitiveid');
  insert into public.context_subjects(kind,artist_id) values('artist',artist) returning id into subject;
  insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
    values(owner_a,owner_a,resource,'request-1',repeat('a',64),'{}') returning id into request;
  begin
    insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
      values(owner_a,owner_a,resource,'request-1',repeat('a',64),'{}');
    raise exception 'duplicate idempotency key accepted';
  exception when unique_violation then null;
  end;
  insert into public.context_attempts(owner_id,request_id,module,attempt,status,recipe_version,schema_version)
    values(owner_a,request,'research',1,'succeeded','1','1') returning id into attempt;
  insert into public.context_sources(owner_id,kind) values(owner_a,'web') returning id into source;
  begin
    insert into public.context_source_versions(owner_id,source_id,fingerprint) values(owner_b,source,repeat('b',64));
    raise exception 'cross-owner source version accepted';
  exception when foreign_key_violation then null;
  end;
  insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
    values(owner_a,source,repeat('c',64),'{"text":"source evidence"}') returning id into source_version;
  insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,coverage,normalized_response)
    values(owner_a,attempt,subject,'artist_research',repeat('d',64),'accepted','interpretation','{}','{"summary":"attributed research"}') returning id into result;
  insert into public.context_documents(owner_id,subject_id,topic) values(owner_a,subject,'artist_research') returning id into document;
  if public.accept_context_result(owner_a,document,result,0) then raise exception 'accepted missing provenance'; end if;
  insert into public.context_result_sources(owner_id,result_id,source_version_id) values(owner_a,result,source_version);
  if public.accept_context_result(owner_b,document,result,0) then raise exception 'cross-owner acceptance'; end if;
  if not public.accept_context_result(owner_a,document,result,0) then raise exception 'valid result rejected'; end if;
  if public.accept_context_result(owner_a,document,result,0) then raise exception 'stale job replaced current result'; end if;
  update public.context_results set evidence_kind = 'creative_proposal' where id = result;
  if public.accept_context_result(owner_a,document,result,1) then raise exception 'proposal became evidence'; end if;
  update public.context_results set evidence_kind = 'interpretation' where id = result;
  if public.withdraw_context_source(owner_b,source) then raise exception 'cross-owner withdrawal'; end if;
  if not public.withdraw_context_source(owner_a,source) then raise exception 'withdrawal failed'; end if;
  if exists(select 1 from public.context_documents where id = document and current_result_id is not null) then raise exception 'withdrawal left current result'; end if;
  if public.accept_context_result(owner_a,document,result,2) then raise exception 'withdrawn source accepted'; end if;
  if has_table_privilege('anon','public.context_sources','SELECT') or has_table_privilege('authenticated','public.context_results','SELECT') then raise exception 'private table accessible to browser'; end if;
  if has_function_privilege('authenticated','public.accept_context_result(uuid,uuid,uuid,bigint)','EXECUTE') then raise exception 'browser can accept results'; end if;
  if (select public from storage.buckets where id='context-private') then raise exception 'context bucket public'; end if;
end;
$$;
rollback;
