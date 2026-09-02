alter table public.event_responses
  add column if not exists payment_updated_at timestamptz,
  add column if not exists payment_updated_by text not null default '';

create or replace function public.set_event_payment_status(
  p_response_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  target_response public.event_responses%rowtype;
  target_event public.events%rowtype;
begin
  if not private.is_admin() then
    raise exception '管理者権限がありません。';
  end if;
  if p_status not in ('unpaid', 'paid', 'cancelled') then
    raise exception '支払い状態が不正です。';
  end if;

  select * into target_response from public.event_responses where id = p_response_id;
  if target_response.id is null then raise exception '回答が見つかりません。'; end if;
  select * into target_event from public.events where id = target_response.event_id;
  if target_response.attendance <> '参加' or not target_event.fee_enabled or target_event.fee <= 0 then
    raise exception 'この回答は支払い管理の対象ではありません。';
  end if;

  update public.event_responses
  set payment_status = p_status,
      cancelled_at = case when p_status = 'cancelled' then coalesce(cancelled_at, now()) else null end,
      payment_updated_at = now(),
      payment_updated_by = private.current_email()
  where id = p_response_id
  returning * into target_response;

  return jsonb_build_object(
    'responseId', target_response.id,
    'paymentStatus', target_response.payment_status,
    'cancelledAt', target_response.cancelled_at,
    'updatedAt', target_response.payment_updated_at,
    'updatedBy', target_response.payment_updated_by
  );
end;
$$;

revoke all on function public.set_event_payment_status(uuid,text) from public;
grant execute on function public.set_event_payment_status(uuid,text) to authenticated;

create or replace function public.apply_overdue_payment_cancellations()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  affected integer;
begin
  if private.current_email() = '' then
    raise exception 'ログインが必要です。';
  end if;

  update public.event_responses as response
  set payment_status = 'cancelled',
      cancelled_at = coalesce(response.cancelled_at, now()),
      payment_updated_at = now(),
      payment_updated_by = 'system:payment-deadline'
  from public.events as event
  where event.id = response.event_id
    and event.payment_deadline_enabled
    and event.payment_deadline is not null
    and event.payment_deadline < now()
    and response.attendance = '参加'
    and response.payment_status = 'unpaid'
    and response.cancelled_at is null;
  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function public.apply_overdue_payment_cancellations() from public;
grant execute on function public.apply_overdue_payment_cancellations() to authenticated;
