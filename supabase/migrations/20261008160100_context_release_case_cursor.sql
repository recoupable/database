-- Forward-only correction: the original migration has a hosted preview.
-- Preserve its history; normalize invalid cursors without leaking their existence.
begin;
create or replace function public.list_context_release_cases(p_actor uuid,p_owner uuid,p_after uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare cursor_row public.context_requests; items jsonb; more boolean;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_after is not null then
  select * into cursor_row from public.context_requests where id=p_after and owner_id=p_owner and input->>'kind'='release';
  if cursor_row.id is null then raise exception 'Invalid release case cursor' using errcode='42501'; end if;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('request_id',q.id,'url',q.input->>'url','created_at',q.created_at,'status',q.status) order by q.created_at desc,q.id desc),'[]'::jsonb)
 into items from (select * from public.context_requests where owner_id=p_owner and input->>'kind'='release'
  and (p_after is null or (created_at,id)<(cursor_row.created_at,cursor_row.id)) order by created_at desc,id desc limit 51) q;
 more:=jsonb_array_length(items)>50;
 if more then items:=items-50; end if;
 return jsonb_build_object('cases',items,'has_more',more,'next_id',case when more then items->49->>'request_id' end);
end $$;

commit;
