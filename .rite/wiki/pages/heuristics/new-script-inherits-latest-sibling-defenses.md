---
type: "heuristics"
title: "テンプレート流用の新規スクリプトは最新兄弟の防御を継承する"
domain: "heuristics"
description: "既存スクリプトをテンプレートに新規スクリプトを作ると、兄弟スクリプト群が後から獲得した防御（wc -l 空白正規化、usage 契約と実装の一致）を継承し漏らす。流用元は最も古い兄弟でなく最も新しい兄弟を選ぶ。sweep の完了検証はパターン限定 grep でなく対象文字列そのものでも掃く。PR #1909 cycle 1 実測。"
created: "2026-07-19T15:00:00+09:00"
updated: "2026-07-19T15:00:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T022247Z-pr-1909.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T022630Z-pr-1909.md"
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

## 関連ページ

- [再発防止 guard スクリプトは docstring の宣言意図と実装 regex を実測で校正する](./guard-script-contract-calibration.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1909 review results (cycle 1)](../../raw/reviews/20260719T022247Z-pr-1909.md)
- [PR #1909 fix results (cycle 1)](../../raw/fixes/20260719T022630Z-pr-1909.md)
