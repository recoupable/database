-- View that flattens the posts ← social_posts → socials ← account_socials
-- chain so the API can fetch artist-scoped posts in one round trip instead of
-- three chained queries + in-memory dedup. `distinct` dedupes posts that are
-- shared across multiple socials belonging to the same artist account.
create or replace view public.artist_posts as
select distinct
  p.id,
  p.post_url,
  p.updated_at,
  ac.account_id as artist_account_id
from public.posts p
join public.social_posts sp on sp.post_id = p.id
join public.socials s on s.id = sp.social_id
join public.account_socials ac on ac.social_id = s.id
where ac.account_id is not null;

comment on view public.artist_posts is
  'Artist-scoped posts: distinct posts reachable via a given account''s socials. '
  'Used by GET /api/artists/{id}/posts to avoid N+1 queries.';
