---
title: "形状検証 gate の allowlist 化は複数行 bypass・上流 degraded 値・コメント同期をセットで棚卸しする"
domain: "heuristics"
promote: rite-plugin
created: "2026-06-10T10:10:00+09:00"
updated: "2026-07-19T23:01:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260609T223122Z-pr-1330.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T223943Z-pr-1330-c2.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T224734Z-pr-1330-c3.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T225247Z-pr-1330-c4.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T120555Z-pr-1909.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T121530Z-pr-1909.md"
tags: []
confidence: high
---

# 形状検証 gate の allowlist 化は複数行 bypass・上流 degraded 値・コメント同期をセットで棚卸しする

## 概要

入力検証 gate を denylist から allowlist に強化する PR では、(1) 検証手段の行単位/文字列全体 anchor の差、(2) 上流が正規に emit する degraded sentinel 値の存在、(3) 置換機構変更に伴う同一ブロック内コメントの同期、の 3 点を着手時に棚卸しする。4 cycle 収束の実測で 3 点すべてが独立指摘として現れた。

## 詳細

起点事例 (review-comment-post.sh の iso_timestamp gate denylist → ISO 8601 allowlist 化 + awk gsub → index()/substr() リテラル置換) で、cycle ごとに異なる落とし穴が surface した:

1. **複数行 bypass (cycle 1, MEDIUM)**: `printf '%s' "$v" | grep -qE '^...$'` は**行単位マッチ**のため、複数行値のいずれか 1 行が形状に一致すれば gate を通過する。LLM caller の literal substitute ミス (複数行貼り付け) という gate 自身の脅威モデル内の入力で破られ、不正 JSON が投稿されるところまで end-to-end 再現された。**bash 組込み `[[ =~ ]]` は `^`/`$` が文字列全体に anchor され改行込み値を構造的に reject する** — hooks/ の支配的 gate パターンでもあり、形状検証 gate の正解形。
2. **上流 degraded 値の reject と誤診断 (cycle 3, MEDIUM ×2 reviewer 合意)**: allowlist は「不正値」と「上流が正規に emit する degraded sentinel (例: EXIT trap の `${var:-unknown}`)」を区別できない。`unknown` を「emit 値を渡せ」という読取漏れ向け診断で reject すると、caller を同一値の再投入ループへ誘導する。**gate 強化時は上流 producer が emit しうる全値 (正常形・degraded 形) を棚卸しし、degraded 値には専用診断 (再投入では解決しない / 根本原因の確認先) を出す**。fail-fast 自体は維持してよい。
3. **置換機構変更時のコメント同期 (cycle 3, MEDIUM)**: gsub → index/substr のような機構変更で、数行上の overview コメント (「gsub する」) が stale 化し、直下の新コメント (「gsub だと壊れる」) と同一ブロック内で矛盾する。機構変更時は同一ブロックの全コメントを同期対象にする。
4. **付随観察**: gate 形式の置換で旧 gate のみが参照していた変数が dead 化する (置換時に変数参照の生存確認をする)。review-fix loop 内で書く新規コメントに「cycle N fix」と書くと次 cycle の comment-journal 検査で HIGH になる (経緯は commit message へ、コメントは機構の WHY のみ)。

検証面では、test reviewer の worktree-only mutation (gate 無効化 / anchor 除去 / grep 復帰 / degraded 分岐除去) が 4 cycle 全てで新規テストの non-vacuity を実証しており、gate 強化 PR のテストは「旧実装に戻すと FAIL する」ことの mutation 確認が収束の決定打になる。

5. **新 arm 追加時の per-arm テスト pin（resume cycle、MEDIUM ×2 reviewer 独立検出）**: exfiltration 境界などの allowlist gate に新しい受理 arm を追加するときは、per-arm のテスト pin — **正例 (受理) + 負例 (拒否) + fallback 経路 (realpath 失敗時の fail-closed + 診断 WARNING)** — の 3 点セットを同一 PR で追加する。実装が正しくてもテスト無しでは受理経路の drift と診断消失の回帰から守れない (test + security の 2 reviewer が独立検出)。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1330 fix cycle 1 (複数行 bypass の [[ =~ ]] 閉塞 + SENTINEL dead variable 解消)](../../raw/fixes/20260609T223122Z-pr-1330.md)
- [PR #1330 fix cycle 2 (テストコメントの journal token 除去)](../../raw/fixes/20260609T223943Z-pr-1330-c2.md)
- [PR #1330 fix cycle 3 (degraded 値 unknown の専用診断 + stale gsub コメント是正)](../../raw/fixes/20260609T224734Z-pr-1330-c3.md)
- [PR #1330 review cycle 4 mergeable (5 reviewer 0 件、mutation 検証で non-vacuity 実証)](../../raw/reviews/20260609T225247Z-pr-1330-c4.md)
- [PR #1909 review results (resume cycle — allowlist 新 arm の per-arm pin 欠落指摘)](../../raw/reviews/20260719T120555Z-pr-1909.md)
- [PR #1909 fix results (per-arm 3 点セット pin の追加)](../../raw/fixes/20260719T121530Z-pr-1909.md)
