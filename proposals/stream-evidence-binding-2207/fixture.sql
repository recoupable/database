-- Synthetic fixture only. These inserts are NOT a proposed production writer.
TRUNCATE accounts, context_resources, songs, catalogs, account_catalogs, catalog_songs CASCADE;
INSERT INTO accounts(id,name) VALUES ('10000000-0000-4000-8000-000000000001','Synthetic owner'),('10000000-0000-4000-8000-000000000012','Other account');
INSERT INTO catalogs VALUES ('10000000-0000-4000-8000-000000000002','Synthetic catalog',now());
INSERT INTO songs VALUES ('USAAA2600001');
INSERT INTO account_catalogs VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002');
INSERT INTO catalog_songs VALUES ('USAAA2600001','10000000-0000-4000-8000-000000000002');
INSERT INTO context_resources(id,provider,resource_kind,provider_id,canonical_url)
VALUES ('10000000-0000-4000-8000-000000000003','recoup','catalog','10000000-0000-4000-8000-000000000002','urn:recoup:catalog:10000000-0000-4000-8000-000000000002');
INSERT INTO context_subjects(id,kind,song_isrc) VALUES ('10000000-0000-4000-8000-000000000005','recording','USAAA2600001');
INSERT INTO context_subjects(id,kind,catalog_id) VALUES ('10000000-0000-4000-8000-000000000006','catalog','10000000-0000-4000-8000-000000000002');
INSERT INTO context_requests(id,owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
VALUES ('10000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003','fixture',repeat('a',64),'{}','partial','{"subjectIds":["10000000-0000-4000-8000-000000000006"]}');
INSERT INTO context_request_catalog_members(request_id,owner_id,catalog_subject_id,recording_subject_id,catalog_id,song_isrc)
VALUES ('10000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002','USAAA2600001');
INSERT INTO catalog_stream_tracking(catalog_id,owner_id,enabled) VALUES ('10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',true);
INSERT INTO catalog_stream_runs(id,catalog_id,revision,scheduled_day,since,until)
SELECT '10000000-0000-4000-8000-000000000007',catalog_id,revision,'2026-10-25','2026-10-24','2026-10-25' FROM catalog_stream_tracking;
INSERT INTO catalog_stream_observations VALUES ('10000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000002','USAAA2600001','2026-10-24',100,'provider-a','retained-hash','2026-10-25T00:00:00Z');
INSERT INTO context_sources(id,owner_id,source_url,kind)
VALUES ('10000000-0000-4000-8000-000000000008','10000000-0000-4000-8000-000000000001','urn:recoup:luminate-daily:10000000-0000-4000-8000-000000000002:10000000-0000-4000-8000-000000000005','provider_metadata');
INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content)
SELECT '10000000-0000-4000-8000-000000000009','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000008',repeat('b',64),jsonb_build_object(
'schemaVersion',1,'catalogId','10000000-0000-4000-8000-000000000002','subjectId','10000000-0000-4000-8000-000000000005','isrc','USAAA2600001',
'metric','luminate_all_dsp_worldwide_daily_streams','since','2026-10-24','until','2026-10-25',
'observations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY date) FROM catalog_stream_observations o));
INSERT INTO context_attempts(id,owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version)
VALUES ('10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000004','retained-stream-binding',1,'succeeded','luminate','retained-luminate-daily-v1','1');
INSERT INTO context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
SELECT '10000000-0000-4000-8000-000000000011','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000005','luminate_daily_streams_v1:10000000-0000-4000-8000-000000000002',repeat('c',64),'accepted','observation',content,'{"scope":"retained_rows_only"}'
FROM context_source_versions;
INSERT INTO context_result_sources VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000011','10000000-0000-4000-8000-000000000009');
INSERT INTO context_documents(owner_id,subject_id,topic)
VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000005','luminate_daily_streams_v1:10000000-0000-4000-8000-000000000002');
SELECT accept_context_result('10000000-0000-4000-8000-000000000001',id,'10000000-0000-4000-8000-000000000011',0) FROM context_documents;
