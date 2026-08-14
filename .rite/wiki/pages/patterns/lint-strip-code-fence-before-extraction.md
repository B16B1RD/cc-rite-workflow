---
title: "Lint の見出し抽出はコードフェンス内行を除外してから行う (検証ツール自身の false-negative 防止)"
domain: "patterns"
description: "markdown を解析する検証ツール (lint / drift-check) が `grep -E '^#{1,6}'` のような単純パターンで見出しを抽出すると、` ```bash ` コードフェンス内の shell コメント (`# ...`) を markdown 見出しと誤認する。"
promote: rite-plugin
created: "2026-05-28T12:42:26Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260528T112627Z-pr-1167.md"
  - type: "fixes"
    resource: "raw/fixes/20260528T121938Z-pr-1167.md"
  - type: "reviews"
    resource: "raw/reviews/20260528T122742Z-pr-1167.md"
tags: ["lint", "verification", "false-negative", "code-fence", "markdown", "heading-extraction", "awk-state-machine", "self-loosening-verification"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-28T12:42:26Z" }
---

# Lint の見出し抽出はコードフェンス内行を除外してから行う (検証ツール自身の false-negative 防止)

## 概要

markdown を解析する検証ツール (lint / drift-check) が `grep -E '^#{1,6}'` のような単純パターンで見出しを抽出すると、` ```bash ` コードフェンス内の shell コメント (`# ...`) を markdown 見出しと誤認する。誤認した「偽の見出し」が参照番号の照合対象に混入すると、本来 dangling であるべき参照が「実在する見出し」と誤って一致し、**検証ツール自身が verification を緩める silent false-negative** に陥る。見出し抽出はコードフェンス内行を `strip_code_fences` (awk in_fence toggle) で除外してから行うのが canonical。

## 詳細

### 失敗の構造（cycle 1 — MEDIUM, code-quality reviewer）

新規追加した `sh-cross-ref-check.sh` は、`.sh` 内の echo / コメントに含まれる `<file>.md (ステップ|Phase) N` 形式の cross-file 参照を、参照先 `.md` の実見出しと突き合わせて dangling を検出する。この「参照先の見出し一覧」を取得する際:

```bash
# 反面教材 (初版)
grep -E '^#{1,6}[[:space:]]' "$target_md"   # ← code fence 内の `# comment` も拾う
```

参照先 `.md` 内の ` ```bash ` ブロックにある `# 何かのコメント` 行が `#` 始まりのため markdown 見出しとして抽出される。その結果、本来存在しない見出し番号への参照でも「偽の見出し」と一致してしまい、**dangling-number チェックが false negative** になる。検証ツールが「検出できているように見えて実は検出網が緩い」状態は、ツールへの信頼を損なう最も危険な failure mode。

### Fix 方針（strip_code_fences ヘルパー）

見出し抽出の **前段** にコードフェンス除去を挟み、フェンス内行を見出し候補から外す:

```bash
# Canonical: フェンス内を除外してから heading 抽出
strip_code_fences "$target_md" | grep -E '^#{1,6}[[:space:]]'
```

`strip_code_fences` は awk の `in_fence` トグルで ` ``` ` 行を境にフェンス内/外を判定し、フェンス内行を出力から落とす。「検証ツールが対象を解析する際、コードフェンス内の構文要素を実コンテンツと誤認しない」という防御は、markdown を grep ベースで解析する lint 全般に適用すべき canonical step。

### 既知の限界 — awk in_fence toggle の nesting（cycle 2 — Hypothetical, non-blocking）

`strip_code_fences` の awk in_fence トグルは ` ``` ` 行を単純にトグルするため、**4-backtick フェンス内に 3-backtick が現れる nesting** では誤トグルしうる構造的弱点を持つ。起点事例の cycle 2 review で指摘されたが、現コーパスに発火する file が無く revert test も中立のため、Observed Likelihood Gate により Hypothetical / non-blocking に降格された ([[observed-likelihood-gate-with-evidence-anchors]])。フェンス delimiter 長を考慮した state machine が必要になるのは、実際に nested fence を含む対象が現れたときで十分。先回りで複雑化しないのが scope 判断として妥当。

### 適用範囲

- markdown 見出し / リスト / リンクを grep で抽出する lint・drift-check 全般 (`^#{1,6}` / `^- ` / `\[.*\]\(.*\)` など)
- フェンス内には対象構文と同形のノイズ (shell `#` コメント / bash の `- ` / コード例中の markdown link) が紛れるため、抽出前のフェンス除去を default step にする
- フェンス除去で偽陽性を消す副作用として、フェンス内の「意図的な参照例」も検出対象外になる点は許容 (検証対象は prose / 見出しであり、コード例は対象外という責務分離)

## 関連ページ

- [Markdown code fence の balance は commit 前に awk で機械検証する](./markdown-fence-balance-precommit-check.md)
- [bash code block 終端は固定 +N 行 window ではなく awk state machine で動的追跡する](./awk-bash-block-termination-tracking.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)

## ソース

- [PR #1167 cycle 1 review — cross-ref 検証スクリプトの `grep -E '^#{1,6}'` が code fence 内 shell コメントを見出し誤認し dangling 検証が false-negative (MEDIUM, code-quality)](../../raw/reviews/20260528T112627Z-pr-1167.md)
- [PR #1167 fix (F-02) — strip_code_fences ヘルパー (awk in_fence toggle) でフェンス内行を除外してから heading 抽出することで解消](../../raw/fixes/20260528T121938Z-pr-1167.md)
- [PR #1167 cycle 2 review — strip_code_fences の 4-backtick/3-backtick nesting 誤トグル弱点 (Hypothetical, revert test 中立で non-blocking 降格)](../../raw/reviews/20260528T122742Z-pr-1167.md)
