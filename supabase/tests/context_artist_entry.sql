-- Run in a transaction against a disposable fixture database; roll back all rows.
do $$
declare owner uuid:=gen_random_uuid(); artist uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); req jsonb; target jsonb; artist_subject uuid;
begin
 insert into public.accounts(id,name) values(owner,'Owner'),(artist,'Fixture artist'),(outsider,'Other workspace');
 insert into public.account_artist_ids(account_id,artist_id) values(owner,artist);
 begin
  perform public.create_context_artist_request(outsider,outsider,artist,'other-workspace');
  raise exception 'TEST_FAILURE: unrelated workspace accepted artist';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Artist not linked to selected workspace' then raise; end if;
 end;
 req:=public.create_context_artist_request(owner,owner,artist,'artist-entry');
 if req->>'status'<>'partial' or req->'input'->>'kind'<>'artist' then raise exception 'Artist request was not saved'; end if;
 target:=public.list_context_artist_request_target(owner,(req->>'id')::uuid);
 artist_subject:=(target->>'subjectId')::uuid;
 if target->>'kind'<>'artist' or target->>'identityConfirmed'<>'true'
 or (target->'availableFields' ? 'artist_account_link') is not true
 or (target->'availableFields' ? 'spotify_id') is true
 then raise exception 'Artist target was not sourced from verified workspace identity'; end if;
 if (public.create_context_artist_request(owner,owner,artist,'artist-entry')->>'id')<>req->>'id'
 then raise exception 'Artist request did not reuse idempotency key'; end if;
 if (select count(*) from public.context_subjects where artist_id=artist)<>1
 or (select count(*) from public.context_results where owner_id=owner and subject_id=artist_subject and topic='artist_identity')<>1
 then raise exception 'Artist identity evidence was duplicated or missing'; end if;
 delete from public.account_artist_ids where account_id=owner and artist_id=artist;
 begin
  perform public.list_context_artist_request_target(owner,(req->>'id')::uuid);
  raise exception 'TEST_FAILURE: removed workspace artist still readable';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 if pg_catalog.has_function_privilege('authenticated','public.create_context_artist_request(uuid,uuid,uuid,text)','EXECUTE')
 or pg_catalog.has_function_privilege('authenticated','public.list_context_artist_request_target(uuid,uuid)','EXECUTE')
 then raise exception 'Browser role can execute artist context function'; end if;
end $$;
