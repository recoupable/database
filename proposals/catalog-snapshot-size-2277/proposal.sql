-- INACTIVE disposable-fixture proposal. Not a migration or deployment authorization.
-- Requires the exact accepted DB125 four-file bundle. No runtime grants.
begin;
create or replace function public.save_context_catalog_case(p_actor uuid,p_owner uuid,p_case uuid,p_expected_revision integer,p_key text,p_snapshot jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare current_case public.context_catalog_cases; saved public.context_catalog_case_revisions; digest text; next_revision integer; stored_snapshot jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_case is null or p_expected_revision is null or p_expected_revision<0 or p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$'
 then raise exception 'Invalid catalog case request' using errcode='22023'; end if;
 -- Fingerprint covers the exact input revision and artifact; replay does not create another revision.
 digest:=encode(sha256(convert_to(jsonb_build_object('case',p_case,'revision',p_expected_revision,'snapshot',p_snapshot)::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended(p_owner::text||':catalog-key:'||p_key,0));
 select * into saved from public.context_catalog_case_revisions where owner_id=p_owner and idempotency_key=p_key;
 if saved.case_id is not null then
  if saved.actor_id<>p_actor or saved.input_fingerprint<>digest then raise exception 'Catalog key reused for different input' using errcode='22023'; end if;
  return public.read_context_catalog_case(p_actor,p_owner,saved.case_id,saved.revision);
 end if;
 -- Replay above remains valid; this signal is owned only by Catalog save size checks.
 if octet_length(p_snapshot::text)>1048576 then
  raise exception 'CATALOG_SNAPSHOT_TOO_LARGE' using errcode='22001';
 end if;
 perform public.validate_context_catalog_snapshot(p_owner,p_case,p_expected_revision,p_snapshot);
 perform pg_advisory_xact_lock(hashtextextended(p_case::text||':catalog-case',0));
 select * into current_case from public.context_catalog_cases where id=p_case for update;
 if current_case.id is not null and current_case.owner_id<>p_owner then raise exception 'Catalog case unavailable' using errcode='42501'; end if;
 if coalesce(current_case.revision,0)<>p_expected_revision then raise exception 'Catalog revision conflict' using errcode='40001'; end if;
 next_revision:=p_expected_revision+1;
 stored_snapshot:=jsonb_set(p_snapshot,'{revision}',to_jsonb(next_revision));
 if octet_length(stored_snapshot::text)>1048576 then
  raise exception 'CATALOG_SNAPSHOT_TOO_LARGE' using errcode='22001';
 end if;
 if current_case.id is null then
  insert into public.context_catalog_cases(id,owner_id,created_by,revision) values(p_case,p_owner,p_actor,next_revision);
 else
  update public.context_catalog_cases set revision=next_revision,updated_at=clock_timestamp() where id=p_case and owner_id=p_owner;
 end if;
 insert into public.context_catalog_case_revisions(case_id,owner_id,revision,actor_id,idempotency_key,input_fingerprint,snapshot)
 values(p_case,p_owner,next_revision,p_actor,p_key,digest,stored_snapshot);
 return public.read_context_catalog_case(p_actor,p_owner,p_case,next_revision);
end $$;

commit;
