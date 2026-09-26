-- A saved release-track lookup may be shown as a recorded execution outcome.
begin;
create or replace function public.save_context_execution_outcome(p_owner uuid,p_execution uuid,p_node_key text,p_outcome jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare run public.context_executions; node jsonb; existing public.context_execution_outcomes;
begin
 select * into strict run from public.context_executions where id=p_execution and owner_id=p_owner;
 select value into node from jsonb_array_elements(run.plan) where value->>'key'=p_node_key;
 if node is null then raise exception 'Unknown execution node'; end if;
 if jsonb_typeof(p_outcome) is distinct from 'object' or coalesce(p_outcome->>'status','') not in ('saved','reused','failed','blocked') then raise exception 'Invalid execution outcome'; end if;
 if p_outcome->>'status' in ('saved','reused') and not exists(
  select 1 from public.context_results r where r.id::text=p_outcome->'receipt'->>'resultId'
   and r.owner_id=p_owner and r.subject_id::text=node->>'subjectId'
   and node->>'state' in ('ready_for_dispatch','reuse_candidate')
   and r.topic=case node->>'module'
    when 'musicbrainz' then 'musicbrainz_recordings'
    when 'mlc_recording' then 'mlc_recordings'
    when 'mlc_search' then 'mlc_work_candidates'
    when 'mlc_work' then 'mlc_works'
    when 'songstats' then 'songstats_context'
    when 'saved_socials' then 'social_context'
    when 'catalog_valuation' then 'catalog_valuation'
    when 'spotify_release' then 'spotify_release_context'
    when 'spotify_release_track_isrcs' then 'spotify_release_track_isrcs'
   end
 ) then raise exception 'Execution evidence does not match node'; end if;
 insert into public.context_execution_outcomes(execution_id,owner_id,node_key,outcome)
 values(p_execution,p_owner,p_node_key,p_outcome) on conflict(execution_id,node_key) do nothing;
 select * into strict existing from public.context_execution_outcomes where execution_id=p_execution and node_key=p_node_key;
 if existing.outcome<>p_outcome then raise exception 'Execution outcome conflict'; end if;
 return to_jsonb(existing);
end $$;
commit;
