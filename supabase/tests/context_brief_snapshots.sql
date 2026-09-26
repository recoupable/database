-- Disposable database only. The fixture rolls back; no external providers.
begin;
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); resource uuid;
 subject uuid; req uuid; src uuid; ver uuid; attempt uuid; result uuid; doc uuid;
 evidence jsonb; payload jsonb; saved jsonb; readback jsonb;
begin
 insert into public.accounts(id) values(owner),(outsider);
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','release','AAAAAAAAAAAAAAAAAAAAAA','https://open.spotify.com/album/AAAAAAAAAAAAAAAAAAAAAA') returning id into resource;
 insert into public.context_subjects(kind,resource_id) values('release',resource) returning id into subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,resource,'brief-fixture',repeat('a',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(subject))) returning id into req;
 insert into public.context_sources(owner_id,source_url,kind) values(owner,'https://example.test/release','provider_metadata') returning id into src;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content) values(owner,src,repeat('b',64),'{}') returning id into ver;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,recipe_version,schema_version)
 values(owner,req,'song_summary',1,'succeeded','1','1') returning id into attempt;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values(owner,attempt,subject,'song_summary',repeat('c',64),'accepted','observation','{"summary":"Fixture song"}','{"extent":"full"}') returning id into result;
 insert into public.context_result_sources values(owner,result,ver);
 insert into public.context_documents(owner_id,subject_id,topic,revision,current_result_id)
 values(owner,subject,'song_summary',1,result) returning id into doc;
 evidence:=public.read_context_documents(owner,req);
 payload:=jsonb_build_object('request_id',req,'request_ids',jsonb_build_array(req),'purpose','playlist_pitch',
  'text','Playlist-pitch fixture','documents',evidence,'input_manifest',jsonb_build_object(
   'compilerVersion','context-brief-v1','method','saved_evidence_selection','requestIds',jsonb_build_array(req),
   'documents',jsonb_build_array(jsonb_build_object('documentId',doc,'resultId',result,'subjectId',subject,
    'topic','song_summary','version',1,'sourceVersionIds',jsonb_build_array(ver)))));
 saved:=public.save_context_brief(owner,'snapshot-1',payload);
 if saved->'brief'<>payload then raise exception 'Snapshot differs from compiled output'; end if;
 if public.save_context_brief(owner,'snapshot-1',payload)->>'id'<>saved->>'id' then raise exception 'Replay duplicated snapshot'; end if;
 begin
  perform public.save_context_brief(owner,'snapshot-1',jsonb_set(payload,'{text}','"Changed"'));
  raise exception 'TEST_FAILURE: conflicting replay accepted';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  perform public.read_context_brief(outsider,(saved->>'id')::uuid);
  raise exception 'TEST_FAILURE: wrong workspace read snapshot';
 exception when no_data_found then null; end;
 begin
  perform public.save_context_brief(owner,'forged',jsonb_set(payload,'{documents,0,text}','"Invented"'));
  raise exception 'TEST_FAILURE: invented document saved';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  perform public.save_context_brief(owner,'wrong-manifest',jsonb_set(payload,'{input_manifest,documents,0,resultId}',to_jsonb(outsider::text)));
  raise exception 'TEST_FAILURE: mismatched manifest accepted';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 update public.context_documents set revision=revision+1 where id=doc;
 readback:=public.read_context_brief(owner,(saved->>'id')::uuid);
 if readback->'brief'<>payload or readback->>'superseded'<>'true' then raise exception 'Historical snapshot changed or hid newer context'; end if;
 begin
  perform public.save_context_brief(owner,'stale',payload);
  raise exception 'TEST_FAILURE: stale input saved as new snapshot';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 update public.context_requests set status='cancelled' where id=req;
 if public.read_context_brief(owner,(saved->>'id')::uuid)->'brief'<>'null'::jsonb then raise exception 'Cancelled request remained readable'; end if;
 update public.context_requests set status='completed' where id=req;
 perform public.withdraw_context_source(owner,src);
 readback:=public.read_context_brief(owner,(saved->>'id')::uuid);
 if readback->>'state'<>'unavailable' or readback->'brief'<>'null'::jsonb then raise exception 'Withdrawn evidence leaked through snapshot'; end if;
 if pg_catalog.has_function_privilege('authenticated','public.read_context_brief(uuid,uuid)','EXECUTE')
  or pg_catalog.has_function_privilege('anon','public.save_context_brief(uuid,text,jsonb)','EXECUTE')
  or pg_catalog.has_table_privilege('service_role','public.context_briefs','UPDATE')
 then raise exception 'Snapshot privileges are too broad'; end if;
end $$;
rollback;
