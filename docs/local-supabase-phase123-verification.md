# Phase 1〜3 Local Supabase検証

この手順は、Productionへ接続せず、Phase 1〜3をLocal Supabaseだけで検証するためのものです。Phase 4は対象外です。

## 安全設計

- Local project IDは`hosei-photo-portal-phase123-local`固定です。
- Production project ref、database URL、secretは使用しません。
- scriptは`supabase link`、`db push`、`--linked`を使用しません。
- DB操作は固定名のLocal Docker containerだけを対象にします。
- `supabase/config.toml`にremote情報やURLが見つかった場合は停止します。
- 既存migrationは変更しません。

## なぜ通常のseedを使わないか

Supabaseのseedは、すべてのmigrationが完了した後に実行されます。一方、`202609030018_import_2026_summer_archive.sql`は実行時点ですでに11名のMemberが必要です。

そのため、このRepositoryではCLIの自動migration/seedを無効にし、Local専用bootstrap scriptが次の順序で処理します。

1. Local DBを空の状態へreset
2. migrationをファイル名順に適用
3. `202609030018`の直前に、必要な11名だけをLocal fixtureから投入
4. `202609030018`以降を含む残りのmigrationを適用
5. verification用のactive Adminを投入

fixtureは`supabase/local/fixtures/`にあり、Production migrationには含まれません。

## 前提

- Supabase CLIがインストール済み
- Docker Desktopが起動済み
- Repository rootで以下が成功する

```bash
supabase --version
docker info
```

Google OAuth設定、Productionの`.env`、Supabase login/linkは不要です。

## 実行

Repository rootで次を実行します。

```bash
./scripts/local-phase123-bootstrap.sh --confirm-local-reset
./scripts/local-phase123-verify.sh
```

## Full-stackが起動できない場合のDB-only fallback

Apple Silicon等でRealtimeを含むLocal Supabase全体が起動できない場合は、PostgreSQLだけを使う追加経路があります。

```bash
./scripts/local-phase123-db-only.sh --confirm-disposable-local-db
```

この経路はSupabase Postgres imageを、外部公開portなし・一時filesystem・固定container名・専用label付きで起動します。Auth/Storage serviceは起動せず、履歴migrationが必要とするDB内の最小契約だけを`supabase/local/db-only/supabase_service_compat.sql`で再現します。

処理順はfull-stack用bootstrapと同じです。

1. Supabase DB互換オブジェクトをLocalだけに作成
2. `202609030017`までのmigration
3. 必須11名のLocal fixture
4. `202609030018`と残りのmigration
5. Phase 1、2、3 migration
6. Local Admin fixture
7. Phase 1、2、3 verification SQL

成功時はcontainerを自動削除します。失敗時は原因確認のためcontainerを残し、削除commandを表示します。scriptには接続URLを渡す引数がなく、portも公開しません。`supabase link`、`db push`、`--linked`、Supabase CLIは使用しません。

bootstrapはLocal DBをresetするため、同じLocal project ID内のデータは削除されます。Productionや他のLocal Supabase projectには接続しません。

検証終了後は、必要に応じて次でLocal stackを停止できます。

```bash
supabase stop
```

`--no-backup`は付けないため、停止だけではLocal volumeを削除しません。

## Verificationの独立性

3つのverification SQLは、すべてPhase 1〜3 migration適用済みschemaとLocal Admin fixtureを前提にします。それぞれが`BEGIN`〜`ROLLBACK`で検証用データを戻すため、DB状態上は独立して実行できます。

通常は問題箇所を特定しやすいよう、Phase 1 → Phase 2 → Phase 3の順で実行します。Phase 2がPhase 1 verificationのデータに依存したり、Phase 3がPhase 2 verificationのデータに依存したりすることはありません。

## 禁止事項

Local検証では次を実行しません。

```text
supabase link
supabase db push
supabase db reset --linked
supabase migration up --linked
```

通常の`supabase db reset`も直接実行せず、安全ガードを含むbootstrap scriptを使用してください。
