-- Migration: Preserve case in YouTube channel URLs, and anchor the Spotify exemption
--
-- Three changes to clean_socials_profile_url(), plus a cleanup of the rows the old
-- behaviour already destroyed. Ref: recoupable/chat#1937.
--
-- 1. YouTube channel ids are case-sensitive ('UC' + 22 base64url chars), so the
--    blanket lower() produced an id that does not exist. Measured 2026-08-05:
--      youtube.com/channel/UCjE28www-twspEryh2U8yOQ -> HTTP 200
--      youtube.com/channel/ucje28www-twsperyh2u8yoq -> HTTP 404
--    Scoped to the '/channel/<id>' segment only. The /@handle, /user/ and /c/
--    forms are genuinely case-insensitive (verified live: youtube.com/@UncleLuciusBand
--    and youtube.com/@uncleluciusband both 200), so they keep today's lowercasing,
--    which is good for dedupe. 137 @handle, 25 /user/ and 11 /c/ rows are unaffected.
--
-- 2. The 2025-06 Spotify exemption used NOT ILIKE '%spotify%' -- a substring test over
--    the whole URL, so it also exempted unrelated rows such as instagram.com/spotifyargentina
--    and tiktok.com/@spotifyde. Anchored to a spotify.com host instead.
--    Blast radius measured on prod 2026-08-05: of 1638 rows matching '%spotify%',
--    1616 stay exempt (1403 of them contain uppercase and depend on that), and 22 lose
--    the exemption. 21 of those 22 are already lowercase, so the only row whose stored
--    value can change is x.com/Spotifycloudp -> x.com/spotifycloudp on its next write
--    (no unique-constraint collision: x.com/spotifycloudp does not exist).
--
-- 3. The protocol/www/trailing-slash strips were case-sensitive, so 'HTTPS://' and
--    'WWW.' were never removed -- the trailing lower() only made the leftovers look
--    normalized ('HTTPS://WWW.TIKTOK.COM/@FooBar' was stored as
--    'https://www.tiktok.com/@foobar', which is a distinct value from
--    'tiktok.com/@foobar' under the socials_profile_url_key UNIQUE index, so the same
--    profile could be stored twice). Made case-insensitive with the 'i' flag.
--    This is also load-bearing for the two anchored tests above: they match at the
--    start of the string, so an unstripped 'HTTPS://' prefix would push the host out
--    of position and silently drop the exemption -- destroying a case-sensitive
--    Spotify or YouTube id that the old substring test happened to preserve.
--    Only 1 prod row is affected (https://x.com/brauxelion_, which predates the
--    2025-05-28 trigger); it is already lowercase, so it simply loses the prefix on
--    its next write. 0 rows start with 'www.'.

CREATE OR REPLACE FUNCTION clean_socials_profile_url()
RETURNS TRIGGER AS $$
DECLARE
  yt_channel_prefix text;
BEGIN
  -- Remove protocol (http://, https://) from the start. Case-insensitive: the host
  -- must be at position 0 for the anchored exemptions below to see it.
  NEW.profile_url := regexp_replace(NEW.profile_url, '^https?://', '', 'i');
  -- Remove leading www. from the start
  NEW.profile_url := regexp_replace(NEW.profile_url, '^www\.', '', 'i');
  -- Remove any trailing slash
  NEW.profile_url := regexp_replace(NEW.profile_url, '/+$', '');

  -- Spotify artist/track/album ids are case-sensitive: leave the URL untouched.
  -- Anchored to the host so a URL that merely contains the word is not exempted.
  IF NEW.profile_url ~* '^([a-z0-9-]+\.)?spotify\.com(/|$)' THEN
    RETURN NEW;
  END IF;

  -- YouTube channel ids are case-sensitive. Lowercase only the host and the
  -- '/channel/' prefix, and preserve everything after it byte-for-byte.
  yt_channel_prefix := (regexp_match(NEW.profile_url, '^(?:m\.|music\.)?youtube\.com/channel/', 'i'))[1];
  IF yt_channel_prefix IS NOT NULL THEN
    NEW.profile_url := lower(yt_channel_prefix)
                    || substr(NEW.profile_url, length(yt_channel_prefix) + 1);
    RETURN NEW;
  END IF;

  -- Everything else keeps today's behaviour.
  NEW.profile_url := lower(NEW.profile_url);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Remove the rows the old trigger already destroyed.
--
-- The original casing is not recoverable from the database -- the trigger overwrote it
-- in place and there is no history column -- so these 69 rows are permanently dead links
-- and cannot be repaired by an UPDATE. They are deleted rather than left as 404s; the
-- affected artists are re-resolved to the case-insensitive @handle form separately
-- (chat#1937), which is the form we store going forward.
--
-- The predicate is self-limiting: every real channel id starts with an uppercase 'UC',
-- so an all-lowercase /channel/ URL is necessarily corrupted. A correctly-cased row
-- inserted after this migration can never match.
--
-- Blast radius measured on prod 2026-08-05: 69 socials rows, cascading to exactly
-- 24 account_socials rows (24 distinct artist accounts) and nothing else. Every other
-- table with an ON DELETE CASCADE reference to socials -- social_posts, post_comments,
-- social_fans, fan_segments, agent_status -- has 0 rows for these ids.
DELETE FROM socials
WHERE profile_url ~* '^(m\.|music\.)?youtube\.com/channel/'
  AND profile_url = lower(profile_url);
