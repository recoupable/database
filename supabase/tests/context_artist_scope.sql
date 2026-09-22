do $$
declare req public.context_requests; subject uuid; artist uuid;
begin
 select r.* into strict req from public.context_requests r where exists(select 1 from public.context_subjects s where s.kind='artist' and r.output->'subjectIds' ? s.id::text) limit 1;
 select s.id,s.artist_id into strict subject,artist from public.context_subjects s where s.kind='artist' and req.output->'subjectIds' ? s.id::text limit 1;
 insert into public.account_artist_ids(account_id,artist_id) values(req.owner_id,artist) on conflict do nothing;
 if public.resolve_context_artist(req.owner_id,req.id,subject)->>'artistId' is distinct from artist::text then raise exception 'Wrong artist'; end if;
 delete from public.account_artist_ids where account_id=req.owner_id and artist_id=artist;
 delete from public.artist_organization_ids where organization_id=req.owner_id and artist_id=artist;
 begin
  perform public.resolve_context_artist(req.owner_id,req.id,subject);
  raise exception 'TEST_FAILURE: revoked artist access allowed';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
end $$;
