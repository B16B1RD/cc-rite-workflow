---
title: "i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する"
domain: "heuristics"
description: "i18n 同期 PR (EN → JA 全面追従など) では、忠実翻訳が原本 (EN) に既存する事実誤りをそのまま翻訳側へ転写する。"
promote: rite-plugin
created: "2026-06-03T23:10:10Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260603T174323Z-pr-1263.md"
  - type: "fixes"
    resource: "raw/fixes/20260603T175332Z-pr-1263.md"
  - type: "reviews"
    resource: "raw/reviews/20260604T000828Z-pr-1265.md"
tags: ["i18n-parity", "faithful-translation", "accept-path", "fingerprint-suppression", "follow-up-issue", "fact-check"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-04T01:45:55Z" }
---

# i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する

## 概要

i18n 同期 PR (EN → JA 全面追従など) では、忠実翻訳が原本 (EN) に既存する事実誤りをそのまま翻訳側へ転写する。翻訳 PR でも原本への盲目的信頼をせず実装突合 (grep verify) を行うことで原本由来の誤りが初めて表面化する。検出した誤りの正しい決着は「翻訳側での部分修正」ではなく「原本+翻訳の両側同時修正を別 Issue 化 + 本 PR は accept (認知のみ) + fingerprint 永続化」である — 翻訳側単独修正は i18n parity を破壊するため。

## 詳細

### 観測された具体パターン

`docs/SPEC.ja.md` を英語版 `docs/SPEC.md` の per-session flow-state モデルへ全面同期する i18n parity 回復 PR で、以下が実測された:

1. **忠実翻訳による誤り転写**: EN SPEC.md に既存する 2 件の事実誤り (存在しないファイル `state-read.sh` への参照 / `_resolve-flow-state-path.sh`+`STATE_FILE_PATH` への参照) を JA 版が忠実に翻訳し、JA 側に新規導入した (revert test pass = 本 PR diff 由来の finding として成立)。
2. **検出経路は実装突合**: Doc-Heavy mode の 5 カテゴリ検証で大半の主張 (hooks.json 7 events / PHASE_ENUM_V3 13 値 / session-ownership.sh 4 関数・4 source caller / loop_count writer 0 hits 等) を実装側 grep verify した結果として、原本由来の誤り 2 件が表面化した。翻訳元 (EN) の誤りは fact 検証で初めて見える — 原本への盲目的信頼では検出できない。
3. **決着の構造判断**: JA 単独修正は i18n parity (EN ↔ JA の対応関係) を破壊するため、scope=follow-up (EN+JA 両側同時修正の別 Issue) が適切と tech-writer / code-quality の両レビュアーが独立に同一結論へ収束した。

### accept (認知のみ) 経路の初適用

HIGH × follow-up の 2 findings に対し、M5 の accept (認知のみ) 経路を初適用した:

- **コード変更ゼロ** で acknowledged 化し、fingerprint 永続化 (`.rite/state/accepted-fingerprints-{pr}.txt`、2 件) により次 cycle での同一 finding 再提示を suppression。
- accept reason の明文化: 「EN SPEC.md 側に同一誤りが存在し JA 単独修正は parity を破壊するため、EN+JA 両側同時修正の follow-up Issue で対応」。
- 統計: Total findings 2 / Fixed 0 / Accepted 2 — fix も reply も行わない第 3 の決着が正規経路として機能した。

### 判断基準

| 状況 | 決着 |
|------|------|
| 翻訳側が独自に導入した誤り | 本 PR 内で fix |
| 原本に既存する誤りの転写 (revert test pass) | accept + EN/JA 両側同時修正の follow-up Issue 化 |
| 原本の誤りを翻訳側単独で修正 | ❌ 禁止 — i18n parity を破壊し、次の同期 PR で再転写される |

### フロー完結の実証

本決着パターンの後半 (follow-up Issue → 両側同時修正) が修正 PR で完結し、フロー全体 (検出 → accept + fingerprint 永続化 → 別 Issue 切り出し → EN+JA 両側同時修正) が **検出 PR → follow-up Issue → 修正 PR の一巡で cycle 1 / 0 findings 収束** することを実証した:

1. **両側同時修正の実装**: `docs/SPEC.md` / `docs/SPEC.ja.md` の 2 箇所 (Session Ownership SoT ノート / flow-state schema table `loop_count` 行) を EN+JA 対称に修正 (+5/-5)。伝播スキャンで検出した `docs/designs/multi-session-state.md` の同一 stale 列挙も同一コミットで修正。
2. **修正 PR 側の検証も実装突合**: tech-writer (Doc-Heavy mode 5 カテゴリ) / code-quality の両レビュアーが、修正後の loop_count reader 集合 (`pre-compact.sh:233` / `post-compact.sh:128` / `session-start.sh:460` / `work-memory-update.sh:205`) と SPEC 両版列挙の byte-for-byte 一致、`pre-tool-bash-guard.sh` の `hook-preamble.sh` 単独 source を独立に grep verify し、AC 検証コマンド (grep 0 hits) も独立再実行して PASS。
3. **伝播チェックの境界判断**: 残存する `state-read.sh` 参照は migration-guide (旧 API→新 API 対応表の正当な参照) / 歴史的設計記録 (削除済注記あり) のみで stale-misleading なしと判定 — 「両側同時修正」のスコープは live claim に限定し、歴史的記録は対象外とする境界が機能した。
4. **収束効率**: 検出 PR で accept + fingerprint 永続化したことで修正 PR は最小 diff (3 files, +5/-5) に閉じ、cycle 1 で 0 findings mergeable に到達した。

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [レビュー結果](../../raw/reviews/20260603T174323Z-pr-1263.md)
- [fix 結果](../../raw/fixes/20260603T175332Z-pr-1263.md)
- [EN+JA 両側同時修正 PR の cycle 1 / 0 findings 収束 — フロー完結 evidence](../../raw/reviews/20260604T000828Z-pr-1265.md)
