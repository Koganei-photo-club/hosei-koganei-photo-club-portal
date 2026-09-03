-- 作品番号を写真展ごとの固定枠として扱い、取り下げ済みの枠は再利用可能にする。
alter table public.exhibition_works
  drop constraint if exists exhibition_works_entry_id_sort_order_key;

create unique index if not exists exhibition_works_active_slot_unique
  on public.exhibition_works(entry_id, sort_order)
  where status <> 'withdrawn';
