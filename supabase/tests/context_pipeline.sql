begin;
do $$
declare a uuid := gen_random_uuid(); req jsonb; second jsonb; token uuid := gen_random_uuid(); payload jsonb; result jsonb; docs jsonb;
begin
 insert into public.accounts(id,name) values(a,'Pipeline test');
 req := public.create_context_request(a,a,'test-one','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{"url":"https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA","topics":["release_metadata","artist_metadata"]}','AAAAAAAAAAAAAAAAAAAAAA');
 second := public.create_context_request(a,a,'test-one','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{"url":"https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA"}','AAAAAAAAAAAAAAAAAAAAAA');
 if req->>'id' <> second->>'id' then raise exception 'retries created duplicate requests'; end if;
 begin
  perform public.create_context_request(a,a,'test-one',repeat('b',64),'{}','AAAAAAAAAAAAAAAAAAAAAA');
  raise exception 'changed input accepted';
 exception when sqlstate '22023' then null; end;
 if not public.claim_context_request(a,(req->>'id')::uuid,token) then raise exception 'claim rejected'; end if;
 if public.claim_context_request(a,(req->>'id')::uuid,gen_random_uuid()) then raise exception 'duplicate worker accepted'; end if;
 payload := '{"trackId":"AAAAAAAAAAAAAAAAAAAAAA","title":"First track","isrc":"USABC2600001","durationSeconds":180,"artists":[{"id":"1234567890123456789012","name":"Test artist"}],"release":{"id":"abcdefghijklmnopqrstuv","title":"Album","date":"2026-09-01","datePrecision":"day","artwork":[]},"previewUrl":null}';
 result := public.commit_spotify_context(a,(req->>'id')::uuid,token,payload);
 if (select album from public.songs where isrc='USABC2600001') is distinct from 'Album' or (select lyrics from public.songs where isrc='USABC2600001') is distinct from '' then raise exception 'Required song fields missing'; end if;
 if result->>'status' <> 'completed' then raise exception 'metadata did not complete'; end if;
 docs := public.read_context_documents(a,(req->>'id')::uuid);
 if jsonb_array_length(docs) <> 2 then raise exception 'expected artist and release documents: %',docs; end if;
 second := public.create_context_request(a,a,'test-two',repeat('c',64),'{"url":"https://open.spotify.com/track/BBBBBBBBBBBBBBBBBBBBBB","topics":["release_metadata","artist_metadata"]}','BBBBBBBBBBBBBBBBBBBBBB');
 perform public.claim_context_request(a,(second->>'id')::uuid,token);
 result := public.commit_spotify_context(a,(second->>'id')::uuid,token,payload || '{"trackId":"BBBBBBBBBBBBBBBBBBBBBB","isrc":"USABC2600002","title":"Second track"}');
 if (select count(*) from public.context_documents where owner_id=a and topic='artist_metadata') <> 1 then raise exception 'artist not reused'; end if;
 if (select count(*) from public.context_documents where owner_id=a and topic='release_metadata') <> 2 then raise exception 'songs collapsed'; end if;
 if public.read_context_request(gen_random_uuid(),(req->>'id')::uuid) is not null then raise exception 'cross owner read'; end if;
 raise notice 'PASS: idempotency, conflict rejection, worker claim, persistence, two-track accumulation, ownership';
end $$;
rollback;
