-- Forward-only correction: keep shared record pages within an inline response budget.
BEGIN;
CREATE OR REPLACE FUNCTION public.ingestion_catalog_command(p_actor uuid,p_org uuid,p_action text,p_input jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 v_manifest jsonb; v_job text; v_dataset uuid; v_import public.ingestion_imports;
 v_result jsonb; v_gold jsonb; v_status text; v_fingerprint text; v_count integer;
 v_limit integer; v_after integer; v_last integer; v_items jsonb; v_cursor_time timestamptz; v_cursor_id uuid; v_cursor_job text;
BEGIN
 PERFORM public.authorize_ingestion_organization(p_actor,p_org);
 IF p_input IS NULL OR jsonb_typeof(p_input)<>'object' OR octet_length(p_input::text)>25165824 THEN
  RAISE EXCEPTION 'Invalid ingestion catalog input' USING ERRCODE='22023';
 END IF;
 IF p_action='register' THEN
  v_manifest:=p_input->'manifest'; v_job:=v_manifest->>'job_id';
  IF v_manifest IS NULL OR jsonb_typeof(v_manifest)<>'object' OR octet_length(v_manifest::text)>1048576
     OR v_job IS NULL OR v_job !~ '^[a-f0-9]{64}$'
     OR (v_manifest->>'scope') IS DISTINCT FROM ('organization/'||p_org::text)
     OR coalesce(v_manifest->>'input_sha256','') !~ '^[a-f0-9]{64}$'
     OR coalesce(v_manifest->>'bronze_sha256','') !~ '^[a-f0-9]{64}$'
     OR (v_manifest->>'bronze_key') IS DISTINCT FROM ('organization/'||p_org::text||'/originals/'||(v_manifest->>'bronze_sha256'))
     OR coalesce(v_manifest->>'format','') NOT IN ('csv','tsv','json','jsonl','xlsx','pdf')
     OR coalesce(length(v_manifest->>'filename'),0) NOT BETWEEN 1 AND 200
     OR coalesce(jsonb_typeof(v_manifest->'contract'),'')<>'object'
  THEN RAISE EXCEPTION 'Invalid ingestion catalog input' USING ERRCODE='22023'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ingestion:'||p_org::text||':'||v_job,0));
  SELECT * INTO v_import FROM public.ingestion_imports WHERE organization_id=p_org AND job_id=v_job FOR UPDATE;
  IF FOUND THEN
   IF v_import.manifest<>v_manifest THEN RAISE EXCEPTION 'Ingestion catalog conflict'; END IF;
   RETURN jsonb_build_object('dataset_id',v_import.dataset_id,'job_id',v_job);
  END IF;
  v_dataset:=(v_manifest->>'dataset_id')::uuid;
  IF v_dataset IS NULL THEN
   INSERT INTO public.ingestion_datasets(organization_id,name,created_by) VALUES(p_org,v_manifest->>'filename',p_actor) RETURNING id INTO v_dataset;
  ELSE
   PERFORM 1 FROM public.ingestion_datasets WHERE id=v_dataset AND organization_id=p_org FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Ingestion access denied' USING ERRCODE='42501'; END IF;
  END IF;
  INSERT INTO public.ingestion_imports(organization_id,job_id,dataset_id,actor_id,manifest) VALUES(p_org,v_job,v_dataset,p_actor,v_manifest);
  RETURN jsonb_build_object('dataset_id',v_dataset,'job_id',v_job);
 ELSIF p_action='complete' THEN
  v_job:=p_input->>'job_id'; v_result:=p_input->'result'; v_gold:=nullif(p_input->'gold','null'::jsonb); v_status:=v_result->>'status';
  SELECT * INTO v_import FROM public.ingestion_imports WHERE organization_id=p_org AND job_id=v_job FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ingestion access denied' USING ERRCODE='42501'; END IF;
  IF v_result IS NULL OR jsonb_typeof(v_result)<>'object' OR v_status IS NULL OR v_status NOT IN ('ready','held','rejected')
     OR (v_result->>'job_id') IS DISTINCT FROM v_job
     OR (v_result->>'source_sha256') IS DISTINCT FROM (v_import.manifest->>'bronze_sha256')
     OR (v_result->>'engine_version') IS DISTINCT FROM (v_import.manifest->>'engine_version')
     OR coalesce(v_result->>'silver_sha256','') !~ '^[a-f0-9]{64}$'
     OR coalesce(v_result->>'rows_read','') !~ '^\d{1,5}$' OR (v_result->>'rows_read')::integer>10000
     OR coalesce(v_result->>'rows_output','') !~ '^\d{1,5}$' OR (v_result->>'rows_output')::integer>10000
  THEN RAISE EXCEPTION 'Invalid ingestion catalog input' USING ERRCODE='22023'; END IF;
  IF v_status='ready' THEN
   IF v_gold IS NULL OR jsonb_typeof(v_gold)<>'object' OR coalesce(jsonb_typeof(v_gold->'records'),'')<>'array'
      OR coalesce(jsonb_typeof(v_gold->'field_types'),'')<>'object'
      OR (v_gold->>'engine_version') IS DISTINCT FROM (v_import.manifest->>'engine_version')
      OR (v_gold->>'contract_version') IS DISTINCT FROM (v_import.manifest->'contract'->>'version')
      OR coalesce(v_result->>'gold_sha256','') !~ '^[a-f0-9]{64}$'
   THEN RAISE EXCEPTION 'Invalid ingestion gold' USING ERRCODE='22023'; END IF;
   v_count:=jsonb_array_length(v_gold->'records');
   IF v_count NOT BETWEEN 1 AND 10000 OR v_count<>(v_result->>'rows_output')::integer
      OR (SELECT count(*) FROM jsonb_object_keys(v_gold->'field_types')) NOT BETWEEN 1 AND 100
      OR EXISTS(SELECT 1 FROM jsonb_each(v_gold->'field_types') f WHERE jsonb_typeof(f.value)<>'string' OR f.value#>>'{}' NOT IN ('string','decimal','integer','date','boolean'))
   THEN RAISE EXCEPTION 'Invalid ingestion gold' USING ERRCODE='22023'; END IF;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_gold->'records') r WHERE jsonb_typeof(r)<>'object') THEN
    RAISE EXCEPTION 'Invalid ingestion gold' USING ERRCODE='22023';
   END IF;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_gold->'records') r WHERE
      (SELECT count(*) FROM jsonb_object_keys(r))<>(SELECT count(*) FROM jsonb_object_keys(v_gold->'field_types'))
      OR EXISTS(SELECT 1 FROM jsonb_each(r) f WHERE NOT (v_gold->'field_types' ? f.key) OR jsonb_typeof(f.value) NOT IN ('string','null')))
   THEN RAISE EXCEPTION 'Invalid ingestion gold' USING ERRCODE='22023'; END IF;
  ELSE
   v_count:=0;
   IF v_gold IS NOT NULL OR (v_result->>'gold_sha256') IS NOT NULL OR (v_result->>'rows_output')::integer<>0 THEN
    RAISE EXCEPTION 'Invalid ingestion gold' USING ERRCODE='22023';
   END IF;
  END IF;
  v_fingerprint:=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_object('result',v_result,'gold',v_gold)::text,'UTF8')),'hex');
  IF v_import.status<>'queued' THEN
   IF v_import.completion_sha256<>v_fingerprint THEN RAISE EXCEPTION 'Ingestion catalog conflict'; END IF;
   RETURN jsonb_build_object('dataset_id',v_import.dataset_id,'job_id',v_job,'status',v_import.status,'rows',v_count);
  END IF;
  INSERT INTO public.ingestion_records(organization_id,job_id,dataset_id,row_number,record)
   SELECT p_org,v_job,v_import.dataset_id,n::integer,r FROM jsonb_array_elements(v_gold->'records') WITH ORDINALITY AS rows(r,n);
  UPDATE public.ingestion_imports SET status=v_status,result=v_result,field_types=v_gold->'field_types',completion_sha256=v_fingerprint,completed_at=clock_timestamp()
   WHERE organization_id=p_org AND job_id=v_job;
  RETURN jsonb_build_object('dataset_id',v_import.dataset_id,'job_id',v_job,'status',v_status,'rows',v_count);
 ELSIF p_action IN ('datasets','imports','records') THEN
  v_limit:=coalesce((p_input->>'limit')::integer,25);
  IF v_limit NOT BETWEEN 1 AND (CASE WHEN p_action='records' THEN 100 ELSE 50 END) THEN RAISE EXCEPTION 'Invalid ingestion page' USING ERRCODE='22023'; END IF;
  IF p_action='datasets' THEN
   v_cursor_id:=(p_input->>'after')::uuid;
   IF v_cursor_id IS NOT NULL THEN
    SELECT created_at INTO v_cursor_time FROM public.ingestion_datasets WHERE id=v_cursor_id AND organization_id=p_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'Ingestion access denied' USING ERRCODE='42501'; END IF;
   END IF;
   SELECT coalesce(jsonb_agg(item ORDER BY created_at DESC,id DESC),'[]'::jsonb) INTO v_items FROM (
    SELECT d.id,d.created_at,jsonb_build_object('dataset_id',d.id,'name',d.name,'created_at',d.created_at) item
    FROM public.ingestion_datasets d WHERE d.organization_id=p_org AND (v_cursor_id IS NULL OR (d.created_at,d.id)<(v_cursor_time,v_cursor_id))
    ORDER BY d.created_at DESC,d.id DESC LIMIT v_limit+1
   ) q;
   RETURN jsonb_build_object('datasets',v_items- v_limit,'next_after',CASE WHEN jsonb_array_length(v_items)>v_limit THEN v_items->(v_limit-1)->>'dataset_id' ELSE NULL END);
  END IF;
  v_dataset:=(p_input->>'dataset_id')::uuid;
  PERFORM 1 FROM public.ingestion_datasets WHERE id=v_dataset AND organization_id=p_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ingestion access denied' USING ERRCODE='42501'; END IF;
  IF p_action='imports' THEN
   v_cursor_job:=p_input->>'after';
   IF v_cursor_job IS NOT NULL THEN
    SELECT created_at INTO v_cursor_time FROM public.ingestion_imports WHERE organization_id=p_org AND dataset_id=v_dataset AND job_id=v_cursor_job;
    IF NOT FOUND THEN RAISE EXCEPTION 'Ingestion access denied' USING ERRCODE='42501'; END IF;
   END IF;
   SELECT coalesce(jsonb_agg(item ORDER BY created_at DESC,job_id DESC),'[]'::jsonb) INTO v_items FROM (
    SELECT i.created_at,i.job_id,jsonb_build_object('job_id',i.job_id,'dataset_id',i.dataset_id,'status',i.status,'filename',i.manifest->>'filename',
     'format',i.manifest->>'format','source_sha256',i.manifest->>'bronze_sha256','created_at',i.created_at,'completed_at',i.completed_at,
     'rows_read',i.result->'rows_read','rows_output',i.result->'rows_output','gold_sha256',i.result->'gold_sha256') item
    FROM public.ingestion_imports i WHERE i.organization_id=p_org AND i.dataset_id=v_dataset AND (v_cursor_job IS NULL OR (i.created_at,i.job_id)<(v_cursor_time,v_cursor_job))
    ORDER BY i.created_at DESC,i.job_id DESC LIMIT v_limit+1
   ) q;
   RETURN jsonb_build_object('imports',v_items-v_limit,'next_after',CASE WHEN jsonb_array_length(v_items)>v_limit THEN v_items->(v_limit-1)->>'job_id' ELSE NULL END);
  END IF;
  v_job:=p_input->>'job_id'; v_after:=coalesce((p_input->>'after_row')::integer,0);
  IF v_after NOT BETWEEN 0 AND 10000 THEN RAISE EXCEPTION 'Invalid ingestion page' USING ERRCODE='22023'; END IF;
  SELECT * INTO v_import FROM public.ingestion_imports WHERE organization_id=p_org AND dataset_id=v_dataset AND job_id=v_job;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ingestion access denied' USING ERRCODE='42501'; END IF;
  IF v_import.status<>'ready' THEN RAISE EXCEPTION 'Artifact not ready'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('row_number',row_number,'record',record) ORDER BY row_number),'[]'::jsonb) INTO v_items FROM (
   SELECT row_number,record,sum(octet_length(record::text)+64) OVER (ORDER BY row_number) page_bytes FROM (
    SELECT row_number,record FROM public.ingestion_records WHERE organization_id=p_org AND job_id=v_job AND row_number>v_after ORDER BY row_number LIMIT v_limit
   ) bounded
  ) q WHERE page_bytes<=2097152;
  v_last:=(v_items->-1->>'row_number')::integer;
  IF v_last IS NULL AND EXISTS(SELECT 1 FROM public.ingestion_records WHERE organization_id=p_org AND job_id=v_job AND row_number>v_after) THEN
   RAISE EXCEPTION 'Ingestion record size limit';
  END IF;
  RETURN jsonb_build_object('dataset_id',v_dataset,'job_id',v_job,'field_types',v_import.field_types,'gold_sha256',v_import.result->>'gold_sha256',
   'records',v_items,'next_after',CASE WHEN EXISTS(SELECT 1 FROM public.ingestion_records WHERE organization_id=p_org AND job_id=v_job AND row_number>v_last) THEN v_last ELSE NULL END);
 END IF;
 RAISE EXCEPTION 'Invalid ingestion catalog action' USING ERRCODE='22023';
END $$;
COMMIT;
