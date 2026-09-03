-- 写真展サイト側（旧Supabase）の SQL Editor で実行する。
-- 2026年度夏写真展の作品別感想と全体感想を、統合ポータル移行用に1つの表へ出力する。
-- 回答者IDは出力せず、response_id は重複取込防止用IDの生成にだけ利用する。

select
  'work'::text as comment_type,
  e.exhibition_key,
  r.id::text || ':work:' || s.work_id as legacy_comment_id,
  s.work_id,
  s.comment,
  r.submitted_at at time zone 'Asia/Tokyo' as submitted_at_jst
from public.survey_response_selections s
join public.survey_responses r
  on r.id = s.response_id
join public.survey_exhibitions e
  on e.id = r.exhibition_id
where e.exhibition_key = '2026-summer'
  and nullif(btrim(s.comment), '') is not null

union all

select
  'overall'::text as comment_type,
  e.exhibition_key,
  r.id::text || ':overall' as legacy_comment_id,
  null::text as work_id,
  r.overall_comment as comment,
  r.submitted_at at time zone 'Asia/Tokyo' as submitted_at_jst
from public.survey_responses r
join public.survey_exhibitions e
  on e.id = r.exhibition_id
where e.exhibition_key = '2026-summer'
  and nullif(btrim(r.overall_comment), '') is not null

order by submitted_at_jst, comment_type, work_id;
