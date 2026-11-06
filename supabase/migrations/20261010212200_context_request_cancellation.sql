-- Deterministic, owner-scoped cancellation of a saved Context request (recoupable/app#2122).
-- Cancellation changes only context_requests.status and releases its worker claim. The saved error,
-- output and evidence are kept, so a failed request's classified failure reason stays readable and
-- request state never overwrites provider state. It makes no credit, enrichment-attempt or
-- provider-settlement change (paid settlement remains the CE07 lane) and never withdraws evidence
-- that was already accepted. Completed and partial requests keep their saved evidence and are
-- reported as not_cancellable instead of raising, so every caller receives a persisted state.
-- Requires authorize_context_case_actor from 20261008160000_context_release_cases.sql.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

create function public.cancel_context_request(p_owner uuid,p_actor uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; outcome text;
begin
 -- Membership is rechecked inside the transaction; a revoked member cannot cancel.
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for update;
 if req.status='cancelled' then outcome:='already_cancelled';
 elsif req.status in ('completed','partial') then outcome:='not_cancellable';
 else
  -- queued, failed, or running: a running worker loses its claim, so commit_spotify_context raises
  -- 'Worker no longer owns request', fail_context_request is a no-op and claim_context_request refuses.
  -- error is deliberately untouched: status records the cancellation, error keeps the last failure.
  update public.context_requests set status='cancelled',claim_token=null,lease_expires_at=null,updated_at=now()
  where id=req.id returning * into req;
  outcome:='cancelled';
 end if;
 return jsonb_build_object('outcome',outcome,'request',to_jsonb(req)-'claim_token');
end $$;

revoke all on function public.cancel_context_request(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.cancel_context_request(uuid,uuid,uuid) to service_role;
commit;
