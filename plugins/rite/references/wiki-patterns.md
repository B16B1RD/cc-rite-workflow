---
description: Wiki 操作の共通パターン（ディレクトリ構造、Git ブランチ管理、テンプレート展開）
---

# Wiki Patterns

Wiki 操作で使用する共通パターンを定義します。Wiki コマンド（init, ingest, query, lint）はこのリファレンスを参照して一貫した操作を行います。

## ディレクトリ構造

Wiki データは `.rite/wiki/` 配下に3層構造で格納されます。

```
.rite/wiki/
├── SCHEMA.md                 # Schema: 蓄積規約（人間 + LLM 共同管理）
├── index.md                  # 全ページのカタログ（Ingest 時に自動更新）
├── log.md                    # 変更履歴ログ（OKF 形式・人間向け・append-only）
├── raw/                      # Raw Sources（不変の一次データ）
│   ├── reviews/              #   レビュー結果
│   ├── retrospectives/       #   Issue 振り返り
│   └── fixes/                #   Fix 結果
└── pages/                    # Wiki ページ（LLM 所有）
    ├── patterns/             #   繰り返しパターン
    ├── heuristics/           #   経験則
    └── anti-patterns/        #   アンチパターン
```

### 層の役割

| 層 | 場所 | 所有者 | 性質 |
|---|---|---|---|
| **Raw Sources** | `.rite/wiki/raw/` | rite ワークフロー（自動生成） | 不変の一次データ |
| **Wiki** | `.rite/wiki/pages/` | LLM（自動生成・更新） | 読解・統合された加工済み知識 |
| **Schema** | `.rite/wiki/SCHEMA.md` | 人間 + LLM（共同管理） | 蓄積規約 |

## ブランチ管理

Wiki データは開発ブランチとは別に管理し、PR diff との分離を確保します。

### ブランチ戦略

`rite-config.yml` の `wiki.branch_strategy` で制御:

| 戦略 | 説明 | 推奨用途 |
|------|------|---------|
| `separate_branch` (推奨) | Wiki データを専用ブランチで管理 | 全プロジェクト（PR diff に Wiki 変更が混入しない） |
| `same_branch` | 開発ブランチと同じブランチで管理 | 小規模プロジェクト、Wiki 変更も PR でレビューしたい場合 |

### separate_branch 戦略のブランチ操作

#### Wiki ブランチの作成（初期化時）

> **Runtime 実装**: 初期化時のブランチ作成は `hooks/scripts/wiki-branch-init.sh` が単一プロセスで実行する (`/rite:wiki-init` ステップ 3.1 から委譲呼び出し)。下記は操作パターンの参照実装であり、動作を変更する際は helper 側を SoT として同期すること。

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
current_branch=$(git branch --show-current)

# cleanup trap: 異常終了時に元のブランチに復帰を保証
# canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
_rite_wiki_init_cleanup() {
  git checkout "$current_branch" 2>/dev/null || true
  if [ "${stash_needed:-false}" = true ]; then
    git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
  fi
}
trap 'rc=$?; _rite_wiki_init_cleanup; exit $rc' EXIT
trap '_rite_wiki_init_cleanup; exit 130' INT
trap '_rite_wiki_init_cleanup; exit 143' TERM
trap '_rite_wiki_init_cleanup; exit 129' HUP

# dirty tree チェック: stash が必要な場合のみ実行
stash_needed=false
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
  git stash push -m "rite-wiki-init-stash"
  stash_needed=true
fi

# orphan ブランチとして作成（開発履歴を含まない）
git checkout --orphan "$wiki_branch" || { echo "ERROR: git checkout --orphan failed" >&2; exit 1; }
git rm -rf . 2>/dev/null || true
# Wiki ファイルを配置してコミット
git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
git commit -m "feat(wiki): initialize Wiki structure" || { echo "ERROR: git commit failed" >&2; exit 1; }
git push origin "$wiki_branch" || { echo "ERROR: git push failed" >&2; exit 1; }

# 元のブランチに戻る（git checkout - は --orphan 後に動作しないため明示的に指定）
git checkout "$current_branch" || {
  echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
  exit 1
}

# stash した場合のみ pop
if [ "$stash_needed" = true ]; then
  git stash pop
  stash_needed=false  # EXIT trap での二重 pop を防止
fi

# cleanup trap を解除（正常完了時は不要）
trap - EXIT INT TERM HUP
```

#### Wiki ブランチへの書き込み（Ingest 時）

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
current_branch=$(git branch --show-current)

# cleanup trap: 異常終了時に元のブランチに復帰を保証
# canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
_rite_wiki_ingest_cleanup() {
  git checkout "$current_branch" 2>/dev/null || true
  if [ "${stash_needed:-false}" = true ]; then
    git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
  fi
}
trap 'rc=$?; _rite_wiki_ingest_cleanup; exit $rc' EXIT
trap '_rite_wiki_ingest_cleanup; exit 130' INT
trap '_rite_wiki_ingest_cleanup; exit 143' TERM
trap '_rite_wiki_ingest_cleanup; exit 129' HUP

# dirty tree チェック: stash が必要な場合のみ実行
stash_needed=false
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
  git stash push -m "rite-wiki-stash"
  stash_needed=true
fi

# Wiki ブランチに切り替え
git checkout "$wiki_branch" || { echo "ERROR: git checkout '$wiki_branch' failed" >&2; exit 1; }

# Wiki ファイルの変更を適用
# ... (ingest/update operations)

git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
git commit -m "docs(wiki): {action} - {description}" || { echo "ERROR: git commit failed" >&2; exit 1; }
git push origin "$wiki_branch" || { echo "ERROR: git push failed" >&2; exit 1; }

# 元のブランチに戻る
git checkout "$current_branch" || {
  echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
  exit 1
}

# stash した場合のみ pop
if [ "$stash_needed" = true ]; then
  git stash pop
  stash_needed=false  # EXIT trap での二重 pop を防止
fi

# cleanup trap を解除（正常完了時は不要）
trap - EXIT INT TERM HUP
```

#### Wiki ブランチからの読み込み（Query 時）

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"

# ブランチ切り替えなしで Wiki ファイルを読み取り
if ! git show "${wiki_branch}:.rite/wiki/index.md" 2>/dev/null; then
  echo "ERROR: Wiki index not found on branch '${wiki_branch}'" >&2
  echo "  対処: Wiki が初期化済みか確認してください (/rite:wiki-init)" >&2
  exit 1
fi
if ! git show "${wiki_branch}:.rite/wiki/pages/{page_path}" 2>/dev/null; then
  echo "WARNING: Wiki page not found: .rite/wiki/pages/{page_path} on branch '${wiki_branch}'" >&2
fi
```

### same_branch 戦略

`same_branch` 戦略では Wiki データは開発ブランチに直接コミットされます。ブランチ切り替えは不要ですが、Wiki 変更が PR diff に含まれます。

```bash
# 直接ファイル操作（ブランチ切り替え不要）
# .rite/wiki/ 配下のファイルを Read/Write ツールで操作
git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
git commit -m "docs(wiki): {action} - {description}" || { echo "ERROR: git commit failed" >&2; exit 1; }
```

## テンプレート展開パターン

Wiki 初期化時にテンプレートを `.rite/wiki/` に展開します。

### テンプレートソース

テンプレートは `{plugin_root}/templates/wiki/` に配置:

| テンプレート | 展開先 | 説明 |
|-------------|--------|------|
| `schema-template.md` | `.rite/wiki/SCHEMA.md` | 蓄積規約 |
| `page-template.md` | (Ingest 時に使用) | 新規ページ作成テンプレート |
| `index-template.md` | `.rite/wiki/index.md` | インデックス |
| `log-template.md` | `.rite/wiki/log.md` | 変更履歴ログ（OKF 形式） |

### プレースホルダー置換

テンプレート内の `{placeholder}` をランタイム値に置換:

| プレースホルダー | 値 |
|----------------|-----|
| `{initialized_date}` | 初期化日（`YYYY-MM-DD`、date-only）。log.md の OKF 日付見出し `## YYYY-MM-DD` に展開。index.md には展開されない（index.md の `- 最終更新:` 行は下記 `{initialized_at}` を使う） |
| `{initialized_at}` | 初期化タイムスタンプ（ISO 8601）。index.md `## 統計` の `- 最終更新:` 行に展開 |
| `{okf_version}` | OKF 仕様バージョン。index.md frontmatter の `okf_version: "0.1"` に展開（OKF v0.1 準拠の宣言、Issue #1519） |
| `{concept_type}` | concept 種別（`patterns` / `heuristics` / `anti-patterns`、`{domain}` と同値）。page-template.md frontmatter の OKF 必須フィールド `type:` に展開（Issue #1518）。詳細は `plugins/rite/skills/wiki-ingest/SKILL.md` ステップ 5.3 の `{concept_type}` 行を SoT として参照 |
| `{title}` | ページタイトル（Ingest 時） |
| `{domain}` | ドメイン名（Ingest 時） |
| `{created}` | 作成日時（Ingest 時） |
| `{updated}` | 更新日時（Ingest 時） |
| `{source_type}` | ソースタイプ（reviews/retrospectives/fixes） |
| `{source_ref}` | Raw Source へのファイルパス形式 (`raw/{type}/{filename}`、wiki-root 起点) の相対パス。**PR 識別子形式 (`pr-NNNN`) は禁止**。詳細は `plugins/rite/skills/wiki-ingest/SKILL.md` ステップ 5.3 の `{source_ref}` 行 (dual-use 警告) を SoT として参照 |
| `{summary}` | ページ概要（1-2文、Ingest 時） |
| `{details}` | 詳細説明（Ingest 時） |
| `{related_page_title}` | 関連ページのタイトル（Ingest 時） |
| `{related_page_path}` | 関連ページへの **page-dir 相対パス**（Ingest 時）。新規 page 格納位置 `.rite/wiki/pages/{domain}/{slug}.md` の格納ディレクトリ `.rite/wiki/pages/{domain}/` を起点として resolve される。同ドメイン内は `./other.md` または `other.md`、別ドメインは `../{other_domain}/other.md` の形式で substitute する。`{source_ref}` (wiki-root 起点、template 側で `../../` prefix を hardcode) とは **起点が異なる** 点に注意。詳細は `plugins/rite/skills/wiki-ingest/SKILL.md` ステップ 5.3 の「設計意図」を参照 |
| `{source_description}` | ソースの説明文（Ingest 時） |

> **F-14 fix（関連ページなし時の操作契約）**: 確信ある関連ページが特定できない場合、`{related_page_title}` / `{related_page_path}` の両 placeholder への substitute は行わず、`## 関連ページ` セクション全体を Edit で `- （関連ページなし）` の平文 1 行に差し替える（空 placeholder のままにすると Markdown リンク `[]()` が破綻するため）。

> **canonical 階層** (ingest.md 内の 2 種 canonical の概念分離): ingest.md には (a) ステップ 4.3「関連ページの特定」= `{related_page_title}` / `{related_page_path}` の**値決定手順** canonical (同セクション冒頭で「本セクションが値決定手順の canonical source」と明示宣言) と (b) ステップ 5.3 placeholder 表の `{related_page_title}` / `{related_page_path}` 行 = **F-14 fix 動作契約** canonical (動作契約の詳細はステップ 4.3「該当ページなし時の処理」で記述され、実体はステップ 5.3 placeholder 表の同 placeholder 行) が共存する。両者は別概念 (手順 vs 動作契約) で並立。本 NOTE は (b) を扱うため canonical = `plugins/rite/skills/wiki-ingest/SKILL.md` ステップ 5.3 placeholder 表の `{related_page_title}` / `{related_page_path}` 行。なお F-14 fix により ステップ 4.3「該当ページなし時の処理」(詳細手順) と ステップ 5.3 placeholder 表 (要約) は同一の操作契約を併記する dual-site として維持される。references → ingest.md 方向は本 NOTE のように要約参照に集約する方針 (ingest.md 内 dual-site 維持とは別方針)。

> **F-14 fix 識別子の disambiguation**: lint.md にも別文脈の F-14 fix (`{log_entry}` placeholder 残留検知) があるため、識別子のみで参照する場合は本 NOTE が指す F-14 fix が「関連ページなし時の操作契約」 であることに注意。

> **confidence フィールド**: page-template.md の `confidence: medium` はリテラル値であり `{confidence}` プレースホルダーではない。Write 後に Edit で ステップ 4 の判定値 (`high` / `medium` / `low`) に置換する。

## OKF v0.1 準拠

rite Wiki bundle（`.rite/wiki/`）は [Open Knowledge Format (OKF) v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog) に準拠した構造で蓄積します（**`index.md` のカタログ形式のみ意図的に逸脱** — 下記 producer 責務の注記を参照）。準拠により、上流の OKF 静的 visualizer で経験則を概念グラフとして閲覧できます（[Visualizer 連携](#okf-visualizer-連携)参照）。

### 準拠規約（SoT は各テンプレート / コマンド）

| 要素 | OKF 準拠内容 | 実装 SoT |
|------|-------------|---------|
| **page frontmatter** | concept 種別を `type:`（`patterns` / `heuristics` / `anti-patterns`）で宣言し、`description:` を持つ | `templates/wiki/page-template.md`（Issue #1518） |
| **index.md** | frontmatter に `okf_version: "0.1"` を持ち、ページカタログを `## ページ一覧` の 5 列テーブル（列順: ページ / ドメイン / サマリー / 更新日 / 確信度）で表現。箇条書きテンプレートが配布されていた期間に初期化された bundle の index.md は箇条書きのまま残るため、consumer は行単位で両形式を受けることが要件（本リポジトリの wiki ブランチでは未観測。両形式対応は外部 bundle への防御的サポート）。`/rite:wiki-query` の Pass 1 は行単位で両形式を受ける（テーブル行はセルの `\|` エスケープを復元し、ページ列の最初のリンクを候補にする） | `templates/wiki/index-template.md` |
| **log.md** | 変更履歴を OKF 予約構造（`## YYYY-MM-DD` 見出し + 散文 bullet、新しい順、append-only、人間向け）で記録 | `templates/wiki/log-template.md`（Issue #1520） |
| **raw frontmatter** | ingest skip 状態を `ingest_status: skipped` + `skip_reason:` で保持（skip の Source of Truth。log.md には保持しない） | `skills/wiki-ingest/SKILL.md` ステップ 5（Issue #1520） |
| **SCHEMA.md** | 蓄積規約（人間 + LLM 共同管理）。OKF 予約ファイルとして bundle ルートに常駐 | `templates/wiki/schema-template.md` |

> **producer 責務**: 上表の frontmatter / 構造はすべて `/rite:wiki-init`（テンプレート展開）と `/rite:wiki-ingest`（ページ生成・更新）が producer として書き込む。consumer（`/rite:wiki-query` / `/rite:wiki-lint`）はこの構造を前提に読む。準拠仕様を変更する場合は各テンプレート / コマンドを SoT として同期する。**ただし `index.md` のカタログ形式は上表のとおり 5 列テーブルであり、OKF v0.1 の箇条書きカタログ `* [title](path) - desc` には準拠しない**（テンプレート・ingest ステップ 6・実体を 5 列テーブルで揃えた意図的な逸脱。`docs/SPEC.md` の OKF v0.1 Conformance 節の `index.md` 行を参照）。

## OKF Visualizer 連携

`.rite/wiki/` bundle は、上流の OKF 静的 HTML visualizer（[`GoogleCloudPlatform/knowledge-catalog`](https://github.com/GoogleCloudPlatform/knowledge-catalog)）で概念グラフとして閲覧することを想定した構造です。**visualizer 本体は rite リポジトリに同梱しません**（vendoring せず、起動手順のみ提供）。

> **カタログ形式は visualizer の描画に影響しません**: 上記「準拠規約」節のとおり `index.md` のカタログ形式は現在テーブル形式で OKF v0.1 箇条書きから意図的に逸脱していますが、上流 visualizer は概念グラフ構築時に `index.md` を走査対象から除外します。ノードは各 page の frontmatter から、辺は**本文の Markdown リンクのみ**から構築されます（frontmatter の `sources` はノードに添付されるデータで、辺にはなりません）。したがってカタログ形式の逸脱は閲覧可否に関係しません。
>
> 出典: 上流 `okf/src/reference_agent/viewer/generator.py` の `_walk_concepts`（`index.md` を skip）と `_build_graph`（`links_to` のみを辺にする）。2026-08 時点、上流 main で確認。再検証: `gh api repos/GoogleCloudPlatform/knowledge-catalog/contents/okf/src/reference_agent/viewer/generator.py --jq .content | base64 -d`

### ライセンス確認

上流 visualizer は **Apache License 2.0**（2026-06 時点）で配布されています。利用前に上流リポジトリの `LICENSE` を直接確認してください:

```bash
gh api repos/GoogleCloudPlatform/knowledge-catalog/license --jq '.license.spdx_id'
# または https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/LICENSE を参照
```

rite は visualizer の成果物をコピー・改変しません。取得・実行は利用者の責任で、上流ライセンス条件に従ってください。

### bundle の materialize

visualizer は `.rite/wiki/` をファイルシステム上のディレクトリとして読みます。`branch_strategy` により materialize 手順が異なります:

- **separate_branch（推奨）**: Wiki データは専用ブランチ（既定 `wiki`）にあり、開発ツリーには存在しません。既存の wiki worktree helper で materialize します。`plugin_root` は local 開発・marketplace install の両方を解決する inline one-liner（[Plugin Path Resolution](plugin-path-resolution.md#inline-one-liner-for-command-files) 参照。`skills/wiki-ingest/SKILL.md` / `setup.md` と同一）で得ます:

  ```bash
  # plugin_root を解決（install 時は ~/.claude/plugins/.../rite に解決される）
  plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

  # wiki ブランチを .rite/wiki-worktree/ にチェックアウト（既存 helper を再利用）
  bash "$plugin_root/hooks/scripts/wiki-worktree-setup.sh"
  # → .rite/wiki-worktree/.rite/wiki/ に bundle が materialize される
  ```

  worktree が未整備の場合も本 helper が冪等に用意します。bundle パスは `.rite/wiki-worktree/.rite/wiki/` です。

- **same_branch**: Wiki データは開発ブランチに直接コミットされているため、`.rite/wiki/` がそのまま bundle パスです（materialize 不要）。

### visualizer の起動

上流 visualizer を取得し、materialize した bundle パスを入力として向けます（具体的な起動コマンドは上流 README を参照）。未取得でも本手順は **非破壊**（bundle を変更しません）:

```bash
# 例: 上流を取得（vendoring せず作業ディレクトリ外に clone）
git clone https://github.com/GoogleCloudPlatform/knowledge-catalog /tmp/okf-visualizer
# 上流 README の手順に従い、bundle パス（上記 materialize 結果）を visualizer に渡す
```

準拠 bundle では、page 本文の Markdown リンク（page 間の相互参照）が概念グラフの辺として描画されます。frontmatter の `sources` は辺ではなくノードに添付されるデータです（上記「カタログ形式は visualizer の描画に影響しません」の出典を参照）。

## Wiki 有効判定パターン

Wiki 操作の前に必ず有効判定を行います。**Wiki は opt-out**: `wiki:` セクション自体や `enabled` キーが未指定の場合は default-on (有効) として扱います。明示的に `false|no|0` が指定された場合のみ無効化されます:

```bash
# Wiki は opt-out — section/key 未指定時のデフォルトは true
wiki_enabled=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+enabled:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]')
wiki_enabled=$(echo "$wiki_enabled" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)          wiki_enabled="true" ;;  # opt-out default
esac

if [ "$wiki_enabled" != "true" ]; then
  echo "Wiki is explicitly disabled (wiki.enabled: false in rite-config.yml)"
  exit 0
fi
```

### 分散実装ファイル一覧 (Single Source of Truth)

`wiki.enabled` パースを実装するファイルは以下の通り。本セクションが**唯一の同期一覧**。将来パース仕様を変更する PR は本一覧の全 site を漏れなく同期更新する義務がある:

- `plugins/rite/skills/wiki-query/SKILL.md` ステップ 1.1 (probe 用簡易パーサ、本ファイル参照)
- `plugins/rite/skills/wiki-ingest/SKILL.md` ステップ 1.1 (`lib/wiki-config.sh` の `parse_wiki_scalar` へ委譲、`wiki_enabled` のみ呼び出し側で lowercase 適用。helper 解決不可は fail-fast `WIKI_CONFIG_HELPER_UNAVAILABLE`)
- `plugins/rite/skills/wiki-lint/SKILL.md` ステップ 1.1 (ingest.md と対称な `parse_wiki_scalar` 委譲、`wiki_enabled` のみ呼び出し側で lowercase 適用。helper 解決不可は fail-fast)
- `plugins/rite/skills/wiki-init/SKILL.md` (init 時の状態判定)
- `plugins/rite/skills/setup/SKILL.md` Phase 4.7 (`/rite:setup` 内 Wiki 自動初期化判定、独自 inline 実装 + typo 検出 WARNING 付き)
- `plugins/rite/skills/cleanup/SKILL.md` ステップ 9 (`parse_wiki_scalar` 委譲、auto_ingest 起動条件。helper 解決不可は skip reason `config_helper_unavailable`)
- `plugins/rite/skills/fix/SKILL.md` ステップ 0.5.W / 4.6.W (Wiki query / ingest 起動条件)
- `plugins/rite/skills/pr-review/SKILL.md` ステップ 4.0.W / 6.5.W (Wiki query / ingest 起動条件)
- `plugins/rite/skills/issue-implement/SKILL.md` (Wiki query 起動条件)
- `plugins/rite/skills/issue-close/SKILL.md` Phase 4.4.W (`parse_wiki_scalar` 委譲、Wiki ingest 起動条件。helper 解決不可は skip reason `config_helper_unavailable`)
- `plugins/rite/hooks/wiki-query-inject.sh` (auto_query 注入の前提判定、ローカル helper `_extract_yaml_value`)
- `plugins/rite/hooks/wiki-ingest-trigger.sh` (raw source staging の事前ゲート、`wiki.enabled` のみ参照、独自 inline 実装 — wiki-config.sh とは別経路。self-comment の inline 実装リストで自身 + growth-check.sh + gitignore-health-check.sh の 3 site を列挙し、完全一覧は本セクションを SoT として指す)
- `plugins/rite/hooks/scripts/wiki-growth-check.sh` (layer 3 growth stall 判定、独自 inline 実装 lenient)
- `plugins/rite/hooks/scripts/gitignore-health-check.sh` (gitignore drift 判定、独自 inline 実装 lenient)
- `plugins/rite/hooks/scripts/lib/wiki-config.sh` (共通 helper `parse_wiki_scalar`、lenient — callers: wiki-ingest-commit.sh / wiki-worktree-commit.sh / wiki-worktree-setup.sh の各 script、および skills 側の wiki-ingest / wiki-lint / cleanup / issue-close が `source` 経由で再利用。skills が inline パーサを持てないのは Skill loader が本文の位置パラメータを起動引数へ展開するため — 静的検出は `hooks/scripts/dollar-zero-check.sh`)

**設計差異**:
- **lenient 経路**: ingest.md / lint.md / query.md / inject.sh / wiki-config.sh / 各 caller (cleanup.md / fix.md / pr-review.md / implement.md / close.md / setup.md) と独立 inline 実装 (growth-check.sh / gitignore-health-check.sh) は **lenient** — `false`/`no`/`0` のみ reject、それ以外 (`true`/`yes`/`1` も不明値も空文字も) は `true` として opt-out default 化する。ingest.md / lint.md は `case "$wiki_enabled" in false|no|0) wiki_enabled=false ;; *) wiki_enabled=true ;; esac` の 2-arm 形式
- **fail-fast 経路**: `wiki-ingest-trigger.sh` のみ意図的に **strict 3-arm with fail-fast `*`** (`case "$wiki_enabled"` の `*) ... exit 2` 分岐) — staging hook の safe-default policy violation 防止のため、`ture` / `yse` 等の typo / 不明値を即座に reject する。本 site だけが lenient ファミリと意図的に非対称
- **`branch_strategy` 検証**: ingest.md ステップ 1.1 では silent default で fill (probe 段階)、ステップ 5.1 (separate_branch 戦略) の if/elif/else 末尾 `else` 分岐で fail-fast 検証 (`ERROR: 未知の branch_strategy ... exit 1`) を行う 2 段階構造。ステップ 5.2 (same_branch 戦略) の bash block は `if [ "$branch_strategy" = "same_branch" ]` 単独分岐で branch_strategy の fail-fast を持たない (未知値は先行するステップ 5.1 の else が catch する)。ステップ 5.1 内の case 文 fail-fast (`commit_msg` placeholder gate は placeholder パターン arm、`commit_rc` は `*)` arm) は branch_strategy 検証ではない。lint.md ステップ 1.1 (Wiki 設定の読み取りとブランチ戦略判定) の `branch_strategy` 検証は case-based (`*) ... exit 1`) で、ingest.md の else-based とは構文が異なるが同じ fail-fast 契約

## Wiki 初期化判定パターン

Wiki が既に初期化済みかを判定します:

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
branch_strategy=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_strategy:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_strategy:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
branch_strategy="${branch_strategy:-separate_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # separate_branch: Wiki ブランチの存在で判定
  if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
     git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
else
  # same_branch: SCHEMA.md の存在で判定
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
fi
```
