-- SOURCE-ONLY PROPOSAL. Not a migration, not a production authorization adapter.
-- No tables, runtime call sites, service grants, collection or implicit expansion.
create schema stream_binding_proposal;
revoke all on schema stream_binding_proposal from public,anon,authenticated,service_role;
create function stream_binding_proposal.read_binding(
 p_actor uuid,p_owner uuid,p_request uuid,p_subject uuid,p_catalog uuid,
 p_result uuid,p_version uuid,p_revision bigint
) returns jsonb language plpgsql set search_path='' set timezone='UTC' as $$
declare
 isrc_value text; resolved jsonb; payload jsonb; actual jsonb; source_key uuid;
 first_day date; last_day date; topic_value text; source_uri text;
 midpoint date; days_count integer; provider_id text; expected jsonb; envelope jsonb;
 absent_days jsonb; null_days jsonb; earliest timestamptz; latest timestamptz; version_time timestamptz;
begin
 if current_setting('transaction_isolation') <> 'read committed' then return 'null'::jsonb; end if;
 -- Parent order follows commit_catalog_stream_track. Chat/session locks, if any,
 -- must be acquired by a future durable caller before entering this boundary.
 perform 1 from public.accounts where id=p_owner for key share;
 if not found then return 'null'::jsonb; end if;
 perform 1 from public.catalogs where id=p_catalog for key share;
 if not found then return 'null'::jsonb; end if;
 select song_isrc into isrc_value from public.context_subjects where id=p_subject and kind='recording';
 if isrc_value is null then return 'null'::jsonb; end if;
 perform 1 from public.songs where isrc=isrc_value for key share;
 perform 1 from public.catalog_stream_tracking where catalog_id=p_catalog and owner_id=p_owner for update;
 if not found then return 'null'::jsonb; end if;
 perform public.authorize_context_case_actor(p_actor,p_owner);
 perform 1 from public.account_catalogs where account=p_owner and catalog=p_catalog for share;
 if not found then return 'null'::jsonb; end if;
 perform 1 from public.catalog_songs where catalog=p_catalog and song=isrc_value for share;
 if not found then return 'null'::jsonb; end if;
 perform 1 from public.context_requests where id=p_request and owner_id=p_owner for share;
 perform 1 from public.context_request_catalog_members
 where owner_id=p_owner and request_id=p_request and recording_subject_id=p_subject
 and catalog_id=p_catalog and song_isrc=isrc_value for share;
 if not found then return 'null'::jsonb; end if;
 -- Lock all mutable identity participants before invoking the existing exact resolver.
 perform 1 from public.context_resources r join public.context_requests q on q.resource_id=r.id
 where q.id=p_request for share of r;
 perform 1 from public.context_subjects s join public.context_request_catalog_members m
 on s.id in (m.catalog_subject_id,m.recording_subject_id)
 where m.owner_id=p_owner and m.request_id=p_request and m.recording_subject_id=p_subject
 order by s.id for share of s;
 resolved:=public.resolve_context_catalog_member_recording(p_owner,p_request,p_subject);
 if resolved->>'isrc' is distinct from isrc_value then return 'null'::jsonb; end if;
 topic_value:='catalog_retained_streams';
 source_uri:='urn:recoup:retained-catalog-streams:'||p_catalog::text||':'||p_subject::text||':all_dsps:worldwide';
 -- A replacement active row cannot restore this withdrawn source scope.
 if (select count(*) from public.context_sources where owner_id=p_owner
 and kind='provider_metadata' and source_url=source_uri)<>1
 then return 'null'::jsonb; end if;
 select s.id into source_key from public.context_sources s
 join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 where s.owner_id=p_owner and s.source_url=source_uri and s.kind='provider_metadata'
 and s.withdrawn_at is null and v.id=p_version and v.removed_at is null
 for share of s,v;
 if source_key is null then return 'null'::jsonb; end if;
 -- Source before result/document agrees with withdraw_context_source.
 select v.content,v.retrieved_at into payload,version_time from public.context_results r
 join public.context_attempts a on a.id=r.attempt_id and a.owner_id=r.owner_id
 join public.context_result_sources rs on rs.result_id=r.id and rs.owner_id=r.owner_id
 join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
 join public.context_documents d on d.current_result_id=r.id and d.owner_id=r.owner_id
 and d.subject_id=r.subject_id and d.topic=r.topic
 where r.id=p_result and r.owner_id=p_owner and r.subject_id=p_subject and r.topic=topic_value
 and r.status='accepted' and r.evidence_kind='observation' and a.request_id=p_request
 and a.provider='luminate' and a.recipe_version='retained-luminate-daily-v1'
 and a.status='succeeded' and a.schema_version='1'
 and d.revision=p_revision and v.id=p_version and r.normalized_response=v.content
 and (select count(*) from public.context_result_sources x where x.result_id=r.id)=1
 for update of r for share of a,d,rs;
 -- A link insertion may have held FK KEY SHARE before the result lock. Recheck
 -- in a new READ COMMITTED statement after acquiring that lock.
 if (select count(*) from public.context_result_sources where result_id=p_result)<>1
 then return 'null'::jsonb; end if;
 if payload is null or payload->>'schemaVersion' is distinct from '1'
 or payload->>'catalogId' is distinct from p_catalog::text
 or payload->>'subjectId' is distinct from p_subject::text
 or payload->>'isrc' is distinct from isrc_value
 or payload->>'metric' is distinct from 'daily_streams'
 or octet_length(convert_to(payload::text,'UTF8'))>524288 or pg_column_size(payload)>524288
 then return 'null'::jsonb; end if;
 first_day:=(payload->>'since')::date; last_day:=(payload->>'until')::date;
 if first_day is null or last_day is null or last_day-first_day not between 2 and 732 or (last_day-first_day)%2<>0 or last_day>current_date
 then return 'null'::jsonb; end if;
 days_count:=(last_day-first_day)/2; midpoint:=first_day+days_count;
 -- Lock retained rows and their run parents against mutation/removal. This does
 -- not prevent arbitrary direct inserts that bypass the tracking writer protocol.
 perform 1 from public.catalog_stream_runs r where r.catalog_id=p_catalog
 and exists(select 1 from public.catalog_stream_observations o where o.run_id=r.id
 and o.catalog_id=p_catalog and o.isrc=isrc_value and o.date>=first_day and o.date<last_day)
 order by r.id for share;
 perform 1 from public.catalog_stream_observations o where o.catalog_id=p_catalog
 and o.isrc=isrc_value and o.date>=first_day and o.date<last_day
 order by o.run_id,o.date for share;
 -- Preserve nullable streams and exact retained tuple; never infer zero or fill gaps.
 select jsonb_agg(to_jsonb(x) order by x.date) into actual from (
  select distinct on (o.date) o.catalog_id,o.isrc,o.date,o.run_id,o.provider_recording_id,
   o.source_hash,o.retrieved_at,o.streams
  from public.catalog_stream_observations o
  where o.catalog_id=p_catalog and o.isrc=isrc_value and o.date>=first_day and o.date<last_day
  order by o.date,o.retrieved_at desc,o.run_id desc
 ) x;
 if actual is null or actual is distinct from payload->'observations'
 or (select count(distinct x->>'provider_recording_id') from jsonb_array_elements(actual) x)<>1
 or exists(select 1 from jsonb_array_elements(actual) x where (x->>'provider_recording_id') !~ '[^[:space:]]'
  or (x->>'source_hash') !~ '^[0-9a-fA-F]{64}$'
  or not isfinite((x->>'retrieved_at')::timestamptz)
  or not exists(select 1 from public.catalog_stream_runs r where r.id=(x->>'run_id')::uuid
    and r.catalog_id=p_catalog and (x->>'date')::date between r.since and r.until))
 then return 'null'::jsonb; end if;
 provider_id:=actual->0->>'provider_recording_id';
 -- An entirely replaced identity also needs an owning reconciliation disposition.
 if exists(select 1 from public.context_source_versions v
 join public.context_result_sources rs on rs.source_version_id=v.id and rs.owner_id=v.owner_id
 join public.context_results r on r.id=rs.result_id and r.owner_id=rs.owner_id
 where v.owner_id=p_owner and v.source_id=source_key and r.status in ('accepted','stale','withdrawn')
 and r.subject_id=p_subject and r.topic=topic_value
 and v.content->>'providerRecordingId' is distinct from provider_id)
 then return 'null'::jsonb; end if;
 select min((x->>'retrieved_at')::timestamptz),max((x->>'retrieved_at')::timestamptz)
 into earliest,latest from jsonb_array_elements(actual) x;
 select coalesce(jsonb_agg(d::date::text order by d),'[]'::jsonb) into absent_days
 from generate_series(first_day::timestamp,(last_day-1)::timestamp,interval '1 day') d
 where not exists(select 1 from jsonb_array_elements(actual) x where x->>'date'=d::date::text);
 select coalesce(jsonb_agg(x->>'date' order by x->>'date'),'[]'::jsonb) into null_days
 from jsonb_array_elements(actual) x where x->'streams'='null'::jsonb;
 expected:=jsonb_build_object('schemaVersion',1,'workspaceId',p_owner,'catalogId',p_catalog,
  'subjectId',p_subject,'isrc',isrc_value,'provider','luminate','metric','daily_streams',
  'platform','all_dsps','territory','worldwide','timezone','UTC','since',first_day,'until',last_day,
  'periods',jsonb_build_object('previous',jsonb_build_object('start',first_day,'end_exclusive',midpoint),
   'current',jsonb_build_object('start',midpoint,'end_exclusive',last_day),'days',days_count,'timezone','UTC'),
  'providerRecordingId',provider_id,'observations',actual,'absentDates',absent_days,'nullDates',null_days,
  'retrievalRange',jsonb_build_object('earliest',earliest,'latest',latest));
 -- Exact reconstruction rejects extra/malformed fields, wrong scope, missing/null
 -- relabeling, and invented freshness. This is evidence-only, not derived totals.
 if payload is distinct from expected or version_time is distinct from latest
 then return 'null'::jsonb; end if;
 envelope:=jsonb_build_object('ownerId',p_owner,'subjectId',p_subject,'requestId',p_request,
  'catalogId',p_catalog,'resultId',p_result,'revision',p_revision,'topic',topic_value,
  'sourceVersionIds',jsonb_build_array(p_version),'evidence',payload);
 if octet_length(convert_to(envelope::text,'UTF8'))>786432 or pg_column_size(envelope)>786432
 then return 'null'::jsonb; end if;
 return envelope;
exception when no_data_found or too_many_rows or insufficient_privilege or data_exception then
 return 'null'::jsonb;
end $$;
revoke all on function stream_binding_proposal.read_binding(uuid,uuid,uuid,uuid,uuid,uuid,uuid,bigint)
from public,anon,authenticated,service_role;
