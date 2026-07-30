---
type: "anti-patterns"
title: "否定形の assert は前提条件が崩れると fail-silent になる"
domain: "anti-patterns"
description: "「壊れていないこと」を検証する assert は、検証対象の入力が前提条件（切り詰め窓の内側にある・偶然解決しない cwd から実行される等）を外れると、実装が壊れていても通ってしまう。前提が成立していることを別途 floor で assert するか、肯定形（中和後の値が観測できること）に書き換える。"
created: "2026-07-25T14:18:43Z"
updated: "2026-07-25T14:18:43Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260725T103734Z-pr-2017-cycle3.md"
tags: []
confidence: high
---

# 否定形の assert は前提条件が崩れると fail-silent になる

## 概要

「X が起きていないこと」を検証する assert は、そもそも X が起こりうる条件が成立していなければ自動的に通る。前提条件が環境依存（`$TMPDIR` の長さ、実行時の cwd、ロケール）だと、blocking gate では機能していても別環境で静かに検証をやめる。肯定形（「中和/変換が行われた痕跡が観測できること」）に書き換えるか、前提条件そのものを floor で assert する。

## 詳細

### 実例 1: 切り詰め窓の外に出て沈黙する

監査ログの 1 行性を検証する pin:

```bash
grep -q 'BLOCKED .*path="[^"]*"$' "$STDERR_FILE"   # レコードが分割されていない = 防御が効いている
```

ログは `${ABS_PATH:0:120}` に切り詰めてから出力される。fixture のパスは `$TMPDIR` 起点なので、`$TMPDIR` が長い環境では検証対象の改行バイトが 120 文字窓の外へ落ちる。**そうなると防御を削除してもレコードは 1 行のままで、pin は通る。** 実測: `len($TMPDIR)=48` では防御除去を検出（42 passed / 1 failed）、`len($TMPDIR)=122` では検出せず（43 passed / 0 failed）。

### 実例 2: cwd 次第で偶然解決して沈黙する（同 PR）

相対パス分岐を stub する mutation を検出する pin は、deny の *種別* まで assert していた:

```bash
assert_deny_gitdir "relative symlink target into parent .git resolved & blocked" "$out"
```

stub すると相対パスのまま後段の walk へ渡るが、そのパスは **hook プロセスの cwd 基準で解決される**。cwd が偶然 fixture の兄弟ディレクトリを持つ位置（このリポジトリでは reviewer に mutation 実験を指示している `$TMPDIR` 直下）だと正しく解決してしまい、stub 版でも期待どおり deny になる。実測: cwd を `/` / `$TMPDIR` / `$HOME` にすると kill、`$TMPDIR` 直下にすると素通り。

### 共通の構造

どちらも「検証対象の現象が起こりうる状態にあること」を assert していない。否定形の pin は次の 2 つを区別できない:

1. 実装が正しいので現象が起きなかった（意図した pass）
2. 前提が崩れて現象が起こりえなかった（vacuous pass）

### 対処 1: 肯定形に書き換える

「壊れていない」ではなく「変換された痕跡がある」を assert する:

```bash
# 否定形: レコードが分割されていない（切り詰めでも通る）
grep -q 'BLOCKED .*path="[^"]*"$' "$STDERR_FILE"

# 肯定形: 中和後のバイトが同一行に載っている（切り詰められると落ちる）
grep -q 'BLOCKED .*path="[^"]*lf-dir?[^"]*"$' "$STDERR_FILE"
```

肯定形は前提が崩れたとき pass ではなく fail に倒れるので、silent にはならない。

### 対処 2: 前提条件を floor で assert する

環境値から前提の成否を導出できるなら、崩れた時点で明示的に落とす。blocking gate では hard fail、それ以外は skip という 2 段構えにすると、長い `$TMPDIR` のワークステーションを spurious に赤くしない:

```bash
_lf_off=$(( ${#ISO_MUT_DIR} + ${#lf_dir} ))   # 検証対象バイトの位置
if [ "$_lf_off" -ge 120 ]; then                # 報告窓の外
  if [ -d /proc ]; then
    fail "floor: 検証対象が報告窓の外（\$TMPDIR が長い）— 以下の pin は vacuous"
  else
    skip "..."
  fi
elif <肯定形の assert>; then
  ...
```

### 対処 3: 環境依存を実行時に固定する

cwd 依存のように、テスト側で固定できる前提は固定してしまう:

```bash
out=$(cd / && run_edit_guard "Write" "$target" ...)   # 兄弟ディレクトリを持たない位置から実行
```

### 検出方法

否定形 pin の vacuous 化は、通常の mutation testing では見つからない（blocking gate の環境では pin が機能するため mutation は kill される）。**環境変数や cwd を振って同じ mutation を再実行する** ことで初めて見える。移植性・環境依存を扱う PR では、mutation matrix に「環境軸」を 1 本足す。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [対象プラットフォーム挙動を shim して blocking gate 側で pin する](../heuristics/portability-fix-needs-target-platform-shim-on-blocking-gate.md)
- [degrade する対象をテストするときは判別子を probe と連動させる](../heuristics/degrade-discriminator-switched-by-probe.md)

## ソース

- [PR #2017 fix results (cycle 3)](../../raw/fixes/20260725T103734Z-pr-2017-cycle3.md)
