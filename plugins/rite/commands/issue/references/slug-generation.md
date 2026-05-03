# Slug Generation — Pre-generation Rules + Translation Guidelines

> **Source of Truth**: 本ファイルは `/rite:issue:create` workflow における **Issue slug 生成** の正規定義 SoT である。Tentative slug pre-generation (Phase 0.1.3) と確認済み slug の context retention rule を集約する。`create.md` Phase 0.1.3 / `create-decompose.md` Phase 0.7.2 / `create-interview.md` / `create-register.md` からは本 reference へ semantic 参照する。
>
> **抽出経緯**: Issue #773 (#768 P1-3 PR 5/8) で `create.md` Phase 0.1.3 の slug 生成ルール・翻訳ガイドライン・context retention rule を本 reference に集約。元ファイルには見出しと redirect notice のみ stub 残置（歴史的アンカー保持 + caller 内ナビゲーション維持）。caller の機能リンクは本ファイルのアンカー (`#slug-generation-rules` / `#translation-guidelines` / `#context-retention`) へ書き換え済み。

## Purpose

Issue slug を early に生成することで、Phase 0.7.2 (`create-decompose.md` Specification Document Saving) における重複した Japanese→English 翻訳を回避する。slug は tentative であり、Issue title が確定した時点で再確認・必要に応じて再生成される。

slug は extracted **What** element (Phase 0.1) または user input title から生成する。

---

## Slug Generation Rules

`create.md` Phase 0.1.3 の正規ルール。caller (Phase 0.7.2 含む) はすべて本セクションを single source of truth として参照する。Tentative と confirmed のいずれの場合も同一のルールが適用される。

| # | ルール | 補足 |
|---|--------|------|
| 1 | 日本語入力の場合、Claude が文脈を考慮して適切な英語に翻訳する | 例: `テトリスゲームを作る` → `tetris-game` / `ユーザー認証システム` → `user-auth-system` / `EC サイト基盤構築` → `ec-site-infrastructure` |
| 2 | すべて小文字に変換する | `Tetris-Game` → `tetris-game` |
| 3 | 空白をハイフン (`-`) に置換する | `user auth system` → `user-auth-system` |
| 4 | 特殊文字を除去する | `user@auth#` → `userauth` |
| 5 | 50 文字以下に切り詰める | 長文タイトルは concept を保持しつつ truncate |

---

## Translation Guidelines

ルール 1 の Japanese→English 翻訳に関する細則。caller は本セクションを参照することで、翻訳の一貫性を保証する。

| ガイドライン | 対応 |
|-------------|------|
| **技術用語は直接英語化** | `API` → `api` / `データベース` → `database` / `フロントエンド` → `frontend` |
| **固有名詞はローマ字化を許容** | `お知らせ機能` → `oshirase-feature` または `notification-feature`（より検索しやすい方を選択） |
| **迷う場合は一般的・検索可能な英語表現を選択** | プロジェクト内の既存命名と整合する表現を優先 |

---

## Context Retention

生成した slug は会話コンテキストに `{tentative_slug}` として保持し、後続フェーズ (Phase 0.7.2 等) で再利用する。caller 側ではこの retention rule に従って `{tentative_slug}` を参照する。

**`{tentative_slug}` が利用不能なケース** (e.g., Phase 0.1.3 が skip された / context が compaction で破棄された): 上記 [Slug Generation Rules](#slug-generation-rules) に従い再生成する。Phase 0.7.2 における再生成も同一ルールを適用する。
