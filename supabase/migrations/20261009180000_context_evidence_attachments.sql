-- Relevance links for retained evidence, not identity, rights or mandate approval.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

-- A unique index supplies the composite FK without an ACCESS EXCLUSIVE table scan.
create unique index organization_professionals_id_owner on public.organization_professionals(id,organization_id);
grant update(updated_at) on public.artist_organization_ids to service_role;
create table public.context_evidence_attachments (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.accounts(id),
 actor_id uuid not null references public.accounts(id),
 source_version_id uuid not null,
 idempotency_key text not null check(idempotency_key ~ '^[A-Za-z0-9._:-]{1,128}$'),
 fingerprint text not null check(fingerprint ~ '^[a-f0-9]{64}$'),
 target_count integer not null check(target_count between 1 and 100),
 created_at timestamptz not null default now(),
 foreign key(source_version_id,owner_id) references public.context_source_versions(id,owner_id),
 unique(owner_id,idempotency_key), unique(id,owner_id)
);
create index context_evidence_attachments_version on public.context_evidence_attachments(owner_id,source_version_id,id);
create table public.context_evidence_attachment_targets (
 attachment_id uuid not null,
 owner_id uuid not null,
 position integer not null check(position between 0 and 99),
 artist_id uuid references public.accounts(id),
 professional_id uuid,
 request_id uuid,
 subject_id uuid references public.context_subjects(id),
 primary key(attachment_id,position),
 foreign key(attachment_id,owner_id) references public.context_evidence_attachments(id,owner_id),
 foreign key(professional_id,owner_id) references public.organization_professionals(id,organization_id),
 foreign key(request_id,owner_id) references public.context_requests(id,owner_id),
 check((artist_id is not null and professional_id is null and request_id is null and subject_id is null)
  or (professional_id is not null and artist_id is null and request_id is null and subject_id is null)
  or (request_id is not null and subject_id is not null and artist_id is null and professional_id is null))
);
alter table public.context_evidence_attachments enable row level security;
alter table public.context_evidence_attachment_targets enable row level security;
revoke all on public.context_evidence_attachments,public.context_evidence_attachment_targets from public,anon,authenticated,service_role;
grant select,insert on public.context_evidence_attachments,public.context_evidence_attachment_targets to service_role;

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
