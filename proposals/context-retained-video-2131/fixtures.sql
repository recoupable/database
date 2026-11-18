-- Test-only setup. Never part of retained-video.sql or a hosted migration.
CREATE SCHEMA video_fixture;
CREATE TABLE video_fixture.state(data jsonb);
GRANT USAGE ON SCHEMA video_fixture TO service_role;
GRANT SELECT ON video_fixture.state TO service_role;
CREATE FUNCTION video_fixture.seed() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE owner_id uuid:='10000000-0000-4000-8000-000000000001'; actor uuid:='10000000-0000-4000-8000-000000000002';
 outsider uuid:='10000000-0000-4000-8000-000000000003'; req jsonb; subject uuid; resource uuid; link uuid;
 source uuid:=gen_random_uuid(); dependency uuid:=gen_random_uuid(); snapshot uuid:=gen_random_uuid(); version uuid:=gen_random_uuid();
 e jsonb; manifest jsonb; state jsonb;
BEGIN
 TRUNCATE public.accounts,public.context_resources,public.context_sources CASCADE;
 TRUNCATE video_fixture.state,public.account_organization_ids;
 INSERT INTO public.accounts(id,name) VALUES(owner_id,'Fixture owner'),(actor,'Fixture member'),(outsider,'Fixture outsider');
 INSERT INTO public.account_organization_ids(account_id,organization_id) VALUES(actor,owner_id);
 req:=public.create_context_video_request(owner_id,actor,'AbCdEfGhI_1','locator');
 SELECT resource_id,(output->'subjectIds'->>0)::uuid INTO resource,subject FROM public.context_requests WHERE id=(req->>'id')::uuid;
 SELECT id INTO link FROM public.context_resource_links WHERE resource_id=resource AND subject_id=subject AND relation='identity';
 e:=jsonb_build_object('requestId',req->>'id','ownerId',owner_id,'videoSubjectId',subject,'videoId','AbCdEfGhI_1',
  'mediaVersion','upload-1','durationSeconds',120,'variant','unknown','title',E'  Café 🎵\nTitle  ','description',E'Original\n description  ',
  'channel',jsonb_build_object('id','channel-1','name','Uploader'),
  'performers',jsonb_build_array(jsonb_build_object('name','Observed performer','sourceVersionIds',jsonb_build_array(version))),
  'identity',jsonb_build_object('state','unresolved','reason','No recording identity established'),
  'sources',jsonb_build_array(jsonb_build_object('versionId',snapshot,'videoId','AbCdEfGhI_1','mediaVersion','upload-1','retrievedAt','2026-11-18T00:00:00Z'),
   jsonb_build_object('versionId',version,'videoId','AbCdEfGhI_1','mediaVersion','upload-1','retrievedAt','2026-11-18T00:00:00Z')),
  'captions',jsonb_build_object('state','available','sourceVersionIds',jsonb_build_array(version),'segments',jsonb_build_array(jsonb_build_object('startSeconds',0,'endSeconds',10,'language','en','text','Retained words'))),
  'analysis',jsonb_build_object('state','unavailable','reason','Analysis not retained'));
 manifest:=jsonb_build_object('contextVideo',jsonb_build_object('contractVersion','retained-video-evidence-v1','requestId',req->>'id','videoSubjectId',subject,'videoId','AbCdEfGhI_1','mediaVersion','upload-1'));
 INSERT INTO public.context_sources(id,owner_id,source_url,kind) VALUES(source,owner_id,'fixture:snapshot','provider_metadata'),(dependency,owner_id,'fixture:captions','provider_metadata');
 INSERT INTO public.context_source_versions(id,owner_id,source_id,fingerprint,content,media_manifest,retrieved_at)
 VALUES(snapshot,owner_id,source,encode(sha256(convert_to(e::text,'UTF8')),'hex'),e,manifest,'2026-11-18T00:00:00Z'),
 (version,owner_id,dependency,repeat('a',64),jsonb_build_object('captions','Retained words'),manifest,'2026-11-18T00:00:00Z');
 state:=jsonb_build_object('owner',owner_id,'actor',actor,'outsider',outsider,'request',req->>'id','subject',subject,'resource',resource,'link',link,'source',source,'dependency',dependency,'snapshot',snapshot,'version',version,'evidence',e);
 INSERT INTO video_fixture.state VALUES(state);
 RETURN state;
END $$;
CREATE FUNCTION video_fixture.raise_fault() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'fixture write fault'; END $$;
