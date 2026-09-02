create extension if not exists pgcrypto;
create schema if not exists private;

create table public.admins (
  email text primary key check (email = lower(trim(email))),
  name text not null,
  role_name text not null default '幹部',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  member_no text not null unique check (member_no ~ '^member-[0-9]{4,}$'),
  email text not null unique check (email = lower(trim(email))),
  name text not null,
  faculty text not null default '',
  grade text not null default '',
  department text not null default '',
  graduate_school text not null default '',
  major text not null default '',
  gender text not null default '',
  line_name text not null default '',
  previous_member text not null default '',
  joined_at timestamptz not null default now(),
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.membership_years (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members(id) on delete restrict,
  fiscal_year integer not null check (fiscal_year between 2000 and 2200),
  joined_at timestamptz not null default now(),
  fee_amount integer not null default 0 check (fee_amount >= 0),
  receipt_id uuid,
  active boolean not null default true,
  unique(member_id, fiscal_year)
);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members(id) on delete restrict,
  issued_at timestamptz not null default now(),
  issued_by text not null,
  amount integer not null check (amount >= 0),
  description text not null,
  fiscal_year integer not null
);

alter table public.membership_years
  add constraint membership_years_receipt_fk foreign key (receipt_id) references public.receipts(id) on delete set null;

create type public.event_genre as enum ('meeting', 'camp', 'exhibition');
create type public.event_status as enum ('draft', 'saved');

create table public.events (
  id uuid primary key default gen_random_uuid(),
  status public.event_status not null default 'draft',
  published boolean not null default false,
  genre public.event_genre not null,
  subtype text not null default '',
  title text not null,
  exhibition_title text not null default '',
  starts_at timestamptz,
  ends_at timestamptz,
  place text not null default '',
  contact text not null default '',
  details text not null default '',
  fee integer not null default 0 check (fee >= 0),
  payment_deadline timestamptz,
  max_works integer not null default 0,
  camera_enabled boolean not null default false,
  disposable_enabled boolean not null default false,
  shift_slots jsonb not null default '[]'::jsonb,
  min_shift_people integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text not null default '',
  deleted_at timestamptz
);

create table public.event_responses (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  submitted_at timestamptz not null default now(),
  line_name text not null default '',
  attendance text not null check (attendance in ('参加','不参加')),
  camera boolean not null default false,
  disposable_camera boolean not null default false,
  allergies text not null default '',
  other_allergy text not null default '',
  note text not null default '',
  agreement boolean not null default false,
  payment_status text not null default 'not_required' check (payment_status in ('not_required','unpaid','paid','cancelled')),
  cancelled_at timestamptz,
  unique(event_id, member_id)
);

create table public.archive_exhibitions (
  id uuid primary key default gen_random_uuid(),
  exhibition_key text not null unique,
  title text not null,
  response_count integer not null default 0,
  published boolean not null default false,
  imported_at timestamptz not null default now()
);

create table public.archive_works (
  id uuid primary key default gen_random_uuid(),
  legacy_work_uuid text unique,
  exhibition_id uuid not null references public.archive_exhibitions(id) on delete cascade,
  owner_member_id uuid not null references public.members(id) on delete restrict,
  display_no text not null default '',
  title text not null default '',
  image_path text,
  image_visible boolean not null default false,
  published boolean not null default true,
  favorite_count integer not null default 0,
  response_count integer not null default 0,
  favorite_rate numeric(6,2) not null default 0,
  imported_at timestamptz not null default now()
);

create table public.archive_work_comments (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.archive_works(id) on delete cascade,
  comment text not null,
  imported_at timestamptz not null default now()
);

create table public.archive_overall_comments (
  id uuid primary key default gen_random_uuid(),
  exhibition_id uuid not null references public.archive_exhibitions(id) on delete cascade,
  comment text not null,
  submitted_at timestamptz,
  imported_at timestamptz not null default now()
);

create table public.exhibition_shifts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete restrict,
  slot_id text not null,
  slot_label text not null,
  status text not null default 'confirmed',
  unique(event_id, member_id, slot_id)
);

create or replace function private.current_email()
returns text language sql stable set search_path = '' as $$
  select lower(coalesce(auth.jwt()->>'email',''))
$$;

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.admins a where a.email=private.current_email() and a.active)
$$;

create or replace function private.current_member_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.members m where m.email=private.current_email() and m.active limit 1
$$;

create or replace function private.current_fiscal_year()
returns integer language sql stable set search_path = '' as $$
  select extract(year from (now() at time zone 'Asia/Tokyo'))::integer
    - case when extract(month from (now() at time zone 'Asia/Tokyo')) < 4 then 1 else 0 end
$$;

create or replace function private.is_current_member()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.membership_years y
    where y.member_id=private.current_member_id()
      and y.fiscal_year=private.current_fiscal_year() and y.active
  )
$$;

-- 写真展関連のRLSから別のRLS対象テーブルを直接参照すると、
-- archive_exhibitions <-> archive_works の循環評価になるため、判定を分離する。
create or replace function private.current_member_has_published_work(target_exhibition_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.archive_works w
    where w.exhibition_id=target_exhibition_id
      and w.owner_member_id=private.current_member_id()
      and w.published
  )
$$;

create or replace function private.is_published_exhibition(target_exhibition_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.archive_exhibitions e
    where e.id=target_exhibition_id and e.published
  )
$$;

create or replace function private.current_member_owns_published_work(target_work_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1
    from public.archive_works w
    join public.archive_exhibitions e on e.id=w.exhibition_id
    where w.id=target_work_id
      and w.owner_member_id=private.current_member_id()
      and w.published and e.published
  )
$$;

create or replace function private.current_member_can_view_preview(target_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1
    from public.archive_works w
    join public.archive_exhibitions e on e.id=w.exhibition_id
    where w.image_path=target_path
      and w.owner_member_id=private.current_member_id()
      and w.image_visible and w.published and e.published
  )
$$;

create or replace function private.validate_event_response()
returns trigger language plpgsql security definer set search_path = '' as $$
declare target public.events%rowtype;
begin
  if new.member_id <> private.current_member_id() and not private.is_admin() then
    raise exception '本人以外の回答は登録できません。';
  end if;
  select * into target from public.events where id=new.event_id;
  if target.id is null or target.deleted_at is not null or not target.published or target.status <> 'saved' then
    raise exception 'この予定は現在受付していません。';
  end if;
  if new.attendance='不参加' then
    new.camera=false;new.disposable_camera=false;new.allergies='';new.other_allergy='';new.agreement=false;new.payment_status='not_required';
    return new;
  end if;
  if target.genre='camp' and not new.agreement then raise exception '合宿の参加条件への同意が必要です。'; end if;
  if (target.genre='camp' or target.subtype='dining') and trim(new.allergies)='' then raise exception 'アレルギー情報を入力してください。'; end if;
  if new.camera then
    if not target.camera_enabled then raise exception '貸出カメラは受け付けていません。'; end if;
    if (select count(*) from public.event_responses r where r.event_id=new.event_id and r.camera and r.cancelled_at is null) >= 3 then raise exception '貸出カメラは上限3台に達しました。'; end if;
  end if;
  if new.disposable_camera and not target.disposable_enabled then raise exception '写るんですは受け付けていません。'; end if;
  new.payment_status=case when target.fee>0 then 'unpaid' else 'not_required' end;
  return new;
end;
$$;

create trigger validate_event_response_before_insert
before insert on public.event_responses for each row execute function private.validate_event_response();

revoke all on schema private from public;
grant usage on schema private to authenticated;
revoke execute on all functions in schema private from public;
grant execute on all functions in schema private to authenticated;

alter table public.admins enable row level security;
alter table public.members enable row level security;
alter table public.membership_years enable row level security;
alter table public.receipts enable row level security;
alter table public.events enable row level security;
alter table public.event_responses enable row level security;
alter table public.archive_exhibitions enable row level security;
alter table public.archive_works enable row level security;
alter table public.archive_work_comments enable row level security;
alter table public.archive_overall_comments enable row level security;
alter table public.exhibition_shifts enable row level security;

revoke all on all tables in schema public from anon;
grant select,insert,update,delete on all tables in schema public to authenticated;

create policy admins_self_or_admin_select on public.admins for select to authenticated
  using (email=private.current_email() or private.is_admin());
create policy admins_admin_write on public.admins for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy members_self_or_admin_select on public.members for select to authenticated
  using (id=private.current_member_id() or private.is_admin());
create policy members_admin_write on public.members for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy membership_self_or_admin_select on public.membership_years for select to authenticated
  using (member_id=private.current_member_id() or private.is_admin());
create policy membership_admin_write on public.membership_years for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy receipts_admin_all on public.receipts for all to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy receipts_self_select on public.receipts for select to authenticated
  using (member_id=private.current_member_id());

create policy events_member_select on public.events for select to authenticated
  using (private.is_admin() or (private.is_current_member() and published and status='saved' and deleted_at is null));
create policy events_admin_write on public.events for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy responses_self_select on public.event_responses for select to authenticated
  using (member_id=private.current_member_id() or private.is_admin());
create policy responses_self_insert on public.event_responses for insert to authenticated
  with check (member_id=private.current_member_id() and private.is_current_member());
create policy responses_admin_update on public.event_responses for update to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy responses_admin_delete on public.event_responses for delete to authenticated
  using (private.is_admin());

create policy archive_exhibitions_owner_or_admin_select on public.archive_exhibitions for select to authenticated
  using (private.is_admin() or (published and private.current_member_has_published_work(id)));
create policy archive_exhibitions_admin_write on public.archive_exhibitions for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy archive_works_owner_or_admin_select on public.archive_works for select to authenticated
  using (private.is_admin() or (owner_member_id=private.current_member_id() and published and private.is_published_exhibition(exhibition_id)));
create policy archive_works_admin_write on public.archive_works for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy archive_comments_owner_or_admin_select on public.archive_work_comments for select to authenticated
  using (private.is_admin() or private.current_member_owns_published_work(work_id));
create policy archive_comments_admin_write on public.archive_work_comments for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy archive_overall_admin_all on public.archive_overall_comments for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create policy shifts_self_or_admin_select on public.exhibition_shifts for select to authenticated
  using (member_id=private.current_member_id() or private.is_admin());
create policy shifts_admin_write on public.exhibition_shifts for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

create index events_public_order_idx on public.events(published,status,starts_at);
create index responses_member_idx on public.event_responses(member_id,event_id);
create index archive_works_owner_idx on public.archive_works(owner_member_id,exhibition_id);
create index archive_comments_work_idx on public.archive_work_comments(work_id);

insert into storage.buckets(id,name,public) values('exhibition-previews','exhibition-previews',false)
on conflict(id) do nothing;

create policy preview_owner_or_admin_select on storage.objects for select to authenticated
using (
  bucket_id='exhibition-previews' and (
    private.is_admin() or private.current_member_can_view_preview(name)
  )
);
create policy preview_admin_write on storage.objects for all to authenticated
using (bucket_id='exhibition-previews' and private.is_admin())
with check (bucket_id='exhibition-previews' and private.is_admin());

-- 初回管理者を、実際の幹部メールへ置き換えてからSQL Editorで実行する。
-- insert into public.admins(email,name,role_name,active)
-- values('YOUR-ADMIN-EMAIL@example.com','初期管理者','管理者',true);
