begin;
do $$
declare actor uuid:=gen_random_uuid(); other uuid:=gen_random_uuid(); guest jsonb; adopted jsonb; worker uuid:=gen_random_uuid(); guest2 jsonb; adopted2 jsonb; payload jsonb; n bigint; before_count bigint;
begin
 insert into public.accounts(id,name) values(actor,'Guest claim test'),(other,'Other user');
 payload:='{"trackId":"2ay96C6SLNv9urvXKD3ecB","title":"LiLBiTcH (feat. Rico Nasty & Soleima)","isrc":"USAT22007772","durationSeconds":135.613,"artists":[{"id":"1QzqrU2lmiW9l1mSvliVoM","name":"chillpill"}],"release":{"id":"6WQTNgQPCS6GApd4cWQUTB","title":"LiLBiTcH","date":"2021-01-22","datePrecision":"day","artwork":[]},"previewUrl":null,"retrievedAt":"2026-09-20T12:00:00Z"}';
 guest:=public.start_context_guest(repeat('b',64),'{"url":"https://open.spotify.com/track/2ay96C6SLNv9urvXKD3ecB","trackId":"2ay96C6SLNv9urvXKD3ecB","topics":["release_metadata","artist_metadata"]}',repeat('c',64),1000);
 if public.read_context_guest(repeat('d',64)) is not null then raise exception 'Invalid token leaked data'; end if;
 if public.claim_context_guest_worker((guest->>'id')::uuid,worker) is null then raise exception 'Worker not claimed'; end if;
 if public.claim_context_guest_worker((guest->>'id')::uuid,gen_random_uuid()) is not null then raise exception 'Duplicate worker admitted'; end if;
 perform public.complete_context_guest((guest->>'id')::uuid,worker,payload);
 adopted:=public.adopt_context_guest(repeat('b',64),actor,actor);
 if public.read_context_guest(repeat('b',64)) is not null then raise exception 'Claimed data still anonymously visible'; end if;
 if public.adopt_context_guest(repeat('b',64),actor,actor)->>'requestId' <> adopted->>'requestId' then raise exception 'Duplicate claim changed request'; end if;
 begin
  perform public.adopt_context_guest(repeat('b',64),other,other);
  raise exception 'Unexpected claim succeeded';
 exception when others then if sqlerrm='Unexpected claim succeeded' then raise; end if; end;
 select count(*) into before_count from public.context_documents where owner_id=actor;
 if before_count<>2 then raise exception 'Guest context not attached'; end if;
 if jsonb_array_length(public.read_context_documents(other,(adopted->>'requestId')::uuid))>0 then raise exception 'Cross-owner leak'; end if;
 -- Signup while extraction is running: complete into the same destination, no refetch.
 guest2:=public.start_context_guest(repeat('e',64),'{"url":"https://open.spotify.com/track/2ay96C6SLNv9urvXKD3ecB","trackId":"2ay96C6SLNv9urvXKD3ecB","topics":["release_metadata","artist_metadata"]}',repeat('f',64),1000);
 worker:=gen_random_uuid();perform public.claim_context_guest_worker((guest2->>'id')::uuid,worker);
 adopted2:=public.adopt_context_guest(repeat('e',64),actor,actor);
 if public.context_guest_worker_scope((guest2->>'id')::uuid,worker)->>'actor'<>actor::text then raise exception 'Worker lost claim destination'; end if;
 perform public.fail_context_guest((guest2->>'id')::uuid,worker);
 if public.read_context_request(actor,(adopted2->>'requestId')::uuid)->>'status'<>'failed' then raise exception 'Claimed failure not visible'; end if;
 worker:=gen_random_uuid();perform public.claim_context_guest_worker((guest2->>'id')::uuid,worker);
 if public.read_context_request(actor,(adopted2->>'requestId')::uuid)->>'status'<>'queued' then raise exception 'Claimed retry not visible'; end if;
 perform public.complete_context_guest((guest2->>'id')::uuid,worker,payload);
 select count(*) into n from public.context_documents where owner_id=actor;
 if n<>before_count then raise exception 'Claim duplicated documents'; end if;
 if exists(select 1 from public.context_documents where owner_id=actor and revision<>1) then raise exception 'Identical context overwritten'; end if;
 -- Expiration is enforced at read and claim, not only by background cleanup.
 update public.context_guest_workspaces set expires_at=now()-interval '1 day' where id=(guest2->>'id')::uuid;
 perform public.purge_expired_context_guests();
 if (select g.payload from public.context_guest_workspaces g where g.id=(guest2->>'id')::uuid) is not null then raise exception 'Claimed temporary payload retained'; end if;
 if public.adopt_context_guest(repeat('e',64),actor,actor)->>'requestId'<>adopted2->>'requestId' then raise exception 'Claim receipt lost'; end if;
 -- Provider refresh preserves a customer correction.
 update public.context_results set evidence_kind='customer_assertion'
 where id in(select current_result_id from public.context_documents where owner_id=actor);
 perform public.save_context_metadata(actor,(adopted->>'requestId')::uuid,d.subject_id,d.topic,'https://example.com/new-metadata','{"name":"Replacement"}',now())
 from public.context_documents d where d.owner_id=actor;
 if exists(select 1 from public.context_documents where owner_id=actor and revision<>1) then raise exception 'Customer correction overwritten'; end if;
 guest:=public.start_context_guest(repeat('1',64),'{"trackId":"2ay96C6SLNv9urvXKD3ecB"}',repeat('2',64),1000);
 update public.context_guest_workspaces set expires_at=now()-interval '1 day' where id=(guest->>'id')::uuid;
 if public.read_context_guest(repeat('1',64)) is not null then raise exception 'Expired guest readable'; end if;
 begin
  perform public.adopt_context_guest(repeat('1',64),actor,actor);
  raise exception 'Expired claim succeeded';
 exception when others then if sqlerrm='Expired claim succeeded' then raise; end if; end;
 perform public.purge_expired_context_guests();
 if exists(select 1 from public.context_guest_workspaces where id=(guest->>'id')::uuid) then raise exception 'Expired guest retained'; end if;
 begin
  perform public.start_context_guest(repeat('3',64),'{}',repeat('4',64),1);
  raise exception 'Quota exceeded';
 exception when others then if sqlerrm='Quota exceeded' then raise; end if; end;
 raise notice 'Guest tests passed: capability, leases, claim before/after completion, private reads, identity reuse, retention';
end $$;
rollback;
