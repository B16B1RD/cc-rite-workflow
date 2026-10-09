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
  - type: "reviews"
    resource: "raw/reviews/20260915T123233Z-pr-2867.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T144951Z-pr-3289.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T163342Z-pr-3311.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T143450Z-pr-3726.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T145449Z-pr-3726-c2.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-09T19:10:23Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-15T12:50:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T14:56:46Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T16:35:29Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-09T19:10:23Z" }
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

### 逆向きの罠: サブシェルで cleanup が走って親の fixture が消える

配列 push が親に届かない罠とは逆に、`$(...)` の中で呼んだ関数が呼び出し元の EXIT trap を `eval` で復元すると、サブシェルが終わる時点でその trap が発火する。trap の中身が cleanup なら、親シェルがそれまでに登録した一時ディレクトリがその場で削除される。後続のテストケースは存在しないディレクトリを前提に動き、原因と離れた箇所で失敗する。

実際に起きた例では、先頭のテストケースが trap を復元する関数を `$(...)` で呼んだ直後に、共有の fixture ディレクトリが消えていた。対処は、そうした呼び出しを済ませてから fixture ディレクトリを作ることである。trap を復元する関数を `$(...)` で呼ぶ限り、そこより前に作ったディレクトリは消える前提で並べる。

### 別のテストファイルでの再発: worktree の登録まで残る

コマンド置換から呼ぶ fixture 関数の中で後片付け用の配列へ追記する形が、別のテストファイルでも見つかった。そのファイルは fixture の一時ディレクトリの中に linked worktree も作るため、残るのはディレクトリだけでなく、fixture の repo 側に記録された worktree の登録も含む（実リポジトリには影響しない）。原因の行が新しい差分の外にあったため、レビューでは指摘にならず先送りの欠陥として記録された。直し方は、関数が base / repo をグローバル変数に設定し、呼び出し側が関数を直接呼ぶ形（同じファイルの他の fixture と同じ方式）に揃えること。

### 直し方: 呼び出し元の local に値を入れる形へ揃える

fixture は呼び出し元スコープの変数を設定する形にする。呼び出し元で `local base repo` を宣言し、fixture 側は local を持たずに代入する。bash の動的スコープにより、値は呼び出し元の local に入り、グローバルへは漏れない。コマンド置換をやめると、fixture 内の失敗が `set -e` で止まるようにもなる（コマンド置換の中では `inherit_errexit` が無効で、失敗が素通りしていた）。

登録の pin が初回呼び出しだけを対象にしていると、残りの呼び出しがコマンド置換へ戻る退行は検出されない。呼び出し箇所が複数あるなら、どれか 1 つを戻す変異で落ちるかを確かめる。


### 一時ファイルの削除は失敗経路ごとに明示し、失敗経路でも残らないことをテストで固定する

作業メモリの同期の修正で、command substitution のサブシェル内で動く関数の一時ファイルを EXIT trap に任せていたが、サブシェル内の関数では EXIT trap が効かない。削除は失敗経路ごとに明示し、成功経路だけでなく失敗経路でも「tmp に残るのは backup だけ」をテストで固定する。次の cycle では、一時ファイルの削除を取り除く変異をテストが検出できることを reviewer が実測して確かめた。

同じ変更では、実装が観測値や挙動を変えたら docs の該当箇所も同じ PR で更新すること、gh の呼び出し形（stdin から `-F body=@file` へ）を変えたら全テストの gh モックを引数を解釈して応答する形に揃えることも必要だった。

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](./trap-register-before-mktemp.md)

## ソース

- [fix 結果](../../raw/fixes/20260703T054500Z-pr-1735.md)
- [レビュー結果](../../raw/reviews/20260703T055450Z-pr-1735.md)
- [サブシェルで trap が発火し fixture が消えた経緯を記録したレビュー結果](../../raw/reviews/20260915T123233Z-pr-2867.md)
- [同じ漏れを別のテストファイルで検出したレビュー結果](../../raw/reviews/20260927T144951Z-pr-3289.md)
- [fixture を呼び出し元の local に値を入れる形へ揃えたレビュー結果](../../raw/reviews/20260927T163342Z-pr-3311.md)
- [レビュー結果（サブシェル内の EXIT trap と失敗経路の削除）](../../raw/reviews/20261009T143450Z-pr-3726.md)
- [レビュー結果（サブシェル内の EXIT trap と失敗経路の削除）](../../raw/reviews/20261009T145449Z-pr-3726-c2.md)
