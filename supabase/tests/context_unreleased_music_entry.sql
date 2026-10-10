-- Run after migrations in a disposable transaction; the fixture rolls back.
-- Synthetic placeholders only: repeat('Z',12) is a fixture key, not a real ISRC.
begin;
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 first jsonb; second jsonb; foreign_rec jsonb; release_a jsonb; release_b jsonb; target jsonb;
 first_subject uuid; second_subject uuid; foreign_subject uuid; isrc_subject uuid;
 resource public.context_resources; saved public.context_results; source_id uuid;
 recording jsonb:='{"title":"  Night   drive  ","working_title":"ND v3","lifecycle_state":"mixed","planned_release_date":"2027-03-05"}'::jsonb;
 single jsonb; release_c jsonb;
begin
 insert into public.accounts(id,name) values(owner,'Unreleased fixture'),(outsider,'Other fixture');
 -- Run the production path with the service role, not the fixture superuser.
 set local role service_role;
 first:=public.create_context_unreleased_recording_request(owner,owner,recording,'recording-1');
 reset role;
 if first->>'status'<>'partial' or first->'input'->>'title'<>'Night drive' or first->'input'->>'kind'<>'unreleased_recording'
  or first->'input'->>'identityConfirmed'<>'false' or first->'input' ? 'isrc'
  or not (first->'output'->'gaps' ? 'ISRC not assigned')
 then raise exception 'Unreleased recording was not saved as an unresolved internal identity: %',first; end if;
 first_subject:=(first->'output'->'subjectIds'->>0)::uuid;
 set local role service_role;
 target:=public.list_context_unreleased_recording_request_target(owner,(first->>'id')::uuid);
 reset role;
 if target->>'subjectId'<>first_subject::text or target->>'kind'<>'unreleased_recording' or target->>'identityConfirmed'<>'false'
  or not (target->'availableFields' ? 'submitted_title') or target->'reusableModules'<>'[]'::jsonb
 then raise exception 'Unreleased recording target was incorrectly linked: %',target; end if;
 select r.* into strict resource from public.context_resources r where r.id=(first->>'resource_id')::uuid;
 if resource.resource_kind<>'recording_input' or resource.canonical_url ilike '%night%' or resource.provider_id ilike '%night%'
 then raise exception 'Private title leaked into global resource'; end if;
 if (select kind from public.context_subjects where id=first_subject)<>'unreleased_recording'
  or (select song_isrc from public.context_subjects where id=first_subject) is not null
 then raise exception 'Internal recording identity acquired an ISRC'; end if;
 select r.* into strict saved from public.context_results r
 where r.owner_id=owner and r.subject_id=first_subject and r.topic='unreleased_recording';
 if saved.evidence_kind<>'customer_assertion' or saved.normalized_response->'identifiers'->>'isrc'<>'unknown'
  or saved.coverage->'identifiers'->>'isrc'<>'unknown' or saved.normalized_response->'recording'->>'lifecycle_state'<>'mixed'
  or saved.normalized_response->'recording'->>'working_title'<>'ND v3' or saved.normalized_response->>'compositionLinked'<>'false'
 then raise exception 'Recording assertion lost its explicit unknowns: %',saved.normalized_response; end if;
 if (public.create_context_unreleased_recording_request(owner,owner,recording,'recording-1')->>'id')<>first->>'id'
 then raise exception 'Replay created a second request'; end if;
 begin
  perform public.create_context_unreleased_recording_request(owner,owner,recording||'{"title":"Other"}'::jsonb,'recording-1');
  raise exception 'TEST_FAILURE: changed recording reused the key';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;
 begin
  perform public.create_context_unreleased_recording_request(owner,owner,recording||'{"isrc":"supplied"}'::jsonb,'invented-isrc');
  raise exception 'TEST_FAILURE: caller-supplied ISRC accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid unreleased recording' then raise; end if;
 end;
 begin
  perform public.create_context_unreleased_recording_request(owner,owner,'{"title":"Draft","lifecycle_state":"released"}'::jsonb,'bad-lifecycle');
  raise exception 'TEST_FAILURE: unknown lifecycle accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid unreleased recording' then raise; end if;
 end;
 begin
  perform public.create_context_unreleased_recording_request(owner,owner,'{"title":"Draft","planned_release_date":"2027-13-01"}'::jsonb,'bad-date');
  raise exception 'TEST_FAILURE: invalid date accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid unreleased recording' then raise; end if;
 end;
 second:=public.create_context_unreleased_recording_request(owner,owner,'{"title":"Second song"}'::jsonb,'recording-2');
 second_subject:=(second->'output'->'subjectIds'->>0)::uuid;
 if (select normalized_response->'recording'->>'lifecycle_state' from public.context_results
   where owner_id=owner and subject_id=second_subject and topic='unreleased_recording')<>'unknown'
 then raise exception 'Omitted lifecycle was not recorded as unknown'; end if;
 -- An ISRC-backed recording with current workspace evidence may also sit on a planned release.
 insert into public.songs(isrc) values(repeat('Z',12));
 insert into public.context_subjects(kind,song_isrc) values('recording',repeat('Z',12)) returning id into isrc_subject;
 perform public.save_context_metadata(owner,(first->>'id')::uuid,isrc_subject,'recording_metadata',
  'https://api.spotify.com/v1/tracks/'||repeat('B',22),'{"name":"Fixture track"}'::jsonb);
 foreign_rec:=public.create_context_unreleased_recording_request(outsider,outsider,'{"title":"Foreign song"}'::jsonb,'recording-1');
 foreign_subject:=(foreign_rec->'output'->'subjectIds'->>0)::uuid;
 set local role service_role;
 release_a:=public.create_context_planned_release_request(owner,owner,jsonb_build_object(
  'title','  Night   Drive EP ','lifecycle_state','scheduled','planned_release_date','2027-03-05',
  'products',jsonb_build_array(jsonb_build_object('format','digital_ep'),jsonb_build_object('format','vinyl','label',' Limited  pressing ')),
  'promotional_links',jsonb_build_array(jsonb_build_object('kind','pre_save','url','https://example.com/presave')),
  'recording_subject_ids',jsonb_build_array(first_subject,isrc_subject,second_subject)),'release-a');
 reset role;
 if release_a->>'status'<>'partial' or release_a->'input'->>'title'<>'Night Drive EP' or release_a->'input'->>'kind'<>'planned_release'
  or release_a->'input' ? 'store_ids' or not (release_a->'output'->'gaps' ? 'UPC and store identifiers not assigned')
 then raise exception 'Planned release was not saved as an unresolved internal identity: %',release_a; end if;
 set local role service_role;
 target:=public.list_context_planned_release_request_target(owner,(release_a->>'id')::uuid);
 reset role;
 if target->>'kind'<>'planned_release' or target->>'identityConfirmed'<>'false'
  or not (target->'availableFields' ? 'tracklist') or not (target->'availableFields' ? 'submitted_title')
 then raise exception 'Planned release target was incorrectly linked: %',target; end if;
 select r.* into strict saved from public.context_results r
 where r.owner_id=owner and r.subject_id=(target->>'subjectId')::uuid and r.topic='planned_release';
 if saved.normalized_response->'storeIds'<>'{"spotify":"unknown","apple_music":"unknown","upc":"unknown"}'::jsonb
  or saved.coverage->'storeIds'->>'upc'<>'unknown'
  or saved.normalized_response->'release'->>'lifecycle_state'<>'scheduled'
  or jsonb_array_length(saved.normalized_response->'release'->'products')<>2
  or saved.normalized_response->'release'->'products'->1->>'label'<>'Limited pressing'
  or saved.normalized_response->'release'->'promotional_links'->0->>'kind'<>'pre_save'
  or saved.normalized_response->'release' ? 'recording_subject_ids'
  or saved.normalized_response->'tracklist'<>jsonb_build_array(
   jsonb_build_object('position',1,'recordingSubjectId',first_subject),
   jsonb_build_object('position',2,'recordingSubjectId',isrc_subject),
   jsonb_build_object('position',3,'recordingSubjectId',second_subject))
  or saved.normalized_response->>'rightsVerified'<>'false' or saved.normalized_response->>'metadataVerified'<>'false'
 then raise exception 'Planned release mixed lifecycle, products or links with store IDs: %',saved.normalized_response; end if;
 select r.* into strict resource from public.context_resources r where r.id=(release_a->>'resource_id')::uuid;
 if resource.resource_kind<>'planned_release_input' or resource.canonical_url ilike '%night%'
 then raise exception 'Private release title leaked into global resource'; end if;
 single:=jsonb_build_object('title','Night Drive (single)','lifecycle_state','planned','recording_subject_ids',jsonb_build_array(first_subject));
 release_b:=public.create_context_planned_release_request(owner,owner,single,'release-b');
 if release_b->>'id'=release_a->>'id' or (release_b->'output'->'subjectIds'->>0)=(release_a->'output'->'subjectIds'->>0)
 then raise exception 'Second planned release collapsed into the first'; end if;
 if (select count(*) from public.context_results r where r.owner_id=owner and r.topic='planned_release' and r.status='accepted'
   and r.normalized_response->'tracklist' @> jsonb_build_array(jsonb_build_object('recordingSubjectId',first_subject)))<>2
 then raise exception 'One recording could not appear on two planned releases'; end if;
 if (public.create_context_planned_release_request(owner,owner,single,'release-b')->>'id')<>release_b->>'id'
 then raise exception 'Planned release replay created a second request'; end if;
 release_c:=public.create_context_planned_release_request(owner,owner,'{"title":"Untitled album"}'::jsonb,'release-c');
 if (select normalized_response->'release'->>'lifecycle_state' from public.context_results
   where owner_id=owner and subject_id=(release_c->'output'->'subjectIds'->>0)::uuid and topic='planned_release')<>'unknown'
 then raise exception 'Omitted release lifecycle was not recorded as unknown'; end if;
 begin
  perform public.create_context_planned_release_request(owner,owner,'{"title":"Nulled","lifecycle_state":null}'::jsonb,'null-lifecycle');
  raise exception 'TEST_FAILURE: null release lifecycle accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,single||'{"lifecycle_state":"announced"}'::jsonb,'release-b');
  raise exception 'TEST_FAILURE: changed release reused the key';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,jsonb_build_object('title','Mystery','lifecycle_state','planned',
   'recording_subject_ids',jsonb_build_array(gen_random_uuid())),'unknown-recording');
  raise exception 'TEST_FAILURE: unknown recording accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Planned release references an unknown recording' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,jsonb_build_object('title','Borrowed','lifecycle_state','planned',
   'recording_subject_ids',jsonb_build_array(foreign_subject)),'foreign-recording');
  raise exception 'TEST_FAILURE: another workspace recording accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Planned release references an unknown recording' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,jsonb_build_object('title','Twice','lifecycle_state','planned',
   'recording_subject_ids',jsonb_build_array(first_subject,first_subject)),'duplicate-slot');
  raise exception 'TEST_FAILURE: duplicate tracklist slot accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,'{"title":"Listed","lifecycle_state":"planned","store_ids":{"spotify":"supplied"}}'::jsonb,'invented-store');
  raise exception 'TEST_FAILURE: caller store IDs accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,'{"title":"Listed","lifecycle_state":"planned","upc":"supplied"}'::jsonb,'invented-upc');
  raise exception 'TEST_FAILURE: caller UPC accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,'{"title":"Linked","lifecycle_state":"planned","promotional_links":[{"kind":"pre_save","url":"spotify:album:placeholder"}]}'::jsonb,'bad-link');
  raise exception 'TEST_FAILURE: non-http link accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,jsonb_build_object('title','Linked','lifecycle_state','planned',
   'promotional_links',(select jsonb_agg(jsonb_build_object('kind','teaser','url','https://example.com/'||n)) from generate_series(1,21) n)),'too-many-links');
  raise exception 'TEST_FAILURE: 21 links accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,'{"title":"Pressed","lifecycle_state":"planned","products":[{"format":"minidisc"}]}'::jsonb,'bad-format');
  raise exception 'TEST_FAILURE: unknown format accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,'{"title":"Out","lifecycle_state":"released"}'::jsonb,'bad-release-lifecycle');
  raise exception 'TEST_FAILURE: unverified store release claimed as released';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid planned release' then raise; end if;
 end;
 begin
  perform public.list_context_unreleased_recording_request_target(outsider,(first->>'id')::uuid);
  raise exception 'TEST_FAILURE: other workspace read recording target';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 begin
  perform public.list_context_planned_release_request_target(outsider,(release_a->>'id')::uuid);
  raise exception 'TEST_FAILURE: other workspace read release target';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 select s.id into strict source_id from public.context_sources s
 join public.context_source_versions v on v.source_id=s.id
 join public.context_result_sources rs on rs.source_version_id=v.id
 join public.context_results r on r.id=rs.result_id and r.subject_id=first_subject and r.topic='unreleased_recording'
 where s.owner_id=owner;
 update public.context_sources set withdrawn_at=now() where id=source_id;
 begin
  perform public.list_context_unreleased_recording_request_target(owner,(first->>'id')::uuid);
  raise exception 'TEST_FAILURE: withdrawn recording remained readable';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 begin
  perform public.create_context_planned_release_request(owner,owner,jsonb_build_object('title','After withdrawal','lifecycle_state','planned',
   'recording_subject_ids',jsonb_build_array(first_subject)),'withdrawn-recording');
  raise exception 'TEST_FAILURE: withdrawn recording linked to a new planned release';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Planned release references an unknown recording' then raise; end if;
 end;
 if (public.create_context_planned_release_request(owner,owner,single,'release-b')->>'id')<>release_b->>'id'
 then raise exception 'Identical planned release replay failed after a recording withdrawal'; end if;
 if (select status from public.context_results where id=saved.id)<>'accepted'
 then raise exception 'Earlier planned release snapshot was rewritten by a recording withdrawal'; end if;
 -- The ISRC-backed recording arm is unchanged by the additive migration.
 begin
  insert into public.context_subjects(kind) values('recording');
  raise exception 'TEST_FAILURE: recording subject saved without an ISRC';
 exception when check_violation then null;
 end;
 begin
  insert into public.context_subjects(kind,song_isrc) values('unreleased_recording',repeat('Y',12));
  raise exception 'TEST_FAILURE: internal recording identity accepted an ISRC column';
 exception when check_violation then null;
 end;
 if exists(select 1 from unnest(array['anon','authenticated']) as browser(role)
   cross join unnest(array[
    'public.create_context_unreleased_recording_request(uuid,uuid,jsonb,text)',
    'public.create_context_planned_release_request(uuid,uuid,jsonb,text)',
    'public.list_context_unreleased_recording_request_target(uuid,uuid)',
    'public.list_context_planned_release_request_target(uuid,uuid)']) as fn(signature)
   where pg_catalog.has_function_privilege(browser.role,fn.signature,'EXECUTE'))
 then raise exception 'Browser role can execute unreleased music functions'; end if;
 if exists(select 1 from unnest(array[
    'public.create_context_unreleased_recording_request(uuid,uuid,jsonb,text)',
    'public.create_context_planned_release_request(uuid,uuid,jsonb,text)',
    'public.list_context_unreleased_recording_request_target(uuid,uuid)',
    'public.list_context_planned_release_request_target(uuid,uuid)']) as fn(signature)
   where not pg_catalog.has_function_privilege('service_role',fn.signature,'EXECUTE'))
 then raise exception 'Service role cannot execute unreleased music functions'; end if;
 raise notice 'PASS: internal identities, explicit unknown identifiers, replay (including after withdrawal), conflicts, unknown release lifecycle, multi-release tracklists, workspace scoping, withdrawal, unchanged ISRC arm and browser grants';
end $$;
rollback;
