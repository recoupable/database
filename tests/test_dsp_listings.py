"""DSP store listings persist as provider observations, never resources; disposable PG only."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT
# The claim/complete/fail chain on top of the release-cases fixture. The execution-record
# migration is not needed for these functions and would pull in catalog tables.
ENRICHMENT_CHAIN = [
    '20260920030000_context_enrichment_pilot.sql',
    '20260922060000_context_provider_evidence.sql',
    '20260923070000_context_enrichment_scope.sql',
    '20260924020000_context_enrichment_reuse_binding.sql',
    '20260927090000_context_audio_source.sql',
]
MIGRATION = ROOT / 'supabase/migrations/20261010214300_context_dsp_listings.sql'

# One workspace with a single completed request over one recording subject. The ISRC is the
# synthetic value the API Context suites already use; provider ids are fixture strings.
DECLARE = '''
 owner uuid:=gen_random_uuid(); resource uuid; subject uuid; req uuid;
 module jsonb; claim jsonb; saved jsonb; kind text; snapshots jsonb;
'''
SEED = '''
 insert into public.accounts(id,name) values(owner,'DSP listings owner');
 insert into public.songs(isrc) values('USAT22103065') on conflict do nothing;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
  values('spotify','track','DSPLISTINGS1AAAAAAAAAA','https://open.spotify.com/track/DSPLISTINGS1AAAAAAAAAA') returning id into resource;
 insert into public.context_subjects(kind,song_isrc) values('recording','USAT22103065') returning id into subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
  values(owner,owner,resource,'dsp-listings-q1',repeat('a',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(subject))) returning id into req;
 module:=jsonb_build_object('key','apple-music-listings-v1','topic','dsp_listings','subjectId',subject,
  'provider','apple_music','model','none','evidenceKind','observation',
  'input',jsonb_build_object('isrc','USAT22103065','storefronts',jsonb_build_array('jp','us'),'collectionVersion','fixture-v1'),
  'fingerprint',repeat('c',64),
  'sources',jsonb_build_array(
   jsonb_build_object('url','https://example.test/apple-music-lookup/jp','kind','provider_metadata',
    'content',jsonb_build_object('isrc','USAT22103065','storefront','jp','role','lookup_request')),
   jsonb_build_object('url','https://example.test/apple-music-lookup/us','kind','provider_metadata',
    'content',jsonb_build_object('isrc','USAT22103065','storefront','us','role','lookup_request'))));
'''


def block(body):
    return 'begin;\ndo $$\ndeclare' + DECLARE + 'begin' + SEED + body + '\nend $$;\nrollback;'


class DspListings(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        for migration in ENRICHMENT_CHAIN:
            cls.sql((ROOT / 'supabase/migrations' / migration).read_text())
        cls.sql(MIGRATION.read_text())

    def test_claim_save_and_reuse_storefront_scoped_listing_observation(self):
        result = self.sql(block('''
 claim:=public.claim_context_enrichment(owner,req,module);
 if claim->>'state'<>'claimed' then raise exception 'Expected claimed, got %',claim; end if;
 -- Two storefronts in one result: jp is not listed, us is listed. Both stay as evidence.
 saved:=public.complete_context_enrichment(owner,req,(claim->>'attemptId')::uuid,jsonb_build_object(
  'content',jsonb_build_object('provider','apple_music','isrc','USAT22103065','collectionVersion','fixture-v1','identityConfirmed',false,
   'storefronts',jsonb_build_array(
    jsonb_build_object('storefront','jp','availability',jsonb_build_object('status','not_listed','storefront','jp'),'songListings','[]'::jsonb),
    jsonb_build_object('storefront','us','availability',jsonb_build_object('status','listed','storefront','us'),
     'songListings',jsonb_build_array(jsonb_build_object('resourceType','song','providerId','1001',
      'albumListing',jsonb_build_object('resourceType','album','providerId','2001','upc',null))))),
   'regionalComparison',jsonb_build_object('listedStorefronts',jsonb_build_array('us'),'varies',null)),
  'coverage','partial','trace',jsonb_build_object('provider','apple_music'),'costUsd',null,'costStatus','unknown',
  'observedSources',jsonb_build_array(
   jsonb_build_object('url','https://example.test/apple-music-lookup/jp','kind','provider_metadata',
    'content',jsonb_build_object('storefront','jp','payload',jsonb_build_object('isrc','USAT22103065','found',false))),
   jsonb_build_object('url','https://example.test/apple-music-lookup/us','kind','provider_metadata',
    'content',jsonb_build_object('storefront','us','payload',jsonb_build_object('isrc','USAT22103065','found',true))))));
 if saved->>'state'<>'saved' then raise exception 'Expected saved, got %',saved; end if;
 select evidence_kind into strict kind from public.context_results where id=(saved->>'resultId')::uuid;
 if kind<>'observation' then raise exception 'Expected observation evidence, got %',kind; end if;
 select jsonb_object_agg(v.content->>'storefront',v.content->'payload'->'found') into strict snapshots from public.context_result_sources rs
  join public.context_source_versions v on v.id=rs.source_version_id where rs.result_id=(saved->>'resultId')::uuid;
 if snapshots is distinct from '{"jp":false,"us":true}'::jsonb
  then raise exception 'Each storefront snapshot was not versioned separately: %',snapshots; end if;
 -- A listing is evidence about a recording; it never becomes a resource, identity or release subject.
 if exists(select 1 from public.context_resources where provider<>'spotify') then raise exception 'Listing became a canonical resource'; end if;
 if exists(select 1 from public.context_resource_links) then raise exception 'Listing became an identity link'; end if;
 if (select count(*) from public.context_subjects)<>1 then raise exception 'Listing created a subject'; end if;
 claim:=public.claim_context_enrichment(owner,req,module);
 if claim->>'state'<>'reused' then raise exception 'Expected reuse, got %',claim; end if;
 if claim->'content'->'storefronts'->1->'songListings'->0->>'providerId'<>'1001'
  or claim->'content'->'storefronts'->1->'songListings'->0->'albumListing'->>'providerId'<>'2001'
  or claim->'content'->'storefronts'->0->'availability'->>'status'<>'not_listed'
  then raise exception 'Reused listing lost its storefront availability: %',claim; end if;
 raise notice 'PASS: dsp_listings claim, storefront-scoped save and reuse';'''))
        self.assertIn('PASS:', result.stderr)

    def test_listing_topic_requires_observation_evidence(self):
        result = self.sql(block('''
 begin
  perform public.claim_context_enrichment(owner,req,module||jsonb_build_object('evidenceKind','interpretation'));
  raise exception 'TEST_FAILURE: interpretation accepted for dsp_listings';
 exception when others then
  if SQLERRM<>'Provider lookup requires observation evidence' then raise; end if;
 end;
 begin
  perform public.claim_context_enrichment(owner,req,module||jsonb_build_object('evidenceKind','estimate'));
  raise exception 'TEST_FAILURE: estimate accepted for dsp_listings';
 exception when others then
  if SQLERRM<>'Provider lookup requires observation evidence' then raise; end if;
 end;
 if exists(select 1 from public.context_attempts) then raise exception 'Rejected claim left an attempt'; end if;
 raise notice 'PASS: dsp_listings requires observation evidence';'''))
        self.assertIn('PASS:', result.stderr)

    def test_existing_provider_topics_still_claim(self):
        result = self.sql(block('''
 claim:=public.claim_context_enrichment(owner,req,module||jsonb_build_object('topic','musicbrainz_recordings','fingerprint',repeat('d',64)));
 if claim->>'state'<>'claimed' then raise exception 'Expected musicbrainz claim, got %',claim; end if;
 claim:=public.claim_context_enrichment(owner,req,module||jsonb_build_object('topic','catalog_valuation','evidenceKind','estimate','fingerprint',repeat('e',64)));
 if claim->>'state'<>'claimed' then raise exception 'Expected valuation claim, got %',claim; end if;
 raise notice 'PASS: earlier topics keep their evidence rules';'''))
        self.assertIn('PASS:', result.stderr)

    def test_unknown_topic_is_still_rejected(self):
        result = self.sql(block('''
 begin
  perform public.claim_context_enrichment(owner,req,module||jsonb_build_object('topic','dsp_listing'));
  raise exception 'TEST_FAILURE: near-miss topic accepted';
 exception when others then
  if SQLERRM<>'Invalid enrichment module' then raise; end if;
 end;
 begin
  perform public.claim_context_enrichment(owner,req,module||jsonb_build_object('topic','youtube_music_listings'));
  raise exception 'TEST_FAILURE: unregistered provider topic accepted';
 exception when others then
  if SQLERRM<>'Invalid enrichment module' then raise; end if;
 end;
 raise notice 'PASS: unknown topics are rejected';'''))
        self.assertIn('PASS:', result.stderr)
