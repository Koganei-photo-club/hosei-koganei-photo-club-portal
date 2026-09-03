-- 写真展サイトへの作品掲載可否を作品単位で管理する。
-- 既存作品は本人の意思を推測せず、未回答（null）のまま保持する。
alter table public.exhibition_works
  add column if not exists publication_consent boolean;

comment on column public.exhibition_works.publication_consent is
  '写真展サイトへの作品画像掲載に同意=true、不同意=false、未回答=null';

create or replace function private.validate_exhibition_publication_consent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('submitted', 'accepted')
     and new.publication_consent is null then
    raise exception '写真展サイトへの作品掲載について、同意または不同意を選択してください。';
  end if;
  return new;
end;
$$;

revoke execute on function private.validate_exhibition_publication_consent() from public;

drop trigger if exists zzzzzz_exhibition_works_validate_publication_consent_before_write
  on public.exhibition_works;
create trigger zzzzzz_exhibition_works_validate_publication_consent_before_write
before insert or update on public.exhibition_works
for each row execute function private.validate_exhibition_publication_consent();
