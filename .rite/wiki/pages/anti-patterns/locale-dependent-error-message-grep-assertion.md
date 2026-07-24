---
type: "anti-patterns"
title: "エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する"
domain: "anti-patterns"
description: "bash 等のローカライズ済みエラーメッセージ（例: 「コマンドが見つかりません」）を英語文字列で grep する assert は、非英語 locale のホスト/CI で常に空振りし、実装破壊 mutation に対して green のまま通過する dead assertion になる。LC_ALL=C で locale を固定するか、rc 直接 assert・状態遷移 assert 等の locale 非依存 discriminator に置換する。"
created: "2026-07-24T16:55:00+09:00"
updated: "2026-07-24T16:55:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T070805Z-pr-2003.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T071409Z-pr-2003.md"
tags: ["bash", "test-quality", "locale", "dead-assertion", "identification-power", "degrade-path", "LC_ALL"]
confidence: high
---

# エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する

## 概要

bash が exit 127 で出す `command not found` のようなエラーメッセージは gettext でローカライズされるため（ja_JP.UTF-8 では `コマンドが見つかりません`）、英語文字列を `grep -q "command not found"` で検査する assert は非英語 locale のホストで**常に空振りして pass する**。「エラーが出ていないこと」の否定形 assert として書かれている場合、実装を破壊する mutation に対しても green のまま通過する dead assertion になり、テストの識別力（identification power）が silent に失われる。

## 詳細

### 実例（PR #2003 / Issue #1999）

flock 不在環境の degrade 分岐（`command -v flock` ガード）を検証する新規テスト TC-9 が、3 重の理由で「ガード除去 mutation に対して 26/26 全 green」の false-positive test になっていた（error-handling / test 両レビュアーが隔離 worktree の mutation 実験で独立に実証）:

1. **rc の破棄**: degrade 分岐を通る唯一の `flow-state set` 呼び出しの rc を `|| true` で破棄
2. **locale 依存 grep**: 唯一の判別 assert が `grep -q "command not found"` で、ja_JP.UTF-8 ホストでは bash が `flock: コマンドが見つかりません` を出すため never match → 常に pass
3. **構造的 pass**: 残り 4 assert（acquire/check/release）は mkdir ロック実装のため、state 書込が失敗してもガード有無に関わらず通過

### 是正パターン

- **rc を直接 assert する**: `rc=0; cmd || rc=$?; assert "rc 0" "0" "$rc"` — locale 非依存で最も単純な discriminator
- **「degrade が働いて初めて成立する肯定結果」を assert する**: PR #2003 では「別セッションからの liveness 判定が `held` を返す」ことを assert した。degrade が壊れて state が書けなければ holder が not-live 扱いになり `stale` が返るため、locale に依存せず破壊を検出できる（既存 TC-2/TC-4 の挙動の再利用）
- **英語 grep を残す場合は `LC_ALL=C` で固定する**: メッセージ文字列の検査自体に意味がある場合（exit 127 系エラーの混入検出等）は、被検査コマンドの env に `LC_ALL=C` を付けて英語メッセージを保証する
- **probe は専用 sid で行う**: スタブ完全性の sanity probe を「テスト本体と同じ識別子 + 依存ツールあり」で行うと、probe の書込が本体の liveness/状態判定を汚染して discriminator を無効化する。probe 専用の識別子を使う

### 検出方法

修正後に必ず「実装破壊 mutation（ガード除去等）でテストが FAIL するか」を隔離 worktree で検証してから commit する（[mutation testing の empirical 検証](../patterns/mutation-testing-test-fidelity.md)）。PR #2003 では commit 前の mutation 検証で新 TC-9 が正確に 2 assert FAIL することを確認した。precedent（issue-claim TC-16）はエラーメッセージ grep を使わず肯定結果（`claimed`）を assert しており、スタブ方式だけでなく**判別メカニズムまで**先行事例に揃えることが重要だった。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [Test が early exit 経路で silent pass する false-positive](./test-false-positive-early-exit.md)

## ソース

- [PR #2003 review cycle 1 (TC-9 false-positive を 2 レビュアーが mutation 実験で独立実証)](../../raw/reviews/20260724T070805Z-pr-2003.md)
- [PR #2003 fix cycle 1 (locale 非依存 discriminator への置換 + probe sid 分離 + LC_ALL=C)](../../raw/fixes/20260724T071409Z-pr-2003.md)
