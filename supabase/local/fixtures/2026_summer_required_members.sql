-- Local-only prerequisites for 202609030018_import_2026_summer_archive.sql.
-- These are deliberately not Production migrations and contain only the
-- minimum columns required by the existing archive import.
insert into public.members(member_no,email,name,active)
values
  ('member-991001','ryoji.takano.2e@stu.hosei.ac.jp','Local Fixture 01',true),
  ('member-991002','risa.maruyama.6s@stu.hosei.ac.jp','Local Fixture 02',true),
  ('member-991003','yuma.hikita.4k@stu.hosei.ac.jp','Local Fixture 03',true),
  ('member-991004','takayuki.fujiyoshi.2r@stu.hosei.ac.jp','Local Fixture 04',true),
  ('member-991005','kazutaka.ishii.6n@stu.hosei.ac.jp','Local Fixture 05',true),
  ('member-991006','ryunosuke.taniguchi.5j@stu.hosei.ac.jp','Local Fixture 06',true),
  ('member-991007','tomohisa.iida.6d@stu.hosei.ac.jp','Local Fixture 07',true),
  ('member-991008','mitsuki.nakamura.6i@stu.hosei.ac.jp','Local Fixture 08',true),
  ('member-991009','kanade.sugimoto.5p@stu.hosei.ac.jp','Local Fixture 09',true),
  ('member-991010','koki.tada.2g@stu.hosei.ac.jp','Local Fixture 10',true),
  ('member-991011','minami.sase.2z@stu.hosei.ac.jp','Local Fixture 11',true)
on conflict (email) do nothing;

