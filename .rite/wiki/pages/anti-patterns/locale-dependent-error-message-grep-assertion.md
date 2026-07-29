---
type: "anti-patterns"
title: "エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する"
domain: "anti-patterns"
description: "bash 等のローカライズ済みエラーメッセージ（例: 「コマンドが見つかりません」）を英語文字列で grep する assert は、非英語 locale のホスト/CI で常に空振りし、実装破壊 mutation に対して green のまま通過する dead assertion になる。LC_ALL=C で locale を固定するか、rc 直接 assert・状態遷移 assert 等の locale 非依存 discriminator に置換する。"
created: "2026-07-24T16:55:00+09:00"
updated: "2026-07-29T21:32:36+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T070805Z-pr-2003.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T071409Z-pr-2003.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T061547Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T062345Z-pr-2044.md"
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

## 変種: 表示経路（assert ではなく診断そのもの）に locale 依存が漏れる (PR #2044)

同じ locale 依存が、テストの grep assert ではなく**人間に見せる診断の表示経路**でも損失を生む。helper の stderr を capture して `neutralize_ctrl --keep-newline` に通す idiom は、0x80-0x9f をバイト単位で `?` へ置換するため、**UTF-8 の多バイト日本語診断が原因語ごと判読不能になる**。「元は端末へ素通しで読めていた stderr」をフィルタ越しにする変更は観測性の退行になりうる。

対策は capture 側に `LC_ALL=C` を付けて stream を ASCII に固定すること。`--c0-only` への切り替えは端末へ書くサイトでは採らない（raw 8-bit C1 = 0x9b CSI の素通しが端末乗っ取りの実損になる）。

実測での確認が有効: 書き込み不能な state root で helper を叩き、`mktemp: ... 許可がありません` が `LC_ALL=C` で `Permission denied` に変わることを見る。

> **判定の分かれ目**: 「スクリプト自身の echo」（locale 非依存、`LC_ALL=C` では変わらない）と「外部コマンドの診断」（locale 依存）を区別する。後者だけが唯一の原因行になる経路（helper が rc しか返さない write 失敗）が修正の要否を決める。tempfile 捕捉済みで元々端末に出ていなかったサイト（`hooks/` 配下の同 idiom 約 20 箇所）は差し引きプラスであり、同一視して retrofit してはならない。

関連して、**`2>&1` capture を「rc≠0 のときだけ表示」と組むと成功時の診断を握り潰す**。helper が rc=0 のまま WARNING を出す経路があると、リダイレクトが無かった頃には届いていた診断が消える。**capture の導入は観測性の向上とは限らない** — 表示条件を rc に紐付けた瞬間、rc=0 の診断は捨てられる。診断の emit は if/else の外に置き、rc とは独立に surface する（成功時の capture は通常空なので `-n` guard でノイズは出ない）。

## ソース（追記分）

- [PR #2044 review results — フィルタ経路の locale 依存](../../raw/reviews/20260729T061547Z-pr-2044.md)
- [PR #2044 fix results — LC_ALL=C による stream 固定](../../raw/fixes/20260729T062345Z-pr-2044.md)
