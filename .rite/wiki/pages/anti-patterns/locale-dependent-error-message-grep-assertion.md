---
type: "anti-patterns"
title: "エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する"
domain: "anti-patterns"
promote: rite-plugin
description: "bash が exit 127 で出す `command not found` のようなエラーメッセージは gettext でローカライズされるため（ja_JP.UTF-8 では `コマンドが見つかりません`）、英語文字列を `grep -q \"command not found\"` で検査する assert は非英語 locale のホストで**常に空振りして pass する**。"
created: "2026-07-24T16:55:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260724T070805Z-pr-2003.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T071409Z-pr-2003.md"
  - type: "reviews"
    resource: "raw/reviews/20260729T061547Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T062345Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T234810Z-pr-2120.md"
tags: ["bash", "test-quality", "locale", "dead-assertion", "identification-power", "degrade-path", "LC_ALL"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T02:49:27Z" }
---

# エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する

## 概要

bash が exit 127 で出す `command not found` のようなエラーメッセージは gettext でローカライズされるため（ja_JP.UTF-8 では `コマンドが見つかりません`）、英語文字列を `grep -q "command not found"` で検査する assert は非英語 locale のホストで**常に空振りして pass する**。「エラーが出ていないこと」の否定形 assert として書かれている場合、実装を破壊する mutation に対しても green のまま通過する dead assertion になり、テストの識別力（identification power）が silent に失われる。

## 詳細

### 実例

flock 不在環境の degrade 分岐（`command -v flock` ガード）を検証する新規テスト TC-9 が、3 重の理由で「ガード除去 mutation に対して 26/26 全 green」の false-positive test になっていた（error-handling / test 両レビュアーが隔離 worktree の mutation 実験で独立に実証）:

1. **rc の破棄**: degrade 分岐を通る唯一の `flow-state set` 呼び出しの rc を `|| true` で破棄
2. **locale 依存 grep**: 唯一の判別 assert が `grep -q "command not found"` で、ja_JP.UTF-8 ホストでは bash が `flock: コマンドが見つかりません` を出すため never match → 常に pass
3. **構造的 pass**: 残り 4 assert（acquire/check/release）は mkdir ロック実装のため、state 書込が失敗してもガード有無に関わらず通過

### 是正パターン

- **rc を直接 assert する**: `rc=0; cmd || rc=$?; assert "rc 0" "0" "$rc"` — locale 非依存で最も単純な discriminator
- **「degrade が働いて初めて成立する肯定結果」を assert する**: 起点事例では「別セッションからの liveness 判定が `held` を返す」ことを assert した。degrade が壊れて state が書けなければ holder が not-live 扱いになり `stale` が返るため、locale に依存せず破壊を検出できる（既存 TC-2/TC-4 の挙動の再利用）
- **英語 grep を残す場合は `LC_ALL=C` で固定する**: メッセージ文字列の検査自体に意味がある場合（exit 127 系エラーの混入検出等）は、被検査コマンドの env に `LC_ALL=C` を付けて英語メッセージを保証する
- **probe は専用 sid で行う**: スタブ完全性の sanity probe を「テスト本体と同じ識別子 + 依存ツールあり」で行うと、probe の書込が本体の liveness/状態判定を汚染して discriminator を無効化する。probe 専用の識別子を使う

### 検出方法

修正後に必ず「実装破壊 mutation（ガード除去等）でテストが FAIL するか」を隔離 worktree で検証してから commit する（[mutation testing の empirical 検証](../patterns/mutation-testing-test-fidelity.md)）。起点事例では commit 前の mutation 検証で新 TC-9 が正確に 2 assert FAIL することを確認した。precedent（issue-claim TC-16）はエラーメッセージ grep を使わず肯定結果（`claimed`）を assert しており、スタブ方式だけでなく**判別メカニズムまで**先行事例に揃えることが重要だった。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [Test が early exit 経路で silent pass する false-positive](./test-false-positive-early-exit.md)

## ソース

- [PR #2003 review cycle 1 (TC-9 false-positive を 2 レビュアーが mutation 実験で独立実証)](../../raw/reviews/20260724T070805Z-pr-2003.md)
- [PR #2003 fix cycle 1 (locale 非依存 discriminator への置換 + probe sid 分離 + LC_ALL=C)](../../raw/fixes/20260724T071409Z-pr-2003.md)

## 変種: 表示経路（assert ではなく診断そのもの）に locale 依存が漏れる

同じ locale 依存が、テストの grep assert ではなく**人間に見せる診断の表示経路**でも損失を生む。helper の stderr を capture して `neutralize_ctrl --keep-newline` に通す idiom は、0x80-0x9f をバイト単位で `?` へ置換するため、**UTF-8 の多バイト日本語診断が原因語ごと判読不能になる**。「元は端末へ素通しで読めていた stderr」をフィルタ越しにする変更は観測性の退行になりうる。

対策は capture 側に `LC_ALL=C` を付けて stream を ASCII に固定すること。`--c0-only` への切り替えは端末へ書くサイトでは採らない（raw 8-bit C1 = 0x9b CSI の素通しが端末乗っ取りの実損になる）。

実測での確認が有効: 書き込み不能な state root で helper を叩き、`mktemp: ... 許可がありません` が `LC_ALL=C` で `Permission denied` に変わることを見る。

> **判定の分かれ目**: 「スクリプト自身の echo」（locale 非依存、`LC_ALL=C` では変わらない）と「外部コマンドの診断」（locale 依存）を区別する。後者だけが唯一の原因行になる経路（helper が rc しか返さない write 失敗）が修正の要否を決める。tempfile 捕捉済みで元々端末に出ていなかったサイト（`hooks/` 配下の同 idiom 約 20 箇所）は差し引きプラスであり、同一視して retrofit してはならない。

関連して、**`2>&1` capture を「rc≠0 のときだけ表示」と組むと成功時の診断を握り潰す**。helper が rc=0 のまま WARNING を出す経路があると、リダイレクトが無かった頃には届いていた診断が消える。**capture の導入は観測性の向上とは限らない** — 表示条件を rc に紐付けた瞬間、rc=0 の診断は捨てられる。診断の emit は if/else の外に置き、rc とは独立に surface する（成功時の capture は通常空なので `-n` guard でノイズは出ない）。

## 変種: 中和済み出力への assert は不正 UTF-8 で検出能力を失う

3 つ目の面がある。上 2 節は「英語文字列を非英語ロケールで grep する」「診断の表示が中和で潰れる」だったが、**中和を通した出力に対する assert 自体が vacuous pass する**経路がある PR の cycle 1 で実測された。

`neutralize_ctrl` は 0x80-0x9f を**バイト単位**で潰すため、ロケール依存の診断（日本語の「許可がありません」等）が**不正な UTF-8 列**になる。GNU grep は UTF-8 ロケール下でその行に対して一切マッチしない。したがって「列 0 に制御文字が漏出していないこと」を見る `assert_not_grep` は、**「漏出が無い」ではなく「grep が読めない」で pass していた**。

実際に漏出を起こす mutation（グループスコープ `{ ...; } 2>&1` を単純コマンドへ落とす）を当てても検出されず、`LC_ALL=C` を付けた raw grep へ変えた途端に検出されるようになった。

```
✗ assert_not_grep '^WARNING:' "$out"
   → 中和が作った不正 UTF-8 に UTF-8 ロケールの grep が一切マッチせず常に pass
✓ LC_ALL=C grep -cE '^WARNING:' "$out"
   → バイト列として読むので漏出を検出する
```

**中和・バイト置換・エンコード変換を通した出力に対する assert は、`LC_ALL=C` を付けない限り検出能力を持たない可能性がある。**

この非対称は既に先例側に現れていた。同種の先例（`review-result-state-root.test.sh` TC-8）は最初から `LC_ALL=C grep -cE` で書かれており、共有ヘルパー（`assert_grep` / `assert_not_grep`）にはロケール上書きが無い。ヘルパーを使う側からはその差が見えない。**中和済み出力を検査するときは共有 assert ヘルパーを使わず raw grep + `LC_ALL=C` で書く。**

### 中和の pin は「隣の未中和行」に邪魔される

中和そのものの regression test を書くとき、素朴な「列 0 に偽 `WARNING:` 行がない」という形は **現状でも FAIL する**。同一実行の数行前に pre-existing の未中和 WARNING があり、同じ入力から列 0 の行を作るためである。

assert は**自分が中和した行に限定**する必要がある（メッセージ末尾のリテラルで grep を絞る）。部分的に中和した経路への assert を全体で見る形にすると、未中和の隣接行が常に混ざって最初から赤いか、逆に緩めすぎて何も検出しなくなる。

## ソース（追記分）

- [PR #2044 review results — フィルタ経路の locale 依存](../../raw/reviews/20260729T061547Z-pr-2044.md)
- [PR #2044 fix results — LC_ALL=C による stream 固定](../../raw/fixes/20260729T062345Z-pr-2044.md)
- [PR #2120 fix results — 中和済み出力への assert が不正 UTF-8 で vacuous pass](../../raw/fixes/20260805T234810Z-pr-2120.md)
