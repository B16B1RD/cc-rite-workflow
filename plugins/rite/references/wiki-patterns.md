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
├── log.md                    # 変更履歴ログ（OKF 形式・人間向け・append-only。lint エントリの「未解消の矛盾」行だけは lint と ingest が読む）
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
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash {plugin_root}/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_branch=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
current_branch=$(git branch --show-current)

# stash は submodule の変更を退避せず、git diff は submodule 内の未追跡ファイルを変更と見なさない。
# 何かを変更する前に両方を検出して止める。利用者の設定で検出が外れないよう、submodule の ignore 設定と
# 未追跡ファイルの非表示設定をこの呼び出しに限って上書きする
status_v2=$(git -c status.showUntrackedFiles=normal status --porcelain=v2 --ignore-submodules=none) || { echo "ERROR: git status failed" >&2; exit 1; }
changed_submodules=$(printf '%s\n' "$status_v2" | awk '
  ($1 == "1" || $1 == "2" || $1 == "u") && $3 ~ /^S/ {
    n = ($1 == "1") ? 8 : ($1 == "2") ? 9 : 10
    for (i = 0; i < n; i++) $0 = substr($0, index($0, " ") + 1)
    sub(/\t.*/, "")
    print
  }')
if [ -n "$changed_submodules" ]; then
  echo "ERROR: submodule に変更または未追跡ファイルがあります。ブランチ・作業ツリー・stash を変更せずに停止します" >&2
  printf '%s\n' "$changed_submodules" | sed 's/^/  対象: /' >&2
  echo "  対処: 変更を残すなら submodule の変更（未追跡ファイルは commit するか submodule の外へ移す）と親の新しい参照先を commit し、残さないなら submodule を記録済みの commit と中身に戻して、git status に submodule が表示されなくなってから再実行してください" >&2
  echo "  確認: git -c status.showUntrackedFiles=normal status --ignore-submodules=none" >&2
  exit 1
fi
submodules_before=$(git submodule status) || { echo "ERROR: git submodule status failed" >&2; exit 1; }

# 元のブランチへ戻ったあと、submodule が実行前と同じ commit で展開されていることを確かめる。
# signal trap の exit で EXIT trap も走るため、照合の前に verify_needed を下ろして 2 回目を防ぐ
verify_needed=true
_rite_verify_submodules() {
  local after
  [ "$verify_needed" = true ] || return 0
  verify_needed=false
  if ! after=$(git submodule status) || [ "$after" != "$submodules_before" ]; then
    echo "ERROR: submodule の状態が実行前と一致しません — git submodule update で記録済みの commit を展開し直してください" >&2
    return 1
  fi
}

stash_needed=false
# stash は全 worktree で共有され、並行セッションが上に積みうる。自分の entry は push 時の SHA で特定する
stash_sha=""

# SHA が一致する stash@{n} だけを pop する。見つからなければほかの entry に触れず失敗を返す
_rite_pop_own_stash() {
  local ref
  ref=$(git stash list --format='%gd %H' | awk -v s="$stash_sha" '$2 == s {print $1; exit}')
  if [ -z "$ref" ]; then
    echo "ERROR: 退避した変更 (stash $stash_sha) が stash に見つかりません。ほかの stash entry には触れずに停止します" >&2
    echo "  確認: git stash list --format='%gd %H %gs'" >&2
    return 1
  fi
  git stash pop "$ref" || { echo "ERROR: 退避した変更 ($ref) を戻せませんでした — git stash list --format='%gd %H %gs' で確認して手動で復旧してください" >&2; return 1; }
}

# cleanup trap: 異常終了時に元のブランチに復帰を保証。pop は元のブランチへ戻れたときだけ行う
# canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
_rite_wiki_init_cleanup() {
  if git checkout "$current_branch" 2>/dev/null; then
    # signal trap の exit で EXIT trap も走るため、pop の前に stash_needed を下ろして 2 回目を防ぐ
    [ "$stash_needed" = true ] && { stash_needed=false; _rite_pop_own_stash; }
    _rite_verify_submodules
  elif [ "$stash_needed" = true ]; then
    echo "WARNING: 元のブランチへ戻れなかったため、退避した変更 (stash $stash_sha) を戻していません" >&2
    echo "  復旧: git checkout '$current_branch' のあと、git stash list --format='%gd %H %gs' で SHA が一致する entry を pop します" >&2
  fi
}
trap 'rc=$?; _rite_wiki_init_cleanup; exit $rc' EXIT
trap '_rite_wiki_init_cleanup; exit 130' INT
trap '_rite_wiki_init_cleanup; exit 143' TERM
trap '_rite_wiki_init_cleanup; exit 129' HUP

# dirty tree チェック: stash が必要な場合のみ実行し、新しく積んだ entry の SHA を記録する
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
  stash_before=$(git rev-parse -q --verify refs/stash) || stash_before=""
  git stash push -m "rite-wiki-init-stash" || { echo "ERROR: git stash push failed" >&2; exit 1; }
  stash_sha=$(git rev-parse -q --verify refs/stash) || stash_sha=""
  [ -n "$stash_sha" ] && [ "$stash_sha" != "$stash_before" ] || { echo "ERROR: git stash push が新しい entry を作りませんでした" >&2; exit 1; }
  stash_needed=true
fi

# orphan ブランチとして作成（開発履歴を含まない）
git checkout --orphan "$wiki_branch" || { echo "ERROR: git checkout --orphan failed" >&2; exit 1; }
# git rm は submodule の作業ツリーを中身ごと消し、元のブランチへ戻っても再展開されない。
# gitlink は index からだけ外し、作業ツリーには触れさせない。
# path は NUL 区切りで読む（行出力は " や \ を含む path を引用し、index の entry と一致しなくなる）
while IFS= read -r -d '' index_entry; do
  case "$index_entry" in
    160000\ *)
      git update-index --force-remove -- "${index_entry#*$'\t'}" \
        || { echo "ERROR: submodule '${index_entry#*$'\t'}' を index から外せませんでした" >&2; exit 1; }
      ;;
  esac
done < <(git ls-files -s -z)
# update-index は対象の entry が無くても成功を返す。gitlink が残ったまま git rm へ進まないよう index を読み直す
remaining_entries=$(git ls-files -s) || { echo "ERROR: git ls-files failed" >&2; exit 1; }
case $'\n'"$remaining_entries" in
  *$'\n160000 '*) echo "ERROR: submodule を index から外せませんでした。作業ツリーを消さずに停止します" >&2; exit 1 ;;
esac
git rm -rf . 2>/dev/null || true
# Wiki ファイルを配置してコミット
git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
# "$wiki_init_msg_file" は作業ツリー外の絶対パス。生成手順は plugins/rite/references/commit-convention.md の「helper への受渡し」。
bash "{plugin_root}/hooks/scripts/git-commit-file.sh" --file "$wiki_init_msg_file" || { echo "ERROR: git commit failed" >&2; exit 1; }
git push origin "$wiki_branch" || { echo "ERROR: git push failed" >&2; exit 1; }

# 元のブランチに戻る（git checkout - は --orphan 後に動作しないため明示的に指定）
git checkout "$current_branch" || {
  echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
  exit 1
}

# stash した場合のみ、自分の entry を pop
if [ "$stash_needed" = true ]; then
  stash_needed=false  # 成否によらず EXIT trap での二重 pop を防止
  _rite_pop_own_stash || exit 1
fi

# cleanup trap を解除（正常完了時は不要）
trap - EXIT INT TERM HUP

_rite_verify_submodules || exit 1
```

#### Wiki ブランチへの書き込み（Ingest 時）

```bash
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash {plugin_root}/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_branch=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
current_branch=$(git branch --show-current)
stash_needed=false
# stash は全 worktree で共有され、並行セッションが上に積みうる。自分の entry は push 時の SHA で特定する
stash_sha=""

# SHA が一致する stash@{n} だけを pop する。見つからなければほかの entry に触れず失敗を返す
_rite_pop_own_stash() {
  local ref
  ref=$(git stash list --format='%gd %H' | awk -v s="$stash_sha" '$2 == s {print $1; exit}')
  if [ -z "$ref" ]; then
    echo "ERROR: 退避した変更 (stash $stash_sha) が stash に見つかりません。ほかの stash entry には触れずに停止します" >&2
    echo "  確認: git stash list --format='%gd %H %gs'" >&2
    return 1
  fi
  git stash pop "$ref" || { echo "ERROR: 退避した変更 ($ref) を戻せませんでした — git stash list --format='%gd %H %gs' で確認して手動で復旧してください" >&2; return 1; }
}

# cleanup trap: 異常終了時に元のブランチに復帰を保証。pop は元のブランチへ戻れたときだけ行う
# canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
_rite_wiki_ingest_cleanup() {
  if git checkout "$current_branch" 2>/dev/null; then
    # signal trap の exit で EXIT trap も走るため、pop の前に stash_needed を下ろして 2 回目を防ぐ
    [ "$stash_needed" = true ] && { stash_needed=false; _rite_pop_own_stash; }
  elif [ "$stash_needed" = true ]; then
    echo "WARNING: 元のブランチへ戻れなかったため、退避した変更 (stash $stash_sha) を戻していません" >&2
    echo "  復旧: git checkout '$current_branch' のあと、git stash list --format='%gd %H %gs' で SHA が一致する entry を pop します" >&2
  fi
}
trap 'rc=$?; _rite_wiki_ingest_cleanup; exit $rc' EXIT
trap '_rite_wiki_ingest_cleanup; exit 130' INT
trap '_rite_wiki_ingest_cleanup; exit 143' TERM
trap '_rite_wiki_ingest_cleanup; exit 129' HUP

# dirty tree チェック: stash が必要な場合のみ実行し、新しく積んだ entry の SHA を記録する
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
  stash_before=$(git rev-parse -q --verify refs/stash) || stash_before=""
  git stash push -m "rite-wiki-stash" || { echo "ERROR: git stash push failed" >&2; exit 1; }
  stash_sha=$(git rev-parse -q --verify refs/stash) || stash_sha=""
  [ -n "$stash_sha" ] && [ "$stash_sha" != "$stash_before" ] || { echo "ERROR: git stash push が新しい entry を作りませんでした" >&2; exit 1; }
  stash_needed=true
fi

# Wiki ブランチに切り替え
git checkout "$wiki_branch" || { echo "ERROR: git checkout '$wiki_branch' failed" >&2; exit 1; }

# Wiki ファイルの変更を適用
# ... (ingest/update operations)

git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
bash "{plugin_root}/hooks/scripts/git-commit-file.sh" --file "$wiki_msg_file" || { echo "ERROR: git commit failed" >&2; exit 1; }
git push origin "$wiki_branch" || { echo "ERROR: git push failed" >&2; exit 1; }

# 元のブランチに戻る
git checkout "$current_branch" || {
  echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
  exit 1
}

# stash した場合のみ、自分の entry を pop
if [ "$stash_needed" = true ]; then
  stash_needed=false  # 成否によらず EXIT trap での二重 pop を防止
  _rite_pop_own_stash || exit 1
fi

# cleanup trap を解除（正常完了時は不要）
trap - EXIT INT TERM HUP
```

#### Wiki ブランチからの読み込み（Query 時）

```bash
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash {plugin_root}/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_branch=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null \
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
bash "{plugin_root}/hooks/scripts/git-commit-file.sh" --file "$wiki_msg_file" || { echo "ERROR: git commit failed" >&2; exit 1; }
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
| `{okf_version}` | OKF 仕様バージョン。index.md frontmatter の `okf_version: "0.2"` に展開し、生成物が準拠する OKF バージョンを明示する |
| `{concept_type}` | concept 種別（`patterns` / `heuristics` / `anti-patterns`、`{domain}` と同値）。page-template.md frontmatter の OKF 必須フィールド `type:` に展開。詳細は `plugins/rite/skills/wiki-ingest/SKILL.md` ステップ 5.3 の `{concept_type}` 行を SoT として参照 |
| `{title}` | ページタイトル（Ingest 時） |
| `{domain}` | ドメイン名（Ingest 時） |
| `{created}` | 初出日時（Ingest 時。独自拡張） |
| `{generated_at}` / `{model_id}` | `generated.at` と `generated.by` の model-id（Ingest 時） |
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

## OKF v0.2 準拠

rite Wiki bundle（`.rite/wiki/`）は [Open Knowledge Format (OKF) v0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog) に準拠した構造で蓄積します（**`index.md` のカタログ形式のみ意図的に逸脱** — 下記 producer 責務の注記を参照）。準拠により、上流の OKF 静的 visualizer で経験則を概念グラフとして閲覧できます（[Visualizer 連携](#okf-visualizer-連携)参照）。

上流 pin: 2026-08 時点、上流 main `82419d051f2c0299082a0aa76b32b762efd6bd3e`（`okf/SPEC.md` Version 0.2）。再検証: `gh api repos/GoogleCloudPlatform/knowledge-catalog/contents/okf/SPEC.md --jq .sha`（blob SHA ではなく commit は `git ls-remote https://github.com/GoogleCloudPlatform/knowledge-catalog.git HEAD`）。

### 準拠規約（SoT は各テンプレート / コマンド）

| 要素 | OKF 準拠内容 | 実装 SoT |
|------|-------------|---------|
| **page frontmatter** | concept 種別を `type:`（`patterns` / `heuristics` / `anti-patterns`）で宣言し、`description:` を持つ | `templates/wiki/page-template.md` |
| **index.md** | frontmatter に `okf_version: "0.2"` を持ち、ページカタログを `## ページ一覧` の 5 列テーブル（列順: ページ / ドメイン / サマリー / 更新日 / 確信度）で表現。箇条書きテンプレートが配布されていた期間に初期化された bundle の index.md は箇条書きのまま残るため、consumer は行単位で両形式を受けることが要件（本リポジトリの wiki ブランチでは未観測。両形式対応は外部 bundle への防御的サポート）。`/rite:wiki-query` の Pass 1 は行単位で両形式を受ける（テーブル行はセルの `\|` エスケープを復元し、ページ列の最初のリンクを候補にする） | `templates/wiki/index-template.md` |
| **log.md** | 変更履歴を OKF 予約構造（`## YYYY-MM-DD` 見出し + 散文 bullet、新しい順、append-only、人間向け）で記録。lint エントリの「未解消の矛盾」行だけは次回の lint と ingest が読む未解消の記録 | `templates/wiki/log-template.md` |
| **raw frontmatter** | ingest skip 状態を `ingest_status: skipped` + `skip_reason:` で保持（skip の Source of Truth。log.md には保持しない） | `skills/wiki-ingest/SKILL.md` ステップ 5 |
| **SCHEMA.md** | 蓄積規約（人間 + LLM 共同管理）。OKF 予約ファイルとして bundle ルートに常駐 | `templates/wiki/schema-template.md` |

> **producer 責務**: 上表の frontmatter / 構造はすべて `/rite:wiki-init`（テンプレート展開）と `/rite:wiki-ingest`（ページ生成・更新）が producer として書き込む。consumer（`/rite:wiki-query` / `/rite:wiki-lint`）はこの構造を前提に読む。準拠仕様を変更する場合は各テンプレート / コマンドを SoT として同期する。**ただし `index.md` のカタログ形式は上表のとおり 5 列テーブルであり、OKF の箇条書きカタログ `* [title](path) - desc` には準拠しない**（テンプレート・ingest ステップ 6・実体を 5 列テーブルで揃えた意図的な逸脱。v0.2 §8 は v0.1 から不変。`docs/SPEC.md` の OKF v0.2 Conformance 節の `index.md` 行を参照）。

ページ frontmatter は `sources[].resource`（v0.2 §5.1 REQUIRED）と `generated: {by, at}` を書く。`verified` / `status` / `stale_after` は実イベント時のみ。旧 bundle は wiki-ingest 冒頭の `wiki-okf-migrate.sh` が一括変換する。

## OKF Visualizer 連携

`.rite/wiki/` bundle は、上流の OKF 静的 HTML visualizer（[`GoogleCloudPlatform/knowledge-catalog`](https://github.com/GoogleCloudPlatform/knowledge-catalog)）で概念グラフとして閲覧することを想定した構造です。**visualizer 本体は rite リポジトリに同梱しません**（vendoring せず、起動手順のみ提供）。

> **カタログ形式は visualizer の描画に影響しません**: 上記「準拠規約」節のとおり `index.md` のカタログ形式は現在テーブル形式で OKF 箇条書きから意図的に逸脱していますが、上流 visualizer は概念グラフ構築時に `index.md` を走査対象から除外します。ノードは各 page の frontmatter から、辺は**本文の Markdown リンクのみ**から構築されます（frontmatter の `sources` はノードに添付されるデータで、辺にはなりません）。したがってカタログ形式の逸脱は閲覧可否に関係しません。
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
  plugin_root=$(cat .rite/plugin-root 2>/dev/null || cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

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

## 昇格候補

Wiki ページはプロジェクト固有の経験則を保持する。rite の挙動・スキル記述法は機械検出可否や既存ページ有無に関係なく raw の候補へ送る。新規 `promote: rite-plugin` ページは作らず、既存の `promote` / `reference` 付き発見ポインタは保持する。

`wiki-promotion-candidates.sh` が知見別の保存・列挙・作業対応・完了突合を行う。正本は既存 raw 本文の `## Promotion candidates` JSON fence と `ingest_status` / `skip_reason`。既存 log の `rite-promotion` コメントに対応 Issue/PR と証拠を記録する。新しい queue・台帳・状態ファイル・設定キーは作らない。

record の入力は次の形。source の行番号は frontmatter と候補節を除いた原文本文の先頭（前後の空行を除く）を 1 とする。`consumer` は現在のプラグイン責務のリポジトリ相対パス。helper が原文抜粋と id を付け、再実行でも既存候補を保持する。`pages` は domain の実書込先のみで、候補だけなら空。domain だけなら candidates は空、知見なしは skip_reason を指定する。

```json
{
  "candidates": [
    {
      "summary": "知見の要約",
      "source": {"start_line": 1, "end_line": 3},
      "condition": "適用条件と反例",
      "consumer": "plugins/rite/hooks/scripts/example.sh"
    }
  ],
  "pages": ["pages/patterns/domain-example.md"]
}
```

record は raw の候補と log を保存・読み戻し、まだ `ingested: false` に保つ。domain のページ・sources・index・raw パスを含む log を保存後に finish を呼ぶ。保存失敗は抽出完了にせず停止し、raw・候補・既存 ingest lock/pending を保持する。混在 raw は rite 部分のみ候補化し、domain の新規/更新を維持する。候補のみは ingest の変更ページ一覧へ入れない。

消化は保守リポジトリで `/rite:batch-run --promotions`（マージまで明示する場合は `--promotions --merge`）。AI が全 raw の候補を列挙・同責務へ集約し、issue-create の重複検出・作成ゲート・Projects を経て既存 open → iterate を駆動する。通常の run-queue を使い、別の未完了キューを上書きしない。旧 `detector-candidate:` も `ingested: true` も対象。旧候補は原文から条件/消費先を具体化して link する。候補の選択・起票判断を毎回人間へ戻さず、AI が解決できない相反する仕様だけ確認する。

link の入力は work 配列。各要素は `candidate`（helper の id）、`raw`、`issue_url`、`condition`、`consumer` を持つ。実装結果の突合時は `pr_url`、`caller`、`test`、`revision` を加える。caller/test はリポジトリ相対パス、test は同じ consumer と caller の実利用を検証する `*.test.sh`。revision は対象 PR の merge commit。Issue/PR 番号の散文引用はせず、対応はリンク先として記録する。

完了は helper/gate の実 caller 呼出し、原則/reference の明示読取、対応試験の成功、同じ Issue を閉じる PR の merge 確認がすべて揃う場合のみ。reconcile は GitHub の merge commit に固定した一時 checkout で試験を再実行し、別 PR/古い revision/無関係な caller の証拠は通さない。試験中に Bash の実行元、Python の実行・読取、オプションなしの `cat`（`--` は可）と単一入力の `sed`（`-n` / `-E` / `-r` は可）の読取を一時的に観測し、caller と consumer の利用および呼出し関係を照合する。Markdown caller の実行 fence は読取と実行の両方を要求し、固定命令を保った通常の引数置換を照合する。検索語・プログラム引数や複数入力の早期終了を読取証拠にしない。コマンド文字列の表示、ファイルの存在確認、caller と無関係な consumer 実行は利用証拠にならない。観測できない利用は未解決とし、観測ファイルは試験後に削除する。log が complete でも再実行時に再検証する。候補保存・起票・draft・未利用 reference・検証失敗・証拠取得失敗は理由付き未解決として保持し、raw の候補理由と出典は完了後も消さない。

配布先の record/finish/list は当該プロジェクト内の保存/読取だけで、外部送信とインストール済みプラグイン編集をしない。link/reconcile は実 source checkout と origin identity を照合した保守側でだけ使う。外部共有は利用者が明示的に依頼した場合に限り、環境固有情報を除いて配布境界を満たす候補を保守側へ渡す。両 Wiki ブランチ戦略の既存 commit/lint/push を維持する。

## Wiki 有効判定パターン

Wiki 操作の前に必ず有効判定を行います。**Wiki は opt-out**: `wiki:` セクション自体や `enabled` キーが未指定の場合は default-on (有効) として扱います。明示的に `false|no|0` が指定された場合のみ無効化されます。

`rite-config.yml` の節は `sed -n '/^{section}:/,/^[^[:space:]#]/p'` で切り出します。節は空白と `#` 以外で始まる次の行で終わります。数字や `_` で始まるトップレベルキーでも終わり、列 0 のコメント行と空行では終わりません。終端を英字始まりの行に限ると、数字や `_` で始まる後続キーの配下の値を節の値として読みます。skill 本文にある同型の切り出しも同じ終端を使います:

```bash
# Wiki は opt-out — section/key 未指定時のデフォルトは true
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash {plugin_root}/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_enabled=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null \
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
- `plugins/rite/scripts/fix-step.sh` の `wiki-query-config` / `wiki-ingest-check` (fix ステップ 0.5.W / 4.6.W の Wiki query / ingest 起動条件)
- `plugins/rite/scripts/pr-review-step.sh` の `wiki-query-config` / `wiki-ingest-config` (pr-review ステップ 4.0.W / 6.5.W から呼ぶ Wiki query / ingest 起動条件)
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
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash {plugin_root}/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_branch=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
branch_strategy=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null \
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
