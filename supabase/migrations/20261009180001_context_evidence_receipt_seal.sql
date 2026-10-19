-- Forward-only correction: preserve the initial migration already applied in preview.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
grant update(updated_at) on public.artist_organization_ids to service_role;
alter table public.context_evidence_attachments add column target_count integer;
-- Seal the existing canonical receipt payload, never reinterpret or repair it.
update public.context_evidence_attachments a set target_count=(
 select count(*) from public.context_evidence_attachment_targets t where t.attachment_id=a.id and t.owner_id=a.owner_id);
do $$
begin
 if exists(select 1 from public.context_evidence_attachments a where a.target_count not between 1 and 100 or
  a.fingerprint<>encode(sha256(convert_to(jsonb_build_object('version',a.source_version_id,'targets',
   (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('artist_id',artist_id,'professional_id',professional_id,
    'request_id',request_id,'subject_id',subject_id)) order by position)
    from public.context_evidence_attachment_targets where attachment_id=a.id and owner_id=a.owner_id))::text,'UTF8')),'hex'))
 then raise exception 'Inconsistent existing evidence receipt; review required' using errcode='23514'; end if;
end $$;
alter table public.context_evidence_attachments alter column target_count set not null;
alter table public.context_evidence_attachments add constraint context_evidence_target_count check(target_count between 1 and 100);
-- Every slot must be filled in the creation transaction. A receipt cannot be
-- committed with holes, nor appended after its fixed slots have been filled.
create function public.guard_context_evidence_target_slot()
returns trigger language plpgsql set search_path='' as $$
declare slots integer;
begin
 select target_count into slots from public.context_evidence_attachments where id=new.attachment_id and owner_id=new.owner_id;
 if slots is null or new.position>=slots then raise exception 'Evidence receipt target count' using errcode='23514'; end if;
 return new;
end $$;
create trigger context_evidence_target_slot before insert on public.context_evidence_attachment_targets
 for each row execute function public.guard_context_evidence_target_slot();
create function public.check_context_evidence_receipt_complete()
returns trigger language plpgsql set search_path='' as $$
begin
 if (select count(*) from public.context_evidence_attachment_targets where attachment_id=new.id and owner_id=new.owner_id)<>new.target_count
 then raise exception 'Evidence receipt target count' using errcode='23514'; end if;
 return new;
end $$;
create constraint trigger context_evidence_receipt_complete after insert on public.context_evidence_attachments
 deferrable initially deferred for each row execute function public.check_context_evidence_receipt_complete();
revoke all on function public.guard_context_evidence_target_slot(),public.check_context_evidence_receipt_complete() from public,anon,authenticated;
grant execute on function public.guard_context_evidence_target_slot(),public.check_context_evidence_receipt_complete() to service_role;

commit;
