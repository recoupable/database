-- Synthetic local fixture admission ONLY. Not production grants or a migration.
grant usage on schema sites_evidence_proposal to service_role;
grant execute on function sites_evidence_proposal.record_evidence(uuid,uuid,uuid,integer,text,jsonb,text,text,jsonb,text) to service_role;
grant execute on function sites_evidence_proposal.read_evidence(uuid,uuid,uuid,uuid) to service_role;
grant execute on function sites_evidence_proposal.publish_candidate(uuid,uuid,uuid,integer,uuid,text,uuid,uuid) to service_role;
