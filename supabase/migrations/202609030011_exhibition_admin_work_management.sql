-- 幹部による作品番号・確認状態の更新と、安全な連番付与を提供する。

create or replace function public.admin_update_exhibition_work(
  p_work_id uuid,
  p_display_no text,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  target_work public.exhibition_works%rowtype;
  normalized_display_no text := trim(coalesce(p_display_no, ''));
begin
  if not private.is_admin() then
    raise exception '管理者権限がありません。';
  end if;
  if p_status not in ('submitted', 'accepted', 'rejected') then
    raise exception '作品の確認状態が不正です。';
  end if;

  select * into target_work
  from public.exhibition_works
  where id = p_work_id;
  if target_work.id is null then
    raise exception '作品が見つかりません。';
  end if;
  if target_work.status = 'withdrawn' then
    raise exception '取り下げ済み作品は更新できません。';
  end if;

  update public.exhibition_works
  set display_no = normalized_display_no,
      status = p_status
  where id = p_work_id
  returning * into target_work;

  return jsonb_build_object(
    'workId', target_work.id,
    'displayNo', target_work.display_no,
    'status', target_work.status,
    'updatedAt', target_work.updated_at
  );
end;
$$;

create or replace function public.admin_assign_exhibition_display_numbers(
  p_event_id uuid,
  p_start integer default 1,
  p_padding integer default 2
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  target_event public.events%rowtype;
  target_work record;
  candidate integer := p_start;
  candidate_text text;
  assigned integer := 0;
begin
  if not private.is_admin() then
    raise exception '管理者権限がありません。';
  end if;
  if p_start < 0 or p_padding < 1 or p_padding > 8 then
    raise exception '連番の開始番号または桁数が不正です。';
  end if;

  select * into target_event
  from public.events
  where id = p_event_id and genre = 'exhibition';
  if target_event.id is null then
    raise exception '写真展が見つかりません。';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));

  for target_work in
    select work.id
    from public.exhibition_works work
    join public.exhibition_entries entry on entry.id = work.entry_id
    where work.event_id = p_event_id
      and work.status <> 'withdrawn'
      and trim(work.display_no) = ''
    order by entry.created_at, work.sort_order, work.created_at
  loop
    loop
      candidate_text := lpad(candidate::text, p_padding, '0');
      exit when not exists (
        select 1
        from public.exhibition_works existing
        where existing.event_id = p_event_id
          and existing.display_no = candidate_text
      );
      candidate := candidate + 1;
    end loop;

    update public.exhibition_works
    set display_no = candidate_text
    where id = target_work.id;

    assigned := assigned + 1;
    candidate := candidate + 1;
  end loop;

  return jsonb_build_object(
    'eventId', p_event_id,
    'assignedCount', assigned,
    'nextNumber', candidate
  );
end;
$$;

revoke all on function public.admin_update_exhibition_work(uuid, text, text) from public;
revoke all on function public.admin_assign_exhibition_display_numbers(uuid, integer, integer) from public;

grant execute on function public.admin_update_exhibition_work(uuid, text, text) to authenticated;
grant execute on function public.admin_assign_exhibition_display_numbers(uuid, integer, integer) to authenticated;

