---
title: "stderr ノイズ削減: truncate ではなく selective surface で解く"
domain: "heuristics"
description: "success path の stderr ノイズを `2>/dev/null` や全 truncate で消すと legitimate warning も silent drop する。git の `-q` で informational 抑制 + grep filter で warning/hint/error 行のみ selective surface する責務分離が正解。過去のレビューで multi-step 処理の per-step tempfile 分離に拡張。過去のレビューで helper status を制御フローに使う委譲 shim は status (制御) + stderr (診断) 両 capture が必要と拡張。過去のレビューで同一 helper (`issue-comment-wm-sync.sh`) の別 caller (§3.5.1) が同 2>/dev/null 破棄を再演し canonical へ修正 (sibling-caller 再発)。過去のレビューで delegation-shim 以外の新規 git fetch フォールバック実装 (テストスクリプト内) でも同 anti-pattern が再演することを確認、canonical selective-surface パターンへ修正。過去のレビューで「fail-safe fallback (`|| fallback=...`) 追加時、分岐の安全性と `2>/dev/null` による診断可視性は独立要件」という変種を追加（4 箇所中 3 箇所だけ `2>/dev/null` が残る非対称を cycle 2 で MEDIUM 検出）。過去のレビューで「テストの captured-stderr は assert 失敗時に surface してから削除する（fail_before=$FAIL 記録 → 失敗増加時のみ head -5 表示 → rm。捕捉だけして表示経路の無い構成は 2>/dev/null と診断上等価）」というテスト版を追加。"
promote: rite-plugin
created: "2026-04-16T19:37:16Z"
updated: "2026-07-24T17:00:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T072825Z-pr-2003.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T073107Z-pr-2003.md"
  - type: "reviews"
    ref: "raw/reviews/20260721T014901Z-pr-1937-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260721T015253Z-pr-1937-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md"
  - type: "reviews"
    ref: "raw/reviews/20260415T121203Z-pr-529-cycle-3.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T202213Z-pr-550.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T151325Z-pr-1201.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T151834Z-pr-1201.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T233836Z-pr-1202.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T234453Z-pr-1202.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T104045Z-pr-1741.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T104347Z-pr-1741.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T104924Z-pr-1741.md"
tags: ["bash", "stderr", "observability", "noise-reduction", "per-step-diagnostic", "delegation-shim", "status-and-stderr-dual-capture", "git-fetch-fallback"]
confidence: high
---

# stderr ノイズ削減: truncate ではなく selective surface で解く

## 概要

success path で git などのコマンドが出す stderr の「ノイズ」を抑えたい場面で、`2>/dev/null` や無条件 truncate を使うと legitimate な warning（`unable to rmdir` / remote hook advice など）まで silent drop してしまう。正しい設計は「情報量を減らす」ではなく「ノイズと警告を分離する」— git 側の `-q` / `--quiet` で informational を抑え、helper で warning/hint/error 行のみ selective surface する。

## 詳細

### Anti-pattern: 全 truncate

```bash
# ❌ NG: cycle 2 fix で導入された silent regression
dump_git_err() {
  # success path でも無条件 truncate
  : > "$git_err"
}
```

この解決は cycle 1 で出た「`Switched to branch 'wiki'` ノイズ」を消す動機で書かれたが、反面 legitimate warning (`hint: ...` / `unable to ...`) まで silent drop し、cycle 3 で silent regression として再検出された。

### Canonical pattern: selective surface

```bash
# ✅ OK: warning/hint/error 行のみ filter surface
surface_git_warnings() {
  local err_file="$1"
  [ -s "$err_file" ] || return 0
  head -n 10 "$err_file" | grep -iE '^(warning|hint|error):' >&2 || true
}

# 呼び出し側
git cmd 2>"$git_err"
rc=$?
if [ "$rc" -eq 0 ]; then
  surface_git_warnings "$git_err"  # success でも warning は残す
else
  head -3 "$git_err" | sed 's/^/  git: /' >&2
fi
```

### 責務分離の原則

stderr に出力される情報を以下の 2 責務に分ける:

| 責務 | 分類 | 対処 |
|------|------|------|
| informational (消してよい) | `Switched to branch` / `Already up to date` | `git <cmd> -q` / `--quiet` で上流抑制 |
| warning (消してはいけない) | `warning:` / `hint:` / `error:` | helper で selective surface |

「情報過多の解決」と「warning の silent loss」を同じツール（truncate）で扱わない。後者の fail mode を増やすだけ。

### `surface_git_warnings` の実装要点

- `head -n 10`: 大量 stderr で context を埋めない
- `grep -iE '^(warning|hint|error):`: 先頭タグで filter（git 出力のフォーマット安定性に依拠）
- `|| true`: grep no-match (rc=1) で script 全体を abort させない
- `>&2`: stdout への混入防止（parser 依存パイプラインを保護）

### Per-step tempfile 分離（拡張）

multi-step 処理 (`git add` → `git diff --cached` → `git commit` → `git push` の 4 段) で 1 つの stderr tempfile を流用すると、**後段 step 失敗時に前段の warning が混在表示**されて root cause 診断が困難になる。step ごとに dedicated tempfile を確保し、trap cleanup で全 tempfile を纏めて削除するのが canonical:

```bash
# ✅ OK: per-step 分離
local add_err="" diff_err="" commit_err="" push_err=""
trap 'rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}"' EXIT INT TERM HUP

add_err=$(mktemp /tmp/rite-add-err-XXXXXX) || add_err=""
diff_err=$(mktemp /tmp/rite-diff-err-XXXXXX) || diff_err=""
# ... (commit_err, push_err も同様)

git add -- "$@" 2>"${add_err:-/dev/null}" || { dump_err "$add_err" "add"; return 3; }
git diff --cached --quiet 2>"${diff_err:-/dev/null}"
# diff_err failure 時に add_err の warning が混ざらない
```

`worktree_commit_push()` で実装。step-specific な診断情報を保つことで、`git push` が corrupt worktree で失敗したとき `rev-parse --abbrev-ref HEAD` の step に由来する warning と混ざらずに push 自体の失敗原因が特定できる。

### 委譲 shim は status (制御用) と stderr (診断用) の両方を capture する（拡張）

helper script の機械可読 `status=...; reason=...` 出力を **制御フローに consume する** thin shim（fix.md 4.5.2 が `issue-comment-wm-sync.sh` の status を読んで `WM_UPDATE_FAILED` routing に使う) では、status だけ capture して helper の stderr を `2>/dev/null` で破棄すると、**failure を routing できても root-cause が operator に届かない** diagnostic-degradation が起きる (error-handling reviewer が cycle 2 で MEDIUM 検出)。

教訓: **helper status を読んで失敗 routing する shim は、status (制御フロー用) と stderr (operator 診断・root-cause 用) の両方を capture する**。これは本 page の「stderr を silent drop しない」原則を delegation-shim 文脈へ拡張したもの — status は「何が起きたか」(routing 用) を、stderr は「なぜ起きたか」(診断用) を担い、責務が異なるため両方必要。

```bash
# ✅ OK: status を制御に使いつつ stderr も capture + selective surface
wm_sync_err=$(mktemp ...) || wm_sync_err=""
wm_out=$(bash helper.sh update --transform ... 2>"${wm_sync_err:-/dev/null}")
state=$(wm_state_of "$wm_out"); reason=$(wm_reason_of "$wm_out")
if [ "$state" != "success" ] && [ "$reason" != "no_comment" ]; then
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_..._failed" >&2   # 制御 routing
  [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && \
    { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | sed 's/^/    /' >&2; }  # 診断 surface
fi
```

実装時は **対称 counterpart (review.md 6.2 = fix.md 4.5) が既に確立した stderr-capture + head -5 surface パターン**を Read してそれに揃える (独自実装の逸脱を避ける)。WM sync 委譲事例の cycle 2 fix は WM_UPDATE_FAILED routing と reason 語彙を一切変えず、trap に stderr tempfile を追加する形で「追加のみ」で適用した。

### 同一 helper の別 caller で同 anti-pattern が再発する（実測）

WM sync 委譲事例で確立した本拡張は、**直後の sibling 委譲 PR で同一 helper (`issue-comment-wm-sync.sh`) の別 caller (`archive-procedures.md` §3.5.1 の WM 完了情報追記委譲) が同じ `2>/dev/null` 破棄を再演**した。委譲 shim が helper status を制御フローに consume しつつ helper stderr を握り潰す構造で、prompt-engineer + error-handling の 2 reviewer が cycle 1 で独立検出 (MEDIUM)。cycle 1 fix で canonical caller `fix.md 4.5.2` / `review.md 6.2` の **tempfile capture + `*)` arm で `head -5` surface** パターンに揃え、status 行による非ブロッキング判定 (`append-eof` への委譲) は不変のまま「追加のみ」で修正した。

教訓: **canonical caller が既に修正済みでも、同一 helper の新規 caller を追加するたびに stderr-discard が再導入される** ([[asymmetric-fix-transcription]] の「canonical pattern の対称伝播漏れ」と同根)。helper への新規委譲を書くときは、先に同 helper の既存 caller を grep して stderr-capture 規約の有無を確認し、それに揃えてから commit する。

### delegation-shim 以外の新規 git フォールバックコードでも同 anti-pattern が発生する（実測）

起点事例以降の evidence はいずれも「既存 helper の委譲 shim」文脈だったが、後続の実測では **委譲 shim ではない、テストスクリプト内の素の `git fetch` フォールバック**が新規実装され、そこでも同一 anti-pattern (全 truncate) が再演された:

```bash
# ❌ NG: PR #1741 cycle 1 の初期実装
git fetch --quiet --depth=1 origin "${BASELINE_COMMIT}" 2>/dev/null || true
```

`2>/dev/null` により fetch 失敗の根本原因 (DNS 不通 / 認証エラー / `couldn't find remote ref` 等) が完全に握り潰され、後続の SKIP メッセージは「到達不能だった」という結果のみを報告していた。error-handling reviewer が「同リポジトリの `wiki-ingest-commit.sh` / `worktree-git.sh` に既に確立された stderr capture 規約に新規コードが従っていない」と HIGH で指摘し、cycle 1 fix で以下の canonical 形へ修正した:

```bash
# ✅ OK: PR #1741 cycle 1 fix (canonical selective-surface パターンへ整合)
FETCH_ERR=$(mktemp)
TMPFILES+=("$FETCH_ERR")
git fetch --quiet --depth=1 origin "${BASELINE_COMMIT}" 2>"$FETCH_ERR" || true
if ! git cat-file -e "${BASELINE_COMMIT}^{commit}" 2>/dev/null; then
  echo "SKIP: baseline commit ... is not reachable even after 'git fetch ...'" >&2
  if [ -s "$FETCH_ERR" ]; then
    sed 's/^/  git: /' "$FETCH_ERR" >&2
  fi
fi
```

single-step の単純ケースのため per-step tempfile 分離や status/stderr 二重 capture までは不要で、「本文冒頭の Canonical pattern: selective surface」のみで十分だった。

教訓: **本 anti-pattern は既存 helper への委譲 shim に限らず、新規に書き下ろす git コマンドラッパー全般で再演する**。「新しい git フォールバックコードを書く前に、同リポジトリの既存 git エラーハンドリング規約（本ページ）を確認する」ことが cycle 1 での早期検出に有効だった。

### fail-safe fallback 追加が「安全側に倒す」ことと「失敗理由を可視化する」ことを混同する（実測）

helper 呼び出しに `cmd || fallback="非空文字列"` 形式の fail-safe を追加する修正は、分岐そのもの（helper 失敗時に安全側の非空値へ倒す）は正しくても、`2>/dev/null` を temporarily 残したままだと **helper 自身の診断 WARNING が呼び出し元の判断根拠として一切表示されない** という別の問題を生む。exit code 未検査事例の cycle 1 で CRITICAL 指摘（exit code 未検査）を修正した際、4 箇所の同型呼び出しのうち 3 箇所は `2>/dev/null` を残したまま、1 箇所だけ `2>/dev/null` を持たない非対称な状態で commit された。cycle 2 で error-handling reviewer がこの非対称を MEDIUM として検出した。

```bash
# ❌ NG: 分岐は安全だが診断情報が消える (cycle 1 修正直後の状態)
dirty=$(bash lib/git-status-filtered.sh 2>/dev/null) || dirty="?? (dirty-check failed — assume dirty for safety)"

# ✅ OK: 分岐の安全性と診断可能性を両立 (cycle 2 fix)
dirty=$(bash lib/git-status-filtered.sh) || dirty="?? (dirty-check failed — assume dirty for safety)"
# helper 自身が WARNING を stderr に出す設計であれば、呼び出し側は stderr を握り潰さない
```

教訓: **「安全側に倒す」ことと「失敗理由を可視化する」ことは独立した要件であり、片方を満たしても他方が漏れることがある**。fail-safe fallback (`|| fallback=...`) を追加する修正では、fallback 値の安全性だけでなく、`2>/dev/null` 等で helper 自身の診断出力を握り潰していないかを併せて確認する。同一コミット内で複数の同型呼び出し箇所に fail-safe を追加する際は、`2>/dev/null` の有無が箇所ごとに非対称にならないよう揃える ([[asymmetric-fix-transcription]] の delegation-shim/fallback 版)。

### テストの captured-stderr は assert 失敗時に surface してから削除する（拡張）

テストが被検査コマンドの stderr を tempfile (`2>>"$nf_err"`) に捕捉しながら、**assert 失敗時にも内容を表示せず無条件 `rm -f` する**構成は、本 anti-pattern のテスト版。ガード退行時の CI トリアージで「expected/actual の不一致」しか見えず、根本原因行 (`flock: command not found` → `ERROR: flock timeout` 等) が失われる。flock 診断事例の cycle 2 で error-handling レビュアーが mutation 実験中に「FAIL 2 件が出るのに stderr 詳細がゼロ表示」を実測して検出した (同一 PR 内の別テストは失敗時 `head -5` 表示済みで非対称)。

canonical 形は「失敗時のみ selective surface」— 成功時はノイズゼロを保ちながら診断を失わない:

```bash
# ✅ OK: assert 群の前にカウンタを記録し、失敗が増えた場合のみ表示してから削除
fail_before=$FAIL
# ... assert 群 (2>>"$nf_err" で捕捉しつつ実行) ...
if [ "$FAIL" -gt "$fail_before" ] && [ -s "$nf_err" ]; then
  head -5 "$nf_err" | sed 's/^/    stderr: /'
fi
rm -f "$nf_err"
```

教訓: **stderr を捕捉するテストブロックを書いたら、その tempfile の削除前に「失敗時に surface する経路」があるかを必ず確認する**。捕捉 (`2>>`) だけして表示経路が無い構成は、捕捉しない (`2>/dev/null`) のと診断上等価であり、むしろ「捕捉している」見た目が問題を隠す。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)

## ソース

- [PR #1937 review cycle 2 (fail-safe fallback 追加時の 2>/dev/null 非対称を MEDIUM 検出)](../../raw/reviews/20260721T014901Z-pr-1937-cycle2.md)
- [PR #1937 fix cycle 2 (2>/dev/null 除去で分岐の安全性と診断可能性を両立)](../../raw/fixes/20260721T015253Z-pr-1937-cycle2.md)
- [PR #529 fix cycle 1 (git stderr tempfile 退避の副作用)](../../raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 cycle 3 fix (success path で selective surface 導入)](../../raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md)
- [PR #529 cycle 3 review (全 truncate の silent regression 検出)](../../raw/reviews/20260415T121203Z-pr-529-cycle-3.md)
- [PR #550 cycle 1 fix (per-step tempfile 分離の一般化)](../../raw/fixes/20260416T202213Z-pr-550.md)
- [PR #1201 review cycle 2 (委譲 shim の stderr 破棄 diagnostic-degradation 検出)](../../raw/reviews/20260529T151325Z-pr-1201.md)
- [PR #1201 fix cycle 2 (status + stderr 両 capture へ修正)](../../raw/fixes/20260529T151834Z-pr-1201.md)
- [PR #1202 review cycle 1 (同一 helper の別 caller §3.5.1 が 2>/dev/null 破棄を再演、2 reviewer 独立検出 MEDIUM)](../../raw/reviews/20260529T233836Z-pr-1202.md)
- [PR #1202 fix cycle 1 (canonical stderr-capture 規約へ整合、status 非ブロッキング判定は不変)](../../raw/fixes/20260529T234453Z-pr-1202.md)
- [PR #1741 review cycle 1 (delegation-shim 以外の新規 git fetch フォールバックで全 truncate anti-pattern を検出、HIGH)](../../raw/reviews/20260703T104045Z-pr-1741.md)
- [PR #1741 fix cycle 1 (canonical selective-surface パターンへ整合)](../../raw/fixes/20260703T104347Z-pr-1741.md)
- [PR #1741 review cycle 2 (0 findings、mergeable に収束)](../../raw/reviews/20260703T104924Z-pr-1741.md)
- [PR #2003 review cycle 2 (テストの captured-stderr 無条件 rm による診断握り潰しを LOW 検出、mutation 実験で実測)](../../raw/reviews/20260724T072825Z-pr-2003.md)
- [PR #2003 fix cycle 2 (fail_before=$FAIL による失敗時のみ selective surface パターンへ修正)](../../raw/fixes/20260724T073107Z-pr-2003.md)
