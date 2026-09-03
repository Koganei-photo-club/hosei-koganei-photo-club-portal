-- 配置案の複製・確認・承認を、途中状態を残さずトランザクション内で処理する。

create or replace function public.admin_clone_exhibition_layout(p_layout_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, auth
as $$
declare
  source_layout public.exhibition_layouts%rowtype;
  cloned_layout public.exhibition_layouts%rowtype;
  next_version integer;
  copied_count integer;
begin
  if not private.is_admin() then
    raise exception '管理者権限がありません。';
  end if;

  select * into source_layout
  from public.exhibition_layouts
  where id = p_layout_id
  for share;
  if source_layout.id is null then
    raise exception '複製元の配置案が見つかりません。';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(source_layout.event_id::text || ':' || source_layout.name, 0));
  select coalesce(max(version_no), 0) + 1 into next_version
  from public.exhibition_layouts
  where event_id = source_layout.event_id and name = source_layout.name;

  insert into public.exhibition_layouts (
    event_id, name, version_no, status, is_current, created_by, notes
  ) values (
    source_layout.event_id,
    source_layout.name,
    next_version,
    'draft',
    false,
    coalesce(auth.jwt()->>'email', ''),
    source_layout.notes
  ) returning * into cloned_layout;

  insert into public.exhibition_placements (
    layout_id, work_id, wall_id, x_mm, top_from_floor_mm,
    z_order, locked, status, notes
  )
  select
    cloned_layout.id, work_id, wall_id, x_mm, top_from_floor_mm,
    z_order, false, status, notes
  from public.exhibition_placements
  where layout_id = source_layout.id and status <> 'removed';
  get diagnostics copied_count = row_count;

  return jsonb_build_object(
    'layoutId', cloned_layout.id,
    'name', cloned_layout.name,
    'versionNo', cloned_layout.version_no,
    'copiedPlacements', copied_count
  );
end;
$$;

create or replace function public.admin_set_exhibition_layout_status(
  p_layout_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  target_layout public.exhibition_layouts%rowtype;
begin
  if not private.is_admin() then
    raise exception '管理者権限がありません。';
  end if;
  if p_status not in ('draft', 'review', 'approved', 'archived') then
    raise exception '配置案の状態が不正です。';
  end if;

  select * into target_layout
  from public.exhibition_layouts
  where id = p_layout_id
  for update;
  if target_layout.id is null then
    raise exception '配置案が見つかりません。';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(target_layout.event_id::text, 0));
  if p_status = 'approved' then
    update public.exhibition_layouts
    set is_current = false
    where event_id = target_layout.event_id and is_current;
    update public.exhibition_layouts
    set status = 'approved', is_current = true
    where id = p_layout_id
    returning * into target_layout;
  else
    update public.exhibition_layouts
    set status = p_status, is_current = false
    where id = p_layout_id
    returning * into target_layout;
  end if;

  return jsonb_build_object(
    'layoutId', target_layout.id,
    'status', target_layout.status,
    'isCurrent', target_layout.is_current,
    'updatedAt', target_layout.updated_at
  );
end;
$$;

revoke all on function public.admin_clone_exhibition_layout(uuid) from public;
revoke all on function public.admin_set_exhibition_layout_status(uuid, text) from public;
grant execute on function public.admin_clone_exhibition_layout(uuid) to authenticated;
grant execute on function public.admin_set_exhibition_layout_status(uuid, text) to authenticated;
