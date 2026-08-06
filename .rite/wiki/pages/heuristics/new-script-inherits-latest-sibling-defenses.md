---
type: "heuristics"
title: "テンプレート流用の新規スクリプトは最新兄弟の防御を継承する"
domain: "heuristics"
description: "既存スクリプトをテンプレートに新規スクリプトを作ると、兄弟スクリプト群が後から獲得した防御（wc -l 空白正規化、usage 契約と実装の一致）を継承し漏らす。流用元は最も古い兄弟でなく最も新しい兄弟を選ぶ。転記元は git grep で全サイトを列挙し git log -S で最終更新を確認してから決める。実装だけでなくその根拠として引用した事実も同時に stale になる。"
created: "2026-07-19T15:00:00+09:00"
updated: "2026-08-06T02:49:27Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T022247Z-pr-1909.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T022630Z-pr-1909.md"
  - type: "reviews"
    ref: "raw/reviews/20260805T233057Z-pr-2120.md"
tags: []
confidence: medium
---

# テンプレート流用の新規スクリプトは最新兄弟の防御を継承する

## 概要

既存スクリプト（bang-backtick-check.sh）をテンプレートに新規 check スクリプトを作ったところ、兄弟スクリプト群が**後から**獲得した防御 — `wc -l` の空白正規化（BSD/macOS パディング対応、sentinel-contract-check.sh が獲得済み）、usage の exit code 契約と実装の一致（同）— を継承し漏らし、cycle 1 レビューで MEDIUM×2 の指摘になった。テンプレート流用時は「最も古い兄弟」でなく「最も新しい兄弟」を流用元に選び、family 共通の防御の有無を差分確認する。

## 詳細

起点事例で tmp-hardcode-check.sh を新設した際の実測:

- **wc -l 正規化の欠落**: `total=$(wc -l < file)` は BSD/macOS で先頭空白パディング付きになり、lint 側の count-line regex `findings: (\d+)` と不一致になる。兄弟の sentinel-contract-check.sh は `| tr -d '[:space:]'` で正規化済み、number-reference-check.sh は算術カウンタで回避済み — 新規スクリプトだけが罠を踏んだ。
- **usage 契約と実装の矛盾ごと踏襲**: テンプレート元の bang-backtick-check.sh は「2 = Invocation error (bad args, missing files)」と宣言しながら missing file を WARNING + exit 0 で扱う矛盾を持っており、新規スクリプトはこの矛盾ごと複製した。修正済みの先例（sentinel-contract-check.sh の引数値ガード）が同ディレクトリに存在したのに参照しなかった。

**付随ヒューリスティック — sweep 検証は表現形式を跨ぐ**: sweep 系 PR の取り残しは「grep パターンの検出範囲外の表現形式」（markdown 表セル・説明 prose 等）に集中する。完了検証は変換パターン限定の grep だけでなく、対象文字列そのもの（例: `rite-backups`）でも掃くと表セルや prose の取り残しを拾える。実例: bash-defensive-patterns.md の code example は更新されたが直下の表セルが `/tmp/rite-backups/` のまま残り、機械 check（P2 regex は代入・redirect・-file 形式のみ）では検出されなかった。

### 参照先が「自分自身の系譜」の場合（PR #2120 cycle 1 実測）

流用元が別ファイルの兄弟とは限らない。**数コミット前の自分自身の同種経路**が参照先になる場合があり、こちらの方が見落としやすい。

PR #2120 は `.rite/logs/.gitignore` を生成する 3 番目の書き手を追加したが、guard として 2 コミット前（#2114）に同一の共有ディレクトリ保護で `[ ! -s ]`（中身検査）+ WARNING + `[CONTEXT]` marker へ明示的に強化された形ではなく、`session-start.sh` の**強化前の形**（`[ -f ]` + `2>/dev/null || true`）を採用していた。

決定的なのは、**実装の形とその根拠の両方が同時に stale になっていた**点である。新規コメントが根拠として挙げた「`/rite:setup` の生成 `.gitignore` が covers するのは 2 エントリ」という記述も、同じ #2114 で 3 エントリへ増えていた。同一 Issue が同一 PR 内で「実装の形」と「その根拠として引用した事実」の両方を陳腐化させた。

**手順として確定させる**:

1. `git grep` でパターンの全サイトを列挙する
2. 各サイトの最終更新を `git log -S` で確認する
3. 最新版を転記元に選ぶ
4. 転記したコメントが引用している**外部の事実**も、同じ列挙の中で再確認する

修正時に 4 サイトを並べたところ **多数派（2/4）は既に新形式で、転記元だけが少数派**だった。列挙していれば選択を誤らなかった。「直近に読んだ先例」を無自覚に選ぶと、強化の履歴を巻き戻す方向へ転記する。

なお、同じ idiom のコピーが 4 つに分岐している状態そのものが別の問題である（[同一箇所への指摘が N cycle 連続したら、その箇所が何番目のコピーかを数える](./idiom-copy-count-decides-patch-vs-extract.md)）。

## 関連ページ

- [再発防止 guard スクリプトは docstring の宣言意図と実装 regex を実測で校正する](./guard-script-contract-calibration.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [同一箇所への指摘が N cycle 連続したら、その箇所が何番目のコピーかを数える](./idiom-copy-count-decides-patch-vs-extract.md)

## ソース

- [PR #1909 review results (cycle 1)](../../raw/reviews/20260719T022247Z-pr-1909.md)
- [PR #1909 fix results (cycle 1)](../../raw/fixes/20260719T022630Z-pr-1909.md)
- [PR #2120 review results (cycle 1)](../../raw/reviews/20260805T233057Z-pr-2120.md)
