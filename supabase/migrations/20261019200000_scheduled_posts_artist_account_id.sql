-- scheduled_posts.artist_account_id: the artist whose connection posts
-- (recoupable/app#2248, decision 2026-10-19).
--
-- account_id is now the account the post is made in and charged to, after the
-- standard account_id override resolves; it is never an artist. The artist,
-- when the post goes out on an artist's connected social account, is stored
-- here. NULL = the account's own connection posted.

ALTER TABLE public.scheduled_posts
    ADD COLUMN IF NOT EXISTS artist_account_id UUID
        REFERENCES public.accounts(id) ON DELETE CASCADE;

COMMENT ON COLUMN public.scheduled_posts.account_id IS
    'Account the post is made in and charged to (never an artist).';
COMMENT ON COLUMN public.scheduled_posts.artist_account_id IS
    'Artist whose connected social account posts; NULL = the account''s own connection.';

-- List Posts filters by artist within an account, newest first.
CREATE INDEX IF NOT EXISTS scheduled_posts_artist_account_id_created_at_idx
    ON public.scheduled_posts (artist_account_id, created_at DESC)
    WHERE artist_account_id IS NOT NULL;
