-- The Sites/context and credit readers traverse these legacy relationships.
-- Keep writes behind their existing APIs/RPCs and leave client-role grants unchanged.
grant select on public.account_socials, public.account_organization_ids,
  public.artist_organization_ids, public.organization_domains,
  public.credit_grants, public.social_snapshots, public.song_measurements,
  public.playcount_snapshots to service_role;
