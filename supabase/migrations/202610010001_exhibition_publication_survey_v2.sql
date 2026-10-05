-- 写真展Workflow v2 Phase 8: immutable Public Publication / UUID Survey。

create table public.exhibition_publication_versions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  source_export_version_id uuid not null references public.exhibition_export_versions(id) on delete restrict,
  source_layout_finalization_id uuid not null references public.exhibition_layout_finalizations(id) on delete restrict,
  site_title text not null,site_title_en text not null default '',site_catchphrase text not null default '',site_catchphrase_en text not null default '',
  site_description text not null,site_description_en text not null default '',place text not null,place_en text not null default '',
  site_additional_info text not null default '',site_additional_info_en text not null default '',
  starts_at timestamptz,ends_at timestamptz,dm_image_path text,note text not null default '',
  created_by text not null,created_at timestamptz not null default now(),
  published_by text not null,published_at timestamptz not null default now(),
  unique(event_id,version_no)
);

create table public.exhibition_publication_items (
  id uuid primary key default gen_random_uuid(),
  publication_version_id uuid not null references public.exhibition_publication_versions(id) on delete restrict,
  source_export_item_id uuid not null references public.exhibition_export_items(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  display_no integer not null,public_order integer not null,
  work_submission_snapshot_id uuid not null references public.exhibition_work_submission_snapshots(id) on delete restrict,
  caption_submission_snapshot_id uuid not null references public.exhibition_caption_submission_snapshots(id) on delete restrict,
  title_ja text not null,display_name text not null,effective_english_title text not null,
  english_title_provenance text not null,medium text not null,medium_details text not null default '',camera text not null default '',
  lens text not null default '',film text not null default '',description_choice text not null,
  description_ja text not null default '',description_en text not null default '',instagram_qr_choice text not null,
  instagram_qr_info text not null default '',publication_consent boolean not null,
  image_state text not null check(image_state in ('public_image','no_image')),
  public_image_path text,
  unique(publication_version_id,work_id),unique(publication_version_id,display_no),unique(publication_version_id,public_order),
  check((publication_consent and image_state='public_image' and public_image_path is not null)
     or (not publication_consent and image_state='no_image' and public_image_path is null))
);

alter table public.events add column if not exists current_publication_version_id uuid
  references public.exhibition_publication_versions(id) on delete restrict;
alter table public.exhibition_survey_responses
  add column if not exists publication_version_id uuid references public.exhibition_publication_versions(id) on delete restrict,
  add column if not exists workflow_version smallint not null default 1 check(workflow_version in (1,2));

create or replace function private.prevent_exhibition_publication_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'Public Publication履歴は変更または削除できません。'; end;
$$;
create trigger exhibition_publication_versions_immutable before update or delete on public.exhibition_publication_versions
for each row execute function private.prevent_exhibition_publication_mutation();
create trigger exhibition_publication_items_immutable before update or delete on public.exhibition_publication_items
for each row execute function private.prevent_exhibition_publication_mutation();

create or replace function private.protect_current_publication_pointer_v2()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.exhibition_workflow_version=2 and new.current_publication_version_id is distinct from old.current_publication_version_id
     and coalesce(current_setting('app.exhibition_publication_rpc',true),'')<>'on' then
    raise exception 'Workflow v2のCurrent Publicationは専用操作から変更してください。';
  end if;
  return new;
end;
$$;
create trigger zzz_events_protect_current_publication_v2 before update of current_publication_version_id on public.events
for each row execute function private.protect_current_publication_pointer_v2();

create or replace function public.admin_get_exhibition_publication_readiness_v2(p_export_version_id uuid)
returns table(work_id uuid,display_no integer,ready boolean,reasons text[])
language plpgsql stable security definer set search_path='' as $$
declare v public.exhibition_export_versions%rowtype; e public.events%rowtype;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into v from public.exhibition_export_versions where id=p_export_version_id;
  select * into e from public.events where id=v.event_id;
  if v.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Exportが見つかりません。'; end if;
  return query
  select i.work_id,i.display_no,cardinality(r.x)=0,coalesce(r.x,'{}'::text[])
  from public.exhibition_export_items i
  join public.exhibition_works w on w.id=i.work_id
  join public.exhibition_work_submission_snapshots ws on ws.id=i.work_submission_snapshot_id
  join public.exhibition_caption_submission_snapshots cs on cs.id=i.caption_submission_snapshot_id
  join public.exhibition_layout_finalizations lf on lf.id=v.layout_finalization_id
  left join public.exhibition_caption_working_data c on c.work_id=w.id
  cross join lateral(select array_remove(array[
    case when i.event_id<>v.event_id or w.event_id<>v.event_id or lf.event_id<>v.event_id then 'Export provenance event mismatch' end,
    case when ws.work_id<>i.work_id or cs.work_id<>i.work_id then 'Export snapshot provenance mismatch' end,
    case when w.workflow_state<>'accepted' then 'Work is no longer accepted' end,
    case when i.work_submission_snapshot_id is distinct from w.current_accepted_snapshot_id then 'A newer Work Export is required' end,
    case when c.state is distinct from 'accepted' then 'Caption is no longer accepted' end,
    case when i.caption_submission_snapshot_id is distinct from c.current_accepted_snapshot_id then 'A newer Caption Export is required' end,
    case when v.layout_finalization_id is distinct from (select f.id from public.exhibition_layout_finalizations f where f.event_id=v.event_id order by f.finalization_version desc limit 1) then 'A newer Layout Export is required' end,
    case when i.publication_consent and (not w.public_release or w.public_image_path is null) then 'Approved public derivative image is missing' end,
    case when trim(i.title_ja)='' or trim(i.display_name)='' or trim(i.effective_english_title)='' then 'Required public caption value is missing' end
  ]::text[],null) x) r
  where i.export_version_id=v.id order by i.viewing_order;
end;
$$;

create or replace function public.admin_set_exhibition_public_image_v2(p_work_id uuid,p_public_image_path text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into w from public.exhibition_works where id=p_work_id for update;
  if w.id is null or not exists(select 1 from public.events where id=w.event_id and exhibition_workflow_version=2) then raise exception 'Workflow v2 Workが見つかりません。'; end if;
  if w.workflow_state<>'accepted' or w.publication_consent is not true then raise exception '公開画像を設定できるWorkではありません。'; end if;
  if trim(coalesce(p_public_image_path,''))='' or p_public_image_path like '%..%' then raise exception '公開画像pathが不正です。'; end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='exhibition-public' and o.name=trim(p_public_image_path)) then
    raise exception '公開派生画像がPublic Storageに見つかりません。';
  end if;
  if exists(select 1 from public.exhibition_works x where x.id<>w.id and x.public_image_path=trim(p_public_image_path))
     or exists(select 1 from public.exhibition_publication_items x where x.work_id<>w.id and x.public_image_path=trim(p_public_image_path)) then
    raise exception '公開派生画像pathは別Workですでに使用されています。';
  end if;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set public_image_path=trim(p_public_image_path),public_release=true,updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'work',w.id,'public_derivative_registered','admin',actor,'','{}',jsonb_build_object('publicImagePath',trim(p_public_image_path)));
  return jsonb_build_object('workId',w.id,'publicImagePath',trim(p_public_image_path));
end;
$$;

create or replace function public.admin_finalize_exhibition_publication_v2(p_export_version_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.exhibition_export_versions%rowtype;e public.events%rowtype;publication_id uuid;next_version integer;
  actor text:=private.current_email();blocked integer;item_count integer;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into v from public.exhibition_export_versions where id=p_export_version_id;
  select * into e from public.events where id=v.event_id for update;
  if v.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Exportが見つかりません。'; end if;
  if nullif(trim(e.exhibition_key),'') is null or nullif(trim(e.site_title),'') is null
     or nullif(trim(e.site_description),'') is null or nullif(trim(e.place),'') is null
     or nullif(trim(e.dm_image_path),'') is null then raise exception '公開サイト基本情報またはDM画像が不足しています。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text||':publication',0));
  select count(*) into blocked from public.admin_get_exhibition_publication_readiness_v2(v.id) where not ready;
  if blocked>0 then raise exception 'Public Publicationを作成できません。未解決項目: %件',blocked; end if;
  select count(*) into item_count from public.exhibition_export_items where export_version_id=v.id;
  if item_count=0 then raise exception 'Publication対象がありません。'; end if;
  select coalesce(max(version_no),0)+1 into next_version from public.exhibition_publication_versions where event_id=e.id;
  insert into public.exhibition_publication_versions(event_id,version_no,source_export_version_id,source_layout_finalization_id,
    site_title,site_title_en,site_catchphrase,site_catchphrase_en,site_description,site_description_en,place,place_en,
    site_additional_info,site_additional_info_en,
    starts_at,ends_at,dm_image_path,note,created_by,published_by)
  values(e.id,next_version,v.id,v.layout_finalization_id,e.site_title,e.site_title_en,e.site_catchphrase,e.site_catchphrase_en,
    e.site_description,e.site_description_en,e.place,e.place_en,e.site_additional_info,e.site_additional_info_en,
    e.starts_at,e.ends_at,e.dm_image_path,coalesce(p_note,''),actor,actor)
  returning id into publication_id;
  insert into public.exhibition_publication_items(publication_version_id,source_export_item_id,event_id,work_id,display_no,public_order,
    work_submission_snapshot_id,caption_submission_snapshot_id,title_ja,display_name,effective_english_title,english_title_provenance,
    medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,
    publication_consent,image_state,public_image_path)
  select publication_id,i.id,e.id,i.work_id,i.display_no,i.viewing_order,i.work_submission_snapshot_id,i.caption_submission_snapshot_id,
    i.title_ja,i.display_name,i.effective_english_title,i.english_title_provenance,i.medium,i.medium_details,i.camera,i.lens,i.film,
    i.description_choice,i.description_ja,i.description_en,i.instagram_qr_choice,i.instagram_qr_info,i.publication_consent,
    case when i.publication_consent then 'public_image' else 'no_image' end,
    case when i.publication_consent then w.public_image_path else null end
  from public.exhibition_export_items i join public.exhibition_works w on w.id=i.work_id where i.export_version_id=v.id order by i.viewing_order;
  perform private.write_exhibition_workflow_audit(e.id,'publication_version',publication_id,'public_publication_finalized','admin',actor,p_note,'{}',
    jsonb_build_object('versionNo',next_version,'sourceExportVersionId',v.id,'layoutFinalizationId',v.layout_finalization_id,'itemCount',item_count));
  return jsonb_build_object('publicationVersionId',publication_id,'versionNo',next_version,'itemCount',item_count);
end;
$$;

create or replace function public.admin_set_current_exhibition_publication_v2(p_publication_version_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.exhibition_publication_versions%rowtype;e public.events%rowtype;old_id uuid;actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into p from public.exhibition_publication_versions where id=p_publication_version_id;
  select * into e from public.events where id=p.event_id for update;
  if p.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Publicationが見つかりません。'; end if;
  old_id:=e.current_publication_version_id;
  perform set_config('app.exhibition_publication_rpc','on',true);
  update public.events set current_publication_version_id=p.id,site_status='published',site_published_at=coalesce(site_published_at,now()),site_ended_at=null,
    updated_at=now(),updated_by=actor where id=e.id;
  perform set_config('app.exhibition_publication_rpc','off',true);
  perform private.write_exhibition_workflow_audit(e.id,'event',e.id,'current_publication_switched','admin',actor,p_reason,
    jsonb_build_object('publicationVersionId',old_id),jsonb_build_object('publicationVersionId',p.id));
  return jsonb_build_object('eventId',e.id,'publicationVersionId',p.id,'versionNo',p.version_no,'siteStatus','published');
end;
$$;

-- v2はcurrent immutable Publicationだけを返す。v1は既存の可変公開表現を維持する。
create or replace function public.get_public_exhibition(p_exhibition_key text)
returns jsonb language sql stable security definer set search_path='' as $$
  select case when e.exhibition_workflow_version=2 then
    jsonb_build_object('exhibitionKey',e.exhibition_key,'publicationVersionId',p.id,'publicationVersionNo',p.version_no,
      'title',p.site_title,'titleEn',p.site_title_en,'catchphrase',p.site_catchphrase,'catchphraseEn',p.site_catchphrase_en,
      'description',p.site_description,'descriptionEn',p.site_description_en,'startsAt',p.starts_at,'endsAt',p.ends_at,
      'place',p.place,'placeEn',p.place_en,'additionalInfo',p.site_additional_info,'additionalInfoEn',p.site_additional_info_en,
      'dmImagePath',p.dm_image_path,'siteStatus',e.site_status,
      'surveyOpensAt',e.survey_opens_at,'surveyClosesAt',e.survey_closes_at,
      'works',case when e.site_status='published' then coalesce((select jsonb_agg(jsonb_build_object(
        'workUuid',i.work_id,'displayNo',i.display_no,'title',i.title_ja,'titleEn',i.effective_english_title,
        'artist',i.display_name,'camera',i.camera,'lensOther',concat_ws(' / ',nullif(i.lens,''),nullif(i.film,''),nullif(i.medium_details,'')),
        'description',case when i.description_choice='provided' then i.description_ja else '' end,
        'descriptionEn',case when i.description_choice='provided' then i.description_en else '' end,
        'medium',i.medium,'instagramQrChoice',i.instagram_qr_choice,'instagramInfo',i.instagram_qr_info,
        'imagePublic',i.image_state='public_image','imageState',i.image_state,
        'publicImagePath',case when i.image_state='public_image' then i.public_image_path else null end
      ) order by i.public_order) from public.exhibition_publication_items i where i.publication_version_id=p.id),'[]'::jsonb) else '[]'::jsonb end)
  else jsonb_build_object('exhibitionKey',e.exhibition_key,'title',e.site_title,'titleEn',e.site_title_en,
    'catchphrase',e.site_catchphrase,'catchphraseEn',e.site_catchphrase_en,'description',e.site_description,'descriptionEn',e.site_description_en,
    'startsAt',e.starts_at,'endsAt',e.ends_at,'place',e.place,'placeEn',e.place_en,'dmImagePath',e.dm_image_path,'siteStatus',e.site_status,
    'surveyOpensAt',e.survey_opens_at,'surveyClosesAt',e.survey_closes_at,
    'works',case when e.site_status='published' then coalesce((select jsonb_agg(jsonb_build_object('workUuid',w.id,'displayNo',w.display_no,
      'title',w.title,'titleEn',w.title_en,'artist',w.artist_name,'camera',w.camera_name,'lensOther',w.lens_other,
      'description',w.description,'descriptionEn',w.description_en,'imagePublic',w.publication_consent,
      'imageState',case when w.publication_consent then 'public_image' else 'no_image' end,
      'publicImagePath',case when w.publication_consent and w.public_release then w.public_image_path else null end)
      order by case when w.display_no~'^[0-9]+$' then w.display_no::integer else 2147483647 end,w.display_no)
      from public.exhibition_works w where w.event_id=e.id and w.status='accepted'),'[]'::jsonb) else '[]'::jsonb end) end
  from public.events e left join public.exhibition_publication_versions p on p.id=e.current_publication_version_id
  where e.exhibition_key=p_exhibition_key and e.genre='exhibition' and e.status='saved' and e.deleted_at is null
    and e.site_status in ('published','ended') and (e.exhibition_workflow_version<>2 or p.id is not null)
$$;

-- v2回答はcurrent Publication UUIDを固定し、そのPublication ItemのWork UUIDだけを許可する。
create or replace function public.submit_exhibition_survey(p_exhibition_key text,p_respondent_token text,p_language text,p_overall_comment text,p_selections jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype;v_response_id uuid;selection_count integer;distinct_count integer;invalid_count integer;respondent_hash text;
begin
  if char_length(coalesce(p_respondent_token,''))<32 or char_length(p_respondent_token)>200 then raise exception 'invalid respondent token' using errcode='22023'; end if;
  if p_language not in ('ja','en') or jsonb_typeof(p_selections)<>'array' then raise exception 'invalid request' using errcode='22023'; end if;
  if char_length(coalesce(p_overall_comment,''))>2000 then raise exception 'overall comment is too long' using errcode='22023'; end if;
  select * into e from public.events where exhibition_key=p_exhibition_key and genre='exhibition' and status='saved' and deleted_at is null for share;
  if e.id is null then raise exception 'unknown exhibition' using errcode='22023'; end if;
  if e.site_status<>'published' or not e.survey_enabled or e.survey_opens_at is null or e.survey_closes_at is null or now()<e.survey_opens_at or now()>e.survey_closes_at then raise exception 'survey is closed' using errcode='55000'; end if;
  select count(*),count(distinct item->>'work_id') into selection_count,distinct_count from jsonb_array_elements(p_selections)item;
  if selection_count<1 or selection_count>3 or selection_count<>distinct_count then raise exception 'select between one and three distinct works' using errcode='22023'; end if;
  if e.exhibition_workflow_version=2 then
    if e.current_publication_version_id is null then raise exception 'publication is unavailable' using errcode='55000'; end if;
    select count(*) into invalid_count from jsonb_array_elements(p_selections)item
      left join public.exhibition_publication_items i on i.publication_version_id=e.current_publication_version_id and i.work_id::text=item->>'work_id'
      where i.id is null or char_length(coalesce(item->>'comment',''))>1000;
  else
    select count(*) into invalid_count from jsonb_array_elements(p_selections)item left join public.exhibition_works w on w.id::text=item->>'work_id'
      where w.id is null or w.event_id<>e.id or w.status<>'accepted' or nullif(trim(w.display_no),'') is null or char_length(coalesce(item->>'comment',''))>1000;
  end if;
  if invalid_count>0 then raise exception 'invalid work or comment' using errcode='22023'; end if;
  respondent_hash:=encode(extensions.digest(p_respondent_token,'sha256'),'hex');
  insert into public.exhibition_survey_responses(event_id,respondent_hash,response_language,overall_comment,publication_version_id,workflow_version)
    values(e.id,respondent_hash,p_language,coalesce(p_overall_comment,''),case when e.exhibition_workflow_version=2 then e.current_publication_version_id else null end,
      case when e.exhibition_workflow_version=2 then 2 else 1 end) returning id into v_response_id;
  insert into public.exhibition_survey_selections(response_id,work_id,comment,position)
    select v_response_id,(item->>'work_id')::uuid,coalesce(item->>'comment',''),ordinality::smallint
    from jsonb_array_elements(p_selections) with ordinality as selection(item,ordinality);
  return v_response_id;
end;
$$;

create or replace function public.admin_get_exhibition_publication_actions_v2(p_event_id uuid default null)
returns table(priority integer,category text,action_type text,event_id uuid,event_title text,entry_id uuid,work_id uuid,member_id uuid,member_name text,
  snapshot_id uuid,case_id uuid,relevant_deadline timestamptz,workflow_state text,occurred_at timestamptz,reason text,context jsonb)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  return query select 45,'organizer_task','publication_refresh_available',e.id,e.title,null::uuid,null::uuid,null::uuid,''::text,
    x.id,null::uuid,null::timestamptz,'ready',x.created_at,'最新Exportに対応するPublicationがありません',
    jsonb_build_object('label','Public Publication readinessを確認してください','exportVersionId',x.id)
  from public.events e join lateral(select v.* from public.exhibition_export_versions v where v.event_id=e.id order by v.version_no desc limit 1)x on true
  where e.exhibition_workflow_version=2 and (p_event_id is null or e.id=p_event_id)
    and not exists(select 1 from public.exhibition_publication_versions p where p.source_export_version_id=x.id)
  union all
  select 46,'organizer_task','publication_switch_available',e.id,e.title,null::uuid,null::uuid,null::uuid,''::text,
    p.id,null::uuid,null::timestamptz,'ready',p.created_at,'最新ExportのPublicationがCurrentではありません',
    jsonb_build_object('label','Current Publicationへの切替要否を確認してください','publicationVersionId',p.id,'exportVersionId',x.id)
  from public.events e
  join lateral(select v.* from public.exhibition_export_versions v where v.event_id=e.id order by v.version_no desc limit 1)x on true
  join lateral(select q.* from public.exhibition_publication_versions q where q.source_export_version_id=x.id order by q.version_no desc limit 1)p on true
  where e.exhibition_workflow_version=2 and (p_event_id is null or e.id=p_event_id)
    and e.current_publication_version_id is distinct from p.id;
end;
$$;

alter table public.exhibition_publication_versions enable row level security;
alter table public.exhibition_publication_items enable row level security;
revoke all on public.exhibition_publication_versions,public.exhibition_publication_items from anon,authenticated;
grant select on public.exhibition_publication_versions,public.exhibition_publication_items to authenticated;
create policy exhibition_publication_versions_admin_select on public.exhibition_publication_versions for select to authenticated using(private.is_admin());
create policy exhibition_publication_items_admin_select on public.exhibition_publication_items for select to authenticated using(private.is_admin());

-- Publicationから参照済みの公開派生画像は、DB履歴だけでなくStorage objectも上書き・削除させない。
drop policy if exists exhibition_public_admin_update on storage.objects;
create policy exhibition_public_admin_update on storage.objects for update to authenticated
using(bucket_id='exhibition-public' and private.is_admin()
  and not exists(select 1 from public.exhibition_publication_items i where i.public_image_path=storage.objects.name)
  and not exists(select 1 from public.exhibition_publication_versions v where v.dm_image_path=storage.objects.name))
with check(bucket_id='exhibition-public' and private.is_admin());
drop policy if exists exhibition_public_admin_delete on storage.objects;
create policy exhibition_public_admin_delete on storage.objects for delete to authenticated
using(bucket_id='exhibition-public' and private.is_admin()
  and not exists(select 1 from public.exhibition_publication_items i where i.public_image_path=storage.objects.name)
  and not exists(select 1 from public.exhibition_publication_versions v where v.dm_image_path=storage.objects.name));

revoke all on function public.admin_get_exhibition_publication_readiness_v2(uuid),public.admin_set_exhibition_public_image_v2(uuid,text),
  public.admin_finalize_exhibition_publication_v2(uuid,text),public.admin_set_current_exhibition_publication_v2(uuid,text),
  public.admin_get_exhibition_publication_actions_v2(uuid) from public,anon;
grant execute on function public.admin_get_exhibition_publication_readiness_v2(uuid),public.admin_set_exhibition_public_image_v2(uuid,text),
  public.admin_finalize_exhibition_publication_v2(uuid,text),public.admin_set_current_exhibition_publication_v2(uuid,text),
  public.admin_get_exhibition_publication_actions_v2(uuid) to authenticated;
revoke execute on function private.prevent_exhibition_publication_mutation(),private.protect_current_publication_pointer_v2() from public,anon,authenticated;
