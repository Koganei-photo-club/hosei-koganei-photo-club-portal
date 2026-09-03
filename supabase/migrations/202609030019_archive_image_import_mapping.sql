-- 過去写真展の表示画像をファイル名で安全に照合するための対応情報。
alter table public.archive_works
  add column if not exists source_file_name text;

alter table public.archive_works
  drop constraint if exists archive_works_source_file_name_length;
alter table public.archive_works
  add constraint archive_works_source_file_name_length
  check (source_file_name is null or char_length(source_file_name) <= 500);

with source(legacy_work_uuid, source_file_name) as (
  values
    ('0af75d93-a725-4c8f-b0c1-b76b4662f96d', '904eb381-e301-454d-bf76-993c765c232e_高野　凌志_作品1.jpg'),
    ('0477b9c7-ae8f-486c-8a44-87f26264eda7', 'e8ce8fce-f23a-4dca-a42f-513c61850ccd_丸山　理紗_作品3.jpg'),
    ('79d62472-9b23-49d7-a0d2-003fdaea7d74', 'e8ce8fce-f23a-4dca-a42f-513c61850ccd_丸山　理紗_作品2.jpg'),
    ('41344c4d-43ad-461c-9879-160b9f96bcf7', 'd5918333-98c8-4bce-b2d4-dd551112f786_疋田　悠真_作品3.jpg'),
    ('fdc33328-b1a4-4511-867d-1d4443f5008b', '6ae0a220-82ed-4f07-a05d-1898d3344d68_藤吉　孝幸_作品2.jpg'),
    ('c7ea6160-cf26-4b41-99df-c75ed9bb338c', '9c7f5b06-22d7-4027-86bd-39321b072d38_石井　壱宝_作品3.jpg'),
    ('4453ef47-5835-4a67-a616-9a4f2a66bcd5', '387b3fe0-0091-45eb-9c2a-2bcac62c57a5_谷口　隆之介_作品3.jpg'),
    ('8dc58946-477b-400e-a4d3-b1ba05850184', '9c7f5b06-22d7-4027-86bd-39321b072d38_石井　壱宝_作品1.jpg'),
    ('d193c555-134f-4ec2-94b6-f433946411c7', 'd5918333-98c8-4bce-b2d4-dd551112f786_疋田　悠真_作品1.jpg'),
    ('d3d1cd92-5ee0-43ec-a6a3-e146cca9a5e2', '9c7f5b06-22d7-4027-86bd-39321b072d38_石井　壱宝_作品2.jpg'),
    ('33687fc6-52bb-4ad6-a5ef-cfdf2952b72f', '6ae0a220-82ed-4f07-a05d-1898d3344d68_藤吉　孝幸_作品3.jpg'),
    ('0097402f-175a-4179-9a61-6faddfe4aee4', 'eb4b4d0c-37b2-4954-8d6d-4d0bc911d7c9_飯田　智久_作品2.jpg'),
    ('a6291be6-725d-4b5d-9ec3-d448d6a2b9e1', 'e8ce8fce-f23a-4dca-a42f-513c61850ccd_丸山　理紗_作品1.jpg'),
    ('46efc28d-ef47-4f74-a9f6-df0ae78aa1b3', 'b24dc9d6-bfdb-48d0-9ccf-120f5357c1c5_中村　充希_作品2.jpg'),
    ('cd1ced30-b88b-4f18-b78e-e66ddc4397f0', 'eb4b4d0c-37b2-4954-8d6d-4d0bc911d7c9_飯田　智久_作品3.jpg'),
    ('c84620ec-291a-4fb9-876c-a2d2d8a36886', '387b3fe0-0091-45eb-9c2a-2bcac62c57a5_谷口　隆之介_作品2.jpg'),
    ('a7069631-9720-442b-85ea-7ef5841232f9', '6ae0a220-82ed-4f07-a05d-1898d3344d68_藤吉　孝幸_作品1.jpg'),
    ('3c867f56-dbd2-4dca-95f2-4f35eb533966', '77e3f08e-fc6c-4712-9baa-bc6558902656_杉本　奏_作品1.jpg'),
    ('42060d83-4732-4bc3-b52e-f00a8a2e578c', '77e3f08e-fc6c-4712-9baa-bc6558902656_杉本　奏_作品3.jpg'),
    ('2a4e84f1-caef-44f1-bfab-7d34408cab02', 'eb4b4d0c-37b2-4954-8d6d-4d0bc911d7c9_飯田　智久_作品1.jpg'),
    ('948c3893-e322-43b5-87cc-5f6d5fc30149', '77e3f08e-fc6c-4712-9baa-bc6558902656_杉本　奏_作品2.jpg'),
    ('0254bac6-f1fa-444b-81fc-884a7d2d303d', 'd5918333-98c8-4bce-b2d4-dd551112f786_疋田　悠真_作品2.jpg'),
    ('aea3a856-07ad-43cb-9fba-72a6e9687c0f', 'b24dc9d6-bfdb-48d0-9ccf-120f5357c1c5_中村　充希_作品1.png'),
    ('45158f79-7863-4893-9a90-d4475fc37bea', '2f3a2ca8-ead5-4fb0-b832-74c54d7dc930_多田　光希_作品2.jpg'),
    ('8d6d1467-edb1-4e8e-9baf-d4ba9f5f9434', 'b24dc9d6-bfdb-48d0-9ccf-120f5357c1c5_中村　充希_作品3.jpg'),
    ('ec8f44aa-e5ab-4d2a-91dc-16b346108303', '2f3a2ca8-ead5-4fb0-b832-74c54d7dc930_多田　光希_作品1.jpg'),
    ('60287df3-b478-44f1-8813-5abb76b4dc71', '387b3fe0-0091-45eb-9c2a-2bcac62c57a5_谷口　隆之介_作品1.jpg'),
    ('50237d75-b56b-4216-baf0-5f9b037e8376', 'cbd6860b-47de-44a3-92db-6455310dd69f_佐瀬　みなみ_作品1.jpg')
)
update public.archive_works work
set source_file_name = source.source_file_name
from source
where work.legacy_work_uuid = source.legacy_work_uuid;

select
  exhibition.exhibition_key,
  count(*) as work_count,
  count(work.source_file_name) as mapped_file_count,
  count(work.image_path) as uploaded_image_count
from public.archive_works work
join public.archive_exhibitions exhibition on exhibition.id = work.exhibition_id
where exhibition.exhibition_key = '2026-summer'
group by exhibition.exhibition_key;

