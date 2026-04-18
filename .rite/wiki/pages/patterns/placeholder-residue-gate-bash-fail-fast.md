---
title: "LLM substitute placeholder は bash residue gate で fail-fast 化する"
domain: "patterns"
created: "2026-04-18T12:50:00+00:00"
updated: "2026-04-18T12:50:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T122454Z-pr-579.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T122707Z-pr-579.md"
tags: []
confidence: high
---

# LLM substitute placeholder は bash residue gate で fail-fast 化する

## 概要

LLM が literal substitute する bash 変数 (例: `commit_msg="... {n_pages_created} ..."` や `var="{placeholder}"`) は、substitute 漏れ時に bash レベルで silent 誤動作する経路を持つ。`case "$var" in "{"*"}") exit 1 ;; esac` 形式の residue gate を同型に配置することで fail-fast 化し、literal `{placeholder}` が landed する silent regression を防ぐ。

## 詳細

### 失敗モード

bash block で `[ "{placeholder}" -gt 0 ]` のような比較を行う場合、LLM が `{placeholder}` を literal substitute しないまま実行すると:

- `[ "{n_contradictions}" -gt 0 ]` は `integer expression expected` rc=2 を返す
- `set -o pipefail` のみでは検知されず silent に `else` 分岐に落ちる
- 結果として `lint:clean` / `lint:warning` 判定が誤値で emit され downstream が汚染される

### Canonical fix (PR #579 cycle 1 で導入)

placeholder を含む変数を使う bash block の冒頭で、以下の gate を同型に配置する:

```bash
case "$commit_msg" in
  *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
    echo "ERROR: Phase 5.1 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
    echo "  対処: LLM は Phase 2.1 / Phase 4 で incrementate したカウンタ値を本 bash block で literal substitute する必要があります" >&2
    exit 1
    ;;
esac
```

### 既存 5 site + 新規 1 site = 6 site 対称化

PR #579 時点で同型の residue gate が `rite` plugin 内の 6 site で運用されている (Phase 1.1 / 1.3 / 6.2 F-01 / 8.3 F-14 / F-04 + 新規 1 site)。canonical reference として新規 bash block を登録する際は既存同種 site と一字一句同型に揃えること。drift は silent regression の温床となる。

### LLM 内部状態 vs shell 変数の境界

bash tool 呼び出し境界を跨いで shell 変数は保持されない。Phase A で `count=5` を定義しても Phase B からは参照不能で、LLM は自身の内部状態 (会話コンテキスト) から literal 値を substitute する責務を負う。この契約は bash コメントで明示することで、将来の読者が「なぜ placeholder が多いのか」を理解できる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](./drift-check-anchor-semantic-name.md)

## ソース

- [PR #579 review results (cycle 1)](../../raw/reviews/20260418T122454Z-pr-579.md)
- [PR #579 fix results (cycle 1)](../../raw/fixes/20260418T122707Z-pr-579.md)
