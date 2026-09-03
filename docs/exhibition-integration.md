# 写真展作品連携仕様

統合ポータルを作品情報の正本とし、写真展サイトと展示用管理アプリへは管理画面から出力するCSVを渡します。

## 識別子

- `WorkUuid`: `exhibition_works.id`。システム間で作品を特定する恒久IDです。
- `DisplayNo`: 会場および来場者アンケートで使用する作品番号です。
- `SubmissionSlot`: 出展者ごとの固定作品枠（作品1、作品2、作品3）です。`DisplayNo`とは別物です。
- `MemberId`: 恒久部員IDです。メールアドレスは連携CSVへ出力しません。

画像を差し替えても`WorkUuid`、`DisplayNo`、`SubmissionSlot`は変わりません。

## CSV列

| 列 | 内容 |
| --- | --- |
| WorkUuid | 恒久作品ID |
| ExhibitionEventId | 統合ポータル内の写真展ID |
| DisplayNo | 展示・アンケート用作品番号 |
| SubmissionSlot | 出展者ごとの作品枠 |
| MemberId / MemberName | 出展者情報 |
| Title | 作品名 |
| Artist / Camera / LensOther / Description | キャプション |
| Orientation | `portrait` または `landscape` |
| PrintSize / PrintSizeDetail | 印刷サイズと補足 |
| OriginalFileName | 管理・ダウンロード用原画像名 |
| OriginalStoragePath | 統合Supabase内の非公開原画像パス |
| InstagramQrPath | 統合Supabase内の非公開QR画像パス |
| Status | `draft`、`submitted`、`accepted`、`rejected` |

## 運用上の注意

- 写真展サイトへ反映する対象は、原則として`Status=accepted`かつ`DisplayNo`が設定済みの作品だけです。
- `OriginalStoragePath`は非公開パスです。写真展サイトへ直接記載しません。
- 公開サイトには、原画像ではなく、縮小・メタデータ除去・必要な透かし処理を行った公開用画像だけを配置します。
- 来場者アンケート側では`DisplayNo`だけでなく`WorkUuid`も保持し、作品番号を変更しても同じ作品として追跡できる形を目標とします。
