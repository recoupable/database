-- Run after migrations in a disposable transaction. Synthetic workspaces only; promoted links are candidates.
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); artist uuid:=gen_random_uuid();
 other_artist uuid:=gen_random_uuid(); release_resource uuid; artist_subject uuid; release_subject uuid;
 outsider_subject uuid; saved_request uuid; cancelled_request uuid; outsider_request uuid;
 campaign_target jsonb; campaign_subject uuid; req jsonb; target jsonb; legacy jsonb; replay jsonb;
 saved public.context_results; resource public.context_resources; invalid jsonb;
 requests_before bigint; resources_before bigint; legacy_resource uuid; legacy_request uuid;
 legacy_normalized jsonb; legacy_hash text; opaque text; fingerprint text;
 base jsonb:='{"name":"  Catalogue   campaign ","goal":"Promote the back catalogue","audience":"Lapsed listeners","start_date":"2026-11-01","end_date":"2026-11-30"}'::jsonb;
 linked jsonb; brief jsonb;
begin
 fingerprint:=encode(sha256(convert_to('fixture-request','UTF8')),'hex');
 insert into public.accounts(id,name) values(owner,'Campaign links fixture'),(outsider,'Other fixture'),
  (artist,'Fixture artist'),(other_artist,'Other artist');
 -- The workspace already saved an artist and a release on one partial request.
 insert into public.context_subjects(kind,artist_id) values('artist',artist) returning id into artist_subject;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
  values('spotify','release',repeat('C',22),'https://open.spotify.com/album/'||repeat('C',22))
  returning id into release_resource;
 insert into public.context_subjects(kind,resource_id) values('release',release_resource) returning id into release_subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
  values(owner,owner,release_resource,'saved-release',fingerprint,'{"kind":"release"}','partial',
   jsonb_build_object('subjectIds',jsonb_build_array(artist_subject,release_subject),'gaps','[]'::jsonb))
  returning id into saved_request;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
  values(owner,owner,release_resource,'cancelled-release',fingerprint,'{"kind":"release"}','cancelled',
   jsonb_build_object('subjectIds',jsonb_build_array(release_subject))) returning id into cancelled_request;
 -- Another workspace saved its own artist and the same global release.
 insert into public.context_subjects(kind,artist_id) values('artist',other_artist) returning id into outsider_subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
  values(outsider,outsider,release_resource,'outsider-release',fingerprint,'{"kind":"release"}','partial',
   jsonb_build_object('subjectIds',jsonb_build_array(outsider_subject,release_subject))) returning id into outsider_request;
 -- A saved campaign is a subject, never a promoted target.
 campaign_target:=public.create_context_campaign_brief_request(owner,owner,'{"name":"Earlier plan","goal":"Warm up"}'::jsonb,'campaign-target');
 campaign_subject:=(campaign_target->'output'->'subjectIds'->>0)::uuid;

 linked:=jsonb_build_array(jsonb_build_object('request_id',saved_request,'subject_id',release_subject),
  jsonb_build_object('request_id',upper(saved_request::text),'subject_id',artist_subject));
 brief:=base||jsonb_build_object('channels',jsonb_build_array(' Short-form   video ','Radio','press','X'),'promoted',linked);
 req:=public.create_context_campaign_brief_request(owner,owner,brief,'campaign-links');
 if req->>'status'<>'partial' or req->'input'->>'identityConfirmed'<>'false'
  or req->'input'->'brief'->>'name'<>'Catalogue campaign'
  or req->'input'->'brief'->'channels'<>'["Short-form video","Radio","press","X"]'::jsonb
 then raise exception 'Channels were not saved normalized'; end if;
 if jsonb_array_length(req->'input'->'brief'->'promoted')<>2
  or req->'input'->'brief'->'promoted'->0<>jsonb_build_object('request_id',saved_request,'subject_id',release_subject,
   'kind','release','assertion','promoted_candidate','ownership_verified',false)
  or req->'input'->'brief'->'promoted'->1->>'request_id'<>saved_request::text
  or req->'input'->'brief'->'promoted'->1->>'kind'<>'artist'
  or (req->'input'->'brief'->'promoted'->1->>'ownership_verified')::boolean
 then raise exception 'Promoted candidates were not saved as unverified links'; end if;
 if not (req->'output'->'gaps' ? 'Promoted subject ownership and rights not verified')
  or not (req->'output'->'gaps' ? 'Supplied assets not inventoried')
  or req->'output'->'gaps' ? 'No promoted subjects linked'
 then raise exception 'Linked brief gaps are not explicit'; end if;
 if req->>'input_fingerprint'<>encode(sha256(convert_to('campaign-brief-v2:'||(req->'input'->'brief')::text,'UTF8')),'hex')
 then raise exception 'Linked brief fingerprint is not versioned'; end if;
 target:=public.list_context_campaign_request_target(owner,(req->>'id')::uuid);
 if target->>'kind'<>'campaign' or target->>'identityConfirmed'<>'false'
 then raise exception 'Linked campaign target unreadable'; end if;
 select r.* into strict saved from public.context_results r
  where r.owner_id=owner and r.subject_id=(target->>'subjectId')::uuid and r.topic='campaign_brief';
 if saved.normalized_response->'brief'<>req->'input'->'brief' or saved.evidence_kind<>'customer_assertion'
 then raise exception 'Result brief diverged from request input'; end if;
 select r.* into strict resource from public.context_resources r where r.id=(req->>'resource_id')::uuid;
 if resource.canonical_url like '%atalogue%' or resource.provider_id like '%atalogue%'
  or resource.canonical_url like '%'||release_subject::text||'%'
 then raise exception 'Private brief leaked into global resource'; end if;
 if (public.create_context_campaign_brief_request(owner,owner,brief,'campaign-links')->>'id')<>req->>'id'
 then raise exception 'Replay created a second request'; end if;
 begin
  perform public.create_context_campaign_brief_request(owner,owner,
   base||jsonb_build_object('channels',jsonb_build_array('Radio'),'promoted',linked),'campaign-links');
  raise exception 'TEST_FAILURE: changed channels reused the key';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;

 -- Unverifiable targets reject the whole brief and save nothing.
 select count(*) into requests_before from public.context_requests where owner_id=owner;
 select count(*) into resources_before from public.context_resources where resource_kind='campaign_input';
 for invalid in select value from jsonb_array_elements(jsonb_build_array(
  jsonb_build_array(jsonb_build_object('request_id',outsider_request,'subject_id',outsider_subject)),
  jsonb_build_array(jsonb_build_object('request_id',outsider_request,'subject_id',release_subject)),
  jsonb_build_array(jsonb_build_object('request_id',saved_request,'subject_id',outsider_subject)),
  jsonb_build_array(jsonb_build_object('request_id',cancelled_request,'subject_id',release_subject)),
  jsonb_build_array(jsonb_build_object('request_id',campaign_target->>'id','subject_id',campaign_subject)),
  jsonb_build_array(jsonb_build_object('request_id',gen_random_uuid(),'subject_id',release_subject)),
  jsonb_build_array(jsonb_build_object('request_id',saved_request,'subject_id',gen_random_uuid())),
  jsonb_build_array(jsonb_build_object('request_id',saved_request,'subject_id',release_subject),
   jsonb_build_object('request_id',gen_random_uuid(),'subject_id',artist_subject))
 )) loop
  begin
   perform public.create_context_campaign_brief_request(owner,owner,base||jsonb_build_object('promoted',invalid),'rejected-'||md5(invalid::text));
   raise exception 'TEST_FAILURE: unverified promoted target accepted %',invalid;
  exception when others then
   if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid promoted subject' then raise; end if;
  end;
 end loop;
 -- Raw links, file references, asset keys and malformed shapes are not briefs.
 for invalid in select value from jsonb_array_elements(jsonb_build_array(
  base||'{"promoted_url":"https://example.com/release"}'::jsonb,
  base||'{"file_path":"/private/artwork.png"}'::jsonb,
  base||'{"asset":"artwork.png"}'::jsonb,
  base||'{"assets":[]}'::jsonb,
  base||'{"promoted":["https://example.com/release"]}'::jsonb,
  base||jsonb_build_object('promoted',jsonb_build_array(jsonb_build_object('request_id',saved_request,'subject_id',release_subject,'url','https://example.com/release'))),
  base||jsonb_build_object('promoted',jsonb_build_array(jsonb_build_object('request_id','not-a-uuid','subject_id',release_subject))),
  base||jsonb_build_object('promoted',jsonb_build_array(jsonb_build_object('request_id',saved_request,'subject_id',release_subject),
   jsonb_build_object('request_id',saved_request,'subject_id',upper(release_subject::text)))),
  base||jsonb_build_object('promoted',jsonb_build_object('request_id',saved_request,'subject_id',release_subject)),
  base||jsonb_build_object('promoted',(select jsonb_agg(jsonb_build_object('request_id',gen_random_uuid(),'subject_id',gen_random_uuid())) from generate_series(1,21))),
  base||'{"channels":"Radio"}'::jsonb,
  base||'{"channels":["Radio","radio"]}'::jsonb,
  base||'{"channels":["   "]}'::jsonb,
  base||'{"channels":["mailto:team@example.com"]}'::jsonb,
  base||'{"channels":["spotify:album:example"]}'::jsonb,
  base||'{"channels":["C:\\plans\\brief.pdf"]}'::jsonb,
  base-'name',
  base-'goal',
  base||'{"name":null}'::jsonb,
  base||jsonb_build_object('promoted',jsonb_build_array(jsonb_build_object('subject_id',release_subject))),
  base||jsonb_build_object('promoted',jsonb_build_array(jsonb_build_object('request_id',saved_request))),
  base||'{"channels":[1]}'::jsonb,
  base||'{"channels":["https://example.com/channel"]}'::jsonb,
  base||'{"channels":["www.example.com"]}'::jsonb,
  base||'{"channels":["/private/plan.pdf"]}'::jsonb,
  base||'{"channels":["file:plan.pdf"]}'::jsonb,
  base||jsonb_build_object('channels',(select jsonb_agg('channel '||g) from generate_series(1,11) g))
 )) loop
  begin
   perform public.create_context_campaign_brief_request(owner,owner,invalid,'malformed-'||md5(invalid::text));
   raise exception 'TEST_FAILURE: malformed brief accepted %',invalid;
  exception when others then
   if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid campaign brief' then raise; end if;
  end;
 end loop;
 -- A missing brief fails closed instead of saving null fields.
 begin
  perform public.create_context_campaign_brief_request(owner,owner,null,'missing-brief');
  raise exception 'TEST_FAILURE: missing brief accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid campaign brief' then raise; end if;
 end;
 if (select count(*) from public.context_requests where owner_id=owner)<>requests_before
  or (select count(*) from public.context_resources where resource_kind='campaign_input')<>resources_before
 then raise exception 'Rejected brief left partial rows behind'; end if;

 -- Briefs without links keep the original fingerprint and report the missing links explicitly.
 legacy:=public.create_context_campaign_brief_request(owner,owner,base,'campaign-unlinked');
 if legacy->'input'->'brief' ? 'channels' or legacy->'input'->'brief' ? 'promoted'
  or legacy->>'input_fingerprint'<>encode(sha256(convert_to('campaign-brief-v1:'||(legacy->'input'->'brief')::text,'UTF8')),'hex')
  or not (legacy->'output'->'gaps' ? 'No promoted subjects linked')
  or not (legacy->'output'->'gaps' ? 'Supplied assets not inventoried')
 then raise exception 'Unlinked brief changed fingerprint or hid its gap'; end if;
 if (public.create_context_campaign_brief_request(owner,owner,base||'{"channels":[],"promoted":[]}'::jsonb,'campaign-unlinked')->>'id')<>legacy->>'id'
 then raise exception 'Empty link arrays changed the unlinked fingerprint'; end if;
 -- A request saved by the earlier function version replays unchanged under its key.
 legacy_normalized:=jsonb_build_object('name','Catalogue campaign','goal','Promote the back catalogue',
  'audience','Lapsed listeners','start_date','2026-11-01','end_date','2026-11-30');
 legacy_hash:=encode(sha256(convert_to('campaign-brief-v1:'||legacy_normalized::text,'UTF8')),'hex');
 opaque:=encode(sha256(convert_to('campaign-input-v1:'||owner::text||':campaign-pre-existing','UTF8')),'hex');
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
  values('recoup','campaign_input',opaque,'urn:recoup:campaign-input:'||opaque) returning id into legacy_resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
  values(owner,owner,legacy_resource,'campaign-pre-existing',legacy_hash,
   jsonb_build_object('kind','campaign','brief',legacy_normalized,'identityConfirmed',false),'partial',
   '{"subjectIds":[],"gaps":["Promoted subjects and assets not verified"]}'::jsonb) returning id into legacy_request;
 replay:=public.create_context_campaign_brief_request(owner,owner,base,'campaign-pre-existing');
 if (replay->>'id')::uuid<>legacy_request or not (replay->'output'->'gaps' ? 'Promoted subjects and assets not verified')
 then raise exception 'Pre-existing v1 brief did not replay unchanged'; end if;
 begin
  perform public.create_context_campaign_brief_request(owner,owner,brief,'campaign-pre-existing');
  raise exception 'TEST_FAILURE: links were added under an existing key';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;
 if pg_catalog.has_function_privilege('authenticated','public.create_context_campaign_brief_request(uuid,uuid,jsonb,text)','EXECUTE')
  or pg_catalog.has_function_privilege('anon','public.create_context_campaign_brief_request(uuid,uuid,jsonb,text)','EXECUTE')
 then raise exception 'Browser role can execute campaign brief function'; end if;
 raise notice 'PASS: campaign brief links';
end $$;
