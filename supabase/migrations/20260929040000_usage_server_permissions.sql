-- Server-side usage reporting and provider audit writes need explicit grants
-- when the schema is replayed into a fresh preview database.
grant select, insert on public.usage_events to service_role;
