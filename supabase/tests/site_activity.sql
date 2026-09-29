begin;
insert into public.accounts(id) values('11111111-1111-4111-8111-111111111111');
insert into public.sites(id,owner_id,artist_id,created_by,name) values('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','Activity fixture');
insert into public.site_activity_events(id,site_id,visit_id,event) values
('33333333-3333-4333-8333-333333333333','22222222-2222-4222-8222-222222222222','44444444-4444-4444-8444-444444444444','visit'),
('55555555-5555-4555-8555-555555555555','22222222-2222-4222-8222-222222222222','44444444-4444-4444-8444-444444444444','complete');
do $$ declare report jsonb; begin
 report:=public.site_activity_summary('22222222-2222-4222-8222-222222222222');
 if report->>'visits'<>'1' or report->>'completions'<>'1' then raise exception 'Incorrect activity summary'; end if;
 if public.take_site_request('fixture',1) is not true then raise exception 'First request denied'; end if;
 if public.take_site_request('fixture',1) is not false then raise exception 'Exceeded request accepted'; end if;
 if has_table_privilege('anon','public.site_activity_events','select') then raise exception 'Anonymous activity access'; end if;
 if has_function_privilege('authenticated','public.site_activity_summary(uuid)','execute') then raise exception 'Client can bypass owner check'; end if;
end $$;
rollback;
