-- Durable private release packs. All access runs through authenticated service operations.
BEGIN;
CREATE TABLE public.release_pack_jobs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES public.accounts(id),
 created_by uuid NOT NULL REFERENCES public.accounts(id), idempotency_key text NOT NULL,
 fingerprint text NOT NULL, revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
 brief jsonb NOT NULL, deliverables jsonb NOT NULL, status text NOT NULL DEFAULT 'draft',
 quote jsonb, production_context jsonb, workflow_run_id text, dispatch_state text, error text,
 held_credits bigint NOT NULL DEFAULT 0 CHECK(held_credits>=0),
 consumed_credits bigint NOT NULL DEFAULT 0 CHECK(consumed_credits>=0),
 wallet_period text, hold_expires_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 sufficient_brief_at timestamptz, approved_at timestamptz, running_at timestamptz,
 first_usable_asset_at timestamptz, completed_at timestamptz, exported_at timestamptz,
 UNIQUE(owner_id,idempotency_key)
);
CREATE TABLE public.release_pack_assets (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), job_id uuid NOT NULL REFERENCES public.release_pack_jobs(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('video','artwork','quote_card','carousel','visualizer')), ordinal integer NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','completed','failed','uncertain')),
 attempt integer NOT NULL DEFAULT 0, billed_credits bigint NOT NULL DEFAULT 0, credits bigint NOT NULL CHECK(credits>0), maximum_usd numeric NOT NULL CHECK(maximum_usd>0),
 provider_state jsonb NOT NULL DEFAULT '{}', files jsonb NOT NULL DEFAULT '[]', caption text, qa jsonb,
 error text, started_at timestamptz, completed_at timestamptz, UNIQUE(job_id,kind,ordinal)
);
ALTER TABLE public.release_pack_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.release_pack_assets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.release_pack_jobs,public.release_pack_assets FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.release_pack_jobs,public.release_pack_assets TO service_role;
CREATE OR REPLACE FUNCTION public.release_pack_command(p_actor uuid,p_org uuid,p_action text,p_job uuid,p_input jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE j public.release_pack_jobs%ROWTYPE; a public.release_pack_assets%ROWTYPE;
 owner uuid:=coalesce(p_org,p_actor); item jsonb; q jsonb; wallet public.credits_usage%ROWTYPE;
 dispatch boolean:=false; claimed boolean:=false; expired_command boolean:=false; amount bigint; refund bigint; saved_id uuid;
BEGIN
 IF p_actor IS NULL OR owner IS NULL OR jsonb_typeof(p_input)<>'object' THEN RAISE EXCEPTION 'Invalid pack command'; END IF;
 IF p_org IS NOT NULL AND p_org<>p_actor AND NOT EXISTS(SELECT 1 FROM public.account_organization_ids WHERE account_id=p_actor AND organization_id=p_org) THEN
  RAISE EXCEPTION 'Pack access denied' USING ERRCODE='42501'; END IF;
 IF p_action='prepare' AND NOT (p_input ? 'expected_revision') THEN
  INSERT INTO public.release_pack_jobs(id,owner_id,created_by,idempotency_key,fingerprint,brief,deliverables,status,sufficient_brief_at)
  VALUES(p_job,owner,p_actor,p_input->>'idempotency_key',p_input->>'fingerprint',p_input->'brief',p_input->'deliverables',p_input->>'status',CASE WHEN p_input->>'status'='ready_to_quote' THEN now() END)
  ON CONFLICT(owner_id,idempotency_key) DO NOTHING RETURNING id INTO saved_id;
  IF saved_id IS NULL THEN
   SELECT * INTO STRICT j FROM public.release_pack_jobs WHERE owner_id=owner AND idempotency_key=p_input->>'idempotency_key' FOR UPDATE;
   IF j.fingerprint IS DISTINCT FROM p_input->>'fingerprint' THEN RAISE EXCEPTION 'Idempotency key conflicts with different inputs'; END IF;
   p_job:=j.id;
  END IF;
 END IF;
 SELECT * INTO STRICT j FROM public.release_pack_jobs WHERE id=p_job AND owner_id=owner FOR UPDATE;
 -- A durable hold cannot outlive the production window. Reading also recovers abandoned runs.
 IF j.status='running' AND j.hold_expires_at<now() THEN expired_command:=p_action<>'read'; p_action:='settle'; p_input:=jsonb_build_object('error','Production window expired; accepted provider requests require reconciliation'); END IF;
 IF p_action='prepare' AND p_input ? 'expected_revision' THEN
  IF (p_input->>'expected_revision')::integer<>j.revision THEN RAISE EXCEPTION 'Pack revision changed'; END IF;
  IF j.status='running' OR j.held_credits>0 THEN RAISE EXCEPTION 'Cannot change a running or funded pack'; END IF;
  -- A changed job has a new creative plan; outputs from the old revision remain in prior exports only.
  IF EXISTS(SELECT 1 FROM public.release_pack_assets WHERE job_id=j.id AND attempt>0) THEN RAISE EXCEPTION 'Create a new pack to change a produced brief'; END IF;
  DELETE FROM public.release_pack_assets WHERE job_id=j.id;
  UPDATE public.release_pack_jobs SET brief=p_input->'brief',deliverables=p_input->'deliverables',fingerprint=p_input->>'fingerprint',revision=revision+1,
   status=p_input->>'status',quote=null,production_context=null,dispatch_state=null,workflow_run_id=null,error=null,updated_at=now(),sufficient_brief_at=CASE WHEN p_input->>'status'='ready_to_quote' THEN now() END WHERE id=j.id RETURNING * INTO j;
 ELSIF p_action='estimate' THEN
  IF j.status='running' OR j.held_credits>0 THEN RAISE EXCEPTION 'Pack is already running'; END IF;
  q:=p_input->'quote';
  IF (q->>'revision')::integer<>j.revision OR j.status='needs_input' THEN RAISE EXCEPTION 'Pack brief is not ready or revision changed'; END IF;
  -- Retry quotes contain only known failed assets; uncertain provider submissions cannot be retried.
  IF p_input ? 'retry_asset_id' THEN
   SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'retry_asset_id')::uuid AND job_id=j.id;
   IF a.status<>'failed' THEN RAISE EXCEPTION 'Only a confirmed failed asset can receive a new paid attempt'; END IF;
  ELSE
   IF EXISTS(SELECT 1 FROM public.release_pack_assets WHERE job_id=j.id AND attempt>0) THEN RAISE EXCEPTION 'Use a per-asset retry quote for existing production'; END IF;
   DELETE FROM public.release_pack_assets WHERE job_id=j.id;
   FOR item IN SELECT value FROM jsonb_array_elements(p_input->'assets') LOOP
    INSERT INTO public.release_pack_assets(job_id,kind,ordinal,credits,maximum_usd)
    VALUES(j.id,item->>'kind',(item->>'ordinal')::integer,(item->>'credits')::bigint,(item->>'maximum_usd')::numeric);
   END LOOP;
  END IF;
  UPDATE public.release_pack_jobs SET quote=q,status='awaiting_approval',updated_at=now() WHERE id=j.id RETURNING * INTO j;
 ELSIF p_action='approve' THEN
  q:=j.quote;
  IF q IS NULL OR q->>'id' IS DISTINCT FROM p_input->>'quote_id' OR j.revision<>(p_input->>'expected_revision')::integer THEN RAISE EXCEPTION 'Approval does not match the current quote and revision'; END IF;
  IF j.status='running' THEN
   RETURN jsonb_build_object('job',to_jsonb(j),'assets',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.kind,x.ordinal),'[]') FROM public.release_pack_assets x WHERE job_id=j.id),'dispatch',false);
  END IF;
  IF j.status<>'awaiting_approval' OR (q->>'expires_at')::timestamptz<now() THEN RAISE EXCEPTION 'Quote expired or is no longer approvable'; END IF;
  IF (p_input->>'approved_max_usd')::numeric<(q->>'maximum_usd')::numeric THEN RAISE EXCEPTION 'Approved budget is below the complete quote'; END IF;
  amount:=(q->>'credits')::bigint;
  IF amount<=0 THEN RAISE EXCEPTION 'Invalid quote credits'; END IF;
  BEGIN SELECT * INTO STRICT wallet FROM public.credits_usage WHERE account_id=owner ORDER BY id FOR UPDATE;
  EXCEPTION WHEN no_data_found OR too_many_rows THEN RAISE EXCEPTION 'Credit wallet unavailable or ambiguous'; END;
  IF wallet.remaining_credits IS NULL THEN RAISE EXCEPTION 'Credit wallet unavailable'; END IF;
  IF wallet.remaining_credits<amount THEN RAISE EXCEPTION 'Insufficient credits' USING ERRCODE='P0002'; END IF;
  UPDATE public.credits_usage SET remaining_credits=remaining_credits-amount WHERE id=wallet.id;
  IF q ? 'retry_asset_id' THEN
   UPDATE public.release_pack_assets SET status='pending',provider_state='{}',error=null,qa=null,files='[]',caption=null WHERE id=(q->>'retry_asset_id')::uuid AND job_id=j.id AND status='failed';
   IF NOT FOUND THEN RAISE EXCEPTION 'Retry asset state changed'; END IF;
  END IF;
  UPDATE public.release_pack_jobs SET status='running',held_credits=amount,wallet_period=wallet.timestamp::text,hold_expires_at=now()+interval '2 hours',
   approved_at=now(),running_at=now(),workflow_run_id=null,dispatch_state='pending',error=null,updated_at=now() WHERE id=j.id RETURNING * INTO j;
  dispatch:=true;
 ELSIF p_action='claim' THEN
  SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id FOR UPDATE;
  IF j.status<>'running' THEN RAISE EXCEPTION 'Pack is not running'; END IF;
  IF a.status='pending' THEN
   IF j.held_credits<a.credits THEN RAISE EXCEPTION 'Pack budget exhausted'; END IF;
   UPDATE public.release_pack_assets SET status='running',attempt=attempt+1,billed_credits=0,started_at=now() WHERE id=a.id RETURNING * INTO a;
   claimed:=true;
  END IF;
  RETURN jsonb_build_object('job',to_jsonb(j),'asset',to_jsonb(a),'claimed',claimed);
 ELSIF p_action='context' THEN
  IF j.status<>'running' THEN RAISE EXCEPTION 'Pack is not running'; END IF;
  UPDATE public.release_pack_jobs SET production_context=p_input->'value',updated_at=now() WHERE id=j.id;
 ELSIF p_action='resume' THEN
  IF j.quote->>'id' IS DISTINCT FROM p_input->>'quote_id' OR j.revision IS DISTINCT FROM (p_input->>'expected_revision')::integer THEN RAISE EXCEPTION 'Resume approval does not match the current quote and revision'; END IF;
  SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id AND status='uncertain' FOR UPDATE;
  amount:=greatest(0,a.credits-a.billed_credits);
  IF p_input->>'approved_max_usd' IS NULL OR (p_input->>'approved_max_usd')::numeric < (amount::numeric*a.maximum_usd/a.credits) THEN RAISE EXCEPTION 'Approved resume budget is below the remaining quote'; END IF;
  IF j.status NOT IN ('partial','failed') OR j.held_credits<>0 THEN RAISE EXCEPTION 'Pack cannot be resumed in its current state'; END IF;
  UPDATE public.release_pack_assets SET status='running',error=null WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id AND status='uncertain';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only an uncertain accepted attempt can be resumed'; END IF;
  -- Already accepted work is charged once. Unsubmitted future stages need a new budget hold.
  amount:=(SELECT greatest(0,credits-billed_credits) FROM public.release_pack_assets WHERE id=(p_input->>'asset_id')::uuid);
  BEGIN SELECT * INTO STRICT wallet FROM public.credits_usage WHERE account_id=owner ORDER BY id FOR UPDATE;
  EXCEPTION WHEN no_data_found OR too_many_rows THEN RAISE EXCEPTION 'Credit wallet unavailable or ambiguous'; END;
  IF wallet.remaining_credits IS NULL THEN RAISE EXCEPTION 'Credit wallet unavailable'; END IF;
  IF wallet.remaining_credits<amount THEN RAISE EXCEPTION 'Insufficient credits'; END IF;
  UPDATE public.credits_usage SET remaining_credits=remaining_credits-amount WHERE id=wallet.id;
  UPDATE public.release_pack_jobs SET status='running',held_credits=amount,wallet_period=wallet.timestamp::text,hold_expires_at=now()+interval '2 hours',error=null,workflow_run_id=null,updated_at=now() WHERE id=j.id;
  dispatch:=true;
 ELSIF p_action='phase' THEN
  SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id AND status='running' FOR UPDATE;
  -- Charge only accepted visual provider work, never the unused remainder of an asset quote.
  IF p_input->'value'->>'state'='accepted' AND p_input->>'phase' LIKE '%submission%'
   AND a.provider_state->(p_input->>'phase')->>'request_id' IS NULL THEN
   amount:=(p_input->'value'->>'charge_credits')::bigint;
   IF amount IS NULL OR amount<=0 OR amount>j.held_credits OR amount>a.credits-a.billed_credits THEN RAISE EXCEPTION 'Pack budget exhausted'; END IF;
   UPDATE public.release_pack_jobs SET held_credits=held_credits-amount,consumed_credits=consumed_credits+amount,updated_at=now() WHERE id=j.id;
   UPDATE public.release_pack_assets SET billed_credits=billed_credits+amount WHERE id=a.id;
   INSERT INTO public.usage_events(id,account_id,source,agent_type,provider,model_id,input_tokens,cached_input_tokens,output_tokens,tool_call_count,credits_deducted,resource_url)
   VALUES('release-pack-'||a.id::text||'-'||a.attempt::text||'-'||(p_input->>'phase'),owner,'api','main','fal','release-pack-house-rates-v1',0,0,0,0,amount,'/content/packs/'||j.id::text);
  END IF;
  UPDATE public.release_pack_assets SET provider_state=jsonb_set(provider_state,ARRAY[p_input->>'phase'],p_input->'value') WHERE id=a.id;
 ELSIF p_action='finish_asset' THEN
  IF p_input->>'status' NOT IN ('completed','failed','uncertain') THEN RAISE EXCEPTION 'Invalid asset outcome'; END IF;
  IF p_input->>'status'='completed' AND (coalesce((p_input->'qa'->>'passed')::boolean,false)=false OR nullif(p_input->>'caption','') IS NULL OR jsonb_array_length(coalesce(p_input->'files','[]'))=0) THEN RAISE EXCEPTION 'Completed assets require reviewed files and a caption'; END IF;
  UPDATE public.release_pack_assets SET status=p_input->>'status',files=coalesce(p_input->'files','[]'),caption=p_input->>'caption',qa=p_input->'qa',error=p_input->>'error',completed_at=now()
   WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id AND status='running';
  IF NOT FOUND THEN RAISE EXCEPTION 'Asset outcome already recorded or not running'; END IF;
  IF p_input->>'status'='completed' AND (p_input->'qa'->>'passed')::boolean=true AND nullif(p_input->>'caption','') IS NOT NULL THEN
   UPDATE public.release_pack_jobs SET first_usable_asset_at=coalesce(first_usable_asset_at,now()),updated_at=now() WHERE id=j.id;
  END IF;
 ELSIF p_action='dispatch_uncertain' THEN
  UPDATE public.release_pack_jobs SET dispatch_state='uncertain',error=p_input->>'error',updated_at=now() WHERE id=j.id AND status='running' AND workflow_run_id IS NULL;
 ELSIF p_action='run' THEN
  UPDATE public.release_pack_jobs SET workflow_run_id=p_input->>'workflow_run_id',dispatch_state='accepted' WHERE id=j.id AND status='running';
 ELSIF p_action='export' THEN
  UPDATE public.release_pack_jobs SET exported_at=now() WHERE id=j.id;
 ELSIF p_action='settle' THEN
  UPDATE public.release_pack_assets SET status=CASE WHEN status='running' AND EXISTS(SELECT 1 FROM jsonb_object_keys(provider_state) k WHERE k LIKE '%submission%') THEN 'uncertain' ELSE 'failed' END, error=coalesce(p_input->>'error','Production stopped before this asset completed') WHERE job_id=j.id AND status IN ('running','pending');
  refund:=j.held_credits;
  IF refund>0 THEN
   -- Monthly refill counts unconsumed holds as existing funds, so every unspent hold refunds once.
   UPDATE public.credits_usage SET remaining_credits=remaining_credits+refund WHERE account_id=owner;
  END IF;
  UPDATE public.release_pack_jobs SET held_credits=0,
   status=CASE WHEN NOT EXISTS(SELECT 1 FROM public.release_pack_assets WHERE job_id=j.id AND status<>'completed') THEN 'completed'
    WHEN EXISTS(SELECT 1 FROM public.release_pack_assets WHERE job_id=j.id AND status='completed') THEN 'partial' ELSE 'failed' END,
   error=p_input->>'error',completed_at=now(),updated_at=now() WHERE id=j.id;
 ELSIF p_action NOT IN ('read','prepare') THEN RAISE EXCEPTION 'Unknown pack command';
 END IF;
 SELECT * INTO STRICT j FROM public.release_pack_jobs WHERE id=p_job AND owner_id=owner;
 RETURN jsonb_build_object('job',to_jsonb(j),'assets',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY CASE WHEN x.kind='video' THEN 0 ELSE 1 END,x.kind,x.ordinal),'[]') FROM public.release_pack_assets x WHERE job_id=j.id),'dispatch',dispatch,'command_expired',expired_command);
END $$;
REVOKE ALL ON FUNCTION public.release_pack_command(uuid,uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.release_pack_command(uuid,uuid,text,uuid,jsonb) TO service_role;
GRANT SELECT ON public.account_organization_ids TO service_role;
-- Compatible with wallet PR #101; the monthly floor additionally counts unconsumed pack holds.
CREATE OR REPLACE FUNCTION public.refill_credits_to_floor(p_account_id uuid,p_floor bigint,p_expected_timestamp timestamp)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE wallet public.credits_usage%ROWTYPE; holds bigint; before_balance bigint;
BEGIN
 IF p_account_id IS NULL OR p_floor IS NULL OR p_floor<0 OR p_floor>9007199254740991 OR p_expected_timestamp IS NULL THEN RAISE EXCEPTION 'Invalid credit refill'; END IF;
 BEGIN SELECT * INTO STRICT wallet FROM public.credits_usage WHERE account_id=p_account_id ORDER BY id FOR UPDATE;
 EXCEPTION WHEN no_data_found OR too_many_rows THEN RAISE EXCEPTION 'Credit wallet unavailable or ambiguous'; END;
 IF wallet.timestamp::timestamp IS DISTINCT FROM p_expected_timestamp THEN RETURN jsonb_build_object('state','superseded','remainingCredits',wallet.remaining_credits,'timestamp',wallet.timestamp); END IF;
 before_balance:=wallet.remaining_credits;
 SELECT coalesce(sum(held_credits),0) INTO holds FROM public.release_pack_jobs WHERE owner_id=p_account_id;
 UPDATE public.credits_usage SET remaining_credits=greatest(remaining_credits,p_floor-holds),timestamp=(now() AT TIME ZONE 'UTC') WHERE id=wallet.id RETURNING * INTO wallet;
 RETURN jsonb_build_object('state',CASE WHEN wallet.remaining_credits>before_balance THEN 'raised' ELSE 'unchanged' END,'remainingCredits',wallet.remaining_credits,'timestamp',wallet.timestamp);
END $$;
CREATE OR REPLACE FUNCTION public.adjust_credit_balance_atomic(p_account uuid,p_delta bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE wallet public.credits_usage%ROWTYPE;
BEGIN
 IF p_delta IS NULL OR abs(p_delta)>9007199254740991 THEN RAISE EXCEPTION 'Invalid credit adjustment'; END IF;
 BEGIN SELECT * INTO STRICT wallet FROM public.credits_usage WHERE account_id=p_account ORDER BY id FOR UPDATE;
 EXCEPTION WHEN no_data_found OR too_many_rows THEN RAISE EXCEPTION 'No credits usage found for this account'; END;
 IF wallet.remaining_credits+p_delta<0 THEN RAISE EXCEPTION 'Insufficient credits. Required: %, Available: %',-p_delta,wallet.remaining_credits; END IF;
 UPDATE public.credits_usage SET remaining_credits=remaining_credits+p_delta WHERE id=wallet.id RETURNING * INTO wallet;
 RETURN to_jsonb(wallet);
END $$;
REVOKE ALL ON FUNCTION public.refill_credits_to_floor(uuid,bigint,timestamp) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.adjust_credit_balance_atomic(uuid,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.refill_credits_to_floor(uuid,bigint,timestamp),public.adjust_credit_balance_atomic(uuid,bigint) TO service_role;
CREATE OR REPLACE FUNCTION public.increment_credits_atomic(p_account_id uuid,p_delta bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE wallet jsonb;
BEGIN
 IF p_delta IS NULL OR p_delta<=0 THEN RAISE EXCEPTION 'Invalid credit increment'; END IF;
 wallet:=public.adjust_credit_balance_atomic(p_account_id,p_delta);
 RETURN jsonb_build_object('remainingCredits',wallet->'remaining_credits');
END $$;
REVOKE ALL ON FUNCTION public.increment_credits_atomic(uuid,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.increment_credits_atomic(uuid,bigint) TO service_role;
COMMIT;
