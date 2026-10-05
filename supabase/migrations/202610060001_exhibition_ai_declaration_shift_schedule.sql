-- Workflow v2公開前追加: AI/大幅加工申告と、出展から独立した写真展シフト版管理。

alter table public.exhibition_caption_working_data
  add column ai_processing_declaration text
    check(ai_processing_declaration is null or ai_processing_declaration in ('none','declared')),
  add column ai_processing_details text not null default '' check(char_length(ai_processing_details)<=3000);
alter table public.exhibition_caption_submission_snapshots
  add column ai_processing_declaration text
    check(ai_processing_declaration is null or ai_processing_declaration in ('none','declared')),
  add column ai_processing_details text not null default '' check(char_length(ai_processing_details)<=3000);
alter table public.exhibition_export_items
  add column ai_processing_declaration text,
  add column ai_processing_details text not null default '';
alter table public.exhibition_archive_items
  add column ai_processing_declaration text,
  add column ai_processing_details text not null default '';

create or replace function private.validate_caption_v2_values(p_caption public.exhibition_caption_working_data)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if trim(p_caption.display_name)='' then raise exception '表示名を入力してください。'; end if;
  if p_caption.english_title_mode='self' and trim(p_caption.member_english_title)='' then raise exception '英語作品名を入力してください。'; end if;
  if p_caption.medium='' then raise exception '媒体を選択してください。'; end if;
  if p_caption.medium='other' and trim(p_caption.medium_details)='' then raise exception '媒体の詳細を入力してください。'; end if;
  if p_caption.medium in ('digital','film','instant') and trim(p_caption.camera)='' then raise exception 'Cameraを入力してください。'; end if;
  if p_caption.medium='film' and trim(p_caption.film)='' then raise exception 'Filmを入力してください。'; end if;
  if p_caption.description_choice='undecided' then raise exception 'Descriptionの要否を確定してください。'; end if;
  if p_caption.description_choice='provided' and trim(p_caption.description_ja)='' then raise exception '日本語Descriptionを入力してください。'; end if;
  if p_caption.instagram_qr_choice='provided' and p_caption.instagram_qr_path is null and trim(p_caption.instagram_qr_info)='' then
    raise exception 'Instagram QRの画像または情報を入力してください。';
  end if;
  if p_caption.ai_processing_declaration is null then raise exception 'AI生成・大幅加工等の有無を選択してください。'; end if;
  if p_caption.ai_processing_declaration='declared' and trim(p_caption.ai_processing_details)='' then
    raise exception 'AI生成・大幅加工等の内容を入力してください。';
  end if;
end;
$$;

create or replace function public.save_exhibition_caption_draft_v2(
  p_work_id uuid,p_display_name text,p_english_title_mode text,p_member_english_title text,
  p_medium text,p_medium_details text,p_camera text,p_lens text,p_film text,
  p_description_choice text,p_description_ja text,p_description_en text,
  p_instagram_qr_choice text,p_instagram_qr_info text,p_instagram_qr_path text,
  p_ai_processing_declaration text,p_ai_processing_details text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype;e public.events%rowtype;en public.exhibition_entries%rowtype;
 c public.exhibition_caption_working_data%rowtype;mid uuid:=private.current_member_id();actor text:=private.current_email();
begin
 if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 select * into w from public.exhibition_works where id=p_work_id and owner_member_id=mid for update;
 select * into e from public.events where id=w.event_id;select * into en from public.exhibition_entries where id=w.entry_id;
 if w.id is null or e.exhibition_workflow_version<>2 or en.application_state<>'active' or w.workflow_state='withdrawn' then raise exception '対象のWorkflow v2 Workが見つかりません。';end if;
 if p_ai_processing_declaration is not null and p_ai_processing_declaration not in ('none','declared') then raise exception 'AI生成・大幅加工等の選択が不正です。';end if;
 select * into c from public.exhibition_caption_working_data where work_id=w.id for update;
 if c.work_id is not null and c.state not in ('draft','rejected','reedit_editing') then raise exception '現在Captionを編集できません。';end if;
 if c.work_id is not null and not private.caption_edit_is_open(c,e) then raise exception 'Caption編集期限を過ぎています。';end if;
 if c.work_id is null and not coalesce(private.exhibition_deadline_is_open(w.event_id,'caption'),false) then raise exception 'Caption締切を過ぎています。';end if;
 insert into public.exhibition_caption_working_data(work_id,event_id,entry_id,member_id,state,display_name,english_title_mode,member_english_title,
  medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,instagram_qr_path,
  ai_processing_declaration,ai_processing_details)
 values(w.id,w.event_id,w.entry_id,w.owner_member_id,'draft',trim(coalesce(p_display_name,'')),p_english_title_mode,trim(coalesce(p_member_english_title,'')),
  p_medium,trim(coalesce(p_medium_details,'')),trim(coalesce(p_camera,'')),trim(coalesce(p_lens,'')),trim(coalesce(p_film,'')),p_description_choice,
  trim(coalesce(p_description_ja,'')),trim(coalesce(p_description_en,'')),p_instagram_qr_choice,trim(coalesce(p_instagram_qr_info,'')),p_instagram_qr_path,
  p_ai_processing_declaration,trim(coalesce(p_ai_processing_details,'')))
 on conflict(work_id) do update set display_name=excluded.display_name,english_title_mode=excluded.english_title_mode,member_english_title=excluded.member_english_title,
  medium=excluded.medium,medium_details=excluded.medium_details,camera=excluded.camera,lens=excluded.lens,film=excluded.film,
  description_choice=excluded.description_choice,description_ja=excluded.description_ja,description_en=excluded.description_en,
  instagram_qr_choice=excluded.instagram_qr_choice,instagram_qr_info=excluded.instagram_qr_info,instagram_qr_path=excluded.instagram_qr_path,
  ai_processing_declaration=excluded.ai_processing_declaration,ai_processing_details=excluded.ai_processing_details,updated_at=now()
 returning * into c;
 perform private.write_exhibition_workflow_audit(w.event_id,'caption_working_data',w.id,'caption_draft_saved','member',actor);
 return to_jsonb(c);
end;$$;

create or replace function public.submit_exhibition_caption_v2(p_work_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype;e public.events%rowtype;c public.exhibition_caption_working_data%rowtype;
 s public.exhibition_caption_submission_snapshots%rowtype;open_case public.exhibition_caption_workflow_cases%rowtype;
 mid uuid:=private.current_member_id();actor text:=private.current_email();next_version integer;
begin
 select * into w from public.exhibition_works where id=p_work_id and owner_member_id=mid for update;select * into e from public.events where id=w.event_id;
 select * into c from public.exhibition_caption_working_data where work_id=w.id for update;
 if w.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Workが見つかりません。';end if;
 if w.workflow_state<>'accepted' then raise exception 'Work確認済み後にCaptionを提出できます。';end if;
 if c.work_id is null or c.state not in ('draft','rejected','reedit_editing') or not private.caption_edit_is_open(c,e) then raise exception '現在Captionを正式提出できません。';end if;
 perform private.validate_caption_v2_values(c);
 if c.state='reedit_editing' and c.current_accepted_snapshot_id is not null and not exists(
  select 1 from public.exhibition_caption_submission_snapshots old where old.id=c.current_accepted_snapshot_id and(
   old.display_name<>c.display_name or old.english_title_mode<>c.english_title_mode or old.member_english_title<>c.member_english_title
   or old.medium<>c.medium or old.medium_details<>c.medium_details or old.camera<>c.camera or old.lens<>c.lens or old.film<>c.film
   or old.description_choice<>c.description_choice or old.description_ja<>c.description_ja or old.description_en<>c.description_en
   or old.instagram_qr_choice<>c.instagram_qr_choice or old.instagram_qr_info<>c.instagram_qr_info or old.instagram_qr_path is distinct from c.instagram_qr_path
   or old.ai_processing_declaration is distinct from c.ai_processing_declaration or old.ai_processing_details<>c.ai_processing_details)
 ) then raise exception '変更内容がありません。';end if;
 select coalesce(max(version_no),0)+1 into next_version from public.exhibition_caption_submission_snapshots where work_id=w.id;
 insert into public.exhibition_caption_submission_snapshots(work_id,event_id,entry_id,member_id,version_no,display_name,english_title_mode,member_english_title,
  medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,instagram_qr_path,
  ai_processing_declaration,ai_processing_details,submitted_by_member_id,submitted_by_identifier)
 values(w.id,w.event_id,w.entry_id,w.owner_member_id,next_version,c.display_name,c.english_title_mode,c.member_english_title,c.medium,c.medium_details,c.camera,c.lens,c.film,
  c.description_choice,c.description_ja,c.description_en,c.instagram_qr_choice,c.instagram_qr_info,c.instagram_qr_path,c.ai_processing_declaration,c.ai_processing_details,mid,actor)
 returning * into s;
 update public.exhibition_caption_working_data set state='submitted',current_submission_snapshot_id=s.id,updated_at=now() where work_id=w.id;
 select * into open_case from public.exhibition_caption_workflow_cases where work_id=w.id and state in('open','permitted') for update;
 if open_case.id is not null then update public.exhibition_caption_workflow_cases set state='resubmitted',closed_at=now() where id=open_case.id;end if;
 perform private.write_exhibition_workflow_audit(w.event_id,'caption_submission_snapshot',s.id,case when next_version=1 then 'caption_submitted' when open_case.case_type='correction' then 'caption_correction_resubmitted' else 'caption_reedit_resubmitted' end,'member',actor,'','{}',jsonb_build_object('workId',w.id,'versionNo',next_version));
 return jsonb_build_object('snapshotId',s.id,'versionNo',next_version,'state','submitted');
end;$$;

create or replace function private.populate_exhibition_ai_declaration_v2()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 select s.ai_processing_declaration,coalesce(s.ai_processing_details,'') into new.ai_processing_declaration,new.ai_processing_details
 from public.exhibition_caption_submission_snapshots s where s.id=new.caption_submission_snapshot_id;
 new.ai_processing_details:=coalesce(new.ai_processing_details,'');
 return new;
end;$$;
create trigger exhibition_export_items_ai_before_insert before insert on public.exhibition_export_items
for each row execute function private.populate_exhibition_ai_declaration_v2();
create trigger exhibition_archive_items_ai_before_insert before insert on public.exhibition_archive_items
for each row execute function private.populate_exhibition_ai_declaration_v2();

create or replace function public.admin_get_exhibition_export_csv_v2(p_export_version_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
declare v public.exhibition_export_versions%rowtype;body text;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into v from public.exhibition_export_versions where id=p_export_version_id;if v.id is null then raise exception 'Export Versionが見つかりません。';end if;
 select string_agg(array_to_string(array[
  private.exhibition_csv_cell_v2(i.work_id::text),private.exhibition_csv_cell_v2(i.display_no::text),private.exhibition_csv_cell_v2(i.viewing_order::text),
  private.exhibition_csv_cell_v2(i.work_submission_snapshot_id::text),private.exhibition_csv_cell_v2(i.caption_submission_snapshot_id::text),private.exhibition_csv_cell_v2(v.layout_finalization_id::text),
  private.exhibition_csv_cell_v2(i.title_ja),private.exhibition_csv_cell_v2(i.display_name),private.exhibition_csv_cell_v2(i.effective_english_title),
  private.exhibition_csv_cell_v2(i.english_title_mode),private.exhibition_csv_cell_v2(i.english_title_provenance),private.exhibition_csv_cell_v2(i.medium),
  private.exhibition_csv_cell_v2(i.medium_details),private.exhibition_csv_cell_v2(i.camera),private.exhibition_csv_cell_v2(i.lens),private.exhibition_csv_cell_v2(i.film),
  private.exhibition_csv_cell_v2(i.description_choice),private.exhibition_csv_cell_v2(i.description_ja),private.exhibition_csv_cell_v2(i.description_en),
  private.exhibition_csv_cell_v2(i.ai_processing_declaration),private.exhibition_csv_cell_v2(i.ai_processing_details),
  private.exhibition_csv_cell_v2(i.instagram_qr_choice),private.exhibition_csv_cell_v2(i.instagram_qr_info),private.exhibition_csv_cell_v2(i.instagram_qr_path),
  private.exhibition_csv_cell_v2(i.publication_consent::text),private.exhibition_csv_cell_v2(i.orientation),private.exhibition_csv_cell_v2(i.print_size),private.exhibition_csv_cell_v2(i.print_size_detail),private.exhibition_csv_cell_v2(i.wall_id::text)
 ],','),E'\r\n' order by i.viewing_order) into body from public.exhibition_export_items i where i.export_version_id=v.id;
 return E'\uFEFFwork_uuid,display_no,viewing_order,work_snapshot_uuid,caption_snapshot_uuid,layout_finalization_uuid,title_ja,display_name,effective_english_title,english_title_mode,english_title_provenance,medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,ai_processing_declaration,ai_processing_details,instagram_qr_choice,instagram_qr_info,instagram_qr_path,publication_consent,orientation,print_size,print_size_detail,wall_uuid\r\n'||coalesce(body,'');
end;$$;

create table public.exhibition_shift_schedule_versions(
 id uuid primary key default gen_random_uuid(),event_id uuid not null references public.events(id) on delete restrict,
 version_no integer not null check(version_no>=1),state text not null default 'draft' check(state in('draft','saved','published')),
 created_at timestamptz not null default now(),created_by text not null,saved_at timestamptz,saved_by text,published_at timestamptz,published_by text,
 shortage_override_reason text not null default '',shortage_snapshot jsonb not null default '[]'::jsonb,
 unique(event_id,version_no)
);
create unique index exhibition_shift_schedule_one_draft on public.exhibition_shift_schedule_versions(event_id) where state='draft';
create table public.exhibition_shift_schedule_assignments(
 id uuid primary key default gen_random_uuid(),schedule_version_id uuid not null references public.exhibition_shift_schedule_versions(id) on delete restrict,
 event_id uuid not null references public.events(id) on delete restrict,slot_id text not null,slot_label text not null,
 member_id uuid not null references public.members(id) on delete restrict,assignment_source text not null check(assignment_source in('preference','admin')),
 assigned_by text not null,assigned_at timestamptz not null default now(),unique(schedule_version_id,slot_id,member_id)
);
alter table public.events add column current_exhibition_shift_schedule_version_id uuid references public.exhibition_shift_schedule_versions(id) on delete restrict;

create or replace function private.member_is_current_for_exhibition_shift(p_member_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.members m join public.membership_years y on y.member_id=m.id
  where m.id=p_member_id and m.active and y.active and y.fiscal_year=(case when extract(month from timezone('Asia/Tokyo',now()))>=4 then extract(year from timezone('Asia/Tokyo',now())) else extract(year from timezone('Asia/Tokyo',now()))-1 end)::integer)
$$;
create or replace function private.protect_exhibition_shift_schedule_history()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='exhibition_shift_schedule_versions'
    and coalesce(to_jsonb(old)->>'state','')<>'draft'
    and coalesce(current_setting('app.exhibition_shift_schedule_rpc',true),'')<>'on'
 then raise exception '保存・公開済みシフト版は変更または削除できません。';end if;
 if tg_table_name='exhibition_shift_schedule_assignments' and exists(
   select 1 from public.exhibition_shift_schedule_versions v
   where v.id=(to_jsonb(old)->>'schedule_version_id')::uuid and v.state<>'draft'
 ) then raise exception '保存・公開済みシフト割当は変更または削除できません。';end if;
 return case when tg_op='DELETE' then old else new end;
end;$$;
create trigger exhibition_shift_versions_immutable before update or delete on public.exhibition_shift_schedule_versions for each row execute function private.protect_exhibition_shift_schedule_history();
create trigger exhibition_shift_assignments_immutable before update or delete on public.exhibition_shift_schedule_assignments for each row execute function private.protect_exhibition_shift_schedule_history();
create or replace function private.protect_current_exhibition_shift_schedule()
returns trigger language plpgsql security definer set search_path='' as $$
begin if new.current_exhibition_shift_schedule_version_id is distinct from old.current_exhibition_shift_schedule_version_id and coalesce(current_setting('app.exhibition_shift_schedule_rpc',true),'')<>'on' then raise exception '公開シフトは専用操作から変更してください。';end if;return new;end;$$;
create trigger zzz_events_protect_current_exhibition_shift before update of current_exhibition_shift_schedule_version_id on public.events for each row execute function private.protect_current_exhibition_shift_schedule();

-- 新規参加は、管理者が明示公開した保存済みEventかつ募集期限内に限定する。
-- 既存の公開状態フィールドを正とし、新しい公開フラグは追加しない。
create or replace function private.is_available_exhibition_event(target_event_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.events e where e.id=target_event_id and e.genre='exhibition'
  and e.status='saved' and e.published and e.deleted_at is null
  and e.registration_deadline is not null and now()<e.registration_deadline)
$$;

create or replace function public.save_my_exhibition_shift_preferences_v1(p_event_id uuid,p_preferences jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare mid uuid:=private.current_member_id();item jsonb;slot jsonb;count_saved integer:=0;
begin
 if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 if not private.is_available_exhibition_event(p_event_id) then raise exception 'この写真展は現在シフト希望を受け付けていません。';end if;
 if jsonb_typeof(coalesce(p_preferences,'[]'::jsonb))<>'array' then raise exception 'シフト希望の形式が不正です。';end if;
 delete from public.exhibition_shift_preferences where event_id=p_event_id and member_id=mid;
 for item in select value from jsonb_array_elements(coalesce(p_preferences,'[]'::jsonb)) loop
  if item->>'preference' not in('preferred','available','unavailable') then raise exception '希望区分が不正です。';end if;
  select value into slot from jsonb_array_elements((select shift_slots from public.events where id=p_event_id)) where coalesce(value->>'id',value#>>'{}')=item->>'slotId';
  if slot is null then raise exception '指定されたシフト枠が見つかりません。';end if;
  insert into public.exhibition_shift_preferences(event_id,member_id,slot_id,slot_label,preference,note)
  values(p_event_id,mid,item->>'slotId',coalesce(slot->>'label',slot#>>'{}'),item->>'preference',left(coalesce(item->>'note',''),1000));count_saved:=count_saved+1;
 end loop;
 return jsonb_build_object('eventId',p_event_id,'savedCount',count_saved);
end;$$;

create or replace function public.get_my_exhibition_shift_workspace_v1(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare mid uuid:=private.current_member_id();e public.events%rowtype;v public.exhibition_shift_schedule_versions%rowtype;
begin
 if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 select * into e from public.events where id=p_event_id and genre='exhibition' and deleted_at is null;
 if e.id is null or e.status<>'saved' or not(
   private.is_available_exhibition_event(e.id)
   or exists(select 1 from public.exhibition_entries x where x.event_id=e.id and x.member_id=mid)
   or exists(select 1 from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=mid)
   or exists(select 1 from public.exhibition_shift_schedule_assignments a where a.schedule_version_id=e.current_exhibition_shift_schedule_version_id and a.member_id=mid)
 ) then raise exception '対象の写真展を確認できません。';end if;
 select * into v from public.exhibition_shift_schedule_versions where id=e.current_exhibition_shift_schedule_version_id and state='published';
 return jsonb_build_object('eventId',e.id,'slots',e.shift_slots,'canSubmitPreferences',private.is_available_exhibition_event(e.id),'preferences',coalesce((select jsonb_agg(to_jsonb(p) order by p.slot_label) from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=mid),'[]'::jsonb),
  'publishedVersion',case when v.id is null then null else jsonb_build_object('id',v.id,'versionNo',v.version_no,'publishedAt',v.published_at) end,
  'assignments',coalesce((select jsonb_agg(jsonb_build_object('slotId',a.slot_id,'slotLabel',a.slot_label,'memberId',a.member_id,'memberName',m.name,'isMine',a.member_id=mid) order by a.slot_label,m.name)
   from public.exhibition_shift_schedule_assignments a join public.members m on m.id=a.member_id where a.schedule_version_id=v.id),'[]'::jsonb));
end;$$;

create or replace function public.get_my_exhibition_hub_v1()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare mid uuid:=private.current_member_id();
begin
 if mid is null or not private.is_current_member() then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(jsonb_build_object('eventId',e.id,'title',e.title,'exhibitionTitle',e.exhibition_title,'startsAt',e.starts_at,'endsAt',e.ends_at,'place',e.place,
   'hasApplication',exists(select 1 from public.exhibition_entries x where x.event_id=e.id and x.member_id=mid),
   'hasShiftPreference',exists(select 1 from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=mid),
   'hasPublishedAssignment',exists(select 1 from public.exhibition_shift_schedule_assignments a where a.schedule_version_id=e.current_exhibition_shift_schedule_version_id and a.member_id=mid)) order by e.starts_at)
  from public.events e where e.genre='exhibition' and e.deleted_at is null and e.status='saved'
   and coalesce(e.ends_at,e.starts_at+interval '4 days')>now() and(
   exists(select 1 from public.exhibition_entries x where x.event_id=e.id and x.member_id=mid) or exists(select 1 from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=mid)
   or exists(select 1 from public.exhibition_shift_schedule_assignments a where a.schedule_version_id=e.current_exhibition_shift_schedule_version_id and a.member_id=mid))),'[]'::jsonb);
end;$$;

-- 非公開化・募集終了後も、既存参加者は終了前まで自分の写真展ページを確認できる。
create or replace function public.get_my_exhibition_event_v1(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare mid uuid:=private.current_member_id();e public.events%rowtype;
begin
 if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 select * into e from public.events where id=p_event_id and genre='exhibition' and status='saved' and deleted_at is null
  and coalesce(ends_at,starts_at+interval '4 days')>now();
 if e.id is null or not(
   (e.published and e.status='saved')
   or exists(select 1 from public.exhibition_entries x where x.event_id=e.id and x.member_id=mid)
   or exists(select 1 from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=mid)
   or exists(select 1 from public.exhibition_shift_schedule_assignments a where a.schedule_version_id=e.current_exhibition_shift_schedule_version_id and a.member_id=mid)
 ) then raise exception '対象の写真展を確認できません。';end if;
 return to_jsonb(e);
end;$$;

create or replace function public.admin_create_exhibition_shift_schedule_draft_v1(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype;v public.exhibition_shift_schedule_versions%rowtype;nextv integer;actor text:=private.current_email();
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into e from public.events where id=p_event_id and genre='exhibition' and deleted_at is null for update;if e.id is null then raise exception '写真展が見つかりません。';end if;
 select * into v from public.exhibition_shift_schedule_versions where event_id=e.id and state='draft';if v.id is not null then return jsonb_build_object('versionId',v.id,'versionNo',v.version_no);end if;
 select coalesce(max(version_no),0)+1 into nextv from public.exhibition_shift_schedule_versions where event_id=e.id;
 insert into public.exhibition_shift_schedule_versions(event_id,version_no,created_by) values(e.id,nextv,actor) returning * into v;
 if e.current_exhibition_shift_schedule_version_id is not null then
  insert into public.exhibition_shift_schedule_assignments(schedule_version_id,event_id,slot_id,slot_label,member_id,assignment_source,assigned_by)
  select v.id,e.id,a.slot_id,a.slot_label,a.member_id,a.assignment_source,actor from public.exhibition_shift_schedule_assignments a where a.schedule_version_id=e.current_exhibition_shift_schedule_version_id;
 end if;
 return jsonb_build_object('versionId',v.id,'versionNo',v.version_no);
end;$$;

create or replace function public.admin_set_exhibition_shift_assignment_v1(p_version_id uuid,p_slot_id text,p_member_id uuid,p_assigned boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.exhibition_shift_schedule_versions%rowtype;e public.events%rowtype;slot jsonb;actor text:=private.current_email();source text;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into v from public.exhibition_shift_schedule_versions where id=p_version_id for update;
 if v.id is null or v.state<>'draft' then raise exception '編集可能なシフトDraftではありません。';end if;select * into e from public.events where id=v.event_id;
 select value into slot from jsonb_array_elements(e.shift_slots) where coalesce(value->>'id',value#>>'{}')=p_slot_id;if slot is null then raise exception 'シフト枠が見つかりません。';end if;
 if not private.member_is_current_for_exhibition_shift(p_member_id) then raise exception '現在有効な部員ではありません。';end if;
 if p_assigned then source:=case when exists(select 1 from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=p_member_id and p.slot_id=p_slot_id and p.preference in('preferred','available')) then 'preference' else 'admin' end;
  insert into public.exhibition_shift_schedule_assignments(schedule_version_id,event_id,slot_id,slot_label,member_id,assignment_source,assigned_by)
  values(v.id,e.id,p_slot_id,coalesce(slot->>'label',slot#>>'{}'),p_member_id,source,actor) on conflict(schedule_version_id,slot_id,member_id) do nothing;
 else delete from public.exhibition_shift_schedule_assignments where schedule_version_id=v.id and slot_id=p_slot_id and member_id=p_member_id;end if;
 return jsonb_build_object('versionId',v.id,'slotId',p_slot_id,'memberId',p_member_id,'assigned',p_assigned,'source',source);
end;$$;

create or replace function public.admin_save_exhibition_shift_schedule_v1(p_version_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.exhibition_shift_schedule_versions%rowtype;actor text:=private.current_email();
begin if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into v from public.exhibition_shift_schedule_versions where id=p_version_id for update;
 if v.id is null or v.state<>'draft' then raise exception '保存可能なDraftではありません。';end if;
 update public.exhibition_shift_schedule_versions set state='saved',saved_at=now(),saved_by=actor where id=v.id;
 perform private.write_exhibition_workflow_audit(v.event_id,'shift_schedule_version',v.id,'shift_schedule_saved','admin',actor,'','{}',jsonb_build_object('versionNo',v.version_no));
 return jsonb_build_object('versionId',v.id,'versionNo',v.version_no,'state','saved');end;$$;

create or replace function public.admin_publish_exhibition_shift_schedule_v1(p_version_id uuid,p_shortage_override_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.exhibition_shift_schedule_versions%rowtype;e public.events%rowtype;actor text:=private.current_email();shortages jsonb;
begin if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into v from public.exhibition_shift_schedule_versions where id=p_version_id for update;
 if v.id is null or v.state<>'saved' then raise exception '保存済みのシフト版だけを公開できます。';end if;select * into e from public.events where id=v.event_id for update;
 select coalesce(jsonb_agg(jsonb_build_object('slotId',s.id,'slotLabel',s.label,'assignedCount',s.cnt,'requiredCount',e.min_shift_people,'shortage',e.min_shift_people-s.cnt) order by s.ord),'[]'::jsonb) into shortages
 from(select coalesce(x->>'id',x#>>'{}') id,coalesce(x->>'label',x#>>'{}') label,ord,(select count(*) from public.exhibition_shift_schedule_assignments a where a.schedule_version_id=v.id and a.slot_id=coalesce(x->>'id',x#>>'{}')) cnt from jsonb_array_elements(e.shift_slots) with ordinality q(x,ord))s where s.cnt<e.min_shift_people;
 if jsonb_array_length(shortages)>0 and trim(coalesce(p_shortage_override_reason,''))='' then raise exception '人数不足の枠があります。例外公開理由を入力してください。';end if;
 perform set_config('app.exhibition_shift_schedule_rpc','on',true);
 update public.exhibition_shift_schedule_versions set state='published',published_at=now(),published_by=actor,shortage_override_reason=trim(coalesce(p_shortage_override_reason,'')),shortage_snapshot=shortages where id=v.id;
 perform set_config('app.exhibition_shift_schedule_rpc','on',true);update public.events set current_exhibition_shift_schedule_version_id=v.id,updated_at=now(),updated_by=actor where id=e.id;perform set_config('app.exhibition_shift_schedule_rpc','off',true);
 perform private.write_exhibition_workflow_audit(e.id,'shift_schedule_version',v.id,case when jsonb_array_length(shortages)>0 then 'shift_schedule_published_with_shortage' else 'shift_schedule_published' end,'admin',actor,p_shortage_override_reason,'{}',jsonb_build_object('versionNo',v.version_no,'shortages',shortages));
 return jsonb_build_object('versionId',v.id,'versionNo',v.version_no,'state','published','shortages',shortages);end;$$;

create or replace function public.admin_get_exhibition_shift_workspace_v1(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e public.events%rowtype;
begin if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into e from public.events where id=p_event_id and genre='exhibition';if e.id is null then raise exception '写真展が見つかりません。';end if;
 return jsonb_build_object('eventId',e.id,'slots',e.shift_slots,'minimumPeople',e.min_shift_people,'currentPublishedVersionId',e.current_exhibition_shift_schedule_version_id,
  'preferences',coalesce((select jsonb_agg(jsonb_build_object('slotId',p.slot_id,'slotLabel',p.slot_label,'preference',p.preference,'note',p.note,'memberId',p.member_id,'memberName',m.name) order by p.slot_label,m.name) from public.exhibition_shift_preferences p join public.members m on m.id=p.member_id where p.event_id=e.id),'[]'::jsonb),
  'members',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'memberNo',m.member_no,'grade',m.grade) order by m.name) from public.members m where private.member_is_current_for_exhibition_shift(m.id)),'[]'::jsonb),
  'versions',coalesce((select jsonb_agg(to_jsonb(v) order by v.version_no desc) from public.exhibition_shift_schedule_versions v where v.event_id=e.id),'[]'::jsonb),
  'assignments',coalesce((select jsonb_agg(jsonb_build_object('versionId',a.schedule_version_id,'slotId',a.slot_id,'slotLabel',a.slot_label,'memberId',a.member_id,'memberName',m.name,'source',a.assignment_source) order by a.slot_label,m.name) from public.exhibition_shift_schedule_assignments a join public.members m on m.id=a.member_id where a.event_id=e.id),'[]'::jsonb));end;$$;

alter table public.exhibition_shift_schedule_versions enable row level security;alter table public.exhibition_shift_schedule_assignments enable row level security;
revoke all on public.exhibition_shift_schedule_versions,public.exhibition_shift_schedule_assignments from anon,authenticated;
grant select on public.exhibition_shift_schedule_versions,public.exhibition_shift_schedule_assignments to authenticated;
create policy exhibition_shift_versions_admin_or_current_select on public.exhibition_shift_schedule_versions for select to authenticated
 using(private.is_admin() or(id=(select e.current_exhibition_shift_schedule_version_id from public.events e where e.id=event_id) and state='published' and private.is_current_member()));
create policy exhibition_shift_assignments_admin_or_published_select on public.exhibition_shift_schedule_assignments for select to authenticated
 using(private.is_admin() or(private.is_current_member() and exists(select 1 from public.events e where e.id=event_id and e.current_exhibition_shift_schedule_version_id=schedule_version_id)));

revoke all on function public.save_exhibition_caption_draft_v2(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text),
 public.save_my_exhibition_shift_preferences_v1(uuid,jsonb),public.get_my_exhibition_shift_workspace_v1(uuid),public.get_my_exhibition_hub_v1(),public.get_my_exhibition_event_v1(uuid),
 public.admin_create_exhibition_shift_schedule_draft_v1(uuid),public.admin_set_exhibition_shift_assignment_v1(uuid,text,uuid,boolean),
 public.admin_save_exhibition_shift_schedule_v1(uuid),public.admin_publish_exhibition_shift_schedule_v1(uuid,text),public.admin_get_exhibition_shift_workspace_v1(uuid) from public,anon;
-- AI申告を持たない旧overloadは、既存DBオブジェクトとして残すが新規の部員操作には公開しない。
revoke all on function public.save_exhibition_caption_draft_v2(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text)
 from public,anon,authenticated;
grant execute on function public.save_exhibition_caption_draft_v2(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text),
 public.save_my_exhibition_shift_preferences_v1(uuid,jsonb),public.get_my_exhibition_shift_workspace_v1(uuid),public.get_my_exhibition_hub_v1(),public.get_my_exhibition_event_v1(uuid),
 public.admin_create_exhibition_shift_schedule_draft_v1(uuid),public.admin_set_exhibition_shift_assignment_v1(uuid,text,uuid,boolean),
 public.admin_save_exhibition_shift_schedule_v1(uuid),public.admin_publish_exhibition_shift_schedule_v1(uuid,text),public.admin_get_exhibition_shift_workspace_v1(uuid) to authenticated;
revoke execute on function private.populate_exhibition_ai_declaration_v2(),private.member_is_current_for_exhibition_shift(uuid),private.protect_exhibition_shift_schedule_history(),private.protect_current_exhibition_shift_schedule() from public,anon,authenticated;
