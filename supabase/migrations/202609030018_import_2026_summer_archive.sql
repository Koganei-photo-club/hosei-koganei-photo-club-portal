-- 2026年度夏写真展「夏彩」を統合ポータルの写真展マイページへ取り込む。
-- 統合ポータル側（新Supabase）の SQL Editor で実行する。

begin;

alter table public.archive_works
  add column if not exists publication_consent boolean;
alter table public.archive_work_comments
  add column if not exists legacy_comment_id text;
alter table public.archive_work_comments
  add column if not exists submitted_at timestamptz;
alter table public.archive_overall_comments
  add column if not exists legacy_comment_id text;

create unique index if not exists archive_work_comments_legacy_id_unique
  on public.archive_work_comments(legacy_comment_id)
  where legacy_comment_id is not null;
create unique index if not exists archive_overall_comments_legacy_id_unique
  on public.archive_overall_comments(legacy_comment_id)
  where legacy_comment_id is not null;

do $$
declare
  missing_emails text;
begin
  with source(email) as (
    values
      ('ryoji.takano.2e@stu.hosei.ac.jp'),
      ('risa.maruyama.6s@stu.hosei.ac.jp'),
      ('yuma.hikita.4k@stu.hosei.ac.jp'),
      ('takayuki.fujiyoshi.2r@stu.hosei.ac.jp'),
      ('kazutaka.ishii.6n@stu.hosei.ac.jp'),
      ('ryunosuke.taniguchi.5j@stu.hosei.ac.jp'),
      ('tomohisa.iida.6d@stu.hosei.ac.jp'),
      ('mitsuki.nakamura.6i@stu.hosei.ac.jp'),
      ('kanade.sugimoto.5p@stu.hosei.ac.jp'),
      ('koki.tada.2g@stu.hosei.ac.jp'),
      ('minami.sase.2z@stu.hosei.ac.jp')
  )
  select string_agg(source.email, ', ' order by source.email)
    into missing_emails
  from source
  left join public.members member on member.email = source.email
  where member.id is null;

  if missing_emails is not null then
    raise exception '現在の部員名簿に見つからない出展者メールがあります: %', missing_emails;
  end if;
end;
$$;

insert into public.archive_exhibitions (
  exhibition_key, title, response_count, published, imported_at
)
values ('2026-summer', '2026年度 夏写真展「夏彩」', 37, true, now())
on conflict (exhibition_key) do update
set title = excluded.title,
    response_count = excluded.response_count,
    published = excluded.published,
    imported_at = excluded.imported_at;

with source(
  legacy_work_uuid, owner_email, display_no, title,
  publication_consent, favorite_count, response_count, favorite_rate
) as (
  values
    ('0af75d93-a725-4c8f-b0c1-b76b4662f96d', 'ryoji.takano.2e@stu.hosei.ac.jp', '1', '藍', true, 6, 37, 16.2),
    ('0477b9c7-ae8f-486c-8a44-87f26264eda7', 'risa.maruyama.6s@stu.hosei.ac.jp', '2', '優しさのなかに', true, 8, 37, 21.6),
    ('79d62472-9b23-49d7-a0d2-003fdaea7d74', 'risa.maruyama.6s@stu.hosei.ac.jp', '3', 'ひなたの隙間', true, 7, 37, 18.9),
    ('41344c4d-43ad-461c-9879-160b9f96bcf7', 'yuma.hikita.4k@stu.hosei.ac.jp', '4', '新緑の香りを感じて', false, 0, 37, 0),
    ('fdc33328-b1a4-4511-867d-1d4443f5008b', 'takayuki.fujiyoshi.2r@stu.hosei.ac.jp', '5', 'HEAVY', true, 2, 37, 5.4),
    ('c7ea6160-cf26-4b41-99df-c75ed9bb338c', 'kazutaka.ishii.6n@stu.hosei.ac.jp', '6', 'ゴーザフォス', true, 1, 37, 2.7),
    ('4453ef47-5835-4a67-a616-9a4f2a66bcd5', 'ryunosuke.taniguchi.5j@stu.hosei.ac.jp', '7', 'ふじ', true, 4, 37, 10.8),
    ('8dc58946-477b-400e-a4d3-b1ba05850184', 'kazutaka.ishii.6n@stu.hosei.ac.jp', '8', '夜の向こうへ', true, 5, 37, 13.5),
    ('d193c555-134f-4ec2-94b6-f433946411c7', 'yuma.hikita.4k@stu.hosei.ac.jp', '9', '光にのって', false, 0, 37, 0),
    ('d3d1cd92-5ee0-43ec-a6a3-e146cca9a5e2', 'kazutaka.ishii.6n@stu.hosei.ac.jp', '10', '宵のTOKYO', true, 0, 37, 0),
    ('33687fc6-52bb-4ad6-a5ef-cfdf2952b72f', 'takayuki.fujiyoshi.2r@stu.hosei.ac.jp', '11', 'TRACE', true, 2, 37, 5.4),
    ('0097402f-175a-4179-9a61-6faddfe4aee4', 'tomohisa.iida.6d@stu.hosei.ac.jp', '12', '藤はなお', true, 12, 37, 32.4),
    ('a6291be6-725d-4b5d-9ec3-d448d6a2b9e1', 'risa.maruyama.6s@stu.hosei.ac.jp', '13', '秘密の夜', true, 6, 37, 16.2),
    ('46efc28d-ef47-4f74-a9f6-df0ae78aa1b3', 'mitsuki.nakamura.6i@stu.hosei.ac.jp', '14', 'F(low)Light', true, 5, 37, 13.5),
    ('cd1ced30-b88b-4f18-b78e-e66ddc4397f0', 'tomohisa.iida.6d@stu.hosei.ac.jp', '15', '移ろい', true, 9, 37, 24.3),
    ('c84620ec-291a-4fb9-876c-a2d2d8a36886', 'ryunosuke.taniguchi.5j@stu.hosei.ac.jp', '16', 'SsEhTiSbUuNyAa', true, 2, 37, 5.4),
    ('a7069631-9720-442b-85ea-7ef5841232f9', 'takayuki.fujiyoshi.2r@stu.hosei.ac.jp', '17', 'BANK', true, 0, 37, 0),
    ('3c867f56-dbd2-4dca-95f2-4f35eb533966', 'kanade.sugimoto.5p@stu.hosei.ac.jp', '18', '黄色の記憶', true, 4, 37, 10.8),
    ('42060d83-4732-4bc3-b52e-f00a8a2e578c', 'kanade.sugimoto.5p@stu.hosei.ac.jp', '19', '夏をつむ', true, 5, 37, 13.5),
    ('2a4e84f1-caef-44f1-bfab-7d34408cab02', 'tomohisa.iida.6d@stu.hosei.ac.jp', '20', '薄明に咲く', true, 3, 37, 8.1),
    ('948c3893-e322-43b5-87cc-5f6d5fc30149', 'kanade.sugimoto.5p@stu.hosei.ac.jp', '21', '小さな秋の入り口', true, 5, 37, 13.5),
    ('0254bac6-f1fa-444b-81fc-884a7d2d303d', 'yuma.hikita.4k@stu.hosei.ac.jp', '22', '朝日を浴びて', false, 0, 37, 0),
    ('aea3a856-07ad-43cb-9fba-72a6e9687c0f', 'mitsuki.nakamura.6i@stu.hosei.ac.jp', '23', 'せいかつかん', true, 2, 37, 5.4),
    ('45158f79-7863-4893-9a90-d4475fc37bea', 'koki.tada.2g@stu.hosei.ac.jp', '24', '閑寂', true, 0, 37, 0),
    ('8d6d1467-edb1-4e8e-9baf-d4ba9f5f9434', 'mitsuki.nakamura.6i@stu.hosei.ac.jp', '25', '3', true, 3, 37, 8.1),
    ('ec8f44aa-e5ab-4d2a-91dc-16b346108303', 'koki.tada.2g@stu.hosei.ac.jp', '26', '街影', true, 6, 37, 16.2),
    ('60287df3-b478-44f1-8813-5abb76b4dc71', 'ryunosuke.taniguchi.5j@stu.hosei.ac.jp', '27', '親子', true, 2, 37, 5.4),
    ('50237d75-b56b-4216-baf0-5f9b037e8376', 'minami.sase.2z@stu.hosei.ac.jp', '28', '個体群', false, 2, 37, 5.4)
)
insert into public.archive_works (
  legacy_work_uuid, exhibition_id, owner_member_id, display_no, title,
  image_path, image_visible, published, publication_consent,
  favorite_count, response_count, favorite_rate, imported_at
)
select
  source.legacy_work_uuid,
  exhibition.id,
  member.id,
  source.display_no,
  source.title,
  null,
  false,
  true,
  source.publication_consent,
  source.favorite_count,
  source.response_count,
  source.favorite_rate,
  now()
from source
join public.members member on member.email = source.owner_email
join public.archive_exhibitions exhibition
  on exhibition.exhibition_key = '2026-summer'
on conflict (legacy_work_uuid) do update
set exhibition_id = excluded.exhibition_id,
    owner_member_id = excluded.owner_member_id,
    display_no = excluded.display_no,
    title = excluded.title,
    published = excluded.published,
    publication_consent = excluded.publication_consent,
    favorite_count = excluded.favorite_count,
    response_count = excluded.response_count,
    favorite_rate = excluded.favorite_rate,
    imported_at = excluded.imported_at;

with source(legacy_comment_id, display_no, comment, submitted_at) as (
  values
    ('9cc75133-19a2-4829-b217-d59cbc15c873:work:26', '26', '見るだけで涙が出た', '2026-08-23 15:48:26.882881+09'),
    ('1ffbfd8c-83a9-4f91-8cb3-3c67a155abb9:work:3', '3', 'ﾈｺﾁｬﾝｶｱｲｲﾆ!', '2026-08-23 15:50:07.292847+09'),
    ('68b609d4-7246-4639-ba60-67de9c814892:work:15', '15', '水彩画みたいな露光でとても好きです', '2026-08-23 16:01:51.652242+09'),
    ('68b609d4-7246-4639-ba60-67de9c814892:work:27', '27', '人間とは違う生命感、目がとても生活', '2026-08-23 16:01:51.652242+09'),
    ('68b609d4-7246-4639-ba60-67de9c814892:work:5', '5', '重量感確かに感じました', '2026-08-23 16:01:51.652242+09'),
    ('143e334b-7d22-4f3a-8814-29b04e0f50ac:work:12', '12', 'ワンダフル', '2026-08-23 16:03:23.326684+09'),
    ('143e334b-7d22-4f3a-8814-29b04e0f50ac:work:13', '13', 'キュート', '2026-08-23 16:03:23.326684+09'),
    ('143e334b-7d22-4f3a-8814-29b04e0f50ac:work:7', '7', 'アメイジング', '2026-08-23 16:03:23.326684+09'),
    ('69c31c81-a25c-4bc7-a5be-9b8bc6235185:work:1', '1', '質感がよく出ていて美しい', '2026-08-23 16:20:52.598554+09'),
    ('69c31c81-a25c-4bc7-a5be-9b8bc6235185:work:15', '15', '半光沢くらいにプリントしたらもっと良いような気がします', '2026-08-23 16:20:52.598554+09'),
    ('69c31c81-a25c-4bc7-a5be-9b8bc6235185:work:25', '25', '垢抜けて良い感じ！', '2026-08-23 16:20:52.598554+09'),
    ('9af51c3a-3839-4139-bc6c-9ef25ec38c89:work:19', '19', 'これこそ夏ですというような明るさとひまわりと蜂がすべて入っててとても綺麗だと思いました。', '2026-08-23 16:27:17.229797+09'),
    ('9af51c3a-3839-4139-bc6c-9ef25ec38c89:work:25', '25', 'ジュースの3とストローを加えた方の形の3、時間が3時台のも面白い！', '2026-08-23 16:27:17.229797+09'),
    ('9af51c3a-3839-4139-bc6c-9ef25ec38c89:work:27', '27', '親子の表情がとても素敵です。チンパンジーのカメラ目線なのもとっても良いです🎶', '2026-08-23 16:27:17.229797+09'),
    ('fc8dae90-87ec-42bf-bfda-347d132d148c:work:5', '5', '迫力がすごい！！❤️', '2026-08-23 16:28:46.884469+09'),
    ('9a53d34d-3a70-4550-8637-e63a82b6ad6c:work:12', '12', '今もなお藤に残る厳かさが溢れていて、良い意味で重さを感じられる写真だと感じました。', '2026-08-23 18:52:19.105+09'),
    ('8145bbf7-dac8-4c14-888e-6e4e33a371ae:work:18', '18', '被写界深度をうまく活用したいい写真だと思います
右から左にかけての遠近感がものすごく好きです。', '2026-08-23 20:41:48.246137+09'),
    ('8145bbf7-dac8-4c14-888e-6e4e33a371ae:work:19', '19', 'ほんの少し真ん中によっているひまわりが
ひまわりの向いている向きも相まって素晴らしいと思います。', '2026-08-23 20:41:48.246137+09'),
    ('8145bbf7-dac8-4c14-888e-6e4e33a371ae:work:21', '21', '日々の生活で目を凝らさないと見えない小さな入り口を捉えた素晴らしい写真だと思います。ベンチの2本足が斜めっている感じもすごく面白いと思います。', '2026-08-23 20:41:48.246137+09'),
    ('64d68b4f-8b4f-4cce-a399-1a3cd729b99c:work:1', '1', 'ハイライトとパープルの残し方がアクセントになってていいなと思いました。', '2026-08-24 12:40:28.02864+09'),
    ('64d68b4f-8b4f-4cce-a399-1a3cd729b99c:work:2', '2', '編集ちゃんと頑張ってて良かった', '2026-08-24 12:40:28.02864+09'),
    ('64d68b4f-8b4f-4cce-a399-1a3cd729b99c:work:21', '21', '秋っぽくていいと思いました。', '2026-08-24 12:40:28.02864+09'),
    ('2719dacf-03c3-42b6-841e-ea9df7f3f757:work:12', '12', '構図が綺麗', '2026-08-24 15:39:48.76411+09'),
    ('2719dacf-03c3-42b6-841e-ea9df7f3f757:work:16', '16', '物が多いのにそれがまとまっていて好き', '2026-08-24 15:39:48.76411+09'),
    ('752b0a28-13cb-483a-a185-16c41928ff36:work:1', '1', '背景も簡潔で青と緑のコントラストをうまく引き出していた。紫陽花は優しいふわふわした雰囲気の作品が多い中、とても印象的な作品でした。静かでしっとりしているのに力強さも感じる雰囲気だった。', '2026-08-25 13:23:34.719405+09'),
    ('752b0a28-13cb-483a-a185-16c41928ff36:work:11', '11', 'ディスクリプションの詩のような雰囲気に魅力を感じた。', '2026-08-25 13:23:34.719405+09'),
    ('752b0a28-13cb-483a-a185-16c41928ff36:work:26', '26', '光と影でニ分割の構図を作っている。
タイトルには影という字が入っていたので感慨深いた感じた。', '2026-08-25 13:23:34.719405+09'),
    ('35f0008e-63d9-4472-9f6c-0f20f1c31cc2:work:2', '2', '綺麗', '2026-08-25 14:00:39.868173+09'),
    ('35f0008e-63d9-4472-9f6c-0f20f1c31cc2:work:7', '7', '構図がいいと思った', '2026-08-25 14:00:39.868173+09'),
    ('35f0008e-63d9-4472-9f6c-0f20f1c31cc2:work:8', '8', '光の入り方がいいと思った', '2026-08-25 14:00:39.868173+09'),
    ('3455ab8e-40ed-4bd2-ad15-e2ded10580c9:work:12', '12', '構図といい光の当たり方ととても綺麗に撮れていると思います。', '2026-08-25 14:32:24.899646+09'),
    ('f50b6ba9-b5c4-4eca-b06d-9a8012e915bf:work:14', '14', '超広角レンズの使い方の大正解って感じですね', '2026-08-25 15:23:32.734984+09'),
    ('694b5b2c-d844-489c-8685-335cb1f215e8:work:18', '18', '黄色の眩しさが残っていて素敵でした', '2026-08-25 15:53:30.838322+09'),
    ('694b5b2c-d844-489c-8685-335cb1f215e8:work:23', '23', 'みつきさんの日常写真大好きです！', '2026-08-25 15:53:30.838322+09'),
    ('694b5b2c-d844-489c-8685-335cb1f215e8:work:28', '28', '素敵なブックでした！！後輩さんの見開き2枚のページが素敵でした', '2026-08-25 15:53:30.838322+09')
)
insert into public.archive_work_comments (
  work_id, legacy_comment_id, comment, submitted_at, imported_at
)
select work.id, source.legacy_comment_id, source.comment,
       source.submitted_at::timestamptz, now()
from source
join public.archive_exhibitions exhibition
  on exhibition.exhibition_key = '2026-summer'
join public.archive_works work
  on work.exhibition_id = exhibition.id
 and work.display_no = source.display_no
on conflict (legacy_comment_id) where legacy_comment_id is not null do update
set work_id = excluded.work_id,
    comment = excluded.comment,
    submitted_at = excluded.submitted_at,
    imported_at = excluded.imported_at;

with source(legacy_comment_id, comment, submitted_at) as (
  values
    ('69c31c81-a25c-4bc7-a5be-9b8bc6235185:overall', '丁寧に展示されていて気持ちよく拝見できました', '2026-08-23 16:20:52.598554+09'),
    ('9a53d34d-3a70-4550-8637-e63a82b6ad6c:overall', '夏の涼しさや、部員の方の好む被写体の魅力を感じられて、場の雰囲気も感じられる展示でした。', '2026-08-23 18:52:19.105+09'),
    ('752b0a28-13cb-483a-a185-16c41928ff36:overall', 'バスの写真でバスが走っているという時間の流れを感じ取れたのでよかった。', '2026-08-25 13:23:34.719405+09'),
    ('3455ab8e-40ed-4bd2-ad15-e2ded10580c9:overall', '使用機材など書かれていて見やすかった。', '2026-08-25 14:32:24.899646+09'),
    ('b5e55428-1079-4832-955e-18a8bf1cdc2f:overall', '学生たちの短い青春が1フレームにおさめられていて儚い。', '2026-08-25 15:18:58.447702+09'),
    ('8648daaf-2acb-4a4a-8176-5c04f351850a:overall', ':)', '2026-08-25 16:43:00.530937+09')
)
insert into public.archive_overall_comments (
  exhibition_id, legacy_comment_id, comment, submitted_at, imported_at
)
select exhibition.id, source.legacy_comment_id, source.comment,
       source.submitted_at::timestamptz, now()
from source
join public.archive_exhibitions exhibition
  on exhibition.exhibition_key = '2026-summer'
on conflict (legacy_comment_id) where legacy_comment_id is not null do update
set exhibition_id = excluded.exhibition_id,
    comment = excluded.comment,
    submitted_at = excluded.submitted_at,
    imported_at = excluded.imported_at;

commit;

select
  exhibition.exhibition_key,
  exhibition.response_count,
  count(distinct work.id) as work_count,
  count(distinct work.owner_member_id) as exhibitor_count,
  count(distinct comment.id) as work_comment_count,
  count(distinct overall.id) as overall_comment_count
from public.archive_exhibitions exhibition
left join public.archive_works work on work.exhibition_id = exhibition.id
left join public.archive_work_comments comment on comment.work_id = work.id
left join public.archive_overall_comments overall on overall.exhibition_id = exhibition.id
where exhibition.exhibition_key = '2026-summer'
group by exhibition.id;

