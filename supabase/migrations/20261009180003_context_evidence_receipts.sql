-- Save/read immutable, version-specific relevance receipts.
begin;
create or replace function public.read_context_evidence_attachment(p_actor uuid,p_owner uuid,p_attachment uuid)
returns jsonb language plpgsql set search_path='' as $$
declare saved public.context_evidence_attachments; targets jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into saved from public.context_evidence_attachments where id=p_attachment and owner_id=p_owner;
 if saved.id is null then raise exception 'Evidence attachment unavailable' using errcode='42501'; end if;
 perform public.authorize_context_evidence_source(p_owner,saved.source_version_id);
 select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('artist_id',artist_id,'professional_id',professional_id,
  'request_id',request_id,'subject_id',subject_id)) order by position) into targets
 from public.context_evidence_attachment_targets where attachment_id=saved.id and owner_id=p_owner;
 if targets is null or jsonb_array_length(targets)<>saved.target_count or
  encode(sha256(convert_to(jsonb_build_object('version',saved.source_version_id,'targets',targets)::text,'UTF8')),'hex')<>saved.fingerprint
 then raise exception 'Evidence attachment unavailable' using errcode='42501'; end if;
 perform public.authorize_context_evidence_targets(p_owner,targets);
 return jsonb_build_object('id',saved.id,'owner_id',saved.owner_id,'actor_id',saved.actor_id,'source_version_id',saved.source_version_id,
  'created_at',saved.created_at,'targets',targets,'assertion','relevance_only','rights_verified',false,
  'policy_version','private-evidence-association-v1');
end $$;

create or replace function public.attach_context_evidence(p_actor uuid,p_owner uuid,p_version uuid,p_key text,p_targets jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare targets jsonb; fingerprint text; saved public.context_evidence_attachments;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$' then raise exception 'Invalid attachment key' using errcode='22023'; end if;
 targets:=public.canonical_context_evidence_targets(p_targets);
 perform public.authorize_context_evidence_source(p_owner,p_version);
 perform public.authorize_context_evidence_targets(p_owner,targets);
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('version',p_version,'targets',targets)::text,'UTF8')),'hex');
 insert into public.context_evidence_attachments(owner_id,actor_id,source_version_id,idempotency_key,fingerprint,target_count)
 values(p_owner,p_actor,p_version,p_key,fingerprint,jsonb_array_length(targets)) on conflict(owner_id,idempotency_key) do nothing returning * into saved;
 if saved.id is not null then
  insert into public.context_evidence_attachment_targets(attachment_id,owner_id,position,artist_id,professional_id,request_id,subject_id)
  select saved.id,p_owner,ordinal-1,(value->>'artist_id')::uuid,(value->>'professional_id')::uuid,(value->>'request_id')::uuid,(value->>'subject_id')::uuid
  from jsonb_array_elements(targets) with ordinality t(value,ordinal);
 else
  select * into strict saved from public.context_evidence_attachments where owner_id=p_owner and idempotency_key=p_key;
  if saved.fingerprint<>fingerprint then raise exception 'Attachment key already used for different input' using errcode='22023'; end if;
 end if;
 return public.read_context_evidence_attachment(p_actor,p_owner,saved.id);
end $$;

revoke all on function public.read_context_evidence_attachment(uuid,uuid,uuid),public.attach_context_evidence(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.read_context_evidence_attachment(uuid,uuid,uuid),public.attach_context_evidence(uuid,uuid,uuid,text,jsonb) to service_role;
commit;
