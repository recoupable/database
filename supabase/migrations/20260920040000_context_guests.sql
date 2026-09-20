-- Temporary, private guest work. No synthetic accounts and no anonymous database access.
begin;
create table public.context_guest_workspaces (
 id uuid primary key default gen_random_uuid(),
 token_hash text not null unique check(token_hash ~ '^[a-f0-9]{64}$'),
 input jsonb not null, input_fingerprint text not null,
 status text not null default 'queued' check(status in ('queued','running','ready','failed')),
 payload jsonb, error text, worker_token uuid, lease_expires_at timestamptz,
 claimed_by uuid references public.accounts(id), claimed_owner uuid references public.accounts(id),
 request_id uuid references public.context_requests(id),
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '7 days',
 check ((claimed_by is null) = (claimed_owner is null)),
 check ((claimed_by is null) = (request_id is null))
);
alter table public.context_guest_workspaces enable row level security;
revoke all on public.context_guest_workspaces from public,anon,authenticated;
grant all on public.context_guest_workspaces to service_role;
create index context_guest_expiry on public.context_guest_workspaces(expires_at);

-- An anonymous request cannot cause unbounded provider spend. This pilot allows
-- metadata only, with a global daily admission ceiling and one URL per capability.
create function public.start_context_guest(p_hash text,p_input jsonb,p_fingerprint text,p_daily_limit integer)
returns jsonb language plpgsql set search_path='' as $$
declare g public.context_guest_workspaces;
begin
 if p_daily_limit is null or p_daily_limit<1 or p_daily_limit>1000 then raise exception 'Invalid guest allowance'; end if;
 perform pg_catalog.pg_advisory_xact_lock(97002001);
 select * into g from public.context_guest_workspaces where token_hash=p_hash;
 if g.id is not null then
  if g.expires_at<=now() or g.claimed_by is not null then raise exception 'Guest session unavailable'; end if;
  if g.input_fingerprint<>p_fingerprint then raise exception 'Guest session already contains another input'; end if;
 else
  if (select count(*) from public.context_guest_workspaces where created_at>=date_trunc('day',now()))>=p_daily_limit then raise exception 'Guest allowance reached'; end if;
  insert into public.context_guest_workspaces(token_hash,input,input_fingerprint) values(p_hash,p_input,p_fingerprint) returning * into g;
 end if;
 return jsonb_build_object('id',g.id,'status',g.status,'expiresAt',g.expires_at);
end $$;

create function public.read_context_guest(p_hash text)
returns jsonb language sql set search_path='' as $$
 select jsonb_build_object('id',g.id,'status',g.status,'input',g.input,'context',g.payload-'raw','error',g.error,'expiresAt',g.expires_at,'coverage','metadata_only')
 from public.context_guest_workspaces g where token_hash=p_hash and expires_at>now() and claimed_by is null;
$$;

create function public.claim_context_guest_worker(p_id uuid,p_token uuid)
returns jsonb language plpgsql set search_path='' as $$
declare g public.context_guest_workspaces;
begin
 update public.context_guest_workspaces set status='running',worker_token=p_token,lease_expires_at=now()+interval '2 minutes',error=null
 where id=p_id and (expires_at>now() or claimed_by is not null)
 and (status in ('queued','failed') or (status='running' and lease_expires_at<now())) returning * into g;
 if g.id is null then return null; end if;
 update public.context_requests set status='queued',error=null,updated_at=now() where id=g.request_id and status='failed';
 return jsonb_build_object('id',g.id,'input',g.input);
end $$;

-- Claim and completion serialize on the same row. Whichever arrives first is safe.
create function public.context_guest_worker_scope(p_id uuid,p_token uuid)
returns jsonb language sql set search_path='' as $$
 select jsonb_build_object('actor',claimed_by,'owner',claimed_owner) from public.context_guest_workspaces where id=p_id and worker_token=p_token and status='running';
$$;

create function public.complete_context_guest(p_id uuid,p_token uuid,p_payload jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare g public.context_guest_workspaces; token uuid:=gen_random_uuid(); result jsonb;
begin
 select * into strict g from public.context_guest_workspaces where id=p_id for update;
 if g.status<>'running' or g.worker_token is distinct from p_token then raise exception 'Stale guest worker'; end if;
 if g.expires_at<=now() and g.claimed_by is null then raise exception 'Guest session expired'; end if;
 if p_payload->>'trackId' is distinct from g.input->>'trackId' then raise exception 'Recording mismatch'; end if;
 if g.claimed_by is not null then
  if not public.claim_context_request(g.claimed_owner,g.request_id,token) then raise exception 'Destination request busy'; end if;
  result:=public.commit_spotify_context(g.claimed_owner,g.request_id,token,p_payload);
 end if;
 update public.context_guest_workspaces set payload=p_payload,status='ready',worker_token=null,lease_expires_at=null where id=p_id;
 return jsonb_build_object('status','ready','requestId',g.request_id);
end $$;

create function public.fail_context_guest(p_id uuid,p_token uuid)
returns boolean language plpgsql set search_path='' as $$
declare g public.context_guest_workspaces;
begin
 update public.context_guest_workspaces set status='failed',error='Metadata extraction did not complete; retry the same input.',lease_expires_at=null
 where id=p_id and worker_token=p_token and status='running' returning * into g;
 if g.id is null then return false; end if;
 update public.context_requests set status='failed',error=g.error,updated_at=now()
 where id=g.request_id and owner_id=g.claimed_owner and status in ('queued','failed');
 return true;
end $$;

-- The domain layer verifies authenticated account/org access before this RPC.
-- A guest secret alone can never select or read a destination workspace.
create function public.adopt_context_guest(p_hash text,p_actor uuid,p_owner uuid)
returns jsonb language plpgsql set search_path='' as $$
declare g public.context_guest_workspaces; r jsonb; input jsonb; token uuid:=gen_random_uuid();
begin
 select * into strict g from public.context_guest_workspaces where token_hash=p_hash for update;
 if g.claimed_by is not null then
  if g.claimed_by<>p_actor or g.claimed_owner<>p_owner then raise exception 'Guest work already claimed'; end if;
  return jsonb_build_object('requestId',g.request_id,'guestId',g.id,'status','claimed','reused',true);
 end if;
 if g.expires_at<=now() then raise exception 'Guest session expired'; end if;
 input:=(g.input-'trackId') || case when p_owner<>p_actor then jsonb_build_object('organization_id',p_owner) else '{}'::jsonb end;
 r:=public.create_context_request(p_owner,p_actor,'guest:'||g.id,encode(sha256(convert_to(input::text,'UTF8')),'hex'),input,g.input->>'trackId');
 update public.context_guest_workspaces set claimed_by=p_actor,claimed_owner=p_owner,request_id=(r->>'id')::uuid where id=g.id;
 if g.payload is not null then
  if not public.claim_context_request(p_owner,(r->>'id')::uuid,token) then raise exception 'Destination request busy'; end if;
  perform public.commit_spotify_context(p_owner,(r->>'id')::uuid,token,g.payload);
 end if;
 return jsonb_build_object('requestId',r->>'id','guestId',g.id,'status','claimed','reused',false);
end $$;

create function public.purge_expired_context_guests()
returns bigint language plpgsql set search_path='' as $$
declare n bigint;
begin
 -- Keep claimed rows as small receipts for idempotent claim retries. Context is
 -- already persisted in the account, so temporary payloads can be discarded.
 update public.context_guest_workspaces set payload=null where expires_at<=now() and claimed_by is not null and status='ready';
 delete from public.context_guest_workspaces where expires_at<=now() and claimed_by is null;
 get diagnostics n=row_count;return n;
end $$;
do $$ declare f text;begin
 foreach f in array array['start_context_guest(text,jsonb,text,integer)','read_context_guest(text)','claim_context_guest_worker(uuid,uuid)','complete_context_guest(uuid,uuid,jsonb)','fail_context_guest(uuid,uuid)','adopt_context_guest(text,uuid,uuid)','purge_expired_context_guests()','context_guest_worker_scope(uuid,uuid)'] loop
 execute 'revoke all on function public.'||f||' from public,anon,authenticated';execute 'grant execute on function public.'||f||' to service_role';end loop;
end $$;
create or replace function public.save_context_metadata(p_owner uuid,p_request uuid,p_subject uuid,p_topic text,p_url text,p_content jsonb,p_captured timestamptz default now())
returns uuid language plpgsql set search_path='' as $$
declare source uuid; version uuid; doc public.context_documents; v_attempt uuid; result uuid; v_fingerprint text;
begin
 v_fingerprint:=encode(sha256(convert_to(p_content::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,p_url,'provider_metadata')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content,retrieved_at)
 values(p_owner,source,v_fingerprint,p_content,p_captured) on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,p_subject,p_topic) on conflict do nothing;
 select * into strict doc from public.context_documents where owner_id=p_owner and subject_id=p_subject and topic=p_topic for update;
 -- A provider refresh must not replace an explicit customer correction.
 if exists(select 1 from public.context_results r where r.id=doc.current_result_id and r.evidence_kind='customer_assertion') then return doc.id; end if;
 if exists(select 1 from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id where rs.result_id=doc.current_result_id and v.retrieved_at>p_captured) then return doc.id; end if;
 if exists(select 1 from public.context_result_sources rs join public.context_results r on r.id=rs.result_id
   where r.id=doc.current_result_id and r.status='accepted' and rs.source_version_id=version) then return doc.id; end if;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,p_request,p_topic||':'||p_subject,1,'succeeded','spotify','spotify-metadata-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into v_attempt;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,v_attempt,p_subject,p_topic,v_fingerprint,'accepted','observation',p_content,p_content - 'raw',
 '{"extent":"partial","scope":"provider_metadata","audioAnalyzed":false}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,version);
 if not public.accept_context_result(p_owner,doc.id,result,doc.revision) then raise exception 'Context acceptance conflict'; end if;
 return doc.id;
end $$;


commit;
