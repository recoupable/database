-- Generated silent cinematic clips share the existing public asset bucket.
-- Upload permissions stay service-role only; preserve every existing MIME type.
update storage.buckets
set file_size_limit = greatest(coalesce(file_size_limit, 40000000), 40000000),
    allowed_mime_types = case
      when allowed_mime_types is null then null
      when 'video/mp4' = any(allowed_mime_types) then allowed_mime_types
      else array_append(allowed_mime_types, 'video/mp4')
    end
where id = 'site-assets';
