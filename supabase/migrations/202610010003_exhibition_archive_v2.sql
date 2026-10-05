-- Workflow v2 Phase 10: immutable Archive。Legacy archive_* は変更しない。
create table public.exhibition_archive_versions(
 id uuid primary key default gen_random_uuid(),event_id uuid not null references public.events(id) on delete restrict,
 version_no integer not null check(version_no>=1),source_actual_version_id uuid not null references public.exhibition_actual_versions(id) on delete restrict,
 note text not null default '' check(char_length(note)<=3000),created_by text not null,created_at timestamptz not null default now(),
 finalized_by text not null,finalized_at timestamptz not null default now(),workflow_version smallint not null default 2 check(workflow_version=2),
 unique(event_id,version_no),unique(source_actual_version_id)
);
create table public.exhibition_archive_items(
 id uuid primary key default gen_random_uuid(),archive_version_id uuid not null references public.exhibition_archive_versions(id) on delete restrict,
 event_id uuid not null references public.events(id) on delete restrict,source_actual_item_id uuid not null references public.exhibition_actual_items(id) on delete restrict,
 source_actual_version_id uuid not null references public.exhibition_actual_versions(id) on delete restrict,
 source_layout_finalization_id uuid not null references public.exhibition_layout_finalizations(id) on delete restrict,
 work_id uuid not null references public.exhibition_works(id) on delete restrict,display_no integer not null check(display_no>=1),
 work_submission_snapshot_id uuid not null references public.exhibition_work_submission_snapshots(id) on delete restrict,
 caption_submission_snapshot_id uuid references public.exhibition_caption_submission_snapshots(id) on delete restrict,
 caption_exception boolean not null default false,caption_exception_reason text not null default '',
 planned_wall_id uuid not null references public.exhibition_walls(id) on delete restrict,planned_x_mm numeric(10,2) not null,planned_top_from_floor_mm numeric(10,2) not null,planned_z_order integer not null,
 actual_wall_id uuid not null references public.exhibition_walls(id) on delete restrict,actual_x_mm numeric(10,2) not null,actual_top_from_floor_mm numeric(10,2) not null,actual_z_order integer not null,
 title_ja text not null,display_name text not null default '',english_title_mode text, effective_english_title text not null default '',
 english_title_provenance text not null default '',english_title_derivation_id uuid references public.exhibition_caption_english_title_derivations(id) on delete restrict,
 medium text not null default '',medium_details text not null default '',camera text not null default '',lens text not null default '',film text not null default '',
 description_choice text not null default '',description_ja text not null default '',description_en text not null default '',
 instagram_qr_choice text not null default '',instagram_qr_info text not null default '',publication_consent boolean not null,
 image_state text not null check(image_state in('public_image','no_image')),public_image_path text,
 unique(archive_version_id,work_id),unique(archive_version_id,display_no),unique(archive_version_id,source_actual_item_id),
 check((image_state='no_image' and public_image_path is null) or (image_state='public_image' and publication_consent and public_image_path is not null)),
 check(not caption_exception or caption_submission_snapshot_id is null)
);
alter table public.events add column if not exists current_archive_version_id uuid references public.exhibition_archive_versions(id) on delete restrict;

create or replace function private.prevent_exhibition_archive_mutation_v2() returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception '確定済みArchive履歴は変更または削除できません。'; end;$$;
create trigger exhibition_archive_versions_immutable before update or delete on public.exhibition_archive_versions for each row execute function private.prevent_exhibition_archive_mutation_v2();
create trigger exhibition_archive_items_immutable before update or delete on public.exhibition_archive_items for each row execute function private.prevent_exhibition_archive_mutation_v2();
create or replace function private.protect_current_archive_pointer_v2() returns trigger language plpgsql security definer set search_path='' as $$
begin if new.exhibition_workflow_version=2 and new.current_archive_version_id is distinct from old.current_archive_version_id and coalesce(current_setting('app.exhibition_archive_rpc',true),'')<>'on' then raise exception 'Current Archiveは専用操作から変更してください。';end if;return new;end;$$;
create trigger zzz_events_protect_current_archive_v2 before update of current_archive_version_id on public.events for each row execute function private.protect_current_archive_pointer_v2();

create or replace function public.admin_get_exhibition_archive_readiness_v2(p_actual_version_id uuid)
returns table(item_id uuid,work_id uuid,display_no integer,ready boolean,reasons text[]) language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 if not exists(select 1 from public.exhibition_actual_versions v join public.events e on e.id=v.event_id where v.id=p_actual_version_id and v.state='finalized' and e.exhibition_workflow_version=2) then raise exception '確定済みWorkflow v2 Actualが見つかりません。';end if;
 return query select i.id,i.work_id,i.display_no,cardinality(r.x)=0,coalesce(r.x,'{}'::text[])
 from public.exhibition_actual_items i join public.exhibition_actual_versions v on v.id=i.actual_version_id
 left join public.exhibition_work_display_numbers n on n.work_id=i.work_id left join public.exhibition_work_submission_snapshots ws on ws.id=i.work_submission_snapshot_id
 left join public.exhibition_caption_submission_snapshots cs on cs.id=i.caption_submission_snapshot_id
 cross join lateral(select array_remove(array[
  case when i.actual_state<>'exhibited' then 'Not an archive candidate' end,
  case when n.display_no is distinct from i.display_no then 'Display number mismatch' end,
  case when ws.work_id is distinct from i.work_id or ws.event_id is distinct from i.event_id then 'Work Snapshot provenance mismatch' end,
  case when not i.caption_exception and (cs.id is null or cs.work_id<>i.work_id or cs.work_submission_snapshot_id<>ws.id or not exists(select 1 from public.exhibition_caption_reviews r where r.caption_snapshot_id=cs.id and r.result='accepted')) then 'Caption provenance mismatch' end,
  case when i.caption_exception and (cs.id is not null or trim(i.note)='') then 'Caption exception is invalid' end,
  case when cs.english_title_mode='organizer' and not exists(select 1 from public.exhibition_caption_english_title_derivations d where d.source_caption_snapshot_id=cs.id) then 'Organizer English title derivation is missing' end,
  case when i.actual_wall_id is null or i.actual_x_mm is null or i.actual_top_from_floor_mm is null or i.actual_z_order is null then 'Actual placement is missing' end
 ]::text[],null)x)r where i.actual_version_id=p_actual_version_id and i.actual_state='exhibited' order by i.display_no;
end;$$;

create or replace function public.admin_finalize_exhibition_archive_v2(p_actual_version_id uuid,p_note text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.exhibition_actual_versions%rowtype;e public.events%rowtype;aid uuid;nextv integer;actor text:=private.current_email();blocked integer;cnt integer;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into v from public.exhibition_actual_versions where id=p_actual_version_id for share;select * into e from public.events where id=v.event_id for update;
 if v.id is null or v.state<>'finalized' or e.exhibition_workflow_version<>2 then raise exception '確定済みWorkflow v2 Actualが必要です。';end if;
 if exists(select 1 from public.exhibition_archive_versions where source_actual_version_id=v.id) then raise exception 'このActualのArchiveは作成済みです。';end if;
 perform pg_advisory_xact_lock(hashtextextended(e.id::text||':archive',0));
 select count(*) into blocked from public.admin_get_exhibition_archive_readiness_v2(v.id) where not ready;if blocked>0 then raise exception 'Archiveを作成できません。未解決項目: %件',blocked;end if;
 select count(*) into cnt from public.exhibition_actual_items where actual_version_id=v.id and actual_state='exhibited';if cnt=0 then raise exception '実展示作品がありません。';end if;
 select coalesce(max(version_no),0)+1 into nextv from public.exhibition_archive_versions where event_id=e.id;
 insert into public.exhibition_archive_versions(event_id,version_no,source_actual_version_id,note,created_by,finalized_by) values(e.id,nextv,v.id,coalesce(p_note,''),actor,actor) returning id into aid;
 insert into public.exhibition_archive_items(archive_version_id,event_id,source_actual_item_id,source_actual_version_id,source_layout_finalization_id,work_id,display_no,
  work_submission_snapshot_id,caption_submission_snapshot_id,caption_exception,caption_exception_reason,planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,
  actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,title_ja,display_name,english_title_mode,effective_english_title,english_title_provenance,english_title_derivation_id,
  medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,publication_consent,image_state,public_image_path)
 select aid,e.id,i.id,v.id,v.source_layout_finalization_id,i.work_id,i.display_no,i.work_submission_snapshot_id,i.caption_submission_snapshot_id,i.caption_exception,case when i.caption_exception then i.note else '' end,
  i.planned_wall_id,i.planned_x_mm,i.planned_top_from_floor_mm,i.planned_z_order,i.actual_wall_id,i.actual_x_mm,i.actual_top_from_floor_mm,i.actual_z_order,ws.title,
  coalesce(cs.display_name,''),cs.english_title_mode,case when cs.english_title_mode='self' then cs.member_english_title when cs.english_title_mode='organizer' then d.english_title else '' end,
  case when cs.english_title_mode='self' then 'member_snapshot' when cs.english_title_mode='organizer' then 'organizer_derivation' else 'caption_exception' end,d.id,
  coalesce(cs.medium,''),coalesce(cs.medium_details,''),coalesce(cs.camera,''),coalesce(cs.lens,''),coalesce(cs.film,''),coalesce(cs.description_choice,''),coalesce(cs.description_ja,''),coalesce(cs.description_en,''),coalesce(cs.instagram_qr_choice,''),coalesce(cs.instagram_qr_info,''),ws.publication_consent,
  case when ws.publication_consent and pi.public_image_path is not null then 'public_image' else 'no_image' end,case when ws.publication_consent then pi.public_image_path else null end
 from public.exhibition_actual_items i join public.exhibition_work_submission_snapshots ws on ws.id=i.work_submission_snapshot_id
 left join public.exhibition_caption_submission_snapshots cs on cs.id=i.caption_submission_snapshot_id
 left join lateral(select x.* from public.exhibition_caption_english_title_derivations x where x.source_caption_snapshot_id=cs.id order by x.version_no desc limit 1)d on true
 left join lateral(select x.public_image_path from public.exhibition_publication_items x join public.exhibition_publication_versions pv on pv.id=x.publication_version_id
  where x.work_id=i.work_id and x.work_submission_snapshot_id=i.work_submission_snapshot_id and x.caption_submission_snapshot_id is not distinct from i.caption_submission_snapshot_id and x.image_state='public_image'
  order by pv.version_no desc limit 1)pi on true
 where i.actual_version_id=v.id and i.actual_state='exhibited' order by i.display_no;
 perform private.write_exhibition_workflow_audit(e.id,'archive_version',aid,'archive_finalized','admin',actor,p_note,'{}',jsonb_build_object('versionNo',nextv,'sourceActualVersionId',v.id,'itemCount',cnt));
 return jsonb_build_object('archiveVersionId',aid,'versionNo',nextv,'itemCount',cnt);
end;$$;

create or replace function public.admin_set_current_exhibition_archive_v2(p_archive_version_id uuid,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.exhibition_archive_versions%rowtype;e public.events%rowtype;oldid uuid;actor text:=private.current_email();
begin if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into a from public.exhibition_archive_versions where id=p_archive_version_id;select * into e from public.events where id=a.event_id for update;
 if a.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Archiveが見つかりません。';end if;oldid:=e.current_archive_version_id;perform set_config('app.exhibition_archive_rpc','on',true);update public.events set current_archive_version_id=a.id where id=e.id;perform set_config('app.exhibition_archive_rpc','off',true);
 perform private.write_exhibition_workflow_audit(e.id,'event',e.id,'current_archive_switched','admin',actor,p_reason,jsonb_build_object('archiveVersionId',oldid),jsonb_build_object('archiveVersionId',a.id));return jsonb_build_object('archiveVersionId',a.id,'versionNo',a.version_no);end;$$;

create or replace function public.admin_get_exhibition_archive_actions_v2(p_event_id uuid default null)
returns table(priority integer,category text,action_type text,event_id uuid,event_title text,entry_id uuid,work_id uuid,member_id uuid,member_name text,snapshot_id uuid,case_id uuid,relevant_deadline timestamptz,workflow_state text,occurred_at timestamptz,reason text,context jsonb)
language plpgsql stable security definer set search_path='' as $$ begin if not private.is_admin() then raise exception '管理者権限がありません。';end if;return query
 select 30,'organizer_task','archive_refresh_available',e.id,e.title,null::uuid,null::uuid,null::uuid,''::text,a.id,null::uuid,null::timestamptz,'ready',a.finalized_at,'確定Actualに対応するArchiveがありません',jsonb_build_object('label','ActualからArchiveを作成してください','actualVersionId',a.id)
 from public.events e join lateral(select v.* from public.exhibition_actual_versions v where v.event_id=e.id and v.state='finalized' order by v.version_no desc limit 1)a on true
 where e.exhibition_workflow_version=2 and (p_event_id is null or e.id=p_event_id) and not exists(select 1 from public.exhibition_archive_versions x where x.source_actual_version_id=a.id)
 union all select 31,'organizer_task','archive_switch_available',e.id,e.title,null::uuid,null::uuid,null::uuid,''::text,x.id,null::uuid,null::timestamptz,'ready',x.created_at,'最新ArchiveがCurrentではありません',jsonb_build_object('label','Current Archiveへの切替を確認してください','archiveVersionId',x.id)
 from public.events e join lateral(select z.* from public.exhibition_archive_versions z where z.event_id=e.id order by z.version_no desc limit 1)x on true where e.exhibition_workflow_version=2 and (p_event_id is null or e.id=p_event_id) and e.current_archive_version_id is distinct from x.id;end;$$;

alter table public.exhibition_archive_versions enable row level security;alter table public.exhibition_archive_items enable row level security;
revoke all on public.exhibition_archive_versions,public.exhibition_archive_items from anon,authenticated;grant select on public.exhibition_archive_versions,public.exhibition_archive_items to authenticated;
create policy exhibition_archive_versions_admin_select on public.exhibition_archive_versions for select to authenticated using(private.is_admin());
create policy exhibition_archive_items_admin_select on public.exhibition_archive_items for select to authenticated using(private.is_admin());
revoke all on function public.admin_get_exhibition_archive_readiness_v2(uuid),public.admin_finalize_exhibition_archive_v2(uuid,text),public.admin_set_current_exhibition_archive_v2(uuid,text),public.admin_get_exhibition_archive_actions_v2(uuid) from public,anon;
grant execute on function public.admin_get_exhibition_archive_readiness_v2(uuid),public.admin_finalize_exhibition_archive_v2(uuid,text),public.admin_set_current_exhibition_archive_v2(uuid,text),public.admin_get_exhibition_archive_actions_v2(uuid) to authenticated;
revoke execute on function private.prevent_exhibition_archive_mutation_v2(),private.protect_current_archive_pointer_v2() from public,anon,authenticated;
