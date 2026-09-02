create or replace function public.issue_membership_receipt(
  p_email text,
  p_name text,
  p_faculty text,
  p_grade text,
  p_department text,
  p_graduate_school text,
  p_major text,
  p_gender text,
  p_line_name text,
  p_previous_member text,
  p_fiscal_year integer,
  p_amount integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  normalized_email text := lower(trim(coalesce(p_email, '')));
  target_member public.members%rowtype;
  new_receipt public.receipts%rowtype;
  next_number integer;
  graduate_student boolean := upper(trim(coalesce(p_grade, ''))) like 'M%'
    or trim(coalesce(p_grade, '')) like '修士%'
    or trim(coalesce(p_grade, '')) like '博士%';
begin
  if not private.is_admin() then
    raise exception '管理者権限がありません。';
  end if;
  if normalized_email = '' or normalized_email not like '%@stu.hosei.ac.jp' then
    raise exception '大学メールアドレスを確認してください。';
  end if;
  if trim(coalesce(p_name, '')) = '' or trim(coalesce(p_grade, '')) = '' or trim(coalesce(p_line_name, '')) = '' then
    raise exception '氏名、学年、LINEの名前は必須です。';
  end if;
  if graduate_student and (trim(coalesce(p_graduate_school, '')) = '' or trim(coalesce(p_major, '')) = '') then
    raise exception '院生は研究科と専攻が必須です。';
  end if;
  if not graduate_student and (trim(coalesce(p_faculty, '')) = '' or trim(coalesce(p_department, '')) = '') then
    raise exception '学部生は学部と学科が必須です。';
  end if;
  if p_fiscal_year not between 2000 and 2200 or p_amount < 0 then
    raise exception '年度または金額を確認してください。';
  end if;

  perform pg_advisory_xact_lock(20260903);
  select * into target_member from public.members where email = normalized_email;

  if target_member.id is not null and exists (
    select 1 from public.membership_years
    where member_id = target_member.id and fiscal_year = p_fiscal_year
  ) then
    raise exception '%年度の在籍登録は完了しています。', p_fiscal_year;
  end if;

  if target_member.id is null then
    select coalesce(max(substring(member_no from '[0-9]+$')::integer), 0) + 1
      into next_number from public.members;
    insert into public.members (
      member_no, email, name, faculty, grade, department, graduate_school,
      major, gender, line_name, previous_member, active
    ) values (
      'member-' || lpad(next_number::text, 4, '0'), normalized_email, trim(p_name),
      trim(coalesce(p_faculty, '')), trim(p_grade), trim(coalesce(p_department, '')),
      trim(coalesce(p_graduate_school, '')), trim(coalesce(p_major, '')),
      trim(coalesce(p_gender, '')), trim(p_line_name), trim(coalesce(p_previous_member, '')), true
    ) returning * into target_member;
  else
    update public.members set
      name = trim(p_name), faculty = trim(coalesce(p_faculty, '')), grade = trim(p_grade),
      department = trim(coalesce(p_department, '')), graduate_school = trim(coalesce(p_graduate_school, '')),
      major = trim(coalesce(p_major, '')), gender = trim(coalesce(p_gender, '')),
      line_name = trim(p_line_name), previous_member = trim(coalesce(p_previous_member, '')),
      active = true, updated_at = now()
    where id = target_member.id returning * into target_member;
  end if;

  insert into public.receipts (member_id, issued_by, amount, description, fiscal_year)
  values (target_member.id, private.current_email(), p_amount, p_fiscal_year || '年度部費として', p_fiscal_year)
  returning * into new_receipt;

  insert into public.membership_years (member_id, fiscal_year, fee_amount, receipt_id, active)
  values (target_member.id, p_fiscal_year, p_amount, new_receipt.id, true);

  return jsonb_build_object(
    'memberId', target_member.member_no,
    'receiptId', new_receipt.id,
    'description', new_receipt.description,
    'issuedAt', new_receipt.issued_at
  );
end;
$$;

revoke all on function public.issue_membership_receipt(text,text,text,text,text,text,text,text,text,text,integer,integer) from public;
grant execute on function public.issue_membership_receipt(text,text,text,text,text,text,text,text,text,text,integer,integer) to authenticated;
