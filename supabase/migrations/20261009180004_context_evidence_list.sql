-- Scope-checked bounded receipt history, withholding inaccessible targets.
begin;
-- Version-scoped paging. Inaccessible target receipts are withheld, while the
-- cursor still advances over stored history so a page cannot loop indefinitely.
create or replace function public.list_context_evidence_attachments(p_actor uuid,p_owner uuid,p_version uuid,p_after uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare row public.context_evidence_attachments; items jsonb:='[]'; visited integer:=0; cursor_id uuid; more boolean:=false;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 perform public.authorize_context_evidence_source(p_owner,p_version);
 if p_after is not null and not exists(select 1 from public.context_evidence_attachments where id=p_after and owner_id=p_owner and source_version_id=p_version)
 then raise exception 'Invalid evidence cursor' using errcode='42501'; end if;
 for row in select * from public.context_evidence_attachments where owner_id=p_owner and source_version_id=p_version
  and (p_after is null or id>p_after) order by id limit 51 loop
  visited:=visited+1;
  if visited>50 then more:=true; exit; end if;
  cursor_id:=row.id;
  begin
   items:=items||jsonb_build_array(public.read_context_evidence_attachment(p_actor,p_owner,row.id));
  exception when insufficient_privilege then null; end;
 end loop;
 return jsonb_build_object('items',items,'next_id',case when more then cursor_id end,'has_more',more);
end $$;

revoke all on function public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) to service_role;
commit;
