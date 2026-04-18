-- Paginated accessor for the fans associated with an artist's segments.
--
-- The legacy flow in api (`lib/fans/getArtistFans.ts`) fetched every
-- `fan_social_id` for the artist's segments into memory, deduplicated, sliced
-- to the requested page, and then re-fetched the `socials` projection. Because
-- PostgREST caps `select()` responses at 10,000 rows, very popular artists
-- silently truncated. This function pushes DISTINCT, ordering, and pagination
-- into Postgres so the ceiling no longer applies.
--
-- `total_count` is repeated on every row (standard `COUNT(*) OVER()` idiom);
-- callers read it from the first row (or treat an empty result as 0).

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_artist_fans(
    artist_account_id UUID,
    limit_count INT,
    offset_count INT
)
RETURNS TABLE (
    total_count BIGINT,
    id UUID,
    username TEXT,
    avatar TEXT,
    profile_url TEXT,
    region TEXT,
    bio TEXT,
    "followerCount" INT,
    "followingCount" INT,
    updated_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $function$
    WITH distinct_fans AS (
        SELECT DISTINCT ON (s.id)
            s.id,
            s.username,
            s.avatar,
            s.profile_url,
            s.region,
            s.bio,
            s."followerCount",
            s."followingCount",
            s.updated_at
        FROM socials s
        JOIN fan_segments fs ON fs.fan_social_id = s.id
        JOIN artist_segments ars ON ars.segment_id = fs.segment_id
        WHERE ars.artist_account_id = get_artist_fans.artist_account_id
    )
    SELECT
        COUNT(*) OVER() AS total_count,
        df.id,
        df.username,
        df.avatar,
        df.profile_url,
        df.region,
        df.bio,
        df."followerCount",
        df."followingCount",
        df.updated_at
    FROM distinct_fans df
    ORDER BY df.updated_at DESC NULLS LAST, df.id
    LIMIT limit_count
    OFFSET offset_count;
$function$;

-- DOWN migration
-- DROP FUNCTION IF EXISTS public.get_artist_fans(UUID, INT, INT);
