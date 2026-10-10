-- Workspace-private, operator-asserted company business relationships, separate from access.
-- A row never grants login, membership, ownership, a rights share, a mandate or collection authority.
-- Frontline roster and catalog interest are distinct kinds; former keeps history without deletion.
-- A change is a new row that names the row it supersedes; the earlier row is never rewritten.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

create table public.context_company_relationships (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.accounts(id) on delete restrict,
 company_subject_id uuid not null references public.context_subjects(id) on delete restrict,
 counterparty_kind text not null check(counterparty_kind in ('workspace','artist_account','professional')),
 artist_id uuid references public.accounts(id) on delete restrict,
 professional_id uuid references public.organization_professionals(id) on delete restrict,
 relationship_kind text not null check(relationship_kind in
  ('frontline_roster','catalog_interest','publishing','distribution','management','services','other')),
 status text not null check(status in ('current','former')),
 started_on date,
 ended_on date,
 basis text not null default 'operator_assertion' check(basis='operator_assertion'),
 note text not null default '' check(length(note)<=2000),
 asserted_by uuid not null references public.accounts(id) on delete restrict,
 idempotency_key text not null check(idempotency_key ~ '^[A-Za-z0-9._:-]{1,128}$'),
 supersedes_id uuid unique,
 created_at timestamptz not null default now(),
 unique(owner_id,idempotency_key),
 unique(id,owner_id,company_subject_id),
 -- A row can only supersede a row of the same workspace and company, and at most one row supersedes it.
 foreign key(supersedes_id,owner_id,company_subject_id)
  references public.context_company_relationships(id,owner_id,company_subject_id) on delete restrict,
 check(
  (counterparty_kind='workspace' and artist_id is null and professional_id is null) or
  (counterparty_kind='artist_account' and artist_id is not null and professional_id is null) or
  (counterparty_kind='professional' and professional_id is not null and artist_id is null)
 ),
 -- Unknown dates stay null; they are never inferred from status.
 check(started_on is null or ended_on is null or ended_on>=started_on),
 check(status='former' or ended_on is null)
);
create index context_company_relationships_company on public.context_company_relationships(owner_id,company_subject_id,id);
alter table public.context_company_relationships enable row level security;
revoke all on public.context_company_relationships from public,anon,authenticated;
grant select,insert on public.context_company_relationships to service_role;

-- A company subject is reachable in a workspace only through that workspace's own company-input
-- document and customer assertion. null: not reachable here; unavailable: its source was withdrawn.
-- Withdrawal clears current_result_id, so reachability must not depend on the current result.
create function public.read_context_company_subject_state(p_owner uuid,p_subject uuid)
returns text language plpgsql set search_path='' as $$
begin
 perform 1 from public.context_subjects s
  join public.context_resources r on r.id=s.resource_id and r.provider='recoup' and r.resource_kind='company_input'
  join public.context_documents d on d.owner_id=p_owner and d.subject_id=s.id and d.topic='company_input'
  where s.id=p_subject and s.kind='company'
   and exists(select 1 from public.context_results result where result.owner_id=p_owner and result.subject_id=s.id
    and result.topic='company_input' and result.evidence_kind='customer_assertion');
 if not found then return null; end if;
 -- Share-lock the evidence so withdrawal waits for an already-authorized transaction.
 perform 1 from public.context_documents d
  join public.context_result_sources rs on rs.result_id=d.current_result_id and rs.owner_id=d.owner_id
  join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
  join public.context_sources source on source.id=v.source_id and source.owner_id=v.owner_id
  where d.owner_id=p_owner and d.subject_id=p_subject and d.topic='company_input'
  order by source.id,v.id for share of source,v;
 if exists(select 1 from public.context_documents d
  join public.context_results result on result.id=d.current_result_id and result.owner_id=d.owner_id
   and result.status='accepted' and result.evidence_kind='customer_assertion'
  join public.context_result_sources rs on rs.result_id=result.id and rs.owner_id=d.owner_id
  join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id and v.removed_at is null
  join public.context_sources source on source.id=v.source_id and source.owner_id=v.owner_id
   and source.withdrawn_at is null and source.kind='customer'
  where d.owner_id=p_owner and d.subject_id=p_subject and d.topic='company_input')
 then return 'available'; end if;
 return 'unavailable';
end $$;

create function public.context_company_relationship_item(r public.context_company_relationships)
returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',r.id,'company_subject_id',r.company_subject_id,
  'counterparty',case r.counterparty_kind
   when 'workspace' then jsonb_build_object('kind','workspace')
   when 'artist_account' then jsonb_build_object('kind','artist_account','artist_id',r.artist_id)
   else jsonb_build_object('kind','professional','professional_id',r.professional_id) end,
  'relationship_kind',r.relationship_kind,'status',r.status,'started_on',r.started_on,'ended_on',r.ended_on,
  'basis',r.basis,'note',r.note,'asserted_by',r.asserted_by,'supersedes_id',r.supersedes_id,
  'superseded_by',(select later.id from public.context_company_relationships later
   where later.supersedes_id=r.id and later.owner_id=r.owner_id),
  'created_at',r.created_at)
$$;

create function public.record_context_company_relationship(
 p_actor uuid,p_owner uuid,p_company_subject uuid,p_counterparty jsonb,p_kind text,p_status text,
 p_started_on date,p_ended_on date,p_note text,p_key text,p_supersedes uuid default null
) returns jsonb language plpgsql set search_path='' as $$
declare state text; cp_kind text; cp_artist uuid; cp_professional uuid; normalized_note text;
 saved public.context_company_relationships; prior public.context_company_relationships; replayed boolean:=false;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_company_subject is null or p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$'
  or jsonb_typeof(p_counterparty) is distinct from 'object'
  or p_kind is null or p_kind not in ('frontline_roster','catalog_interest','publishing','distribution','management','services','other')
  or p_status is null or p_status not in ('current','former')
  or (p_status='current' and p_ended_on is not null)
  or (p_started_on is not null and p_ended_on is not null and p_ended_on<p_started_on)
  or p_note is null or length(p_note)>2000
 then raise exception 'Invalid company relationship'; end if;
 normalized_note:=pg_catalog.btrim(p_note);
 cp_kind:=p_counterparty->>'kind';
 if cp_kind='workspace' and p_counterparty-'kind'='{}'::jsonb then null;
 elsif cp_kind='artist_account' and p_counterparty-'kind'-'artist_id'='{}'::jsonb
  and jsonb_typeof(p_counterparty->'artist_id')='string' then cp_artist:=(p_counterparty->>'artist_id')::uuid;
 elsif cp_kind='professional' and p_counterparty-'kind'-'professional_id'='{}'::jsonb
  and jsonb_typeof(p_counterparty->'professional_id')='string' then cp_professional:=(p_counterparty->>'professional_id')::uuid;
 else raise exception 'Invalid company relationship'; end if;
 -- One generic denial for unknown and foreign subjects: no existence hint across workspaces.
 state:=public.read_context_company_subject_state(p_owner,p_company_subject);
 if state is null then raise exception 'Company relationship denied' using errcode='42501'; end if;
 if state<>'available' then raise exception 'Company source withdrawn' using errcode='42501'; end if;
 -- Counterparties must already be reachable in this workspace; nothing is enrolled or created here.
 if cp_artist is not null
  and not exists(select 1 from public.artist_organization_ids where organization_id=p_owner and artist_id=cp_artist)
  and not exists(select 1 from public.account_artist_ids where account_id=p_owner and artist_id=cp_artist)
 then raise exception 'Company relationship denied' using errcode='42501'; end if;
 if cp_professional is not null
  and not exists(select 1 from public.organization_professionals where id=cp_professional and organization_id=p_owner)
 then raise exception 'Company relationship denied' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_owner::text||':company-relationship:'||p_key,0));
 select * into saved from public.context_company_relationships where owner_id=p_owner and idempotency_key=p_key;
 if saved.id is not null then
  if saved.company_subject_id<>p_company_subject or saved.counterparty_kind<>cp_kind
   or saved.artist_id is distinct from cp_artist or saved.professional_id is distinct from cp_professional
   or saved.relationship_kind<>p_kind or saved.status<>p_status
   or saved.started_on is distinct from p_started_on or saved.ended_on is distinct from p_ended_on
   or saved.note<>normalized_note or saved.supersedes_id is distinct from p_supersedes
  then raise exception 'Idempotency key already used for different input'; end if;
  replayed:=true;
 else
  if p_supersedes is not null then
   -- Serialize successors of one row; key locks are always taken first, so lock order is fixed.
   perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_owner::text||':company-relationship-supersedes:'||p_supersedes::text,0));
   select * into prior from public.context_company_relationships where id=p_supersedes and owner_id=p_owner;
   -- One rejection for unknown, foreign and mismatched rows: only the same company, counterparty
   -- and relationship kind can be superseded.
   if prior.id is null or prior.company_subject_id<>p_company_subject or prior.counterparty_kind<>cp_kind
    or prior.artist_id is distinct from cp_artist or prior.professional_id is distinct from cp_professional
    or prior.relationship_kind<>p_kind
   then raise exception 'Invalid superseded relationship' using errcode='22023'; end if;
   if exists(select 1 from public.context_company_relationships where supersedes_id=p_supersedes and owner_id=p_owner)
   then raise exception 'Company relationship already superseded' using errcode='23505'; end if;
  end if;
  insert into public.context_company_relationships(owner_id,company_subject_id,counterparty_kind,artist_id,professional_id,
   relationship_kind,status,started_on,ended_on,note,asserted_by,idempotency_key,supersedes_id)
  values(p_owner,p_company_subject,cp_kind,cp_artist,cp_professional,p_kind,p_status,p_started_on,p_ended_on,
   normalized_note,p_actor,p_key,p_supersedes) returning * into saved;
 end if;
 return jsonb_build_object('contract_version','company-relationship-v1',
  'relationship',public.context_company_relationship_item(saved),'replayed',replayed,
  'gaps',jsonb_build_array('operator_assertion_not_verified','no_ownership_rights_or_mandate_implied','no_access_granted'));
end $$;

create function public.list_context_company_relationships(p_actor uuid,p_owner uuid,p_company_subject uuid,p_after uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare state text; items jsonb; more boolean;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 state:=public.read_context_company_subject_state(p_owner,p_company_subject);
 if state is null then raise exception 'Company relationship denied' using errcode='42501'; end if;
 if p_after is not null and not exists(select 1 from public.context_company_relationships
  where id=p_after and owner_id=p_owner and company_subject_id=p_company_subject)
 then raise exception 'Invalid relationship cursor' using errcode='22023'; end if;
 if state='available' then
  select coalesce(jsonb_agg(public.context_company_relationship_item(q.r) order by (q.r).id),'[]'::jsonb) into items
  from (select r from public.context_company_relationships r
   where r.owner_id=p_owner and r.company_subject_id=p_company_subject and (p_after is null or r.id>p_after)
   order by r.id limit 51) q;
 else
  items:='[]'::jsonb;
 end if;
 more:=jsonb_array_length(items)>50;
 if more then items:=items-50; end if;
 return jsonb_build_object('contract_version','company-relationship-v1','company_subject_id',p_company_subject,
  'state',state,'coverage','operator_asserted_relationships_only','items',items,
  'next_id',case when more then items->49->>'id' end,
  'gaps',jsonb_build_array('operator_assertion_not_verified','no_ownership_rights_or_mandate_implied','no_access_granted'));
end $$;

revoke all on function public.read_context_company_subject_state(uuid,uuid),
 public.context_company_relationship_item(public.context_company_relationships),
 public.record_context_company_relationship(uuid,uuid,uuid,jsonb,text,text,date,date,text,text,uuid),
 public.list_context_company_relationships(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.read_context_company_subject_state(uuid,uuid),
 public.context_company_relationship_item(public.context_company_relationships),
 public.record_context_company_relationship(uuid,uuid,uuid,jsonb,text,text,date,date,text,text,uuid),
 public.list_context_company_relationships(uuid,uuid,uuid,uuid) to service_role;
commit;
