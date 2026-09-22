-- Run in a rollback transaction after the candidate migration.
insert into public.socials(profile_url, username)
select 'https://example.invalid/context-index-fixture/' || n, 'context-index-fixture'
from generate_series(1,10000) n;
analyze public.socials;
do $$
declare plan json;
begin
  perform set_config('enable_seqscan', 'off', true);
  execute $q$explain (format json)
    select s.id from public.socials s
    where regexp_replace(regexp_replace(s.profile_url,'^https?://',''),'[?#].*$','')
      in ('open.spotify.com/artist/1QzqrU2lmiW9l1mSvliVoM', 'open.spotify.com/artist/1QzqrU2lmiW9l1mSvliVoM/')
    order by s.id limit 1 for update$q$ into plan;
  if plan::text not like '%socials_context_profile_identity_idx%' then
    raise exception 'Artist lookup cannot use its normalized profile index: %', plan;
  end if;
end $$;
