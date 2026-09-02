# 法政大学小金井写真部 統合活動ポータル

部員名簿、年度在籍、領収証、全体会、合宿、写真展、シフトを一元管理するWebアプリです。GitHub Pagesをフロントエンド、Supabaseを認証・データベース・画像保存基盤として使用します。

## 現在の状態

移行開発中です。Googleログイン、管理者・部員照合、初期データベース、予定と回答、写真展アーカイブの基本画面まで実装しています。既存GASはデータ移行と本番確認が完了するまで参照用として残しています。

## 構成

- `web/`: Vite + Supabase JavaScriptによるGitHub Pagesフロントエンド
- `supabase/migrations/`: テーブル、RLS、トリガー、Storageの初期SQL
- `.github/workflows/pages.yml`: GitHub Pagesのビルド・デプロイ
- ルートの`.gs` / `.html`: 移行元GAS実装（移行完了までの参照用）
- `GITHUB_PAGES_MIGRATION.md`: 構築・移行手順

## ローカル開発

`web/.env.example`を`web/.env`へコピーし、公開用の接続値を設定します。

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_YOUR_KEY
VITE_GOOGLE_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

起動コマンド：

```bash
cd web
npm install
npm run dev
```

開発URLは `http://localhost:5173` です。

## GitHub Pages

GitHub Actions Secretsへ次を登録します。

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`
- `VITE_GOOGLE_CLIENT_ID`

リポジトリのPages SourceをGitHub Actionsに設定すると、`main`へのpushで公開されます。

## セキュリティ

- Google Client Secret、Supabase Secret key、`service_role` key、DBパスワードはリポジトリへ保存しません。
- `web/.env`、`web/node_modules/`、`web/dist/`はGit管理対象外です。
- データアクセスはSupabase RLSで本人・当年度部員・有効な管理者に制限します。
- Googleログイン後、メールアドレスを`members`と`admins`へ照合します。
- 写真展画像は非公開Storageに保存し、所有者本人または管理者だけに許可します。

## 運用上の注意

- 幹部の追加・無効化はSupabaseの`admins`で管理します。
- 恒久部員IDは`member-0001`形式、年度在籍は`membership_years`で管理します。
- 既存GAS、Googleスプレッドシート、旧写真展データは、移行件数と権限試験が完了するまで削除しません。
