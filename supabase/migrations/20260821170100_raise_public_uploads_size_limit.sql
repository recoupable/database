-- Raise the public-uploads size limit from 25 MiB to 64 MiB so generated audio
-- fits (recoupable/chat#1992).
--
-- MiniMax Music 3 returns 44.1 kHz 16-bit stereo WAV, about 10.6 MB per
-- minute. Against the 25 MiB limit set in 20260508151035 that caps a mirrored
-- song at roughly 148 seconds, while the API accepts a requested duration of
-- up to 300. Without this, a long generation renders on fal, is charged for,
-- and then fails at the upload step.
--
-- 64 MiB is sized to the longest song we accept (300 seconds is about 50.5
-- MiB) and no further, rather than a round 100. The limit is per bucket, not
-- per MIME type, so every raise also raises the ceiling for the images, PDFs
-- and CSVs that share this bucket - keeping the number tight keeps that blast
-- radius small. A separate audio-only bucket would scope it exactly, at the
-- cost of a second bucket, its own keys and a second upload path; not worth it
-- for a 39 MiB difference on an API-gated bucket.
--
-- allowed_mime_types is untouched: audio/wav and audio/mpeg were permitted
-- from the start.
--
-- Idempotent: safe to re-apply.

update storage.buckets
   set file_size_limit = 67108864 -- 64 MiB
 where id = 'public-uploads'
   and (file_size_limit is null or file_size_limit < 67108864);
