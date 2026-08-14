---
title: "consume 操作 (read+delete+return) は delete-then-return 順で fail-closed にする"
domain: "patterns"
description: "state ファイルから値を read し、その値に基づいて消費者が判断を下す **consume 操作 (read + delete + return value)** は、必ず **delete (= 状態変更の確定) を先に行ってから値を return / emit する** 順序で実装する。"
promote: rite-plugin
created: "2026-05-28T15:05:43Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260528T142118Z-pr-1169.md"
  - type: "reviews"
    resource: "raw/reviews/20260528T141817Z-pr-1169.md"
tags: ["fail-closed", "consume-operation", "ordering", "atomic-write", "stop-hook", "handoff", "infinite-loop", "asymmetric-fix-transcription"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-28T15:05:43Z" }
---

# consume 操作 (read+delete+return) は delete-then-return 順で fail-closed にする

## 概要

state ファイルから値を read し、その値に基づいて消費者が判断を下す **consume 操作 (read + delete + return value)** は、必ず **delete (= 状態変更の確定) を先に行ってから値を return / emit する** 順序で実装する。値を先に return すると、削除に失敗したケースで「消費したつもりで未消費」という不整合状態に陥り、消費者がその値に基づいて動作を確定してしまう。one-shot consume を前提とする消費者 (Stop hook 等) では、これが永続 FS 障害下での無限ループに直結する。

print-then-delete は fail-open (削除失敗を無視して値を吐く)、delete-then-return は fail-closed (削除失敗時は値を withhold する) になる。後者が正解。

## 詳細

### 発生事例（Stop hook loop-continuation）

`flow-state.sh` に `consume-handoff` サブコマンド (handoff マーカーを read + delete + return する one-shot consume) を追加した起点事例で、初版実装が **print-then-delete** 順だった:

```bash
# 初版 (fail-open — print-then-delete)
cmd_consume_handoff() {
  local handoff
  handoff=$(read_handoff)        # 1. read
  printf '%s' "$handoff"         # 2. return value (先に出力)
  _atomic_write "$state" "$new"  # 3. delete (handoff をクリア)
  # _atomic_write 失敗時: || return 0 で握りつぶし、診断も出さない
}
```

`_atomic_write` が失敗 (read-only state dir / permanent FS error 等) しても `|| return 0` で握りつぶしていたため、**handoff が消えていないのに「消費した」値を返す**。consume 結果を受けて Stop hook が `decision:block` で停止差し戻し → 次サイクルでも handoff が残存しているため再び block → **永続 FS 障害下で無限ループ** (AC-3 違反)。

### 表層観察の奥に潜む behavioral bug

cycle 1 review では 4 reviewer (code-quality / error-handling / security / devops) が同じ `consume-handoff` の「`del(.handoff)` / `_atomic_write` 失敗時の silent fail-open (`|| return 0`、WARNING なし)」を **独立に指摘したが、全員が design_confirmation / Hypothetical に降格**した (= 表層の「診断欠落」として扱われた)。cycle 2 で error-handling reviewer が **read-only state dir (chmod 0555) で runtime 再現** したことで、これが単なる診断欠落ではなく **ordering バグ (AC-3 break) = HIGH** だと初めて Demonstrable になった。

教訓: 表層観察 (診断欠落) の奥に behavioral bug が潜むケースは、re-review の deeper runtime 分析で初めて顕在化する。`|| return 0` の silent fail-open を見つけたら「診断を足す」で終わらせず、**その経路が consume の正当性を壊さないか** を runtime 再現 (権限剥奪等の fault injection) で verify する。

### Canonical fix — 3 点セット

1. **reorder で fail-closed 化**: delete (`_atomic_write`) を先に実行し、成功した場合のみ値を return / emit する。失敗時は値を withhold (空を返す or non-zero return) して消費者を「未消費」側に倒す。

   ```bash
   # 修正版 (fail-closed — delete-then-return)
   cmd_consume_handoff() {
     local handoff
     handoff=$(read_handoff)
     if ! _atomic_write "$state" "$new"; then
       echo "ERROR: consume-handoff: handoff クリアに失敗、値を withhold します" >&2
       return 1          # 値を出力せず fail-closed
     fi
     printf '%s' "$handoff"   # delete 確定後にのみ return
   }
   ```

2. **診断 emit で対称化**: 同一ファイル内の対称 helper (`cmd_set` 等) が `_atomic_write` を `|| return 1` で fail-closed 伝播 + 診断 emit しているのに、`consume-handoff` だけ `|| return 0` 無診断だった = [[asymmetric-fix-transcription]] の一種。対称 helper と同じ fail-closed + 診断 pattern に揃える。

3. **呼び出し側の `2>/dev/null` を gate 化**: consume を呼ぶ hook が stderr を `2>/dev/null` で常時握りつぶしていると、せっかくの診断 emit が surface しない。`RITE_DEBUG` gate 付き ([[silent-fallback-observability-via-debug-log]]) にして、必要時に診断を観測可能にする。

### 一般化

本 pattern は handoff consume に限らず、**read-modify-delete を含むあらゆる「消費」操作** に適用される。「消費者が return 値に基づいて非冪等な動作 (停止・送信・削除等) を確定する」場合、状態変更 (delete / commit) を return より前に置かないと、状態変更失敗時に「動作は確定したが状態は未変更」という分岐を許す。fail-closed = 「状態変更が確定しない限り値を渡さない」を default に倒す。

### 回帰検出ネット

correctness path を導入したら同 PR 内で「invariant を壊す mutation で FAIL する test」を必ず添える ([[mutation-testing-test-fidelity]])。起点事例では read-only state dir (chmod 0555) で `_atomic_write` を強制失敗させ、値 withhold / handoff 残存 / rc≠0 / 診断 ERROR emit を assert する TC-H6 を追加し、print-then-delete への mutation で実際に FAIL することを確認した。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](./silent-fallback-observability-via-debug-log.md)
- [jq -n create mode: 既存値を読み取ってから再構築する](./jq-create-mode-preserve-existing.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)

## ソース

- [PR #1169 fix results (cycle 2) — consume-handoff を delete-then-return で fail-closed 化 + 診断 emit で cmd_set と対称化](../../raw/fixes/20260528T142118Z-pr-1169.md)
- [PR #1169 review results (cycle 2) — 表層の診断欠落の奥に潜む ordering バグ (AC-3 break) を runtime 再現で HIGH 昇格](../../raw/reviews/20260528T141817Z-pr-1169.md)
