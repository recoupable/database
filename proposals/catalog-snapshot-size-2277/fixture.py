"""Reuse the accepted four-file synthetic bundle setup for paired API size tests."""
import pathlib
import test_release_cases as base
ROOT = pathlib.Path(__file__).resolve().parents[2]
def apply(cls, name):
    cls.sql((ROOT / 'supabase/migrations' / name).read_text())
def setup_catalog_size_fixture(cls):
 base.ReleaseCases.setUpClass.__func__(cls)
 cls.sql('CREATE EXTENSION IF NOT EXISTS "uuid-ossp";')
 cls.sql('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon,authenticated,service_role; ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO service_role;')
 for n in ['20260630210000_create_email_send_log.sql','20260630211500_finalize_email_send_log.sql']:apply(cls,n)
 cls.sql("INSERT INTO public.email_send_log(id,status,raw_body) VALUES('00000000-0000-4000-8000-000000000001','rejected','synthetic pre-migration row');")
 for n in ['20261022120000_context_catalog_cases.sql','20261106120000_email_send_log_reason.sql','20261110010000_ingestion_catalog.sql','20261110010100_ingestion_catalog_page_budget.sql']:apply(cls,n)

class CatalogSizeFixture(base.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        setup_catalog_size_fixture(cls)
        cls.sql((ROOT / "proposals/catalog-snapshot-size-2277/proposal.sql").read_text())
