# メンテナンスモード機能 実装計画書

## 1. 目的

写真技術研究会ポータルに、一般利用者の通常利用を安全に遮断しつつ、承認されたメンテナンス管理者が通常ポータル・管理画面へアクセスして動作確認や保守作業を行える「メンテナンスモード」を実装する。

本機能は、単なる画面表示ではなく、以下を一体として実現する。

- 一般利用者の通常画面へのアクセス制御
- ログイン画面でのメンテナンス予定・実施中情報の公開
- メンテナンスの予定作成、編集、開始、終了、履歴管理
- 複数管理者による競合防止
- 緊急終了
- 状態不整合の検出・診断・修復
- 例外操作の監査記録
- 通信障害・曖昧な処理結果に対する再確認
- PC / スマートフォン双方で利用可能な管理UI

本計画書は実装指示書である。実装前に必ず既存リポジトリ、既存Supabaseスキーマ、RLS、認証方式、管理画面、UIコンポーネント、日時処理、既存イベント管理の実装を調査し、本計画の要件を満たしつつ既存設計へ整合させること。

---

## 2. 実装時の重要原則

### 2.1 既存実装を先に調査する

実装前に少なくとも以下を確認する。

- フロントエンドのディレクトリ構成
- 認証処理、ログイン後の遷移
- 既存の `admins` 利用箇所
- Supabaseクライアント初期化箇所
- 既存RLSポリシー
- 既存RPC / PostgreSQL function の有無と命名規則
- migration管理方法
- 既存管理画面のレイアウト、フォーム、カード、ボタン、モーダル等
- 全体会・合宿・写真展の予定データ構造
- 日時の保存・表示方式
- 既存エラー画面・共通レイアウト
- テスト方法、lint、build、型チェック等

本計画書では既存ファイル名や既存コンポーネント名を推測しない。実装先はリポジトリ調査後に決定すること。

### 2.2 実装完了後も commit / push しない

Codex Work は以下を行わないこと。

- `git commit`
- `git push`
- PR作成

変更・検証までを担当し、コミットとpushはユーザー本人が行う。

### 2.3 v1 の範囲

本機能のv1では、主として

- 画面アクセス制御
- メンテナンス状態の安全な参照
- メンテナンス設定自体のRLS保護

を対象とする。

既存の全機能テーブルに対して「メンテナンス中は一般利用者のRLSを全面的に拒否する」ような大規模改修は行わない。

したがって本機能は「ポータルUI上の運用アクセス制御」であり、「すべてのSupabase API呼び出しをメンテナンス中に完全遮断する」ことを保証するものではない。

---

# 3. 利用者区分

## 3.1 一般利用者

通常の認証済みポータル利用者。

メンテナンス中は通常ポータルへ入れない。

## 3.2 既存管理者

既存 `admins` テーブルに登録されている役員等。

既存管理画面への権限は従来どおり。

ただし、`maintenance_admins` に登録されていない場合は、メンテナンス中の通常ポータルをバイパスできない。

## 3.3 メンテナンス管理者

新規 `maintenance_admins` に登録され、`active = true` の認証済みユーザー。

可能な操作:

- メンテナンス中の通常ポータル利用
- メンテナンス管理画面へのアクセス
- メンテナンス予定の作成、編集、削除
- 開始、終了
- 緊急終了
- 診断・修復
- 履歴閲覧

メンテナンス管理権限は `members` や `membership_year` に依存させない。

---

# 4. データモデル

## 4.1 `maintenance_admins`

概念スキーマ:

```text
maintenance_admins
- id uuid PK
- email unique NOT NULL
- name NOT NULL
- role_name NOT NULL
- active NOT NULL
- created_at NOT NULL
```

要件:

- メールアドレスで認証ユーザーと照合する。
- `active = true` のみ現在のメンテナンス管理者として扱う。
- 過去の操作履歴を保持するため、`active = false` のレコードも削除前提にしない。
- 過去の開始者・終了者・修復対象の人物選択では inactive も参照可能とする。

---

## 4.2 `maintenances`

概念スキーマ:

```text
maintenances
- id
- title
- status
- enabled
- scheduled_start_at
- scheduled_end_at
- started_at
- ended_at
- started_at_is_estimated
- ended_at_is_estimated
- message
- contact
- description
- created_by
- updated_by
- started_by
- ended_by
- client_request_id
- display_order
- created_at
- updated_at
```

既存DBの命名規則に合わせて最終型・制約・名称を決めること。

### status

許可値:

```text
scheduled
in_progress
completed
```

### enabledとの対応

```text
scheduled   -> enabled = false
in_progress -> enabled = true
completed   -> enabled = false
```

DB側で整合性を保証する。

### 状態ごとの正規状態

#### scheduled

```text
scheduled_start_at != NULL
scheduled_end_at = timestamp or NULL
started_at = NULL
ended_at = NULL
started_by = NULL
ended_by = NULL
enabled = false
```

#### in_progress

```text
scheduled_start_at != NULL
scheduled_end_at = timestamp or NULL
started_at != NULL   ※修復で「不明」と確定した特殊ケースは別途考慮
ended_at = NULL
started_by != NULL   ※修復で不明扱いを許容する場合は監査上明示
ended_by = NULL
enabled = true
```

#### completed

```text
scheduled_start_at != NULL
scheduled_end_at = timestamp or NULL
enabled = false
```

通常の終了処理では以下が必須:

```text
started_at
started_by
ended_at
ended_by
```

ただし修復後の履歴では「不明」を正式状態として保持できる設計を許容する。その場合は不明であることがUI・監査ログから明確に分かるようにする。

---

## 4.3 例外操作監査ログ

修復履歴と緊急終了履歴を別々に分散させず、例外的な管理操作を一元記録する。

概念:

```text
maintenance_operation_logs
- id
- maintenance_id
- operation_type
- performed_by
- performed_at
- reason
- before_state
- after_state
```

`operation_type` 例:

```text
repair
emergency_end
```

要件:

- 管理者による直接編集・削除は禁止。
- RPC等のサーバー側処理のみが書き込む。
- 本体更新とログ保存は同一トランザクションで実行。
- `before_state` / `after_state` は、修復の内容が後から追える形式にする。
- 修復理由・緊急終了理由は必須。

---

## 4.4 編集ロック

保存形式は既存設計を調査して決める。

要件:

- ロック対象は既存メンテナンスレコードの編集のみ。
- 新規作成にはロック不要。
- 閲覧ではロックしない。
- Edit押下時に取得。
- 10分間操作がなければ失効。
- 編集中の操作に応じて適切な間隔でheartbeat更新。
- 毎キーストロークDB更新はしない。
- Save成功 / Cancel で解除。
- ブラウザ終了時の解除はbest-effort。正しさは10分失効に依存。
- 強制解除ボタンは通常設けない。

無効化条件:

- ロック所有者 `active = false`
- ロック所有者レコード不存在
- 最終操作から10分超過
- 対象レコードが `completed`

これらを認識した時点でDB上のロックも破棄可能とする。

同一レコードに複数有効ロックが存在しない設計にする。

---

## 4.5 表示順

基本順:

```text
scheduled_start_at ASC
```

同一 `scheduled_start_at` のグループ内のみ手動並べ替え可能。

同時刻開始以外ではドラッグ順変更不可。

フォールバック:

```text
display_order
created_at ASC
```

表示順異常時は以下の修復を提供:

- 基本順へリセット
- 最後に正常保存された表示順へ戻す

表示順の正常スナップショット履歴は必要最小限でよい。既存DB設計を踏まえ、直前または数世代を保持する方式を選ぶ。

---

# 5. 日時

## 5.1 保存と表示

- DB: UTC基準
- PostgreSQL: 原則 `timestamptz`
- フロント表示: `Asia/Tokyo`
- 管理フォーム入力: 日本時間として扱う
- DBによるシステム時刻記録を優先
- Start / End / 緊急終了 / 監査時刻はブラウザ時計ではなくDB側時刻を利用

## 5.2 通常予定日時

### 新規作成

- scheduled start: 作成時点より未来
- scheduled end:
  - NULL可 = 終了予定未定
  - 入力時は現在より未来
  - scheduled start より後

### scheduled編集

- startを変更する場合、新しいstartは未来
- 既存startが過去でも、変更しないなら他フィールド編集・Startは許可
- endを変更する場合、現在より未来、startより後

### in_progress編集

変更可能な具体的endは現在より未来。

NULLに戻して「終了予定未定」も可能。

---

# 6. 修復時の日時の確度

修復時のみ、実績日時を

- 正確
- 推定
- 不明

の3段階で扱う。

### 正確

```text
started_at / ended_at = timestamp
*_is_estimated = false
```

### 推定

```text
started_at / ended_at = timestamp
*_is_estimated = true
```

UIでは例:

```text
約 2026/09/08 20:00
```

### 不明

日時自体をNULLとして保持可能とし、UIでは「不明」と表示。

修復理由を必須にし、推定・不明の場合は根拠を残せるようにする。

### 修復時でも禁止する矛盾

- 実績開始が未来
- 実績終了が未来
- 終了が開始より前

### 許可するもの

- 予定開始より実際の開始が早い
- 予定終了より実際の終了が遅い

これらはエラーではなく、必要ならUI警告のみ。

---

# 7. 公開情報とセキュリティ境界

一般・匿名ユーザーには `maintenances` 本体の全面SELECTを許可しない。

公開情報は安全なRPC / function等を介して返す。

## 7.1 ログイン画面向け公開RPC

未認証から利用可能。

返す情報:

### 現在実施中

存在する場合:

- title
- started_at
- scheduled_end_at
- message
- contact

### 今後の予定

- status = scheduled
- 今後1か月以内
- 近い順3件
- 同一開始時刻は保存済み表示順を反映

公開項目:

- title
- scheduled_start_at
- scheduled_end_at
- message
- 必要ならcontact

内部項目は返さない。

## 7.2 認証済み一般ユーザー向け状態確認RPC

30秒ポーリング、ページアクセス、送信直前確認で利用。

返す内容:

- 正常 / メンテナンス中 / 状態異常
- メンテナンス中なら公開項目のみ
  - title
  - started_at
  - scheduled_end_at
  - message
  - contact

返さない:

- description
- created_by / updated_by
- started_by / ended_by
- lock情報
- 内部表示順
- 監査ログ

## 7.3 管理系

active maintenance_admin のみ。

- full detail read
- create
- scheduled edit
- scheduled delete
- start
- end
- emergency end
- repair
- lock操作
- operation log閲覧

DB側でも操作時点でactiveを再確認する。

---

# 8. 状態取得異常

公開RPCは、状態不整合時に「どれか1件を勝手に正常として採用」しない。

例:

- in_progress が複数
- status / enabled 不一致
- 状態判定に必要な重大不整合

この場合は「maintenance_state_error」等の内部的な結果を返し、一般利用者の通常利用を許可しない。

---

# 9. アクセス制御

概念:

```text
未認証
  -> ログイン画面

認証済み + 正常状態
  -> 通常ポータル

認証済み + メンテナンス中
  -> active maintenance_admin: 通常ポータル
  -> その他: メンテナンス画面

状態取得不能 / 状態不整合
  -> 通常ポータルへ入れない
```

## 9.1 直接URL

一般利用者がメンテナンス中に認証済みページへ直接URLアクセスしても、共通アクセス制御層でメンテナンス画面へ遷移する。

各ページに個別実装を乱立させず、共通ガード / 共通レイアウト等の既存構造に適切に統合する。

## 9.2 30秒確認

### 通常ポータル

30秒ごとに状態確認。

一般利用者でメンテナンス開始を検出したら即メンテナンス画面へ。

### メンテナンス画面

30秒ごとに確認。

- 継続中 -> そのまま
- 終了 -> ポータルトップへ
- 取得失敗 -> 状態確認エラー画面へ
- 状態不整合 -> 状態異常画面へ

メンテナンス終了後は元ページへ戻さず、必ずポータルトップ。

## 9.3 フォーム送信直前

一般利用者の既存フォーム送信直前にもメンテナンス状態を再確認する。

メンテナンス開始済みなら送信を止め、メンテナンス画面へ遷移。

既存全テーブルRLSの全面変更はv1範囲外。

---

# 10. メンテナンス画面

一般利用者向け。

表示:

- 「システムメンテナンス中」
- 公開 `message`
- 実際の開始日時 `started_at`
- `scheduled_end_at`
  - NULLなら「未定」
- `contact`
- ログアウト
- 「メンテナンス終了後、自動的にポータルトップへ移動します。」

表示しない:

- description
- created_by / updated_by
- started_by / ended_by
- 内部エラー
- Supabase詳細
- lock / audit data

ブラウザ更新は可能。専用reloadボタンは不要。

---

# 11. 状態確認エラー画面

見た目は同じエラー画面ファミリーとし、原因カテゴリで文言を変える。

## 11.1 通信・状態取得失敗

タイトル:

```text
システムの状態を確認できません
```

説明例:

```text
現在、ポータルの状態を確認できないため、一時的にご利用いただけません。
通信環境をご確認のうえ、しばらくしてからもう一度お試しください。
```

## 11.2 DB状態不整合

タイトル:

```text
システムの状態に問題が発生しています
```

説明例:

```text
現在、ポータルの利用状態を正しく判定できないため、
安全のため一時的にご利用いただけません。
管理者による確認・復旧をお待ちください。
```

共通:

- 「もう一度確認する」
- ログアウト
- 自動リトライなし
- 技術詳細を一般ユーザーに表示しない
- 必要ならconsoleへ技術ログ

maintenance_admin でも状態取得そのものに失敗した場合は通常ポータルへ無理に通さない。

---

# 12. ログイン画面

表示順:

1. 現在実施中のメンテナンス
2. 今後のメンテナンス予定
3. Googleログインボタン

## 12.1 実施中

例:

```text
現在システムメンテナンス中です
```

表示:

- message
- started_at
- scheduled_end_at / 未定
- contact

## 12.2 予定

- 次の1か月
- scheduledのみ
- 近い3件
- completedは表示しない

例:

```text
2026/09/11 12:00〜14:00 写真展機能追加のため
2026/09/28 14:00〜16:00 全体的なパフォーマンス向上のため
```

終了未定:

```text
12:00〜終了予定未定
```

0件時:

```text
現在予定されているメンテナンスはありません
```

---

# 13. メンテナンス管理画面への導線

active maintenance_admin の既存管理画面上部に追加。

概念:

```text
[ポータルトップに戻る] [メンテナンス管理] [ログアウト]
```

既存 `admins` だけで maintenance_admin でないユーザーには表示しない。

URL直打ちもDB権限・フロントガード双方で拒否。

---

# 14. 管理画面 PC

3カラム構成。

## 14.1 左カラム

上から:

1. 実施中メンテナンス（存在する場合、目立たせる）
2. 直近の通常予定
3. recent completed maintenance
4. 「履歴をもっと見る」

### 直近の通常予定

対象:

- 全体会
  - 撮影会
  - お食事会
- 合宿
- 写真展

期間:

- 現在から2か月先

表示:

- 種別
- タイトル
- 日時
- 申込期限

閲覧のみ。

既存予定の編集削除は既存管理画面で行う。

### recent completed

最新5件。

「履歴をもっと見る」で中央タブを履歴へ切り替える。

## 14.2 中央カラム

上部タブ:

```text
[新規 | 履歴]
```

その上/直下に常時:

```text
メンテナンスの予定
```

を表示。

- scheduled
- 近い3件
- 日付上限なし
- clickでdetail

新規タブ:

- 新規作成フォーム

履歴タブ:

- completed一覧
- filter/search/pagination

## 14.3 右カラム

月間カレンダー。

- monthのみ
- prev / next
- day/week viewなし
- scheduled / in_progress / completed を表示
- 色だけでなくstatus badge等も併用
- visible month周辺のみ取得
- clickでdetail

---

# 15. スマートフォン

1カラム中心。

推奨順:

1. 実施中 / 状態異常
2. メンテナンス予定
3. 新規 / 履歴タブ
4. フォーム / 履歴
5. 直近通常予定
6. 最近のメンテナンス

月間カレンダーは常時表示せず、右上のカレンダーアイコンから右ドロワー表示。

- 右からスライド
- ×で閉じる
- 背景tapで閉じる
- 緊急終了・修復導線はカレンダー内に隠さない

---

# 16. 実施中ステータス表示

管理画面上部または右上等に常時分かる表示を置く。

正常1件:

```text
● メンテナンス実施中
写真展機能更新
開始から 1時間23分
[詳細]
```

経過時間は `started_at` から算出。

`started_at` 不明:

```text
⚠ 開始日時を確認できません
```

状態異常時:

```text
⚠ メンテナンス状態に異常があります
実施中のメンテナンスが2件あります
[状態を確認・修復する]
```

---

# 17. 新規作成

入力:

- title
- scheduled_start_at
- scheduled_end_at または終了未定
- message
- contact
- description

### 文字数

- title: 必須、50文字以内、改行不可
- message: 必須、100文字以内、改行可
- description: 必須、500文字以内、改行可
- contact: 必須、30文字以内、改行不可

共通:

- 前後空白trim
- 空白/改行だけは禁止
- 超過時はreject、切り捨て禁止

### client_request_id

新規作成要求ごとに一意UUIDを生成。

通信断時に同じ要求を再試行しても二重作成しない。

DB側で一意性を保証する。

---

# 18. scheduled detail

表示:

- title
- scheduled start
- scheduled end / 未定
- message
- contact
- description
- creator
- last updater
- created_at
- updated_at

操作:

- Edit
- Delete
- Start

Edit中:

- Cancel
- Save

を使用。

---

# 19. in_progress detail

表示:

- title
- scheduled start
- scheduled end / 未定
- message
- contact
- description
- creator
- actual start
- starter
- last updater

編集可能:

- scheduled_end_at / 未定
- message
- description

編集不可:

- scheduled_start_at
- started_at
- status
- enabled
- contact
- audit fields

操作:

- Edit
- End
- 状況に応じて Emergency End

---

# 20. completed detail

完全read-only。

表示:

- title
- scheduled start
- scheduled end / 未定
- message
- contact
- description
- creator
- actual start
- starter
- actual end
- ender
- last updater
- exception operation log

編集・削除不可。

---

# 21. lifecycle

## 21.1 Start

確認ダイアログで、一般利用者が利用できなくなることを明示。

専用RPCで原子的に:

```text
status = in_progress
enabled = true
started_at = DB now()
started_by = actor
updated_by = actor
```

要件:

- active maintenance_admin再確認
- targetがscheduled
- 他にin_progressがない
- 編集ロック中なら禁止
- concurrency-safe
- 同一操作再試行でstarted_atを上書きしない

## 21.2 通常End

専用RPCで:

```text
status = completed
enabled = false
ended_at = DB now()
ended_by = actor
updated_by = actor
```

scheduled_end_atは変更しない。

通常Endは編集ロック中は実行不可。

## 21.3 緊急終了

in_progressのみ。

編集ロックを無視できる例外操作。

確認画面:

- 対象
- 編集者名
- 「未保存内容は保存できなくなる」
- 一般利用者が利用可能になる旨
- 理由必須

専用RPCで原子的に:

1. actorがactive maintenance_adminか確認
2. targetがin_progressか確認
3. completed化
4. enabled=false
5. ended_at = DB now()
6. ended_by = actor
7. updated_by = actor
8. edit lock解除
9. operation logへ emergency_end + reason + before/after

編集中だった他管理者のSaveはDB側で拒否。

scheduledに対する緊急開始・緊急削除は作らない。

---

# 22. 編集競合

## 22.1 edit lock

他管理者のロック中:

- 閲覧: 可
- Edit: 不可
- Start: 不可
- Delete: 不可

ロック所有者自身も、Start/Delete前にSaveまたはCancelしてロック解除する。

## 22.2 optimistic check

編集開始時の `updated_at` 等を保持。

Save時にDB側最新値と比較。

他の更新が入っていれば保存拒否し、最新状態の再取得を促す。

編集ロック + optimistic check の二重防御とする。

---

# 23. maintenance_admin 権限喪失

管理画面では60秒ごとに `maintenance_admins.active` を確認。

`active=false` を検出:

- 管理操作を停止
- 権限エラー表示
- 数秒後にポータルトップへ
- 未保存の新規作成内容は保存不可
- 未保存の既存編集内容も保存不可
- DB操作時にも必ず権限再確認

表示例:

```text
このアカウントは現在、メンテナンス管理者として承認されていません。
数秒後にポータルトップへ移動します。
```

既存編集ロックは、active=falseを認識した時点で無効・破棄可能。

---

# 24. 履歴

対象:

- completedのみ

順序:

```text
ended_at DESC
```

実績終了不明の場合の安定した並び順は既存設計に合わせて定義する。

10件/ページ。

filter:

- start date optional
- end date optional
- keyword optional

期間は `ended_at` 基準。

```text
start only -> ended_at >= start
end only   -> ended_at <= end
both       -> inclusive
none       -> no date filter
```

keyword:

```text
title OR description
```

部分一致。

期間 + keyword は AND。

filter変更で1ページ目へ。

clear filterあり。

---

# 25. 状態診断・修復UI

通常時は目立たせない。

異常検出時:

```text
⚠ メンテナンス状態に異常があります
3件の問題が検出されました
[状態を確認・修復する]
```

専用画面:

```text
メンテナンス状態の診断・修復
```

DBカラムを直接編集させるUIにしない。

「何がおかしいか」を日本語で表示し、質問形式・ウィザード形式で安全に修復する。

修復後:

1. RPC成功
2. DB再取得
3. 全体再診断
4. 結果表示

---

# 26. 修復対象

## 26.1 scheduled の実績情報混入

`status = scheduled` を基準に扱う。

異常例:

- started_atあり
- started_byあり
- ended_atあり
- ended_byあり
- enabled=true

UIでは異常な項目だけ赤/警告表示。

修復:

```text
status=scheduled
enabled=false
started_at=null
started_by=null
ended_at=null
ended_by=null
```

必要な箇所だけクリア。

---

## 26.2 in_progress に終了情報あり

例:

- ended_atあり
- ended_byあり

質問:

```text
このメンテナンスは現在も実施中ですか？
```

選択:

- 現在も実施中
  - 不要な終了情報をクリア
- すでに終了
  - completedへ修復
  - existing end dataが妥当なら利用

---

## 26.3 in_progress の開始情報欠損

例:

- started_atなし
- started_byなし
- 片方のみ存在

質問:

```text
このメンテナンスは正しく実施されましたか？
```

### 実施された

欠損項目のみ入力。

開始者は現在・過去の `maintenance_admins` から、activeに関係なく選択可能。

日時は「正確 / 推定 / 不明」。

修復理由必須。

### 実施されていない

選択:

- scheduledへ戻す
- 削除する

削除時は強い確認。

---

## 26.4 completed の不整合

まず:

```text
このメンテナンスは実際に実施され、終了しましたか？
```

### yes

欠損している:

- started_at
- started_by
- ended_at
- ended_by

を補完。

時間は正確 / 推定 / 不明。

人物は現在・過去のmaintenance_adminから選択。

### no

- scheduledへ戻す
- 削除する

completed削除は強い確認。

修復ログは残す。

---

# 27. 複数in_progress

一般側:

- どれか1件に決めない
- 状態異常として通常利用を拒否

管理側:

```text
実施中のメンテナンスがN件あります
```

と重大警告。

修復では各対象について:

- 実施中として残す
- scheduledへ戻す
- completedへ修復

「実施中として残す」は最終的に1件まで。

新しいStartは禁止。

---

# 28. status / enabled 不整合

正常マッピングから外れていれば異常。

一般側:

- 状態異常

管理側:

- 診断対象

修復UIではstatusの意味を人間向けに説明し、必要な修復を提示。

通常経路ではCHECK / RPC制約により発生を防ぐ。

---

# 29. 日時矛盾

以下は修復UIで後処理するよりDB制約で防ぐ。

- scheduled_end_at < scheduled_start_at
- ended_at < started_at
- 修復実績日時が未来

Create / Edit / Start / End / Repair のすべての経路で防ぐ。

---

# 30. 管理者参照

created_by / updated_by / started_by / ended_by 等はFK等で整合性を守る。

過去管理者が `active=false` でも異常扱いしない。

履歴上の人物は保持する。

---

# 31. 監査情報

以下は可能な限りDB側で自動設定し、手入力させない。

- created_at
- updated_at
- created_by
- updated_by

通常ユーザー入力から改変できないようにする。

修復ログ自体の整合性はDB制約とトランザクション原子性で保護する。

---

# 32. 表示順修復

同一開始日時グループのみ並び替え。

操作:

- drag reorder
- 保存

異常時:

```text
表示順の情報に不整合があります
```

選択:

- 基本順にリセット
- 最後に正常保存された表示順に戻す

---

# 33. 通信障害と曖昧な結果

原則:

```text
ブラウザの「成功/失敗」認識ではなく、
Supabaseに保存された現在状態を正とする。
```

## 33.1 Create

`client_request_id` で重複防止。

応答不明時:

- 同一request IDでDB確認
- 作成済み -> 成功扱い
- 未作成 -> 入力内容を保持し再実行可能

## 33.2 Edit

応答不明時:

- target再取得
- 入力内容と一致 -> 保存済み
- old state -> 未保存
- third state -> 競合

確認完了まで入力内容を消さない。

## 33.3 Delete

応答不明時:

- target再取得
- 不存在 -> 削除成功
- 存在 -> 未削除

確認中は連打を防止。

## 33.4 Start / End / Emergency End / Repair

専用RPC。

- transaction
- retry-safe
- 返答不明時は再取得
- 同じ操作の再試行で実績日時を上書きしない

Startがすでにin_progressなら `started_at` を変更しない。

End済みなら `ended_at` を変更しない。

---

# 34. DB制約・RPC

最低限以下をDB側で担保すること。

- status許可値
- status / enabled整合
- 1件のみin_progress
- datetime順序
- public readの情報制限
- maintenance_admin active check
- lifecycle fieldの自由更新防止
- completedの通常編集防止
- operation logの一般更新防止
- repairによる最終状態の妥当性
- client_request_id一意
- lockの一意性 / 有効性

1件のみin_progressはフロント確認だけでなく、同時操作でも破れないDB側制約を使用する。

---

# 35. 実装優先順位

早期に安全なメンテナンス運用を可能にするため、以下の順で進める。

## Phase 1: 調査

- repo構造
- auth
- admins
- Supabase schema
- migrations
- RLS/RPC
- 管理UI
- event schedules
- date handling
- test commands

## Phase 2: DB基盤

- maintenance_admins
- maintenances
- constraints
- RLS
- public RPC
- management access
- lifecycle RPC
- client_request_id
- operation log基盤

## Phase 3: 一般利用者遮断

- common access guard
- login public info
- maintenance screen
- state error screens
- 30sec polling
- submit-before-check

この段階で「安全に一般利用者を止める」基礎を成立させる。

## Phase 4: 管理画面基礎

- 3-column
- mobile responsive
- create
- schedule list
- detail
- history
- calendar
- normal event reference

## Phase 5: lifecycle

- Start
- End
- state banner
- admin active 60sec check

## Phase 6: concurrency

- edit lock
- heartbeat
- optimistic updated_at validation
- communication re-fetch

## Phase 7: emergency

- Emergency End
- audit log
- stale editor rejection

## Phase 8: diagnosis/repair

- diagnostics
- scheduled repair
- in_progress repair
- completed repair
- multiple active repair
- exact/estimated/unknown dates
- display order repair

## Phase 9: polish

- responsive
- loading
- empty states
- accessibility
- error wording
- final regression

---

# 36. 受け入れ条件

## アクセス

- 通常時は一般利用者が従来どおり利用できる。
- maintenance_adminでない一般利用者はメンテナンス中に通常画面へ入れない。
- direct URLでも回避できない。
- active maintenance_adminはメンテナンス中でも通常ポータルを利用できる。
- inactive maintenance_adminはバイパスできない。

## Login

- 実施中情報を未ログインでも確認できる。
- 1か月以内のscheduled最大3件を確認できる。
- completedは出ない。
- 内部descriptionや監査情報が匿名に漏れない。

## Polling

- 一般ポータルは30秒でメンテナンス開始を検知する。
- メンテナンス終了後30秒以内を目安にtopへ戻る。
- 状態エラー画面では自動retryしない。

## Lifecycle

- Startで1件だけin_progressになる。
- 同時Startでも2件in_progressにならない。
- Endでscheduled timesが上書きされない。
- lifecycle timestampはDB時刻。
- Retryでstarted_at/ended_atを再上書きしない。

## Lock

- 他人のedit lock中はedit/start/delete不可。
- 10分 inactivity で失効。
- inactive ownerのlockは無効。
- completedではlock不可。
- emergency endはlockを解除して終了可能。

## Repair

- 異常がない時は修復UIを通常操作で意識させない。
- 異常時に診断画面への導線が出る。
- 欠損項目だけ警告表示できる。
- exact/estimated/unknownを表現できる。
- repair reasonが監査ログに残る。
- repair後に再診断される。

## Errors

- 通信失敗と状態不整合で一般ユーザー向け文言が異なる。
- 内部エラー詳細は一般画面に露出しない。
- 状態が判定不能な場合はfail closed。

## Responsive

- PCは3カラム。
- スマホは1カラム中心。
- カレンダーは右上アイコンからright drawer。
- 緊急終了・状態異常導線がスマホでも利用できる。

---

# 37. 検証項目

実装後、最低限以下を検証する。

## Static / build

既存プロジェクトで用意されているものをすべて実施。

例:

- formatter
- lint
- type check
- build
- unit test

実際のコマンドはrepo調査後に決定。

## DB

- migration適用可否
- rollbackまたは再現性
- constraint
- RLS
- anon / authenticated / maintenance admin別権限
- RPC concurrency
- idempotency

## Manual scenarios

1. 通常状態で一般利用
2. scheduled作成
3. login予定表示
4. Start
5. 一般ユーザー遮断
6. direct URL遮断
7. maintenance_admin bypass
8. 30秒検知
9. End
10. top復帰
11. scheduled edit
12. scheduled delete
13. lock競合
14. lock timeout
15. active false
16. emergency end
17. create response loss simulation
18. edit response loss simulation
19. duplicate Start
20. duplicate End
21. multiple in_progress anomaly
22. missing started_by
23. missing started_at
24. completed missing end info
25. status/enabled anomaly
26. display order anomaly
27. communication failure
28. malformed DB state
29. mobile calendar drawer
30. history filters/pagination

---

# 38. 既存機能への影響

変更前に必ず影響範囲を洗い出す。

主な影響候補:

- auth / login routing
- common authenticated layout
- every existing authenticated page
- form submission flows
- existing admin navigation
- Supabase config / migrations
- normal schedule queries
- global error / loading state
- date utility functions

既存イベントCRUD自体は原則変更しない。

既存 `admins` と `maintenance_admins` の意味を混同しない。

---

# 39. UI方針

既存管理画面の

- white cards
- green accent
- button hierarchy
- spacing
- form layout
- typography

等を再利用し、新機能だけ別デザインにしない。

statusは色だけでなくテキスト/badge/iconを併用する。

修復・緊急終了等の危険操作は視覚的に通常操作と区別する。

---

# 40. Workが独自判断してよい範囲

以下は要件を損なわない範囲で既存実装に合わせて選択してよい。

- SQL function名
- policy名
- migrationファイル名
- component名
- lock保存方式
- display-order snapshotの保存方式
- calendar library / existing component利用
- modal / drawerの具体的実装
- responsive breakpoint
- 3〜5秒程度の権限喪失redirect delay
- UIの細かな文言
- exact query implementation
- estimated/unavailable timestampのDB表現詳細

ただし、要件の意味を変更する判断を勝手に行わないこと。

---

# 41. Workが実装中に要確認とすべきケース

以下に該当した場合は、推測で大規模変更せずユーザーへ報告する。

- 既存DB構造が本計画と根本的に矛盾
- migration運用が不明
- 既存auth guardがなく、大規模routing変更が必要
- existing formsの送信共通層がなく、全フォーム個別修正が大量に必要
- 既存RLSに重大な問題が見つかった
- Supabase側で必要な権限が不足
- 通常イベントデータの構造が想定と大きく異なる

---

# 42. 完了時報告

Workは実装完了時に以下を報告する。

1. 変更概要
2. 変更したファイル一覧
3. 追加したmigration一覧
4. 新規/変更したDB table / constraint / policy / RPC
5. UI変更
6. 実行した検証
7. 検証結果
8. 未解決事項
9. ユーザーがSupabase等で手動実施する必要がある作業
10. 本番投入前の推奨確認手順

最後に `git status` を提示し、commit / pushは行わない。

---

# 43. 完了の定義

この機能は、単に「メンテナンス中画面が表示される」だけでは完了としない。

最低限、

- 安全なアクセス制御
- public/internal data separation
- maintenance admin permission
- Start/End
- 1件in_progress保証
- 30秒状態検知
- error fail-closed
- management UI
- history
- edit lock
- emergency end
- audit log
- communication retry safety
- diagnosis/repair
- mobile対応
- tests / verification

まで成立し、後任者がSupabaseの生データを直接編集しなくても通常運用・主要な異常復旧を行える状態を完成形とする。
