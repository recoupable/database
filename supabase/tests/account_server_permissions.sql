begin;
do $$
declare table_name text; operation text;
begin
  foreach table_name in array array['accounts', 'credits_usage'] loop
    foreach operation in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
      if not has_table_privilege('service_role', 'public.' || table_name, operation) then
        raise exception 'Missing server permission: % on %', operation, table_name;
      end if;
    end loop;
  end loop;
end;
$$;
rollback;
