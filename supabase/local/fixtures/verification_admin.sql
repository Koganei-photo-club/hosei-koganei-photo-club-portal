-- Local-only Admin used by Phase 1-3 verification SQL.
insert into public.admins(email,name,role_name,active)
values('local.phase123.admin@example.invalid','Local Phase 1-3 Admin','検証管理者',true)
on conflict (email) do update set active=true;

