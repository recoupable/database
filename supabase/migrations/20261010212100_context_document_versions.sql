-- Immutable accepted-document-version history behind the existing current pointer.
-- context_documents keeps the current pointer and revision; every revision change
-- (a newly accepted result or a pointer cleared by source withdrawal) is recorded
-- once in context_document_versions by a trigger. accept_context_result,
-- withdraw_context_source, save_context_metadata, enrichment completion and the
-- entry functions therefore record history without any change to their bodies.
-- Existing documents are backfilled from their current revision; a fresh document
-- (revision 0, no result) has no version yet and gets no row.
--
-- Rollback keeps customer documents, results, sources and briefs untouched:
--   drop trigger context_documents_record_version on public.context_documents;
--   drop trigger context_document_versions_immutable on public.context_document_versions;
--   drop function public.record_context_document_version();
--   drop function public.reject_context_document_version_change();
--   drop function public.read_context_document_history(uuid,uuid,bigint,integer);
--   drop table public.context_document_versions;
-- The unique(id, owner_id) constraint on context_documents may remain; re-running
-- this migration skips it when present and re-backfills history from current rows.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

do $$ begin
 if not exists(select 1 from pg_catalog.pg_constraint
  where conname='context_documents_id_owner' and conrelid='public.context_documents'::regclass) then
  alter table public.context_documents add constraint context_documents_id_owner unique(id, owner_id);
 end if;
end $$;

create table public.context_document_versions (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null,
 document_id uuid not null,
 revision bigint not null check (revision >= 0),
 result_id uuid,
 change text not null check (change in ('accepted','cleared')),
 backfilled boolean not null default false,
 recorded_at timestamptz not null default now(),
 unique(document_id, revision),
 unique(id, owner_id),
 foreign key(document_id, owner_id) references public.context_documents(id, owner_id) on delete restrict,
 foreign key(result_id, owner_id) references public.context_results(id, owner_id) on delete restrict,
 check ((change = 'cleared') = (result_id is null))
);
create index context_document_versions_document_idx
 on public.context_document_versions(owner_id, document_id, revision desc);
create index context_document_versions_result_idx
 on public.context_document_versions(result_id, owner_id);
alter table public.context_document_versions enable row level security;
revoke all on public.context_document_versions from public, anon, authenticated, service_role;
grant select, insert on public.context_document_versions to service_role;

-- History rows are never rewritten, even by service-role writers.
create function public.reject_context_document_version_change()
returns trigger language plpgsql set search_path='' as $$
begin
 raise exception 'Context document history is immutable';
end $$;
create trigger context_document_versions_immutable
 before update or delete on public.context_document_versions
 for each row execute function public.reject_context_document_version_change();

-- One history row per document revision. A pointer that moves without a new
-- revision is a lineage bug and is rejected rather than silently overwritten.
create function public.record_context_document_version()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op = 'UPDATE' then
  if new.revision = old.revision then
   if new.current_result_id is distinct from old.current_result_id then
    raise exception 'Context document pointer changed without a new revision';
   end if;
   return null;
  end if;
  if new.revision < old.revision then
   raise exception 'Context document revision cannot move backwards';
  end if;
 elsif new.revision = 0 and new.current_result_id is null then
  return null;
 end if;
 insert into public.context_document_versions(owner_id, document_id, revision, result_id, change)
 values (new.owner_id, new.id, new.revision, new.current_result_id,
  case when new.current_result_id is null then 'cleared' else 'accepted' end);
 return null;
end $$;
create trigger context_documents_record_version
 after insert or update of current_result_id, revision on public.context_documents
 for each row execute function public.record_context_document_version();
revoke all on function public.reject_context_document_version_change(), public.record_context_document_version()
 from public, anon, authenticated;
grant execute on function public.reject_context_document_version_change(), public.record_context_document_version()
 to service_role;

-- Existing data compatibility: the current revision of every existing document
-- becomes its first recorded version, dated by the document's last update.
insert into public.context_document_versions(owner_id, document_id, revision, result_id, change, backfilled, recorded_at)
select d.owner_id, d.id, d.revision, d.current_result_id,
 case when d.current_result_id is null then 'cleared' else 'accepted' end, true, d.updated_at
from public.context_documents d
where d.current_result_id is not null or d.revision > 0;

-- Scoped lineage read: newest revision first, bounded, with the cited result's
-- current status and source state so a superseded brief can be resolved.
-- Returns null when the document is not in the caller's authorized workspace.
create function public.read_context_document_history(p_owner uuid, p_document uuid, p_before bigint default null, p_limit integer default 50)
returns jsonb language plpgsql set search_path='' as $$
declare doc public.context_documents; bound integer; items jsonb; more boolean;
begin
 if p_owner is null or p_document is null then return null; end if;
 select * into doc from public.context_documents where id=p_document and owner_id=p_owner;
 if doc.id is null then return null; end if;
 bound:=least(greatest(coalesce(p_limit,50),1),100);
 select coalesce(jsonb_agg(jsonb_build_object(
  'revision',v.revision,'result_id',v.result_id,'change',v.change,'backfilled',v.backfilled,'recorded_at',v.recorded_at,
  'result_status',r.status,'evidence_kind',r.evidence_kind,
  'source_version_ids',coalesce((select jsonb_agg(rs.source_version_id order by rs.source_version_id)
   from public.context_result_sources rs where rs.result_id=r.id and rs.owner_id=p_owner),'[]'::jsonb),
  'source_state',case when r.id is null then null
   when exists(select 1 from public.context_result_sources rs
    join public.context_source_versions sv on sv.id=rs.source_version_id and sv.owner_id=rs.owner_id
    join public.context_sources s on s.id=sv.source_id and s.owner_id=sv.owner_id
    where rs.result_id=r.id and rs.owner_id=p_owner and s.withdrawn_at is not null) then 'withdrawn'
   when exists(select 1 from public.context_result_sources rs
    join public.context_source_versions sv on sv.id=rs.source_version_id and sv.owner_id=rs.owner_id
    where rs.result_id=r.id and rs.owner_id=p_owner and sv.removed_at is not null) then 'removed'
   else 'live' end) order by v.revision desc),'[]'::jsonb)
 into items
 from (select * from public.context_document_versions
  where owner_id=p_owner and document_id=doc.id and (p_before is null or revision<p_before)
  order by revision desc limit bound+1) v
 left join public.context_results r on r.id=v.result_id and r.owner_id=v.owner_id;
 more:=jsonb_array_length(items)>bound;
 if more then items:=items-bound; end if;
 return jsonb_build_object(
  'document',jsonb_build_object('id',doc.id,'subject_id',doc.subject_id,'topic',doc.topic,
   'current_revision',doc.revision,'current_result_id',doc.current_result_id,'updated_at',doc.updated_at),
  'versions',items,'has_more',more,
  'next_before',case when more then (items->(bound-1)->>'revision')::bigint end);
end $$;
revoke all on function public.read_context_document_history(uuid,uuid,bigint,integer) from public, anon, authenticated;
grant execute on function public.read_context_document_history(uuid,uuid,bigint,integer) to service_role;
commit;
