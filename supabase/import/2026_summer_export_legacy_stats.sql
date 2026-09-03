-- 写真展サイト側（旧Supabase）の SQL Editor で実行する。
-- コメント未記入の投票も含め、2026年度夏写真展の正確な得票数を出力する。

with target as (
  select id, exhibition_key, work_ids
  from public.survey_exhibitions
  where exhibition_key = '2026-summer'
), response_total as (
  select count(*)::integer as response_count
  from public.survey_responses r
  join target e on e.id = r.exhibition_id
), work_list as (
  select work_id, ordinality
  from target,
       unnest(target.work_ids) with ordinality as listed(work_id, ordinality)
), vote_counts as (
  select s.work_id, count(*)::integer as favorite_count
  from public.survey_response_selections s
  join public.survey_responses r on r.id = s.response_id
  join target e on e.id = r.exhibition_id
  group by s.work_id
)
select
  '2026-summer'::text as exhibition_key,
  w.work_id,
  coalesce(v.favorite_count, 0) as favorite_count,
  totals.response_count,
  case
    when totals.response_count = 0 then 0
    else round(coalesce(v.favorite_count, 0)::numeric / totals.response_count * 100, 1)
  end as favorite_rate
from work_list w
cross join response_total totals
left join vote_counts v on v.work_id = w.work_id
order by w.ordinality;
