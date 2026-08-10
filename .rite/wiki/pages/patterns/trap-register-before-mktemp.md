---
title: "trap 登録 → mktemp の順序で tempfile lifecycle を守る"
domain: "patterns"
description: "`mktemp` で tempfile を作った直後に `trap 'rm -f \"$f\"' EXIT ...` を登録するのでは、signal (INT/TERM/HUP) が `mktemp` 成功直後〜`trap` 登録前の窓で届いた場合に orphan tempfile が残る。"
created: "2026-04-16T19:37:16Z"
updated: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T165559Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T180658Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T180001Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T231929Z-pr-1033.md"
  - type: "fixes"
    ref: "raw/fixes/20260713T093252Z-pr-1850.md"
  - type: "reviews"
    ref: "raw/reviews/20260713T104006Z-pr-1850.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T122258Z-pr-2038.md"
tags: ["bash", "tempfile", "trap", "cleanup", "lifecycle", "hand-off", "cleanup-variable-assignment-order"]
confidence: high
---

# trap 登録 → mktemp の順序で tempfile lifecycle を守る

## 概要

`mktemp` で tempfile を作った直後に `trap 'rm -f "$f"' EXIT ...` を登録するのでは、signal (INT/TERM/HUP) が `mktemp` 成功直後〜`trap` 登録前の窓で届いた場合に orphan tempfile が残る。canonical 順序は「空文字で変数宣言 → signal-specific trap 登録 → `mktemp` で値代入」。逆順は `mktemp → trap` race と呼ばれ、起点事例の cycle 4 で複数箇所で検出された。

## 詳細

### Anti-pattern (mktemp → trap race)

```bash
# ❌ NG: mktemp と trap の間で INT が届くと orphan
f=$(mktemp /tmp/rite-XXXXXX) || f=""
trap 'rm -f "${f:-}"' EXIT INT TERM HUP
```

### Canonical pattern (path-declare → trap → mktemp)

```bash
# ✅ OK: trap が先、mktemp が後
f=""                                        # 1. 空文字で変数宣言
trap 'rm -f "${f:-}"' EXIT INT TERM HUP     # 2. trap install ("${f:-}" で空時も安全)
f=$(mktemp /tmp/rite-XXXXXX) || f=""        # 3. mktemp で値代入
# ...
rm -f "$f"                                  # 4. 明示 cleanup
trap - EXIT INT TERM HUP                    # 5. trap disarm（success path）
```

### Signal-specific handler で POSIX exit code を保持

signal 経由の中断で `$?` を 0 に畳まないために signal 別 handler を登録する:

```bash
_cleanup_body() { rm -f "${f:-}"; }
trap '_cleanup_body' EXIT
trap '_cleanup_body; exit 130' INT   # SIGINT
trap '_cleanup_body; exit 143' TERM  # SIGTERM
trap '_cleanup_body; exit 129' HUP   # SIGHUP
```

POSIX exit code 慣習: `128 + signal number` (INT=2, TERM=15, HUP=1)。この明示渡しをしないと caller 側が中断と通常失敗を区別できない。

### scope 限定 mini-trap

script 上部で trap 前に作られる tempfile（例: `ref_err` のような `git rev-parse` stderr 退避）は、メイン cleanup 関数とは別の scope 限定 mini-trap を書く:

```bash
# fm_err / ref_err / stage_dir 退避用 tempfile 作成箇所
ref_err=""
trap 'rm -f "${ref_err:-}"' EXIT INT TERM HUP
ref_err=$(mktemp /tmp/rite-ref-err-XXXXXX 2>/dev/null) || ref_err=""
# ... git コマンドで使用 ...
[ -n "$ref_err" ] && rm -f "$ref_err"
trap - EXIT INT TERM HUP
```

### `trap -` の最小化

`trap - EXIT INT TERM HUP` は**他の** trap も無効化する副作用を持つ。tempfile 削除直後に `var=""` で空文字代入して cleanup を no-op 化してから `trap -` を呼ぶか、そもそも signal 別 handler の重複を避ける設計にする。

### 依存コマンド gate は mktemp より前に置く (deterministic gate-exit variant)

signal race だけでなく、**mktemp と trap 登録の間に `exit` 経路 (依存コマンド gate 等) が挟まる**と、その環境では決定論的に orphan が残る。exit 経路 orphan 事例で実測: テストスクリプトが `TEST_DIR="$(mktemp -d)"` → `command -v jq || exit 1` → trap 登録 の順になっており、jq 不在環境では trap 未武装のまま exit して temp dir が実行回数分蓄積する (performance / error-handling の 2 reviewer が独立検出した高信頼シグナル)。

```bash
# ❌ NG: mktemp と trap の間に exit 経路 (jq gate) が挟まる
TEST_DIR="$(mktemp -d)"
if ! command -v jq >/dev/null 2>&1; then exit 1; fi   # ← ここで exit すると orphan
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP

# ✅ 最小修正: gate を mktemp より前へ移動 (gate 時点では未割当リソースなし)
if ! command -v jq >/dev/null 2>&1; then exit 1; fi
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
```

canonical 順序 (宣言 → trap → mktemp) への全面書換が既存慣習との対称性で見送られる場合でも、**exit 経路の除去だけは最小 reorder で必ず行う** — signal race window (数行分、Hypothetical) と異なり、gate-exit は該当環境で 100% 再現する Demonstrable な欠陥のため。同一 PR 内の sibling ファイル間で gate の位置が非対称になっていないかも確認する (片方は trap 後 = trap が回収、片方は trap 前 = orphan という非対称は review で検出しにくい)。

### Hand-off registry pattern (scope 外への hand-off 後も cleanup を保つ)

tempfile を同一 bash block 内で downstream に hand-off (例: `review_source_path="$norm_tmp"; norm_tmp=""`) すると、元変数 `norm_tmp` は cleanup 対象から外れる (意図的: downstream が path を参照中のため早期削除を防ぐ)。しかし block 終了時にも cleanup されないと `/tmp/rite-fix-normalized-XXXXXX` 等が orphan として残る。canonical solution は **cleanup function 内に「hand-off registry variable」を追加** し、hand-off 時に元 path を registry に保存して enclosing trap で削除する:

```bash
# ❌ NG: hand-off 後 norm_tmp は cleanup されず orphan
norm_tmp=""
_cleanup() { rm -f "${norm_tmp:-}"; }
trap '_cleanup' EXIT INT TERM HUP
norm_tmp=$(mktemp /tmp/rite-fix-normalized-XXXXXX) || norm_tmp=""
# ... normalize 処理 ...
review_source_path="$norm_tmp"
norm_tmp=""  # downstream 参照保護のため空クリア → trap が rm を呼んでも no-op
# ... downstream が $review_source_path を参照 ...
# block 終了 → trap は norm_tmp="" を rm するだけで /tmp/rite-fix-normalized-* は orphan
```

```bash
# ✅ OK: hand-off registry variable を cleanup function に追加
norm_tmp=""
handed_off_norm_tmp=""                                    # 1. hand-off registry 宣言
_cleanup() {
  rm -f "${norm_tmp:-}"
  [ -n "${handed_off_norm_tmp:-}" ] && rm -f "$handed_off_norm_tmp"  # 2. registry も削除対象
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP
norm_tmp=$(mktemp /tmp/rite-fix-normalized-XXXXXX) || norm_tmp=""
# ... normalize 処理 ...
review_source_path="$norm_tmp"
handed_off_norm_tmp="$norm_tmp"  # 3. hand-off 時に path を registry へ保存
norm_tmp=""                       # 4. 元変数クリア (downstream 参照保護 + 二重 rm 回避)
# ... downstream が $review_source_path を参照 ...
# block 終了 → trap が $handed_off_norm_tmp を確実に rm
```

ポイント:
- **既存 trap 機構の再利用**: 新規 cleanup block を追加せず、cleanup function に変数を 1 つ足すだけの最小拡張
- **`${var:-}` parameter expansion**: `set -u` 下でも安全
- **二重 rm 回避**: 元変数 `norm_tmp=""` クリアで `rm -f "${norm_tmp:-}"` を no-op 化、`handed_off_norm_tmp` のみが実 path を保持
- **同一 bash block 内で完結**: bash session 境界を跨ぐ追加機構 (PR-specific wildcard cleanup 等) は不要

このパターンは「tempfile を作る人」と「使う人」が同一 bash block 内に居る限り適用可能。block を跨ぐ場合は別の戦略 (caller 側で wildcard cleanup 等) が必要。

### 新規 mktemp は「そのファイルの cleanup 関数の引数リスト」に載せる

trap を先に張っていても、**新しい tempfile をその cleanup 関数に登録し忘れる**と成功経路でリークする。型ガード tempfile 事例は型ガード用の tempfile を `elif` の条件部で mktemp し `then` ブロックでのみ `rm` する形にしたため、ガードが通る成功経路（最頻）で毎回リークした。**TMPDIR に 780 件蓄積していたのを実測で確認**、3 reviewer が独立に検出。

同ファイルの既存 tempfile は例外なく「先頭で空文字列に先行宣言 → cleanup 関数に登録 → trap で回収」というパターンを取っており、新規分だけがそこから外れていた。

**チェック**: 新規 `mktemp` を足すときは、そのファイルの cleanup 関数の引数リストを見る。そこに載っていなければ設計が違う。

**テスト側の pin**: 成功経路を実行した後に当該 glob の tempfile が残らないことを assert する（hygiene pin）。ただしこれは「cleanup が働いた」でも「そもそも到達していない」でも成立するため、rc と marker を positive に固定してから不在を判定する（positive control）。実装が P0/P2 のように対称なら、**両側を実行する pin** を置かないと片側の退行が生存する。

**inline rm は削除する**: tempfile が trap に登録済みなら、`[ -n "$v" ] && rm -f "$v"` のような短絡形式の inline `rm` は不要かつ有害（失敗を silent 化する）。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](./mktemp-failure-surface-warning.md)

> **補強**: trap の登録順だけでなく、**cleanup 関数が読む変数への代入順**にも同じ窓がある。trap は既に設置済みで `rm -f "${gh_err:-}"` を実行する形だったが、新設した一時ファイルを別変数 `_body_jq_err` に受けてから `gh_err` へ代入するのが**その一時ファイルを使う処理の後**だった。生成〜代入の間に signal を受けると cleanup は空の `gh_err` しか見ず、ファイルが残る（jq stub を sleep させ SIGTERM を送って leak を再現）。修正は代入を生成直後へ前倒しする 1 行。**trap が読む変数への代入は、そのリソースを使い始める前に済ませる。** signal-timing テストは本質的に racy なため、「代入行が使用行より前にある」ことの順序静的 pin で代替した（mutation で検出を実測）。

## ソース

- [PR #529 cycle 3 fix (tempfile lifecycle 契約)](../../raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md)
- [PR #548 cycle 1 fix (trap action リセット最小化)](../../raw/fixes/20260416T165559Z-pr-548.md)
- [PR #548 cycle 4 fix (mktemp → trap race の複数箇所修正)](../../raw/fixes/20260416T180658Z-pr-548.md)
- [PR #548 cycle 4 review (wiki-ingest-commit.sh worktree fast path で race 残存検出)](../../raw/reviews/20260416T180001Z-pr-548.md)
- [PR #1033 review (hand-off registry pattern で `/tmp/rite-fix-normalized-*` orphan 解消)](../../raw/reviews/20260517T231929Z-pr-1033.md)
- [PR #1850 fix (jq gate を mktemp より前へ移動する最小 reorder — gate-exit variant)](../../raw/fixes/20260713T093252Z-pr-1850.md)
- [PR #1850 review (2 reviewer 独立検出 + sibling 間の gate 位置非対称の実測)](../../raw/reviews/20260713T104006Z-pr-1850.md)
- [PR #2038 fix results (cycle 6, final) — 回収変数への代入が遅れて signal 窓が開く](../../raw/fixes/20260728T122258Z-pr-2038.md)
