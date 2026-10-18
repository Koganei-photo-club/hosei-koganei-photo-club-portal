begin;

do $$
declare
  function_config text[];
begin
  if to_regprocedure('public.get_my_exhibition_history_v1()') is null then
    raise exception 'member exhibition history RPC is missing';
  end if;
  select proconfig into function_config from pg_proc where oid='public.get_my_exhibition_history_v1()'::regprocedure;
  if not exists(select 1 from unnest(coalesce(function_config,'{}'::text[])) setting where setting in ('search_path=', 'search_path=""')) then
    raise exception 'member exhibition history RPC search_path is not locked';
  end if;
  if has_function_privilege('anon','public.get_my_exhibition_history_v1()','execute') then
    raise exception 'anon must not execute member exhibition history RPC';
  end if;
  if not has_function_privilege('authenticated','public.get_my_exhibition_history_v1()','execute') then
    raise exception 'authenticated must execute member exhibition history RPC';
  end if;
end;
$$;

rollback;
