# GitHub Pages・Supabase移行手順

## 1. 管理主体

個人所有を避けるため、写真研究会用のGitHub OrganizationとSupabase Organizationを作成します。現幹部と次期幹部をOwnerにし、退任時に個人アカウントを外します。

## 2. Supabaseプロジェクト

1. 統合アプリ専用の新規プロジェクトを作成します。
2. SQL Editorで`supabase/migrations/202609020001_initial_schema.sql`を実行します。
3. SQL末尾の例を使い、初期管理者メールを`public.admins`へ登録します。
4. Authentication → Sign In / Providers → Googleを有効化し、Google OAuthのClient IDとClient Secretを登録します。
5. Google Auth Platformには、GitHub PagesのoriginとSupabaseのCallback URLを登録します。
6. Project Settings → APIからProject URLとPublishable keyを確認します。`service_role`キーはGitHub Pagesへ絶対に登録しません。

## 3. 初期データ

次の順にSupabase Table EditorまたはCSV Importで登録します。

1. `admins`
2. `members`
3. `membership_years`
4. `events`
5. `event_responses`
6. 写真展の`archive_exhibitions`、`archive_works`、`archive_work_comments`

メールは小文字へ統一します。`members.member_no`は`member-0001`形式を維持します。写真展作品画像はStorageの非公開バケット`exhibition-previews`へアップロードします。

## 4. GitHub Pages

Organization所有リポジトリのSettings → Secrets and variables → Actionsへ、次を登録します。

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`
- `VITE_GOOGLE_CLIENT_ID`

Settings → Pages → SourceでGitHub Actionsを選択します。`main`へpushすると`.github/workflows/pages.yml`が`web`をビルドして公開します。

ローカル確認では`web/.env.example`を`web/.env`へコピーして実値を設定し、次を実行します。

```bash
cd web
npm install
npm run dev
```

## 5. セキュリティ

- ブラウザにはPublishable keyだけを置きます。これはRLSとの併用を前提とした公開可能なキーです。
- Google Client IDは公開可能ですが、Client SecretはSupabaseだけへ登録し、GitHubやブラウザには置きません。
- 全テーブルでRLSを有効にし、本人・当年度部員・管理者をDB側で判定します。
- 写真展全体への感想は管理者だけが閲覧できます。
- 貸出カメラ3台、合宿同意、アレルギー必須はDBトリガーでも検証します。
- GitHub PagesのソースやActions Secretsへ`service_role`キー、DBパスワードを保存しません。

## 6. 切り替え

Supabaseへの件数照合と本人・非本人・管理者の権限試験が完了するまでは、既存GASを削除しません。GitHub Pages版のURLを部員へ公開した後、GAS版は非公開にして読み取り専用の移行元として一定期間保持します。
