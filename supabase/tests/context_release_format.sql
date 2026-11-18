-- Observed release format is projected from saved Spotify album evidence only.
-- Unknown stays unknown: no UPC, reissue or physical format is ever invented.
begin;
do $$
declare owner uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 album_resource uuid:=gen_random_uuid(); album_subject uuid:=gen_random_uuid(); album_req uuid:=gen_random_uuid();
 album_attempt uuid:=gen_random_uuid(); album_source uuid:=gen_random_uuid(); album_version uuid:=gen_random_uuid();
 album_result uuid:=gen_random_uuid(); album_doc uuid:=gen_random_uuid();
 single_resource uuid:=gen_random_uuid(); single_subject uuid:=gen_random_uuid(); single_req uuid:=gen_random_uuid();
 single_attempt uuid:=gen_random_uuid(); single_source uuid:=gen_random_uuid(); single_version uuid:=gen_random_uuid();
 single_result uuid:=gen_random_uuid(); single_doc uuid:=gen_random_uuid();
 long_resource uuid:=gen_random_uuid(); long_subject uuid:=gen_random_uuid(); long_req uuid:=gen_random_uuid();
 long_attempt uuid:=gen_random_uuid(); long_source uuid:=gen_random_uuid(); long_version uuid:=gen_random_uuid();
 long_result uuid:=gen_random_uuid(); long_doc uuid:=gen_random_uuid();
 part_resource uuid:=gen_random_uuid(); part_subject uuid:=gen_random_uuid(); part_req uuid:=gen_random_uuid();
 part_attempt uuid:=gen_random_uuid(); part_source uuid:=gen_random_uuid(); part_version uuid:=gen_random_uuid();
 part_result uuid:=gen_random_uuid(); part_doc uuid:=gen_random_uuid();
 current_case jsonb; format jsonb; before_hash text; slot_rows integer; receipt jsonb;
begin
 insert into public.accounts(id,name) values(owner,'Synthetic format owner'),(member,'Reviewer'),(outsider,'Other account');
 insert into public.account_organization_ids(account_id,organization_id) values(member,owner);
 insert into public.context_resources(id,provider,resource_kind,provider_id,canonical_url) values
  (album_resource,'spotify','release',repeat('A',22),'https://open.spotify.com/album/'||repeat('A',22)),
  (single_resource,'spotify','release',repeat('C',22),'https://open.spotify.com/album/'||repeat('C',22));
 insert into public.context_subjects(id,kind,resource_id) values(album_subject,'release',album_resource),(single_subject,'release',single_resource);
 insert into public.context_resource_links(resource_id,subject_id,relation,status) values
  (album_resource,album_subject,'identity','accepted'),(single_resource,single_subject,'identity','accepted');
 insert into public.context_requests(id,owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output) values
  (album_req,owner,member,album_resource,'format-album',repeat('a',64),jsonb_build_object('kind','release','releaseId',repeat('A',22),'url','https://open.spotify.com/album/'||repeat('A',22)),'partial',jsonb_build_object('subjectIds',jsonb_build_array(album_subject))),
  (single_req,owner,member,single_resource,'format-single',repeat('b',64),jsonb_build_object('kind','release','releaseId',repeat('C',22),'url','https://open.spotify.com/album/'||repeat('C',22)),'partial',jsonb_build_object('subjectIds',jsonb_build_array(single_subject)));
 -- Uncollected: the format block exists with explicit uncollected/unknown states and the case stays blocked.
 current_case:=public.read_context_release_case(member,owner,album_req);
 format:=current_case->'release_format';
 if format is null then raise exception 'release_format missing from uncollected case: %',current_case; end if;
 if current_case->>'readiness' is distinct from 'blocked' or format->>'state' is distinct from 'uncollected'
  or format->>'format_state' is distinct from 'unknown' or format->>'upc_state' is distinct from 'uncollected'
  or format->'disc_count' is distinct from 'null'::jsonb or format->'multi_disc' is distinct from 'null'::jsonb
  or format->'upc' is distinct from 'null'::jsonb or format->>'reissue' is distinct from 'unknown' or format->>'physical_format' is distinct from 'unknown'
  or format->>'track_coverage' is distinct from 'uncollected'
 then raise exception 'Uncollected format was not explicit: %',format; end if;
 -- Multi-disc album observation: disc 1 tracks 1-2, disc 2 track 1, no external_ids at all.
 insert into public.context_attempts(id,owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version)
 values(album_attempt,owner,album_req,'spotify_release_context',1,'succeeded','spotify','1','1');
 insert into public.context_sources(id,owner_id,kind,source_url) values(album_source,owner,'provider_metadata','https://api.spotify.com/v1/albums/'||repeat('A',22));
 insert into public.context_source_versions(id,owner_id,source_id,fingerprint) values(album_version,owner,album_source,repeat('c',64));
 insert into public.context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values(album_result,owner,album_attempt,album_subject,'spotify_release_context',repeat('d',64),'accepted','observation',
  jsonb_build_object('releaseId',repeat('A',22),
   'album',jsonb_build_object('id',repeat('A',22),'name','Fixture double album','album_type','album','total_tracks',3,
    'release_date','2024-05-17','release_date_precision','day','label','Fixture label'),
   'tracks',jsonb_build_array(
    jsonb_build_object('id',repeat('B',22),'name','First','type','track','disc_number',1,'track_number',1),
    jsonb_build_object('id',repeat('D',22),'name','Second','type','track','disc_number',1,'track_number',2),
    jsonb_build_object('id',repeat('E',22),'name','Third','type','track','disc_number',2,'track_number',1)),
   'trackCoverage',jsonb_build_object('extent','full','collectedSlots',3,'reportedTotal',3)),'{"extent":"full"}');
 insert into public.context_result_sources values(owner,album_result,album_version);
 insert into public.context_documents(id,owner_id,subject_id,topic,current_result_id,revision) values(album_doc,owner,album_subject,'spotify_release_context',album_result,1);
 perform public.save_context_spotify_release_track_slots(owner,album_req,album_subject,album_result);
 current_case:=public.read_context_release_case(member,owner,album_req);
 format:=current_case->'release_format';
 if current_case->>'readiness' is distinct from 'partial' or format->>'state' is distinct from 'observed'
  or format->>'format_state' is distinct from 'album' or format->>'observed_type' is distinct from 'album'
  or (format->>'disc_count')::integer is distinct from 2 or format->>'multi_disc' is distinct from 'true'
  or (format->>'reported_total_tracks')::integer is distinct from 3 or format->>'release_date' is distinct from '2024-05-17'
  or format->>'release_date_precision' is distinct from 'day' or format->>'label' is distinct from 'Fixture label'
  or format->'upc' is distinct from 'null'::jsonb or format->>'upc_state' is distinct from 'not_observed'
  or format->>'reissue' is distinct from 'unknown' or format->>'physical_format' is distinct from 'unknown'
  or format->>'source' is distinct from 'spotify_album_observation' or format->>'track_coverage' is distinct from 'full'
 then raise exception 'Multi-disc album format projection failed: %',format; end if;
 if current_case->'tracks'->2->>'disc_number' is distinct from '2' or current_case->'tracks'->2->>'track_number' is distinct from '1'
 then raise exception 'Disc structure lost in track projection: %',current_case->'tracks'; end if;
 if not exists(select 1 from jsonb_array_elements_text(current_case->'gaps') g where g like 'Reissue and physical-format status%')
 then raise exception 'Format limitation was not disclosed as a gap: %',current_case->'gaps'; end if;
 -- Repeated slot save adds no duplicate evidence and does not move the fingerprint.
 before_hash:=current_case->>'fingerprint';
 perform public.save_context_spotify_release_track_slots(owner,album_req,album_subject,album_result);
 select count(*) into slot_rows from public.context_release_track_slots where owner_id=owner and release_subject_id=album_subject;
 if slot_rows<>3 then raise exception 'Repeated slot save duplicated evidence: % rows',slot_rows; end if;
 current_case:=public.read_context_release_case(member,owner,album_req);
 if current_case->>'fingerprint' is distinct from before_hash or (current_case->'track_page'->>'linkedSlots')::integer is distinct from 3
 then raise exception 'Repeated save changed the case'; end if;
 -- A changed observed type is changed evidence: the fingerprint moves and a saved review turns stale.
 receipt:=public.review_context_release_case(member,owner,album_req,before_hash,'reviewed','Checked format','format-review-1');
 update public.context_results set normalized_response=jsonb_set(normalized_response,'{album,album_type}','"compilation"') where id=album_result;
 current_case:=public.read_context_release_case(member,owner,album_req);
 if current_case->'release_format'->>'format_state' is distinct from 'compilation' or current_case->>'fingerprint'=before_hash
  or current_case->'latest_review'->>'stale' is distinct from 'true'
 then raise exception 'Changed format did not invalidate the review: %',current_case->'latest_review'; end if;
 -- Single with an observed synthetic UPC passes through unchanged; absent label/date stay null.
 insert into public.context_attempts(id,owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version)
 values(single_attempt,owner,single_req,'spotify_release_context',1,'succeeded','spotify','1','1');
 insert into public.context_sources(id,owner_id,kind,source_url) values(single_source,owner,'provider_metadata','https://api.spotify.com/v1/albums/'||repeat('C',22));
 insert into public.context_source_versions(id,owner_id,source_id,fingerprint) values(single_version,owner,single_source,repeat('e',64));
 insert into public.context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values(single_result,owner,single_attempt,single_subject,'spotify_release_context',repeat('f',64),'accepted','observation',
  jsonb_build_object('releaseId',repeat('C',22),
   'album',jsonb_build_object('id',repeat('C',22),'name','Fixture single','album_type','single','total_tracks',1,
    'external_ids',jsonb_build_object('upc',repeat('0',12))),
   'tracks',jsonb_build_array(jsonb_build_object('id',repeat('F',22),'name','Only','type','track','disc_number',1,'track_number',1)),
   'trackCoverage',jsonb_build_object('extent','full','collectedSlots',1,'reportedTotal',1)),'{"extent":"full"}');
 insert into public.context_result_sources values(owner,single_result,single_version);
 insert into public.context_documents(id,owner_id,subject_id,topic,current_result_id,revision) values(single_doc,owner,single_subject,'spotify_release_context',single_result,1);
 perform public.save_context_spotify_release_track_slots(owner,single_req,single_subject,single_result);
 format:=public.read_context_release_case(member,owner,single_req)->'release_format';
 if format->>'format_state' is distinct from 'single' or format->>'multi_disc' is distinct from 'false'
  or (format->>'disc_count')::integer is distinct from 1 or (format->>'reported_total_tracks')::integer is distinct from 1
  or format->>'upc' is distinct from repeat('0',12) or format->>'upc_state' is distinct from 'observed'
  or format->'label' is distinct from 'null'::jsonb or format->'release_date' is distinct from 'null'::jsonb
 then raise exception 'Single format projection failed: %',format; end if;
 -- A release longer than the 100-slot display page whose second disc starts only beyond it:
 -- disc structure must come from the whole observed track array, not the truncated page.
 insert into public.context_resources(id,provider,resource_kind,provider_id,canonical_url) values
  (long_resource,'spotify','release',repeat('G',22),'https://open.spotify.com/album/'||repeat('G',22));
 insert into public.context_subjects(id,kind,resource_id) values(long_subject,'release',long_resource);
 insert into public.context_resource_links(resource_id,subject_id,relation,status) values(long_resource,long_subject,'identity','accepted');
 insert into public.context_requests(id,owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output) values
  (long_req,owner,member,long_resource,'format-long',repeat('9',64),jsonb_build_object('kind','release','releaseId',repeat('G',22),'url','https://open.spotify.com/album/'||repeat('G',22)),'partial',jsonb_build_object('subjectIds',jsonb_build_array(long_subject)));
 insert into public.context_attempts(id,owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version)
 values(long_attempt,owner,long_req,'spotify_release_context',1,'succeeded','spotify','1','1');
 insert into public.context_sources(id,owner_id,kind,source_url) values(long_source,owner,'provider_metadata','https://api.spotify.com/v1/albums/'||repeat('G',22));
 insert into public.context_source_versions(id,owner_id,source_id,fingerprint) values(long_version,owner,long_source,repeat('8',64));
 insert into public.context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values(long_result,owner,long_attempt,long_subject,'spotify_release_context',repeat('7',64),'accepted','observation',
  jsonb_build_object('releaseId',repeat('G',22),
   'album',jsonb_build_object('id',repeat('G',22),'name','Fixture long album','album_type','album','total_tracks',101),
   'tracks',(select jsonb_agg(jsonb_build_object('id',repeat('H',22),'name','Track','type','track',
     'disc_number',case when n<=100 then 1 else 2 end,'track_number',case when n<=100 then n else 1 end) order by n) from generate_series(1,101) n),
   'trackCoverage',jsonb_build_object('extent','full','collectedSlots',101,'reportedTotal',101)),'{"extent":"full"}');
 insert into public.context_result_sources values(owner,long_result,long_version);
 insert into public.context_documents(id,owner_id,subject_id,topic,current_result_id,revision) values(long_doc,owner,long_subject,'spotify_release_context',long_result,1);
 perform public.save_context_spotify_release_track_slots(owner,long_req,long_subject,long_result);
 current_case:=public.read_context_release_case(member,owner,long_req);
 format:=current_case->'release_format';
 if current_case->'track_page'->>'hasMore' is distinct from 'true' or jsonb_array_length(current_case->'tracks')<>100
  or exists(select 1 from jsonb_array_elements(current_case->'tracks') t where t->>'disc_number' is distinct from '1')
 then raise exception 'Long release fixture did not truncate the display page to disc 1: %',current_case->'track_page'; end if;
 if (format->>'disc_count')::integer is distinct from 2 or format->>'multi_disc' is distinct from 'true'
  or (format->>'reported_total_tracks')::integer is distinct from 101
 then raise exception 'Disc structure beyond the 100-slot page was under-counted: %',format; end if;
 -- Partial collection (page limit or a failed later page): 50 of 60 reported slots, all on disc 1 so far.
 -- The unseen slots may sit on another disc, so the disc count and single-disc status stay unknown.
 insert into public.context_resources(id,provider,resource_kind,provider_id,canonical_url) values
  (part_resource,'spotify','release',repeat('J',22),'https://open.spotify.com/album/'||repeat('J',22));
 insert into public.context_subjects(id,kind,resource_id) values(part_subject,'release',part_resource);
 insert into public.context_resource_links(resource_id,subject_id,relation,status) values(part_resource,part_subject,'identity','accepted');
 insert into public.context_requests(id,owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output) values
  (part_req,owner,member,part_resource,'format-partial',repeat('6',64),jsonb_build_object('kind','release','releaseId',repeat('J',22),'url','https://open.spotify.com/album/'||repeat('J',22)),'partial',jsonb_build_object('subjectIds',jsonb_build_array(part_subject)));
 insert into public.context_attempts(id,owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version)
 values(part_attempt,owner,part_req,'spotify_release_context',1,'succeeded','spotify','1','1');
 insert into public.context_sources(id,owner_id,kind,source_url) values(part_source,owner,'provider_metadata','https://api.spotify.com/v1/albums/'||repeat('J',22));
 insert into public.context_source_versions(id,owner_id,source_id,fingerprint) values(part_version,owner,part_source,repeat('5',64));
 insert into public.context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values(part_result,owner,part_attempt,part_subject,'spotify_release_context',repeat('4',64),'accepted','observation',
  jsonb_build_object('releaseId',repeat('J',22),
   'album',jsonb_build_object('id',repeat('J',22),'name','Fixture partial album','album_type','album','total_tracks',60),
   'tracks',(select jsonb_agg(jsonb_build_object('id',repeat('K',22),'name','Track','type','track','disc_number',1,'track_number',n) order by n) from generate_series(1,50) n),
   'trackCoverage',jsonb_build_object('extent','partial','collectedSlots',50,'reportedTotal',60,
    'next','https://api.spotify.com/v1/albums/'||repeat('J',22)||'/tracks?offset=50&limit=50')),'{"extent":"partial"}');
 insert into public.context_result_sources values(owner,part_result,part_version);
 insert into public.context_documents(id,owner_id,subject_id,topic,current_result_id,revision) values(part_doc,owner,part_subject,'spotify_release_context',part_result,1);
 perform public.save_context_spotify_release_track_slots(owner,part_req,part_subject,part_result);
 format:=public.read_context_release_case(member,owner,part_req)->'release_format';
 if format->>'track_coverage' is distinct from 'partial' or format->'disc_count' is distinct from 'null'::jsonb
  or format->'multi_disc' is distinct from 'null'::jsonb or format->>'format_state' is distinct from 'album'
  or (format->>'reported_total_tracks')::integer is distinct from 60
 then raise exception 'Partial track list reported a definite disc structure: %',format; end if;
 -- A partial list that already shows disc 2 proves multiple discs, but not how many.
 format:=public.project_context_release_format(jsonb_build_object('album_type','album','total_tracks',4),
  jsonb_build_array(jsonb_build_object('disc_number',1),jsonb_build_object('disc_number',2)),
  jsonb_build_object('extent','partial','collectedSlots',2,'reportedTotal',4));
 if format->>'multi_disc' is distinct from 'true' or format->'disc_count' is distinct from 'null'::jsonb or format->>'track_coverage' is distinct from 'partial'
 then raise exception 'Partial multi-disc list was not a lower bound: %',format; end if;
 -- A claimed full extent whose slot count differs from the reported total is still partial.
 format:=public.project_context_release_format(jsonb_build_object('album_type','album','total_tracks',3),
  jsonb_build_array(jsonb_build_object('disc_number',1)),jsonb_build_object('extent','full','collectedSlots',1,'reportedTotal',3));
 if format->>'track_coverage' is distinct from 'partial' or format->'disc_count' is distinct from 'null'::jsonb or format->'multi_disc' is distinct from 'null'::jsonb
 then raise exception 'Mismatched slot count was treated as full coverage: %',format; end if;
 -- Disc zero is invalid, matching the positive-number track-slot constraint.
 format:=public.project_context_release_format('{"album_type":"album"}', '[{"disc_number":0}]',
  '{"extent":"full","reportedTotal":1}');
 if format->'disc_count' is distinct from 'null'::jsonb or format->'multi_disc' is distinct from 'null'::jsonb
 then raise exception 'Invalid disc zero became a definite disc structure: %',format; end if;
 -- Helper edge cases: absent or unexpected provider values stay unknown; an unavailable slot leaves the disc count unknown.
 format:=public.project_context_release_format(jsonb_build_object('id',repeat('A',22),'name','No type'),
  jsonb_build_array(jsonb_build_object('disc_number',1),'null'::jsonb,jsonb_build_object('disc_number','x')),
  jsonb_build_object('extent','full','collectedSlots',3,'reportedTotal',3));
 if format->>'state' is distinct from 'observed' or format->>'format_state' is distinct from 'unknown' or format->'observed_type' is distinct from 'null'::jsonb
  or format->>'track_coverage' is distinct from 'full' or format->'disc_count' is distinct from 'null'::jsonb
  or format->'multi_disc' is distinct from 'null'::jsonb or format->>'upc_state' is distinct from 'not_observed'
 then raise exception 'Absent album_type or unnumbered slots were not kept unknown: %',format; end if;
 format:=public.project_context_release_format(jsonb_build_object('album_type','ep','total_tracks','many','external_ids',jsonb_build_object('upc','')),'[]'::jsonb,null);
 if format->>'format_state' is distinct from 'unknown' or format->>'observed_type' is distinct from 'ep' or format->'reported_total_tracks' is distinct from 'null'::jsonb
  or format->>'upc_state' is distinct from 'not_observed' or format->'upc' is distinct from 'null'::jsonb
  or format->'disc_count' is distinct from 'null'::jsonb or format->'multi_disc' is distinct from 'null'::jsonb
  or format->>'track_coverage' is distinct from 'partial'
 then raise exception 'Unexpected provider values were not kept unknown: %',format; end if;
 format:=public.project_context_release_format(null,null,null);
 if format->>'state' is distinct from 'uncollected' or format->>'upc_state' is distinct from 'uncollected' or format->>'format_state' is distinct from 'unknown'
  or format->>'track_coverage' is distinct from 'uncollected'
 then raise exception 'Null evidence was not uncollected: %',format; end if;
 -- Production service role reads the projection; outsiders and browser roles do not.
 set local role service_role;
 if public.read_context_release_case(member,owner,album_req)->'release_format'->>'format_state' is distinct from 'compilation' then raise exception 'Service role cannot read format'; end if;
 reset role;
 begin
  perform public.read_context_release_case(outsider,owner,album_req);
  raise exception 'TEST_FAILURE: outsider read format';
 exception when insufficient_privilege then null; end;
 if has_function_privilege('authenticated','public.project_context_release_format(jsonb,jsonb,jsonb)','execute')
  or has_function_privilege('anon','public.read_context_release_case(uuid,uuid,uuid)','execute')
 then raise exception 'Browser bypass exposed'; end if;
 raise notice 'PASS: uncollected and unknown states, multi-disc album, disc beyond the 100-slot page, partial track list keeps disc structure unknown, single with observed UPC, repeated save without duplicates, changed-format staleness, service role and outsider denial';
end $$;
rollback;
