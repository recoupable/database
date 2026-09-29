begin;
-- Run on a disposable database with the migration applied. Roll back all fixture data.
insert into public.accounts(id) values('11111111-1111-4111-8111-111111111111');
insert into public.sites(id,owner_id,artist_id,created_by,name) values('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','Fan connection fixture');
insert into public.site_fan_configs(site_id,return_url,marketing_text,enabled)
values('22222222-2222-4222-8222-222222222222','https://artist.example/release','Receive release announcements from Fixture Artist.',true);
insert into public.site_fan_oauth_sessions(state_hash,site_id,browser_hash,verifier,return_url,marketing_text,config_revision,scopes,expires_at,consumed_at)
values('test-state','22222222-2222-4222-8222-222222222222','browser','verifier','https://artist.example/release','Receive release announcements from Fixture Artist.',1,array['user-read-email','user-read-private'],now()+interval '10 minutes',now());
do $$ declare fan uuid; begin
  begin
    perform public.complete_site_fan_connection('test-state','spotify-fixture','Fan','fan@example.test',array['user-read-private']);
    raise exception 'Missing scope was accepted';
  exception when others then
    if sqlerrm <> 'Missing permissions' then raise; end if;
  end;
  if exists(select 1 from public.site_fans where spotify_id='spotify-fixture') then raise exception 'Partial write'; end if;
  fan := public.complete_site_fan_connection('test-state','spotify-fixture','Fan','fan@example.test',array['user-read-email','user-read-private']);
  if (select count(*) from public.site_fan_connections c join public.site_fan_permissions p on p.connection_id=c.id join public.site_fan_marketing_consents m on m.connection_id=c.id where c.fan_id=fan) <> 1 then raise exception 'Missing atomic records'; end if;
  begin
    perform public.complete_site_fan_connection('test-state','spotify-fixture','Fan','fan@example.test',array['user-read-email','user-read-private']);
    raise exception 'Replay accepted';
  exception when others then
    if sqlerrm <> 'Invalid connection session' then raise; end if;
  end;
  if has_table_privilege('anon','public.site_fans','select') then raise exception 'Anonymous fan access'; end if;
  if has_function_privilege('authenticated','public.complete_site_fan_connection(text,text,text,text,text[])','execute') then raise exception 'Direct completion allowed'; end if;
end $$;
rollback;
