---
title: "Exit code semantic preservation: caller は case で語彙を保持する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-07-13T14:35:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260415T094007Z-pr-529.md"
  - type: "reviews"
    ref: "raw/reviews/20260608T112156Z-pr-1306.md"
  - type: "fixes"
    ref: "raw/fixes/20260608T112705Z-pr-1306.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T164934Z-pr-1743.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T165654Z-pr-1743.md"
  - type: "reviews"
    ref: "raw/reviews/20260713T045650Z-pr-1847-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260713T045756Z-pr-1847-cycle2.md"
tags: ["bash", "exit-code", "api-contract", "sentinel"]
confidence: high
---

# Exit code semantic preservation: caller は case で語彙を保持する

## 概要

shell script の header で `Exit codes: 0=success, 2=legitimate skip, 3=real error` のように exit code の語彙を定義しても、caller が `if cmd` / `cmd || handle_error` のように non-zero を一律 failure 扱いすると、legitimate skip も false-positive incident として報告される。caller 側に case 文で exit code ごとの分岐を書くのが API 契約の完成。

## 詳細

### Anti-pattern: 一律 failure 扱い

```bash
# ❌ NG: exit 2 (legitimate skip) も failure として sentinel emit
if ! bash wiki-ingest-commit.sh; then
  echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=ingest_failed"
fi
```

script が `exit 2` で skip（例: `wiki.enabled=false`）した場合も incident として報告され、false-positive が観測ダッシュボードを汚染する。

### Canonical pattern: case 文で語彙を保持

```bash
set +e
bash wiki-ingest-commit.sh
rc=$?
set -e
case "$rc" in
  0)
    echo "[CONTEXT] WIKI_INGEST=ok"
    ;;
  2)
    # legitimate skip — incident 扱いしない
    echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=wiki-disabled"
    ;;
  3)
    echo "ERROR: wiki-ingest-commit.sh 内部で git 操作失敗 (rc=3)" >&2
    exit 1
    ;;
  4)
    # commit landed, push failed — 非 fatal
    echo "WARNING: commit は landed したが push に失敗 (rc=4)" >&2
    echo "  手動回復: git -C .rite/wiki-worktree push origin $wiki_branch" >&2
    ;;
  *)
    echo "ERROR: 予期しない exit code ($rc)" >&2
    exit 1
    ;;
esac
```

### 双方向契約

exit code 語彙は片方向の宣言では不十分。以下の両方を揃える:

1. **script 側**: header comment に `Exit codes:` セクションを書く
2. **caller 側**: `case "$rc" in` で全 rc 値を explicit に routing

`case` に `*)` デフォルトを置いて未知の rc を fail-fast させることで、script 側が exit code を追加したときの silent OK 判定も防げる。

### sentinel emit との組み合わせ

skip 経路では `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=...` のような sentinel を emit することで、caller の caller（workflow 監視側）が incident とそうでないものを区別できる。sentinel + case の 2 層で語彙を保持する。

### `$?` 経由の 3 値コマンドとの違い

本パターンは「独自定義 exit code を持つスクリプト」を対象とする。`git diff --quiet` のような標準コマンドの 3 値 exit code (0/1/>1) も case で扱うが、そちらは [`if ! cmd` anti-pattern](../anti-patterns/bash-if-bang-rc-capture.md) が別軸で混在するので区別して扱うこと。

### script 自身の失敗経路も宣言した exit-code 契約に従う

caller 側の case routing だけでなく、**script 自身のすべての内部失敗経路** が header で宣言した exit-code 語彙に従う必要がある。peer script から arg-parse を copy-paste すると、peer と異なる exit-code 契約のもとで失敗経路が契約違反の code を emit する。

起点事例の `projects-board-drift-check.sh` は `watchdog-status-mismatch.sh` から作法を踏襲したが、exit-code 契約を再設計した (watchdog: `exit 1=fatal` / 本 script: **`exit 1=drift warning` / `exit 2=invocation error`**)。arg-parse の `--limit) LIMIT="${2:-}"; shift 2` を verbatim copy-paste した結果、`--limit` に値が無いと `set -e` 下で `shift 2` が exit 1 abort → **usage error が exit 1 (=「drift 検出」warning) として誤分類** され、lint 上で実在しない drift を報告する経路が生まれた (code-quality + error-handling の cross-validated MEDIUM)。

- **`${2:-}` は防御にならない**: `${2:-}` は `set -u` の unset 参照だけを防ぐ。`shift 2` が引数不足で失敗する経路は防げない。
- **canonical fix**: `[ "$#" -lt 2 ]` で値の存在を gate し、欠落時は契約どおり exit 2 (invocation error) へ統一する。
- **教訓**: 独自 exit-code 契約を持つ script では「全失敗経路 (arg-parse 含む) が契約の code を emit するか」を runtime で検証する。peer からの copy-paste 同形性は exit-code 契約一致を保証しない (Asymmetric Fix Transcription の peer script flag 契約 runtime 検証 sub-pattern の再演)。新規 lint step 追加 PR では exit-code 契約が反復 trigger になる（cycle 1 の dominant finding として検出され 4 cycle で mergeable に到達した実測がある）。
- **successful preventive application**: 新規 drift-check スクリプトが `--repo-root) [ $# -ge 2 ] || { echo "ERROR: ..." >&2; usage >&2; exit 2; }` の consume-before-validate ガードを「set -u の unbound $2 が exit 1 = drift 誤分類になるのを防ぐ」rationale コメント付きで最初から適用し、回帰 TC（`--repo-root` 値欠落 → rc=2）で pin した。sibling スクリプト（doc-heavy-patterns-drift-check.sh）に同パターンが pre-existing で残る点は scope 外として別 Issue 追跡 — 本 pattern の事前適用 + TC pin が cycle 収束を阻害しない実例。

### markdown SKILL.md の表示ロジックでも同じ語彙保持が要る

本パターンはこれまで bash script の `exit code` 語彙を対象としてきたが、同じ「legitimate skip と genuine failure を区別しないと false-positive を生む」構造は、**SKILL.md 内の完了レポート表示ロジック**（`[CONTEXT] KEY=value` sentinel の有無で分岐する markdown 記述）でも再演する。

`cleanup/SKILL.md` の Projects Status 表示ロジックで、cycle1 の自己修正が「`[CONTEXT] PROJECTS_STATUS_UPDATED=` sentinel が見つからない場合は一律 false（更新失敗）扱いとする」という単純化を導入した。しかし当該ステップ (ステップ8) は `projects_enabled=false` または関連 Issue 未識別のとき **意図的に丸ごとスキップされ sentinel 自体を emit しない**設計だったため、この単純化は legitimate skip（設定無効）を genuine failure（更新失敗）と誤って混同し、Projects 連携を無効化しているユーザー全員に false-positive の `⚠️ 更新失敗` 警告を表示する regression を生んだ。

- **検出経路**: prompt-engineer と error-handling の 2 レビュアーが cycle2 で独立に同一箇所を指摘（cross-validation 一致、MEDIUM→HIGH へ昇格）
- **canonical fix**: sentinel 不在を単純に failure 扱いにするのではなく、「上から評価し最初に一致したものを採用する」明示的な多分岐（`{projects_enabled}=false` → informational skip / Issue 未識別 → informational skip / sentinel=true → 成功 / それ以外 → 真の失敗）に再設計した。同ファイル内の `{wiki_ingest_check}`（`reason=disabled` を区別する既存パターン）を参照して一貫性を持たせた
- **教訓**: 「sentinel absent → 失敗扱い」という設計を導入するときは、そのステップ自体が正当にスキップされうる条件を必ず洗い出し、既存の類似パターンを参照して一貫性のある区別ロジックにすること。bash の exit-code 語彙と同型の問題が、markdown 記述の sentinel-presence 語彙でも発生しうる

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)
- [set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する](../anti-patterns/bare-statement-under-set-e-dead-code-rc-branch.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [`cmd=$(...) || cmd=""` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする](../anti-patterns/command-substitution-fallback-discards-diagnostic-json.md)

## ソース

- [PR #529 fix cycle 1 (exit 2 semantic preservation)](../../raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 review (6-reviewer による exit code mismatch 検出)](../../raw/reviews/20260415T094007Z-pr-529.md)
- [PR #1306 review cycle 1 (peer copy-paste の exit-code 契約非対称 + shift 2/set -e abort)](../../raw/reviews/20260608T112156Z-pr-1306.md)
- [PR #1306 fix cycle 1 (`[ "$#" -lt 2 ]` gate で欠落時 exit 2 へ統一)](../../raw/fixes/20260608T112705Z-pr-1306.md)
- [PR #1847 review cycle 2 (markdown 表示ロジックでの legitimate-skip/failure 混同を cross-validation で検出)](../../raw/reviews/20260713T045650Z-pr-1847-cycle2.md)
- [PR #1847 fix cycle 2 (`{wiki_ingest_check}` パターンを参照した多分岐への再設計)](../../raw/fixes/20260713T045756Z-pr-1847-cycle2.md)
