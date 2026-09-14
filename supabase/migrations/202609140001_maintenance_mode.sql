-- ポータルのメンテナンスモード基盤。

create type public.maintenance_status as enum ('scheduled', 'in_progress', 'completed');

create table public.maintenance_admins (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check (email = lower(trim(email))),
  name text not null check (length(trim(name)) between 1 and 100),
  role_name text not null default 'メンテナンス管理者',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.maintenances (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 50 and title !~ E'[\\n\\r]'),
  status public.maintenance_status not null default 'scheduled',
  enabled boolean not null default false,
  scheduled_start_at timestamptz not null,
  scheduled_end_at timestamptz,
  started_at timestamptz,
  ended_at timestamptz,
  started_at_is_estimated boolean not null default false,
  ended_at_is_estimated boolean not null default false,
  started_at_is_unknown boolean not null default false,
  ended_at_is_unknown boolean not null default false,
  message text not null check (length(trim(message)) between 1 and 100),
  contact text not null check (length(trim(contact)) between 1 and 30 and contact !~ E'[\\n\\r]'),
  description text not null check (length(trim(description)) between 1 and 500),
  created_by text not null references public.maintenance_admins(email) on update cascade on delete restrict,
  updated_by text not null references public.maintenance_admins(email) on update cascade on delete restrict,
  started_by text references public.maintenance_admins(email) on update cascade on delete restrict,
  ended_by text references public.maintenance_admins(email) on update cascade on delete restrict,
  client_request_id uuid not null unique,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint maintenance_schedule_order check (
    scheduled_end_at is null or scheduled_end_at > scheduled_start_at
  ),
  constraint maintenance_actual_order check (
    started_at is null or ended_at is null or ended_at >= started_at
  ),
  constraint maintenance_state_shape check (
    (status = 'scheduled' and not enabled and started_at is null and ended_at is null
      and started_by is null and ended_by is null)
    or (status = 'in_progress' and enabled and ended_at is null and ended_by is null)
    or (status = 'completed' and not enabled)
  )
);

create unique index maintenance_only_one_in_progress
  on public.maintenances ((true)) where status = 'in_progress';
create index maintenances_schedule_idx on public.maintenances(scheduled_start_at, display_order, created_at);
create index maintenances_history_idx on public.maintenances(ended_at desc nulls last, updated_at desc);

create table public.maintenance_edit_locks (
  maintenance_id uuid primary key references public.maintenances(id) on delete cascade,
  owner_email text not null references public.maintenance_admins(email) on update cascade on delete cascade,
  acquired_at timestamptz not null default now(),
  heartbeat_at timestamptz not null default now()
);

create table public.maintenance_operation_logs (
  id uuid primary key default gen_random_uuid(),
  maintenance_id uuid,
  operation_type text not null check (operation_type in ('repair', 'emergency_end')),
  performed_by text not null references public.maintenance_admins(email) on update cascade on delete restrict,
  performed_at timestamptz not null default now(),
  reason text not null check (length(trim(reason)) between 1 and 500),
  before_state jsonb not null,
  after_state jsonb not null
);

create table public.maintenance_order_snapshots (
  id bigint generated always as identity primary key,
  scheduled_start_at timestamptz not null,
  ordered_ids uuid[] not null,
  saved_by text not null references public.maintenance_admins(email) on update cascade on delete restrict,
  saved_at timestamptz not null default now()
);

create or replace function private.is_maintenance_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.maintenance_admins a
    where a.email = private.current_email() and a.active
  )
$$;

create or replace function private.require_maintenance_admin()
returns text language plpgsql stable security definer set search_path = '' as $$
declare actor text := private.current_email();
begin
  if not private.is_maintenance_admin() then
    raise exception 'メンテナンス管理者権限がありません。';
  end if;
  return actor;
end;
$$;

create or replace function private.clear_invalid_maintenance_locks()
returns void language sql security definer set search_path = '' as $$
  delete from public.maintenance_edit_locks l
  where l.heartbeat_at < now() - interval '10 minutes'
     or not exists (
       select 1 from public.maintenance_admins a
       where a.email = l.owner_email and a.active
     )
     or exists (
       select 1 from public.maintenances m
       where m.id = l.maintenance_id and m.status = 'completed'
     )
$$;

create or replace function private.maintenance_public_state()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare active_count integer; bad_count integer; active_row public.maintenances%rowtype;
begin
  select count(*) into active_count from public.maintenances where status = 'in_progress';
  select count(*) into bad_count from public.maintenances
  where enabled <> (status = 'in_progress')
     or (status = 'scheduled' and (started_at is not null or ended_at is not null or started_by is not null or ended_by is not null))
     or (status = 'in_progress' and ended_at is not null)
     or (status in ('in_progress','completed') and (
       (started_at is null and not started_at_is_unknown)
       or (started_at is not null and started_by is null)
     ))
     or (status = 'completed' and (
       (ended_at is null and not ended_at_is_unknown)
       or (ended_at is not null and ended_by is null)
     ));
  if active_count > 1 or bad_count > 0 then
    return jsonb_build_object('state', 'maintenance_state_error');
  end if;
  if active_count = 1 then
    select * into active_row from public.maintenances where status = 'in_progress';
    return jsonb_build_object(
      'state', 'maintenance', 'maintenance', jsonb_build_object(
        'title', active_row.title, 'started_at', active_row.started_at,
        'scheduled_end_at', active_row.scheduled_end_at,
        'message', active_row.message, 'contact', active_row.contact
      )
    );
  end if;
  return jsonb_build_object('state', 'normal');
end;
$$;

create or replace function public.get_public_maintenance_info()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare state jsonb; schedules jsonb;
begin
  state := private.maintenance_public_state();
  select coalesce(jsonb_agg(item - 'display_order' order by item->>'scheduled_start_at', (item->>'display_order')::integer), '[]'::jsonb)
  into schedules
  from (
    select jsonb_build_object(
      'title', m.title, 'scheduled_start_at', m.scheduled_start_at,
      'scheduled_end_at', m.scheduled_end_at, 'message', m.message,
      'contact', m.contact, 'display_order', m.display_order
    ) item
    from public.maintenances m
    where m.status = 'scheduled' and m.scheduled_start_at between now() and now() + interval '1 month'
    order by m.scheduled_start_at, m.display_order, m.created_at limit 3
  ) q;
  return state || jsonb_build_object('scheduled', schedules);
end;
$$;

create or replace function public.get_maintenance_state()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception '認証が必要です。'; end if;
  return private.maintenance_public_state()
    || jsonb_build_object('isMaintenanceAdmin', private.is_maintenance_admin());
end;
$$;

create or replace function public.create_maintenance(
  p_client_request_id uuid, p_title text, p_scheduled_start_at timestamptz,
  p_scheduled_end_at timestamptz, p_message text, p_contact text, p_description text
) returns public.maintenances
language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); result public.maintenances;
begin
  select * into result from public.maintenances where client_request_id = p_client_request_id;
  if found then return result; end if;
  if p_scheduled_start_at <= now() then raise exception '開始予定は未来の日時にしてください。'; end if;
  if p_scheduled_end_at is not null and p_scheduled_end_at <= now() then
    raise exception '終了予定は未来の日時にしてください。';
  end if;
  insert into public.maintenances(
    title, scheduled_start_at, scheduled_end_at, message, contact, description,
    created_by, updated_by, client_request_id
  ) values (
    trim(p_title), p_scheduled_start_at, p_scheduled_end_at, trim(p_message),
    trim(p_contact), trim(p_description), actor, actor, p_client_request_id
  ) returning * into result;
  return result;
end;
$$;

create or replace function public.acquire_maintenance_lock(p_maintenance_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); existing public.maintenance_edit_locks%rowtype; owner_name text;
begin
  perform private.clear_invalid_maintenance_locks();
  if not exists(select 1 from public.maintenances where id=p_maintenance_id and status <> 'completed') then
    raise exception '編集できるメンテナンスが見つかりません。';
  end if;
  select * into existing from public.maintenance_edit_locks where maintenance_id=p_maintenance_id for update;
  if found and existing.owner_email <> actor then
    select name into owner_name from public.maintenance_admins where email=existing.owner_email;
    return jsonb_build_object('acquired', false, 'ownerEmail', existing.owner_email, 'ownerName', owner_name);
  end if;
  insert into public.maintenance_edit_locks(maintenance_id,owner_email)
  values(p_maintenance_id,actor)
  on conflict(maintenance_id) do update set heartbeat_at=now(), owner_email=excluded.owner_email;
  return jsonb_build_object('acquired', true, 'ownerEmail', actor);
end;
$$;

create or replace function public.heartbeat_maintenance_lock(p_maintenance_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); changed integer;
begin
  update public.maintenance_edit_locks set heartbeat_at=now()
  where maintenance_id=p_maintenance_id and owner_email=actor and heartbeat_at >= now()-interval '10 minutes';
  get diagnostics changed = row_count; return changed=1;
end;
$$;

create or replace function public.release_maintenance_lock(p_maintenance_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); changed integer;
begin
  delete from public.maintenance_edit_locks where maintenance_id=p_maintenance_id and owner_email=actor;
  get diagnostics changed = row_count; return changed=1;
end;
$$;

create or replace function public.update_maintenance(
  p_id uuid, p_expected_updated_at timestamptz, p_title text,
  p_scheduled_start_at timestamptz, p_scheduled_end_at timestamptz,
  p_message text, p_contact text, p_description text
) returns public.maintenances
language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); target public.maintenances%rowtype;
begin
  perform private.clear_invalid_maintenance_locks();
  select * into target from public.maintenances where id=p_id for update;
  if target.id is null or target.status='completed' then raise exception 'この履歴は編集できません。'; end if;
  if not exists(select 1 from public.maintenance_edit_locks where maintenance_id=p_id and owner_email=actor) then
    raise exception '編集ロックが失効しています。';
  end if;
  if target.updated_at <> p_expected_updated_at then raise exception '他の管理者による更新があります。再読み込みしてください。'; end if;
  if target.status='scheduled' and p_scheduled_start_at <> target.scheduled_start_at and p_scheduled_start_at <= now() then
    raise exception '変更後の開始予定は未来の日時にしてください。';
  end if;
  if p_scheduled_end_at is not null and p_scheduled_end_at <> target.scheduled_end_at and p_scheduled_end_at <= now() then
    raise exception '変更後の終了予定は未来の日時にしてください。';
  end if;
  update public.maintenances set
    title=case when status='scheduled' then trim(p_title) else title end,
    scheduled_start_at=case when status='scheduled' then p_scheduled_start_at else scheduled_start_at end,
    scheduled_end_at=p_scheduled_end_at,
    message=trim(p_message),
    contact=case when status='scheduled' then trim(p_contact) else contact end,
    description=trim(p_description), updated_by=actor, updated_at=now()
  where id=p_id returning * into target;
  delete from public.maintenance_edit_locks where maintenance_id=p_id;
  return target;
end;
$$;

create or replace function public.delete_maintenance(p_id uuid, p_expected_updated_at timestamptz)
returns boolean language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); target public.maintenances%rowtype;
begin
  perform private.clear_invalid_maintenance_locks();
  select * into target from public.maintenances where id=p_id for update;
  if target.id is null then return true; end if;
  if target.status <> 'scheduled' then raise exception '予定状態のメンテナンスだけ削除できます。'; end if;
  if target.updated_at <> p_expected_updated_at then raise exception '他の管理者による更新があります。'; end if;
  if exists(select 1 from public.maintenance_edit_locks where maintenance_id=p_id) then raise exception '編集中のため削除できません。'; end if;
  delete from public.maintenances where id=p_id; return true;
end;
$$;

create or replace function public.start_maintenance(p_id uuid)
returns public.maintenances language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); target public.maintenances%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended('portal-maintenance-lifecycle',0));
  perform private.clear_invalid_maintenance_locks();
  select * into target from public.maintenances where id=p_id for update;
  if target.status='in_progress' then return target; end if;
  if target.status <> 'scheduled' then raise exception '開始できる予定ではありません。'; end if;
  if exists(select 1 from public.maintenance_edit_locks where maintenance_id=p_id) then raise exception '編集中のため開始できません。'; end if;
  if exists(select 1 from public.maintenances where status='in_progress') then raise exception '別のメンテナンスが実施中です。'; end if;
  update public.maintenances set status='in_progress',enabled=true,started_at=now(),started_by=actor,
    updated_by=actor,updated_at=now() where id=p_id returning * into target;
  return target;
end;
$$;

create or replace function public.end_maintenance(p_id uuid)
returns public.maintenances language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); target public.maintenances%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended('portal-maintenance-lifecycle',0));
  perform private.clear_invalid_maintenance_locks();
  select * into target from public.maintenances where id=p_id for update;
  if target.status='completed' then return target; end if;
  if target.status <> 'in_progress' then raise exception '実施中のメンテナンスではありません。'; end if;
  if exists(select 1 from public.maintenance_edit_locks where maintenance_id=p_id) then raise exception '編集中のため終了できません。'; end if;
  update public.maintenances set status='completed',enabled=false,ended_at=now(),ended_by=actor,
    updated_by=actor,updated_at=now() where id=p_id returning * into target;
  return target;
end;
$$;

create or replace function public.emergency_end_maintenance(p_id uuid, p_reason text)
returns public.maintenances language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); target public.maintenances%rowtype; before_value jsonb;
begin
  if length(trim(p_reason)) < 1 then raise exception '緊急終了理由は必須です。'; end if;
  perform pg_advisory_xact_lock(hashtextextended('portal-maintenance-lifecycle',0));
  select * into target from public.maintenances where id=p_id for update;
  if target.status='completed' then return target; end if;
  if target.status <> 'in_progress' then raise exception '実施中のメンテナンスではありません。'; end if;
  before_value=to_jsonb(target);
  delete from public.maintenance_edit_locks where maintenance_id=p_id;
  update public.maintenances set status='completed',enabled=false,ended_at=now(),ended_by=actor,
    updated_by=actor,updated_at=now() where id=p_id returning * into target;
  insert into public.maintenance_operation_logs(maintenance_id,operation_type,performed_by,reason,before_state,after_state)
  values(p_id,'emergency_end',actor,trim(p_reason),before_value,to_jsonb(target));
  return target;
end;
$$;

create or replace function public.diagnose_maintenance_state()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); issues jsonb;
begin
  select coalesce(jsonb_agg(issue), '[]'::jsonb) into issues from (
    select jsonb_build_object('code','multiple_in_progress','message','実施中のメンテナンスが複数あります。','count',count(*)) issue
    from public.maintenances where status='in_progress' having count(*)>1
    union all
    select jsonb_build_object('code','state_mismatch','message','状態と有効フラグが一致しません。','maintenanceId',id)
    from public.maintenances where enabled <> (status='in_progress')
    union all
    select jsonb_build_object('code','missing_actual_start','message','実施中または完了済みですが開始記録が不足しています。','maintenanceId',id)
    from public.maintenances where status in ('in_progress','completed')
      and ((started_at is null and not started_at_is_unknown) or (started_at is not null and started_by is null))
    union all
    select jsonb_build_object('code','missing_actual_end','message','完了済みですが終了記録が不足しています。','maintenanceId',id)
    from public.maintenances where status='completed'
      and ((ended_at is null and not ended_at_is_unknown) or (ended_at is not null and ended_by is null))
  ) q;
  return jsonb_build_object('ok',jsonb_array_length(issues)=0,'issues',issues);
end;
$$;

create or replace function public.reorder_maintenance_group(
  p_scheduled_start_at timestamptz, p_ordered_ids uuid[]
) returns boolean language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); expected_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('maintenance-order-' || p_scheduled_start_at::text,0));
  select count(*) into expected_count from public.maintenances
  where status='scheduled' and scheduled_start_at=p_scheduled_start_at;
  if expected_count < 2 or cardinality(p_ordered_ids) <> expected_count
     or (select count(distinct value) from unnest(p_ordered_ids) value) <> expected_count
     or exists(
       select 1 from unnest(p_ordered_ids) value
       where not exists(select 1 from public.maintenances m where m.id=value and m.status='scheduled' and m.scheduled_start_at=p_scheduled_start_at)
     ) then raise exception '同じ開始日時の予定をすべて1回ずつ指定してください。'; end if;
  update public.maintenances m set display_order=ordered.ordinality::integer,
    updated_by=actor,updated_at=now()
  from unnest(p_ordered_ids) with ordinality ordered(id,ordinality)
  where m.id=ordered.id;
  insert into public.maintenance_order_snapshots(scheduled_start_at,ordered_ids,saved_by)
  values(p_scheduled_start_at,p_ordered_ids,actor);
  return true;
end;
$$;

create or replace function public.restore_maintenance_group_order(
  p_scheduled_start_at timestamptz, p_mode text
) returns boolean language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); ids uuid[];
begin
  if p_mode='last_snapshot' then
    select ordered_ids into ids from public.maintenance_order_snapshots
    where scheduled_start_at=p_scheduled_start_at order by saved_at desc limit 1;
  elsif p_mode='base' then
    select array_agg(id order by created_at,id) into ids from public.maintenances
    where status='scheduled' and scheduled_start_at=p_scheduled_start_at;
  else raise exception '未対応の復元方法です。'; end if;
  if ids is null then raise exception '復元できる表示順がありません。'; end if;
  perform public.reorder_maintenance_group(p_scheduled_start_at,ids);
  return true;
end;
$$;

create or replace function public.repair_maintenance(
  p_id uuid, p_action text, p_reason text,
  p_started_at timestamptz default null, p_started_by text default null, p_started_estimated boolean default false,
  p_started_unknown boolean default false,
  p_ended_at timestamptz default null, p_ended_by text default null, p_ended_estimated boolean default false,
  p_ended_unknown boolean default false
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor text := private.require_maintenance_admin(); target public.maintenances%rowtype; before_value jsonb; after_value jsonb;
begin
  if length(trim(p_reason)) < 1 then raise exception '修復理由は必須です。'; end if;
  select * into target from public.maintenances where id=p_id for update;
  if target.id is null then raise exception '対象が見つかりません。'; end if;
  before_value=to_jsonb(target);
  if p_started_at > now() or p_ended_at > now() or (p_started_at is not null and p_ended_at is not null and p_ended_at < p_started_at) then
    raise exception '実績日時に矛盾があります。';
  end if;
  delete from public.maintenance_edit_locks where maintenance_id=p_id;
  if p_action='scheduled' then
    update public.maintenances set status='scheduled',enabled=false,started_at=null,started_by=null,ended_at=null,ended_by=null,
      started_at_is_estimated=false,ended_at_is_estimated=false,started_at_is_unknown=false,ended_at_is_unknown=false,
      updated_by=actor,updated_at=now() where id=p_id;
  elsif p_action='in_progress' then
    if exists(select 1 from public.maintenances where status='in_progress' and id<>p_id) then raise exception '実施中として残せるのは1件だけです。'; end if;
    update public.maintenances set status='in_progress',enabled=true,started_at=p_started_at,started_by=p_started_by,
      started_at_is_estimated=p_started_estimated,started_at_is_unknown=p_started_unknown,
      ended_at=null,ended_by=null,ended_at_is_estimated=false,ended_at_is_unknown=false,
      updated_by=actor,updated_at=now() where id=p_id;
  elsif p_action='completed' then
    update public.maintenances set status='completed',enabled=false,started_at=p_started_at,started_by=p_started_by,
      started_at_is_estimated=p_started_estimated,ended_at=p_ended_at,ended_by=p_ended_by,
      ended_at_is_estimated=p_ended_estimated,started_at_is_unknown=p_started_unknown,
      ended_at_is_unknown=p_ended_unknown,updated_by=actor,updated_at=now() where id=p_id;
  elsif p_action='delete' then
    delete from public.maintenances where id=p_id;
  else raise exception '未対応の修復方法です。'; end if;
  select coalesce(to_jsonb(m),'null'::jsonb) into after_value from public.maintenances m where id=p_id;
  insert into public.maintenance_operation_logs(maintenance_id,operation_type,performed_by,reason,before_state,after_state)
  values(p_id,'repair',actor,trim(p_reason),before_value,coalesce(after_value,'null'::jsonb));
  return coalesce(after_value,'null'::jsonb);
end;
$$;

alter table public.maintenance_admins enable row level security;
alter table public.maintenances enable row level security;
alter table public.maintenance_edit_locks enable row level security;
alter table public.maintenance_operation_logs enable row level security;
alter table public.maintenance_order_snapshots enable row level security;

revoke all on public.maintenance_admins, public.maintenances, public.maintenance_edit_locks,
  public.maintenance_operation_logs, public.maintenance_order_snapshots from anon, authenticated;
grant select on public.maintenance_admins, public.maintenances, public.maintenance_edit_locks,
  public.maintenance_operation_logs, public.maintenance_order_snapshots to authenticated;

create policy maintenance_admins_self_or_maintenance_admin_select on public.maintenance_admins
for select to authenticated using(email=private.current_email() or private.is_maintenance_admin());
create policy maintenances_maintenance_admin_select on public.maintenances
for select to authenticated using(private.is_maintenance_admin());
create policy maintenance_locks_admin_select on public.maintenance_edit_locks
for select to authenticated using(private.is_maintenance_admin());
create policy maintenance_logs_admin_select on public.maintenance_operation_logs
for select to authenticated using(private.is_maintenance_admin());
create policy maintenance_order_snapshots_admin_select on public.maintenance_order_snapshots
for select to authenticated using(private.is_maintenance_admin());
create policy events_maintenance_admin_select on public.events
for select to authenticated using(private.is_maintenance_admin());

revoke all on function public.get_public_maintenance_info() from public;
grant execute on function public.get_public_maintenance_info() to anon, authenticated;
revoke execute on function public.get_maintenance_state() from public;
revoke execute on function public.create_maintenance(uuid,text,timestamptz,timestamptz,text,text,text) from public;
revoke execute on function public.acquire_maintenance_lock(uuid) from public;
revoke execute on function public.heartbeat_maintenance_lock(uuid) from public;
revoke execute on function public.release_maintenance_lock(uuid) from public;
revoke execute on function public.update_maintenance(uuid,timestamptz,text,timestamptz,timestamptz,text,text,text) from public;
revoke execute on function public.delete_maintenance(uuid,timestamptz) from public;
revoke execute on function public.start_maintenance(uuid) from public;
revoke execute on function public.end_maintenance(uuid) from public;
revoke execute on function public.emergency_end_maintenance(uuid,text) from public;
revoke execute on function public.diagnose_maintenance_state() from public;
revoke execute on function public.reorder_maintenance_group(timestamptz,uuid[]) from public;
revoke execute on function public.restore_maintenance_group_order(timestamptz,text) from public;
revoke execute on function public.repair_maintenance(uuid,text,text,timestamptz,text,boolean,boolean,timestamptz,text,boolean,boolean) from public;
grant execute on function public.get_maintenance_state() to authenticated;
grant execute on function public.create_maintenance(uuid,text,timestamptz,timestamptz,text,text,text) to authenticated;
grant execute on function public.acquire_maintenance_lock(uuid) to authenticated;
grant execute on function public.heartbeat_maintenance_lock(uuid) to authenticated;
grant execute on function public.release_maintenance_lock(uuid) to authenticated;
grant execute on function public.update_maintenance(uuid,timestamptz,text,timestamptz,timestamptz,text,text,text) to authenticated;
grant execute on function public.delete_maintenance(uuid,timestamptz) to authenticated;
grant execute on function public.start_maintenance(uuid) to authenticated;
grant execute on function public.end_maintenance(uuid) to authenticated;
grant execute on function public.emergency_end_maintenance(uuid,text) to authenticated;
grant execute on function public.diagnose_maintenance_state() to authenticated;
grant execute on function public.reorder_maintenance_group(timestamptz,uuid[]) to authenticated;
grant execute on function public.restore_maintenance_group_order(timestamptz,text) to authenticated;
grant execute on function public.repair_maintenance(uuid,text,text,timestamptz,text,boolean,boolean,timestamptz,text,boolean,boolean) to authenticated;

-- 初回メンテナンス管理者は、実際のメール・氏名へ置き換えて同時に実行する。
-- insert into public.maintenance_admins(email,name,role_name,active)
-- values('YOUR-EMAIL@example.com','氏名','メンテナンス管理者',true);

select
  to_regclass('public.maintenance_admins') is not null as maintenance_admins_ready,
  to_regclass('public.maintenances') is not null as maintenances_ready,
  to_regprocedure('public.get_public_maintenance_info()') is not null as public_state_ready,
  to_regprocedure('public.start_maintenance(uuid)') is not null as lifecycle_ready;
