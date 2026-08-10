---
title: "POSIX `[[:cntrl:]]` は C1 8-bit 制御バイト (0x80–0x9f) を分類しない"
domain: "anti-patterns"
description: "glibc (C / UTF-8 両ロケールでバイト単位実測確認) の `[[:cntrl:]]` POSIX 文字クラスは C0 (0x00–0x1f) + DEL (0x7f) のみを cntrl と分類し、C1 8-bit 制御バイト (0x80–0x9f、特に CSI introducer 0x9b) を素通しする。"
promote: rite-plugin
created: "2026-06-05T05:45:26Z"
updated: "2026-06-05T17:02:41Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260605T045347Z-pr-1277.md"
  - type: "reviews"
    ref: "raw/reviews/20260605T163454Z-pr-1280.md"
tags: ["bash", "posix-character-class", "c1-control-bytes", "csi-introducer", "neutralize", "locale", "utf-8"]
confidence: high
---

# POSIX `[[:cntrl:]]` は C1 8-bit 制御バイト (0x80–0x9f) を分類しない

## 概要

glibc (C / UTF-8 両ロケールでバイト単位実測確認) の `[[:cntrl:]]` POSIX 文字クラスは C0 (0x00–0x1f) + DEL (0x7f) のみを cntrl と分類し、C1 8-bit 制御バイト (0x80–0x9f、特に CSI introducer 0x9b) を素通しする。制御文字 neutralize 規約を `${VAR//[[:cntrl:]]/?}` や `sed 's/[[:cntrl:]]/?/g'` で実装すると、ESC を経由しない 8-bit エスケープ経路が残る。canonical 対策は `LC_ALL=C tr` によるバイト単位置換で C0 + DEL + C1 を同時遮断する共通ヘルパー化。

## 詳細

### 盲点の構造（review → follow-up Issue → 修正 PR）

一部端末は 0x9b を `ESC [` 相当の CSI introducer として解釈するため、`[[:cntrl:]]` ベースの neutralize は理論上の 8-bit エスケープシーケンス注入経路を残す。「`[[:cntrl:]]` = 全制御文字」という直感が glibc の locale 分類と一致しないことが盲点の核。

### 攻撃経路: jq の JSON round-trip は U+009B を素通しする

- 生 0x9b (latin1 系端末経路): jq の JSON 読み書きで U+FFFD 化されるため JSON 経路では届きにくい
- **U+009B の UTF-8 エンコード 0xc2 0x9b (UTF-8 端末経路)**: valid UTF-8 として jq の JSON 読み書きを素通りする — 現実の攻撃バイト列はこちら

両経路を同時に遮断するにはバイト単位置換 (`LC_ALL=C tr`) が必要 (0xc2 0x9b の 2 バイト目 0x9b が C1 範囲に入るため、バイト単位なら UTF-8 エンコード形も自動的に潰れる)。

### Canonical 対策: 共通ヘルパーによるバイト単位フィルタ

`control-char-neutralize.sh` の `neutralize_ctrl()` (stdin→stdout バイトフィルタ) に neutralize 責務を集約し、全 call site を共通ヘルパー経由に対称統一する (片側のみの対応は Asymmetric Fix を生む)。置換対象: C0 (0x00–0x1f) + DEL (0x7f) + C1 (0x80–0x9f) を `?` へ。行構造保持が必要な snippet 用に `--keep-newline` オプションで `\n` のみ保持。

**トレードオフ**: バイト単位置換は UTF-8 マルチバイト文字の継続バイト (0x80–0xbf のうち 0x80–0x9f 重複域) も潰すため、診断 snippet 内の日本語等は `?` 連続に劣化する。置換対象を破損 state file 断片・未知 handoff 等の異常系診断出力に限定し、安全側に倒すのが正当化条件。

### テスト責務分離: 統合層は U+009B、生バイトは単体層で pin

jq の JSON 経路は生 0x9b を U+FFFD 化するため、統合テスト (JSON round-trip を通る経路) では valid UTF-8 の U+009B で pin し、生 0x9b バイトの遮断は単体テスト層 (バイトフィルタ直接呼び出し) で pin する。経路ごとに到達可能なバイト列が異なることをテスト設計に反映する責務分離が有効。

### 執筆ミスパターン: CSI 代表例を範囲上限と混同する

C1 範囲のコードポイントラベルを「U+0080–U+009B」と書く誤記が発生しやすい (CSI introducer の代表例 U+009B を範囲上限と混同する。正: U+0080–U+009F = 0x80–0x9f)。コメント内のコードポイント範囲ラベルと実装バイト範囲の不整合として review で検出された実例（cycle 1 の唯一の MEDIUM finding）。

### 検出 (reject) 用途も同じ盲点を共有する — `contains_ctrl()` で解決（follow-up Issue → 修正 PR）

neutralize (置換) 側を共通ヘルパー化しても、検出 (reject) 用途の `=~ [[:cntrl:]]` には同じ C1 非検出盲点が残存する。`[[:cntrl:]]` を使う全用途 (置換 / 検出) が同じ盲点を共有することに注意。起点事例で検出用共通関数 `contains_ctrl()` を `control-char-neutralize.sh` に追加し、3 call site (`flow-state.sh` の session_id 検証 / `wiki-ingest-trigger.sh` の SOURCE_REF・TITLE 検証) を neutralize 側と同一バイト範囲定義 (`tr '\000-\037\177\200-\237'`) で統一して解決 (4 reviewer 0 findings / 1 cycle)。

検出側実装の設計判断（review で検証済）:

- **grep でなく tr + バイト数比較**: ugrep 等の grep 実装は `LC_ALL=C` でも raw 8-bit バイト (invalid UTF-8) にリテラルパターンですらマッチせず、検出が環境依存で silent に壊れる。tr は neutralize_ctrl と同一コマンド・同一レンジ定義で「同じバイト範囲定義」という規約対称性が文字どおりになる
- **pure-bash 代替 (`${var//[...]/}`) は等価でない**: ja_JP.UTF-8 で codepoint-aware となり locale 依存を再導入することを実測で棄却
- **fail-closed**: pipeline 失敗 / 非数値 wc 出力は「detected」扱いで reject 側に倒し、reject 経路が silent pass-through に劣化しないことを優先
- **byte-wise 検出の許容条件**: UTF-8 継続バイト (日本語等) を誤検出するが、現呼び出し元の値が ASCII 固定であることを確認した上で採用 (日本語 TITLE が必要になった時点で UTF-8 セーフモードを追加する方針)
- **性能トレードオフ**: 旧 bash regex ~0.0085ms → 新 4-fork ~2.7ms/call。最高頻度経路でも発火あたり 1 回・非ループのため imperceptible と判定
- **検証**: mutation testing 2 段階 (`contains_ctrl` を always-clean 化 → C1 固有テストのみ FAIL することで「C1 検出が本丸として pin されている」ことを実証) + fail-closed 契約の runtime 強制検証

残存調査で pre-existing の同一 failure class を列挙し別 Issue 境界で追跡: `_validate-state-root.sh:59` の reject 用途 `tr -d '[:cntrl:]'` (C1 見逃し、follow-up Issue 化候補) / `work-memory-update.sh:237` の strip 用途 (別系統)。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](../heuristics/empirical-reproduction-over-invariant-reasoning.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #1277 review results](../../raw/reviews/20260605T045347Z-pr-1277.md)
- [PR #1280 review results — 検出側 contains_ctrl() 統一の設計判断検証 (tr vs grep / pure-bash 棄却 / fail-closed / mutation 2 段階)](../../raw/reviews/20260605T163454Z-pr-1280.md)
