# 写真展Workflow v2 リリース準備状況

最終更新: 2026-10-05（Phase 11 DB-only統合検証完了）

## 結論

**RELEASE READY — application / DB implementation上のrelease blockerなし**

Local専用のdisposable clean DBで全Migrationを適用し、Phase 1〜10の独立検証SQLとPhase 11統合検証SQLがすべてPASSした。Frontend Vite build、`git diff --check`、最終静的release reviewもPASSしている。Production適用、Production Cron、メール送信、デプロイは行っていない。

## Migration順序

既存Migrationをファイル名順に適用した後、Workflow v2を次の順で適用する。

| Phase | Migration | 主責務 |
|---|---|---|
| 1 | `202609300001_exhibition_workflow_v2_foundation.sql` | Version、4締切、Agreement、Audit |
| 2 | `202609300002_exhibition_application_v2.sql` | Application / Snapshot |
| 3 | `202609300003_exhibition_work_submission_v2.sql` | Work / Submission Snapshot |
| 4 | `202609300004_exhibition_caption_workflow_v2.sql` | Caption / Review / Case |
| 5 | `202609300005_exhibition_action_center_v2.sql` | Snapshot整合、Action Center、SYSTEM処理 |
| 6 | `202609300006_exhibition_layout_finalization_v2.sql` | Layout Finalization、display_no履歴 |
| 7 | `202609300007_exhibition_export_v2.sql` | immutable Master Export |
| 8 | `202610010001_exhibition_publication_survey_v2.sql` | Publication、UUID Survey、Storage保護 |
| 9 | `202610010002_exhibition_actual_v2.sql` | Actual Exhibition Record |
| 10 | `202610010003_exhibition_archive_v2.sql` | immutable Archive / Current pointer |

重複timestampはない。静的確認では参照先は導入済みの前PhaseまたはLegacy schemaに存在する。Phase 1〜10はProduction未適用という前提で管理する。

## Local bootstrap

履歴Migration `202609030018_import_2026_summer_archive.sql` の直前に、Local専用の11名fixtureが必要である。

1. `supabase/local/db-only/supabase_service_compat.sql`
2. Migrationを`202609030017`まで順番に適用
3. `supabase/local/fixtures/2026_summer_required_members.sql`
4. `202609030018`以降の全Migrationを順番に適用
5. `supabase/local/fixtures/verification_admin.sql`
6. Phase 1〜11のverification SQLをファイル名順に実行

一括実行用: `./scripts/local-workflow-v2-db-only.sh --confirm-disposable-local-db`

このスクリプトは外部portを公開せず、一時DB、固定Local専用label、固定Local資格情報を使用する。URL/ref/link引数を受け取らず、remote接続用環境変数が存在すると停止する。`supabase link`、`db push`、`--linked`は使用しない。

## Verification inventory / 実行状況

全SQLは`BEGIN`〜`ROLLBACK`で検証データを戻し、Local Admin fixtureを前提とする。

| Phase | Verification | 主な不変条件 | Runtime |
|---|---|---|---|
| 1 | `202609300001_exhibition_workflow_v2_foundation_verification.sql` | Version、締切順序、Agreement、Audit、Legacy | PASS |
| 2 | `202609300002_exhibition_application_v2_verification.sql` | Application Snapshot、再申込、権限 | PASS |
| 3 | `202609300003_exhibition_work_submission_v2_verification.sql` | Work Snapshot、Review、Replacement、Storage original | PASS |
| 4 | `202609300004_exhibition_caption_workflow_v2_verification.sql` | Caption Snapshot、英題、Correction/Re-edit | PASS |
| 5 | `202609300005_exhibition_action_center_v2_verification.sql` | stale検出、SYSTEM期限処理、Action Center | PASS |
| 6 | `202609300006_exhibition_layout_finalization_v2_verification.sql` | Layout、物理再確認、display_no | PASS |
| 7 | `202609300007_exhibition_export_v2_verification.sql` | Export provenance、CSV、immutable version | PASS |
| 8 | `202610010001_exhibition_publication_survey_v2_verification.sql` | Publication、NO IMAGE、Survey、Storage | PASS |
| 9 | `202610010002_exhibition_actual_v2_verification.sql` | Planned対Actual、Correction、authoritative set | PASS |
| 10 | `202610010003_exhibition_archive_v2_verification.sql` | Actual由来Archive、A1/A2、Current、Legacy | PASS |
| 11 | `202610010004_exhibition_workflow_v2_integration_verification.sql` | 全ライフサイクルとcross-phase mutation | PASS |

## Phase 11統合シナリオ

統合SQLは実RPCを使って次を一つのEventで検証する。

- Application → Work 2件 → Caption → Layout → Export
- Workのtitle-only再編集後、物理Layoutは維持しつつ古いCaption/Exportを拒否
- Caption再提出後にExport V2を作成し、Export V1が不変
- 掲載同意true/falseを含むPublicationとNO IMAGE境界
- 不同意作品へのUUID Survey回答とrespondent hash
- Actualで一方を`not_exhibited`にし、Archiveが展示作品だけを採用
- Snapshot UUID、display_no、配置、Audit chain
- 一般部員/AnonymousによるAdmin操作・内部履歴列挙の拒否

## Security review（静的）

- Workflow v2の`SECURITY DEFINER`定義は明示的な空`search_path`を使用している。
- 動的SQLは検出されなかった。
- Admin RPCは関数内で`private.is_admin()`を確認し、SYSTEM処理はAdminまたは`service_role`へ限定している。
- private helper/immutable trigger関数は`public`、`anon`、`authenticated`からrevokeされている。
- Application/Work/Captionはcallerの`private.current_member_id()`と対象所有者を照合する。
- Export/Publication/Actual/Archive/Audit内部表は一般部員向け一覧を許可しない設計である。

静的レビューに加え、Local DB-only verificationでRLS/RPCの権限境界を実行確認し、**PASS**した。

| Resource | Anonymous | Member | Admin | service_role | Static result |
|---|---|---|---|---|---|
| Application / Snapshots | 非公開 | 本人のみ、履歴直接変更不可 | 管理参照 | SYSTEM処理のみ必要時 | 設計OK |
| Work / Snapshots / Reviews | 非公開 | 本人Working Data、本人履歴 | Review/救済 | 期限処理 | 設計OK |
| Caption / Snapshots / Reviews | 非公開 | 本人Working Data、本人履歴 | Review/救済 | 期限処理 | 設計OK |
| Layout / Finalization / display_no | 非公開 | 管理内部を変更不可 | 管理操作 | 特別経路なし | 設計OK |
| Export | 非公開 | 列挙・FINAL不可 | 管理操作 | 特別経路なし | 設計OK |
| Publication内部表 | Public RPC経由のみ | 内部表列挙不可 | 管理操作 | 特別経路なし | 設計OK |
| Survey | 安全なsubmit RPC | 安全なsubmit RPC | 管理参照 | 特別経路なし | 設計OK |
| Actual / Archive | 非公開 | 列挙・変更不可 | 管理操作 | 特別経路なし | 設計OK |
| Audit Log | 非公開 | 偽造・変更不可 | 管理参照 | private writer経由 | 設計OK |
| Storage original/public | Public bucketのみ公開 | originalは本人pathのみ | Public派生画像管理 | Storage service | DB policy検証PASS |

## Storage / Public boundary

静的確認:

- 原画像は`exhibition-originals`に置き、Work Snapshot参照中の削除をStorage policyで防ぐ。
- Publicationで参照中の公開画像とDM画像はupdate/delete policyで保護する。
- `publication_consent=false`はPublication Itemの`no_image` + NULL path制約で固定される。
- Public RPCは不同意作品の`publicImagePath`をNULLとして返す。
- Actual/Archiveの内部データはPublic RPCから公開されない。

Phase 11で、`admin_set_exhibition_public_image_v2`がPublic Storage上の実在確認をせず任意のpath文字列を受理する欠陥を発見した。Phase 8 Migrationを最小修正し、次をDB側で必須化した。

- `exhibition-public` bucketに同名objectが実在すること
- 他Workが使用中またはimmutable Publicationへ固定済みのpathを流用しないこと
- Phase 8/11 verificationでprivate・存在しないpathの拒否を確認すること

修正後のDB runtime検証はPhase 8およびPhase 11で**PASS**した。

Storage policyのDB runtime検証: **PASS**。Storage APIを含むfull-stack検証は未実施。

## Legacy regression

各Phase SQLにworkflow v1/Legacyの非昇格・既存表/RPC維持のassertionがある。Phase 10はLegacy Archiveを従来表へ作成・読取する検証を含み、Local DB-only runtimeで**PASS**した。

## Frontend / Browser

| Gate | Status |
|---|---|
| `git diff --check` | PASS |
| `node --check web/src/main.js` | PASS |
| `npm --prefix web run build` | PASS |
| 公開サイトJavaScript syntax | PASS |
| Jekyll build | NOT EXECUTED（依存環境を追加しない） |
| Browser E2E | NOT EXECUTED（非Production backendなし） |

## Release-critical gates

| Gate | Status |
|---|---|
| clean DBへ全Migration適用 | PASS |
| Phase 1〜10 verification | ALL PASS |
| Phase 11 integration | PASS |
| RLS/RPC authorization runtime | PASS（DB-only） |
| Storage privacy runtime | PASS（DB policy。Storage API full-stackは未実施） |
| Public NO IMAGE runtime | PASS（DB-only） |
| Legacy critical paths runtime | PASS（DB-only） |
| Frontend build | PASS |
| `git diff --check` | PASS |
| 最終静的release review | PASS（application / DB implementation上のrelease blockerなし） |
| Critical/high defect | 公開画像path検証欠落を修正済み、runtime回帰PASS |

## Production rollout前の必須作業

1. Local専用clean DBでの一括Migration・Phase 1〜11検証は完了済み（ALL PASS）。
2. Production適用前にバックアップと、適用対象Migration 10件の順序を再確認する。
3. Production適用後、Storage APIを含むoriginal/private/public境界を最小smoke testで確認する。
4. member/admin/publicの主要導線を最小smoke testで確認する。
5. Legacyの申込・公開・Survey・Archive主要経路が維持されていることを最小smoke testで確認する。

## Rollback considerations

Phase 1〜10は多数の新規表・列・trigger・RPCを追加するため、Production適用後にMigrationファイルを巻き戻して再実行してはならない。適用前バックアップとstaging検証を必須とし、適用後の不具合は追加Migrationで前方修正する。Archive/Actual/Publication/Export等のimmutable履歴を手動削除して復旧しない。
