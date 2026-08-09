---
type: "patterns"
title: "Embedded markdown bash block の observability 三要素 (pipefail 宣言 + stderr stage 分離 + cd 失敗可視化)"
domain: "patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/patterns/embedded-bash-block-observability-trio.md"
created: "2026-05-17T09:08:26Z"
updated: "2026-07-22T22:54:19Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260722T221143Z-pr-1973.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T221542Z-pr-1973.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T000446Z-pr-1004.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T004634Z-pr-1004.md"
  - type: "fixes"
    ref: "raw/fixes/20260517T020335Z-pr-1004.md"
tags: ["embedded-bash", "pipefail", "stderr-attribution", "observability", "root-cause-attribution", "silent-suppression"]
confidence: high
---

# Embedded markdown bash block の observability 三要素 (pipefail 宣言 + stderr stage 分離 + cd 失敗可視化)

## 概要

command / skill ファイル (`.md`) に埋め込まれた bash block は、(1) `set -o pipefail` 宣言、(2) pipeline 各 stage の stderr を独立 tempfile に退避、(3) `cd` / `[ -d ]` 失敗の明示可視化、の 3 要素を揃えないと、上流コマンド (gh / jq / git) の失敗が pipefail dominant exit や stderr 握り潰しで silent suppression される。累積 32 回目の review cycle 2/3 で同型の observability gap が 3 site で同時 surface し、cycle 3 fix で 3 要素揃いの canonical 実装に統一された。

## 詳細

### 観測された 3 つの silent suppression 経路

#### 1. Pipeline pipefail invariant 不在

embedded markdown bash block の典型形:

```bash
if cmd | jq '.field'; then
  ...
fi
```

`set -o pipefail` を宣言していない場合、最終 stage (`jq`) の exit code が pipeline 全体の exit code となり、`cmd` (例: `gh repo view`) が失敗しても pipeline は exit 0 で「成功」扱いになる。累積 32 回目の cycle 2 で start.md / start-finalize.md / post-compact.sh の embedded bash が同型の `if gh ... | jq` を持ち、gh failure が silent に jq 出力 (null) で吸収される経路を 3 reviewer 独立検出。

**canonical 対策**: bash block 冒頭で `set -euo pipefail` を宣言する。`set -e` 単独では pipeline の中間段失敗を捕捉しないため、`-o pipefail` の併用が必須。

#### 2. Stderr stage 分離 (pipe 各段の attribution)

`if cmd1 2>/dev/null | jq 2>/dev/null; then` 形式は pipeline 失敗時に「どの段が失敗したか」を完全に失う。stderr を 1 つにマージ (`2>&1`) しても、pipefail dominant exit と組み合わさると最終段の stderr で上書きされ root cause の trail が消える。

**canonical 対策**: pipeline 各段で独立 tempfile に stderr を退避し、失敗時に段ごとの stderr を sentinel emit に併記する:

```bash
gh_stderr=$(mktemp /tmp/probe-gh-err-XXXXXX 2>/dev/null) || gh_stderr=""
jq_stderr=$(mktemp /tmp/probe-jq-err-XXXXXX 2>/dev/null) || jq_stderr=""
trap 'rm -f "$gh_stderr" "$jq_stderr"' EXIT INT TERM HUP

set -o pipefail
if ! result=$(gh api ... 2>"$gh_stderr" | jq -r '.field' 2>"$jq_stderr"); then
  echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=context_retrieval_failed; gh_stderr=$(head -3 "$gh_stderr" | tr '\n' '|'); jq_stderr=$(head -3 "$jq_stderr" | tr '\n' '|')" >&2
fi
```

これにより `gh` failure と `jq` failure が独立に attribution され、incident 解析時の trail が保持される。

#### 3. cd / directory existence failure の明示可視化

`cd "$STATE_ROOT" && ...` 形式の `&&` chain や `[ -d "$STATE_ROOT" ]` 不在は、ディレクトリ未作成 / permission denied を silent skip する経路を作る。累積 32 回目の cycle 3 F-10 で post-compact.sh が `cd "$STATE_ROOT"` の失敗を silent fall-through していた経路を別 incident sentinel (`state_root_inaccessible`) として emit する fix で解消。

**canonical 対策**: directory access の前後で explicit guard と incident emit:

```bash
if [ ! -d "$STATE_ROOT" ]; then
  echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=state_root_inaccessible; details=path=$STATE_ROOT; iteration_id=$(date +%s)" >&2
  exit 0  # non-blocking
fi
cd "$STATE_ROOT" || {
  echo "ERROR: cd $STATE_ROOT failed (rc=$?)" >&2
  exit 1
}
```

### 3 要素の relationship

3 要素は独立ではなく相互補完:

- `set -o pipefail` 単独 → 失敗は検出するが attribution 不可
- stderr stage 分離 単独 → attribution は可能だが pipefail なしでは失敗自体が silent
- cd guard 単独 → directory アクセスは保護されるが pipeline 内 cd は無防備

**canonical 規範**: embedded markdown bash block で 3 要素を **同時宣言** する。1 つでも欠けると残り 2 つの効果が打ち消される。

### sub-shell scope-internal context retrieval (関連 sub-pattern)

累積 32 回目の F-01 で観測された関連パターン: embedded bash block が `{owner}` / `{repo}` を消費する場合、orchestrator (caller markdown) からの substitute に依存すると、別 bash invocation で値が失われる Claude Code Bash tool の挙動と衝突する。解決策は **sub-shell scope 内で `gh repo view` を再実行して context retrieval を内製化する**:

```bash
owner=$(gh repo view --json owner --jq '.owner.login') || {
  echo "ERROR: gh repo view failed for owner" >&2
  exit 1
}
repo=$(gh repo view --json name --jq '.name') || {
  echo "ERROR: gh repo view failed for repo" >&2
  exit 1
}
# ↑ ここで上述の pipefail + stderr 分離 + emit を組み合わせると AC-8 core 検知が silent skip と機能等価にならない
```

これにより orchestrator state dependency を排除し、bash invocation の独立性を担保する。

### 変種: 明示的な exit code チェックすら dead code 化する capture-first の必要性

要素 (1) `set -o pipefail` 宣言の欠如は、`if cmd | jq` のような **暗黙の** silent suppression だけでなく、開発者が明示的に書いた exit code チェックすら dead code 化する、より insidious な変種を生む。実測では、開発者が「pipefail 対策のつもり」で以下を書いていた:

```bash
# ❌ NG: 明示的にチェックしているつもりが dead code
ORIG_WTH=$(bash "$SCRIPT_DIR/lib/git-status-filtered.sh" | md5sum | awk '{print $1}')
if [ $? -ne 0 ]; then
  echo "WARNING: ..." >&2
  ORIG_WTH=""
fi
```

このコードは一見正しく見える (`$?` を直後でチェックしている) が、Claude Code の Bash tool は **各呼び出しごとに fresh shell を起動し、shell state (pipefail を含む) は呼び出し間で一切継承されない**。同じ pattern を standalone `.sh` script (file scope で `set -uo pipefail` を宣言) に書けば正しく動作するが、markdown に埋め込まれた bash block では pipefail が OFF のデフォルト状態のまま実行されるため、`$?` は pipeline 最終段 (`awk`) の exit code (常に 0) を返し、`if [ $? -ne 0 ]` は**永久に発火しない**。同じ実装パターンが sibling ファイル (post-review-state-verify.sh、standalone script) では正しく動作していたため、cycle 1 fix の時点ではこの非対称に気付かれなかった。cycle 2 review で 5 reviewer 全員がこの dead code を独立に検出し、CRITICAL → 全員一致で確定した。

**canonical fix: capture-first pattern** — pipe の出力を非パイプの command substitution で一旦変数に captureし、`$?` を **その直後** (pipefail 状態に依存しない箇所) でチェックしてから、captured 値を後続コマンドに渡す:

```bash
# ✅ OK: capture-first — pipefail の有無に関わらず exit code チェックが機能する
_wth_raw=$(bash "$SCRIPT_DIR/lib/git-status-filtered.sh")
_wth_rc=$?
if [ "$_wth_rc" -ne 0 ]; then
  echo "WARNING: git-status-filtered.sh failed — worktree drift snapshot skipped" >&2
  ORIG_WTH=""
else
  ORIG_WTH=$(printf '%s' "$_wth_raw" | md5sum | awk '{print $1}')
fi
```

`_wth_raw=$(bash ...)` は単一コマンドの command substitution であり、`$?` はそのコマンド自身の exit code を返す (pipe が絡まないため pipefail 設定に非依存)。この後で `printf | md5sum | awk` のような pure なテキスト変換 pipe に captured 値を渡せば、変換 pipe 自体は失敗しない (入力が既に確定しているため) ので pipefail 有無を問わず安全になる。

**教訓**: `set -o pipefail` を宣言できない/宣言していない embedded bash block では、「pipe の直後で `$?` をチェックする」という直感的パターンは dead code になりうる。**`$?` チェックが機能する保証があるのは、直前のコマンドが単一コマンド（pipe を含まない command substitution）である場合のみ**。pipe を含む処理の失敗を検出したい場合は、capture-first (非パイプ command substitution で captureしてから変換する) が pipefail 状態に依存しない唯一の canonical pattern。同一実装パターンが「本来動作する」standalone script と「動作しない」markdown embedded block の両方に存在する非対称は、レビューで見逃されやすい (Asymmetric Fix Transcription の一種)。

### 累積観測

Projects Status In Review 遷移漏れを修正した PR の review-fix loop で 3 要素の同時欠落が 3 site (start.md / start-finalize.md / post-compact.sh) で同時 surface し、cycle 3 fix で全 site 揃って canonical 実装に統一。これは Wiki 経験則 Asymmetric Fix Transcription (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`) の sibling site 対称化と組み合わせて適用すべき canonical 規範。

## 関連ページ

- Asymmetric Fix Transcription (対称位置への伝播漏れ) (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`)
- stderr ノイズ削減: truncate ではなく selective surface で解く (`Wiki provenance: ../heuristics/stderr-selective-surface-over-truncate.md`)
- `2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される (self-defeating observability) (`Wiki provenance: ../anti-patterns/stderr-merge-silent-sentinel-suppression.md`)

## ソース

- PR #1004 cycle 2 review (3 reviewer 独立検出 / F-01 syntax error + pipefail / dangling references) (`Wiki provenance: ../../raw/reviews/20260517T000446Z-pr-1004.md`)
- PR #1004 cycle 3 review (Self-violation cascade / DRY 4-site / Observability gap F-08/F-09/F-10) (`Wiki provenance: ../../raw/reviews/20260517T004634Z-pr-1004.md`)
- PR #1004 cycle 3 fix (stderr stage separation / sub-shell scope-internal retrieval / state_root_inaccessible emit) (`Wiki provenance: ../../raw/fixes/20260517T020335Z-pr-1004.md`)
- PR #1973 cycle 3 review — 5 reviewer 独立検出: 明示的な `if [ $? -ne 0 ]` チェックが Bash tool の per-invocation pipefail-off により dead code 化 (`Wiki provenance: ../../raw/reviews/20260722T221143Z-pr-1973.md`)
- PR #1973 cycle 3 fix (capture-first pattern で pipefail 非依存の exit code チェックに修正) (`Wiki provenance: ../../raw/fixes/20260722T221542Z-pr-1973.md`)
