begin;
do $$
declare owner uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 resource uuid:=gen_random_uuid(); subject uuid:=gen_random_uuid(); req uuid:=gen_random_uuid(); attempt uuid:=gen_random_uuid();
 source uuid:=gen_random_uuid(); version uuid:=gen_random_uuid(); result uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid();
 current_case jsonb; receipt jsonb; replay jsonb; saved_id uuid; old_hash text;
begin
 insert into public.accounts(id,name) values(owner,'Synthetic case owner'),(member,'Reviewer'),(outsider,'Other account');
 insert into public.account_organization_ids(account_id,organization_id) values(member,owner);
 insert into public.context_resources(id,provider,resource_kind,provider_id,canonical_url)
 values(resource,'spotify','release',repeat('A',22),'https://open.spotify.com/album/'||repeat('A',22));
 insert into public.context_subjects(id,kind,resource_id) values(subject,'release',resource);
 insert into public.context_resource_links(resource_id,subject_id,relation,status) values(resource,subject,'identity','accepted');
 insert into public.context_requests(id,owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(req,owner,member,resource,'case-fixture',repeat('a',64),jsonb_build_object('kind','release','releaseId',repeat('A',22),'url','https://open.spotify.com/album/'||repeat('A',22)), 'partial',jsonb_build_object('subjectIds',jsonb_build_array(subject)));
 current_case:=public.read_context_release_case(member,owner,req);
 if current_case->>'readiness' is distinct from 'blocked' or current_case->'evidence_manifest' is distinct from '[]'::jsonb then raise exception 'Uncollected metadata became ready'; end if;
 insert into public.context_attempts(id,owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version)
 values(attempt,owner,req,'spotify_release_context',1,'succeeded','spotify','1','1');
 insert into public.context_sources(id,owner_id,kind,source_url) values(source,owner,'provider_metadata','https://api.spotify.com/v1/albums/'||repeat('A',22));
 insert into public.context_source_versions(id,owner_id,source_id,fingerprint) values(version,owner,source,repeat('b',64));
 insert into public.context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values(result,owner,attempt,subject,'spotify_release_context',repeat('c',64),'accepted','observation',
 jsonb_build_object('releaseId',repeat('A',22),'album',jsonb_build_object('id',repeat('A',22),'name','Fixture release'),
 'tracks',jsonb_build_array(jsonb_build_object('id',repeat('B',22),'name','First','type','track','disc_number',1,'track_number',1)),
 'trackCoverage',jsonb_build_object('extent','full','collectedSlots',1,'reportedTotal',1)),'{"extent":"full"}');
 insert into public.context_result_sources values(owner,result,version);
 insert into public.context_documents(id,owner_id,subject_id,topic,current_result_id,revision) values(doc,owner,subject,'spotify_release_context',result,1);
 perform public.save_context_spotify_release_track_slots(owner,req,subject,result);
 current_case:=public.read_context_release_case(member,owner,req);
 if current_case->>'readiness' is distinct from 'partial' or current_case->>'title' is distinct from 'Fixture release' or jsonb_array_length(current_case->'tracks') is distinct from 1
 then raise exception 'Source-backed case projection failed: %',current_case; end if;
 if public.list_context_release_cases(member,owner)->'cases'->0->>'request_id' is distinct from req::text then raise exception 'Case list lost selected scope'; end if;
 begin
  perform public.read_context_release_case(outsider,outsider,req);
  raise exception 'TEST_FAILURE: other owner read';
 exception when insufficient_privilege then null; end;
 -- Run the full read and insert path with the production service role, not the fixture owner.
 set local role service_role;
 if public.read_context_release_case(member,owner,req)->>'title' is distinct from 'Fixture release' then raise exception 'Service role cannot read'; end if;
 if current_case->'capabilities'->>'distribute' is distinct from 'unsupported' then raise exception 'Metadata implied external authority'; end if;
 begin
  perform public.list_context_release_cases(member,owner,gen_random_uuid());
  raise exception 'TEST_FAILURE: invalid cursor accepted';
 exception when insufficient_privilege then null; end;
 old_hash:=current_case->>'fingerprint';
 receipt:=public.review_context_release_case(member,owner,req,old_hash,'reviewed','Checked metadata','review-1'); saved_id:=(receipt->>'id')::uuid;
 replay:=public.review_context_release_case(member,owner,req,old_hash,'reviewed','Checked metadata','review-1');
 if replay->>'id' is distinct from receipt->>'id' then raise exception 'Retry duplicated review'; end if;
 reset role;
 begin
  perform public.review_context_release_case(member,owner,req,old_hash,'needs_changes','Different','review-1');
  raise exception 'TEST_FAILURE: key reused for different decision';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.read_context_release_case(outsider,owner,req);
  raise exception 'TEST_FAILURE: outsider read';
 exception when insufficient_privilege then null; end;
 update public.context_documents set revision=2 where id=doc;
 if public.read_context_release_case_review(member,owner,saved_id)->>'stale' is distinct from 'true' then raise exception 'Changed evidence review remained current'; end if;
 begin
  perform public.review_context_release_case(member,owner,req,old_hash,'reviewed','','review-2');
  raise exception 'TEST_FAILURE: stale review saved';
 exception when serialization_failure then null; end;
 if jsonb_typeof(public.read_context_release_case_review(member,owner,saved_id)->'snapshot') is distinct from 'object' then raise exception 'Authorized superseded snapshot lost'; end if;
 -- Large releases are visibly bounded and must not receive a whole-case review.
 update public.context_results set normalized_response=jsonb_set(normalized_response,'{tracks}',
  (select jsonb_agg(jsonb_build_object('id',repeat('B',22),'name','Track','type','track','disc_number',1,'track_number',n)) from generate_series(1,101) n)) where id=result;
 update public.context_results set normalized_response=jsonb_set(normalized_response,'{trackCoverage}', '{"extent":"full","collectedSlots":101,"reportedTotal":101}') where id=result;
 perform public.save_context_spotify_release_track_slots(owner,req,subject,result);
 current_case:=public.read_context_release_case(member,owner,req);
 if current_case->>'reviewable' is distinct from 'false' or current_case->'track_page'->>'hasMore' is distinct from 'true' then raise exception 'Truncated release can be reviewed'; end if;
 begin
  perform public.review_context_release_case(member,owner,req,current_case->>'fingerprint','reviewed','','large-review');
  raise exception 'TEST_FAILURE: truncated review saved';
 exception when sqlstate '22023' then null; end;
 perform public.withdraw_context_source(owner,source);
 receipt:=public.read_context_release_case_review(member,owner,saved_id);
 if receipt->>'state' is distinct from 'unavailable' or receipt->'snapshot' is distinct from 'null'::jsonb or receipt->'note' is distinct from 'null'::jsonb then raise exception 'Withdrawn private interpretation leaked'; end if;
 delete from public.account_organization_ids where account_id=member and organization_id=owner;
 begin
  perform public.read_context_release_case_review(member,owner,saved_id);
  raise exception 'TEST_FAILURE: revoked member read';
 exception when insufficient_privilege then null; end;
 if has_function_privilege('authenticated','public.read_context_release_case(uuid,uuid,uuid)','execute')
 or has_table_privilege('authenticated','public.context_release_case_reviews','select')
 then raise exception 'Browser bypass exposed'; end if;
 raise notice 'PASS: scope, unknowns, manifest, exact-version review, retry, stale history, withdrawal, revoked membership and browser grants';
end $$;
rollback;
