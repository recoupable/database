-- Owner-scoped cancellation of saved Context requests. Fixtures roll back; no providers are called.
begin;
do $$
declare owner uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 token uuid:=gen_random_uuid(); queued jsonb; running jsonb; done jsonb; part jsonb; failed jsonb; receipt jsonb;
 before_row jsonb; after_row jsonb; req uuid;
begin
 insert into public.accounts(id,name) values(owner,'Synthetic cancellation owner'),(member,'Workspace member'),(outsider,'Other account');
 insert into public.account_organization_ids(account_id,organization_id) values(member,owner);
 queued:=public.create_context_request(owner,member,'cancel-queued',repeat('a',64),'{"url":"https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA"}','AAAAAAAAAAAAAAAAAAAAAA');
 running:=public.create_context_request(owner,member,'cancel-running',repeat('b',64),'{"url":"https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA"}','AAAAAAAAAAAAAAAAAAAAAA');
 done:=public.create_context_request(owner,member,'cancel-completed',repeat('c',64),'{"url":"https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA"}','AAAAAAAAAAAAAAAAAAAAAA');
 part:=public.create_context_request(owner,member,'cancel-partial',repeat('d',64),'{"url":"https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA"}','AAAAAAAAAAAAAAAAAAAAAA');
 failed:=public.create_context_request(owner,member,'cancel-failed',repeat('e',64),'{"url":"https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA"}','AAAAAAAAAAAAAAAAAAAAAA');
 update public.context_requests set status='completed',output='{"subjectIds":[]}' where id=(done->>'id')::uuid;
 update public.context_requests set status='partial',output='{"subjectIds":[],"gaps":[{"topic":"lyrics","status":"unavailable"}]}' where id=(part->>'id')::uuid;

 -- Queued: a workspace member stops the request before any worker claims it.
 req:=(queued->>'id')::uuid;
 receipt:=public.cancel_context_request(owner,member,req);
 if receipt->>'outcome' is distinct from 'cancelled' or receipt->'request'->>'status' is distinct from 'cancelled'
  or receipt->'request'->>'id' is distinct from req::text or receipt->'request' ? 'claim_token'
  or receipt->'request'->>'error' is distinct from 'Cancelled by a workspace member before completion'
  or receipt->'request'->>'lease_expires_at' is not null
 then raise exception 'Queued cancellation receipt is wrong: %',receipt; end if;
 if public.read_context_request(owner,req)->>'status' is distinct from 'cancelled' then raise exception 'Cancellation was not persisted'; end if;
 if public.claim_context_request(owner,req,gen_random_uuid()) then raise exception 'Cancelled request was claimed'; end if;

 -- Replay is idempotent and writes nothing.
 update public.context_requests set updated_at=now()-interval '1 hour' where id=req;
 select to_jsonb(r) into before_row from public.context_requests r where id=req;
 receipt:=public.cancel_context_request(owner,member,req);
 select to_jsonb(r) into after_row from public.context_requests r where id=req;
 if receipt->>'outcome' is distinct from 'already_cancelled' or receipt->'request'->>'status' is distinct from 'cancelled'
  or before_row is distinct from after_row then raise exception 'Replay changed a cancelled request: %',receipt; end if;

 -- Completed and partial requests keep their saved evidence and status.
 foreach req in array array[(done->>'id')::uuid,(part->>'id')::uuid] loop
  select to_jsonb(r) into before_row from public.context_requests r where id=req;
  receipt:=public.cancel_context_request(owner,member,req);
  select to_jsonb(r) into after_row from public.context_requests r where id=req;
  if receipt->>'outcome' is distinct from 'not_cancellable' or receipt->'request'->>'status' is distinct from before_row->>'status'
   or before_row is distinct from after_row then raise exception 'Terminal request changed: %',receipt; end if;
 end loop;

 -- Running with a live lease: the worker loses its claim and cannot commit or fail over the cancellation.
 req:=(running->>'id')::uuid;
 if not public.claim_context_request(owner,req,token) then raise exception 'Fixture claim rejected'; end if;
 receipt:=public.cancel_context_request(owner,member,req);
 if receipt->>'outcome' is distinct from 'cancelled' then raise exception 'Running request not cancelled: %',receipt; end if;
 if exists(select 1 from public.context_requests where id=req and (claim_token is not null or lease_expires_at is not null or status<>'cancelled'))
 then raise exception 'Running cancellation left a live claim'; end if;
 if public.claim_context_request(owner,req,gen_random_uuid()) then raise exception 'Cancelled running request was reclaimed'; end if;
 begin
  perform public.commit_spotify_context(owner,req,token,'{}'::jsonb);
  raise exception 'TEST_FAILURE: stale worker committed over cancellation';
 exception when others then
  if sqlerrm not like '%no longer owns request%' then raise; end if;
 end;
 if public.fail_context_request(owner,req,token,'late failure') then raise exception 'Stale worker overwrote cancellation'; end if;
 if (select status||':'||error from public.context_requests where id=req) is distinct from 'cancelled:Cancelled by a workspace member before completion'
 then raise exception 'Cancellation outcome drifted after stale worker calls'; end if;

 -- Failed requests are retryable, so cancelling them stops future retries.
 req:=(failed->>'id')::uuid;
 perform public.claim_context_request(owner,req,token);
 if not public.fail_context_request(owner,req,token,'provider unavailable') then raise exception 'Fixture failure rejected'; end if;
 receipt:=public.cancel_context_request(owner,member,req);
 if receipt->>'outcome' is distinct from 'cancelled' then raise exception 'Failed request not cancelled: %',receipt; end if;
 if public.claim_context_request(owner,req,gen_random_uuid()) then raise exception 'Cancelled failed request was reclaimed'; end if;

 -- Workspace scope: another owner sees nothing, a non-member or revoked member is denied, and nothing changes.
 req:=(done->>'id')::uuid;
 begin
  perform public.cancel_context_request(outsider,outsider,req);
  raise exception 'TEST_FAILURE: other owner cancelled';
 exception when no_data_found then null; end;
 begin
  perform public.cancel_context_request(owner,outsider,req);
  raise exception 'TEST_FAILURE: non-member cancelled';
 exception when insufficient_privilege then null; end;
 delete from public.account_organization_ids where account_id=member and organization_id=owner;
 begin
  perform public.cancel_context_request(owner,member,req);
  raise exception 'TEST_FAILURE: revoked member cancelled';
 exception when insufficient_privilege then null; end;
 if (select status from public.context_requests where id=req) is distinct from 'completed' then raise exception 'Denied cancellation changed status'; end if;

 -- The production service role can run the function; browser roles cannot.
 set local role service_role;
 receipt:=public.cancel_context_request(owner,owner,(part->>'id')::uuid);
 if receipt->>'outcome' is distinct from 'not_cancellable' then raise exception 'Service role cancellation failed: %',receipt; end if;
 reset role;
 if has_function_privilege('authenticated','public.cancel_context_request(uuid,uuid,uuid)','execute')
  or has_function_privilege('anon','public.cancel_context_request(uuid,uuid,uuid)','execute')
  or not has_function_privilege('service_role','public.cancel_context_request(uuid,uuid,uuid)','execute')
 then raise exception 'Browser bypass exposed'; end if;
 raise notice 'PASS: queued, idempotent replay, terminal evidence kept, running lease fenced, failed retry stopped, workspace scope, revoked membership and role grants';
end $$;
rollback;
