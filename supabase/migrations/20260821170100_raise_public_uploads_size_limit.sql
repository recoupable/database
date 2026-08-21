-- Raise the public-uploads size limit from 25 MiB to 100 MiB so generated
-- audio fits (recoupable/chat#1992).
--
-- MiniMax Music 3 returns 44.1 kHz 16-bit stereo WAV, which is about
-- 10.6 MB per minute. Against the 25 MiB limit set in 20260508151035 that caps
-- a mirrored song at roughly 148 seconds, while the API accepts a requested
-- duration of up to 300. Without this, a long generation renders successfully
-- on fal, is charged for, and then fails at the upload step — the worst
-- possible place to discover the limit.
--
-- 100 MiB covers a 300-second WAV (about 53 MB) with room for the other audio
-- types the bucket already allows. The allowed_mime_types list is untouched:
-- audio/wav and audio/mpeg were permitted from the start.
--
-- Idempotent: safe to re-apply.

update storage.buckets
   set file_size_limit = 104857600 -- 100 MiB
 where id = 'public-uploads'
   and (file_size_limit is null or file_size_limit < 104857600);
