---
type: "patterns"
title: "path を返す test fixture ヘルパーの cleanup 登録は $() サブシェルではなく親シェルで行う"
domain: "patterns"
description: "path を `echo`/`printf` で返す fixture ヘルパーを `X=\"$(new_repo ...)\"` の **コマンド置換 (`$()`)** 経由で呼ぶと、そのヘルパーは **subshell** で実行される。"
created: "2026-07-03T06:00:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260703T054500Z-pr-1735.md"
  - type: "reviews"
    resource: "raw/reviews/20260703T055450Z-pr-1735.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-03T06:00:00+09:00" }
---

# path を返す test fixture ヘルパーの cleanup 登録は $() サブシェルではなく親シェルで行う

## 概要

path を `echo`/`printf` で返す fixture ヘルパーを `X="$(new_repo ...)"` の **コマンド置換 (`$()`)** 経由で呼ぶと、そのヘルパーは **subshell** で実行される。関数内で cleanup 配列に push (`SANDBOXES+=("$dir")` 等) しても、その配列変更は subshell 内に閉じ込められ親シェルに伝播しない。結果、EXIT trap の cleanup が対象ディレクトリを回収できず `/tmp` にリークする。canonical: **ヘルパーは path を echo するだけ**にし、cleanup 配列への登録は各呼び出し元（親シェル）で `X="$(new_repo ...)"; SANDBOXES+=("$X")` の形で行う。

## 詳細

### 罠の構造（subshell array-push loss）

```bash
SANDBOXES=()
cleanup() { for d in "${SANDBOXES[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT INT TERM HUP

# ❌ アンチパターン: 関数内で配列 push するが $() 経由で呼ぶ
new_repo() { repo="$(mktemp -d)"; SANDBOXES+=("$repo"); ...; printf '%s' "$repo"; }
disabled_repo="$(new_repo false)"   # ← $() は subshell。SANDBOXES+= は親に届かない
# → cleanup は disabled_repo を回収せず /tmp にリーク
```

path を返すヘルパーは `printf` の出力を `$()` で捕捉する必要があるため **必ず subshell 経由**になる。一方、path を返さず直接呼ばれるヘルパー（`setup_wiki_worktree "$repo"` 等）の `SANDBOXES+=` は親シェルで実行され正しく届く — この非対称が罠を見えにくくする。

canonical fix:

```bash
# ✅ ヘルパーは path を echo するだけ、登録は親シェル
new_repo() { repo="$(mktemp -d)"; ...; printf '%s' "$repo"; }
disabled_repo="$(new_repo false)"; SANDBOXES+=("$disabled_repo")
```

これは共有ヘルパー `_test-helpers.sh` の `make_sandbox` / `make_plain_sandbox` が「Callers MUST push to cleanup_dirs from the parent shell … not inside the wrapper」として既に文書化している罠であり、**文書化済みでも新規テストファイルで再発する**（HIGH として検出、code-quality + error-handling の 2 reviewer 独立合意）。新規 fixture ヘルパーを書くときは既存の共有ヘルパーと同じ「echo するだけ、登録は親」パターンに揃える。

### 併発する fixture-quality の落とし穴（同 PR で cross-validation）

- **fixture 構築の silent failure（偽 PASS）**: fixture の git 操作を `&&` 連結せず逐次実行し戻り値を検査しないと、`git commit`/`git push` が失敗しても壊れた repo を返し、後続の **skip 期待テスト（exit 0）が壊れた repo でも緑になる**。末尾で `git rev-parse HEAD`（構築検証）/ `git rev-parse origin/wiki`（push 検証）を assert し、`&&` 連結 + 失敗時 `exit 1` で fail-loud にする。
- **exit-code assertion の非 isolation**: guard の発火を `exit 1` で assert しても、その guard を削除しても後続チェック（例: not-a-git-repo 検査）が **同じ exit 1** を返すなら、テストは guard を消しても pass し続ける false-positive になる。guard の直前が exit 0 になる構成（例: 構築済み repo で benign 入力=0 / trigger 入力=1）に置き、**benign と trigger の差分**で guard を isolate する。

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](./trap-register-before-mktemp.md)

## ソース

- [PR #1735 fix results](../../raw/fixes/20260703T054500Z-pr-1735.md)
- [PR #1735 review results](../../raw/reviews/20260703T055450Z-pr-1735.md)
