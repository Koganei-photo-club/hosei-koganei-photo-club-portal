-- Storage の upsert は、insert/update に加えて既存オブジェクトの select 権限も必要。
-- 一般公開バケットの読み取り方式は変更せず、管理画面からのDM差し替えを許可する。

drop policy if exists exhibition_public_admin_select on storage.objects;
create policy exhibition_public_admin_select
on storage.objects for select to authenticated
using (bucket_id = 'exhibition-public' and private.is_admin());

select exists (
  select 1
  from pg_policies
  where schemaname = 'storage'
    and tablename = 'objects'
    and policyname = 'exhibition_public_admin_select'
) as public_storage_admin_select_ready;
