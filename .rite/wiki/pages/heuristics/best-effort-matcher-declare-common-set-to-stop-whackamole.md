---
type: "heuristics"
title: "best-effort な静的 matcher hardening は allowlist を COMMON-SET（非網羅）と宣言して review の whack-a-mole を止める"
domain: "heuristics"
description: "静的 bash matcher で危険操作を捕捉する security hardening（reviewer の `.git` 書き込み遮断等）は、原理的に列挙を完全にできない（任意の write ツール・難読化形を静的に enumerate できない）。"
created: "2026-07-16T06:07:53+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260715T160953Z-pr-1865.md"
  - type: "fixes"
    resource: "raw/fixes/20260715T163038Z-pr-1865.md"
  - type: "fixes"
    resource: "raw/fixes/20260715T164655Z-pr-1865.md"
  - type: "fixes"
    resource: "raw/fixes/20260715T171255Z-pr-1865.md"
  - type: "fixes"
    resource: "raw/fixes/20260715T173545Z-pr-1865.md"
  - type: "reviews"
    resource: "raw/reviews/20260715T194532Z-pr-1865.md"
  - type: "fixes"
    resource: "raw/fixes/20260715T195606Z-pr-1865.md"
  - type: "reviews"
    resource: "raw/reviews/20260715T203920Z-pr-1865.md"
tags: ["security", "static-matcher", "allowlist", "common-set", "whack-a-mole", "review-loop", "scope", "layer-1", "mergeable", "hardening"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-16T06:07:53+09:00" }
---

# best-effort な静的 matcher hardening は allowlist を COMMON-SET（非網羅）と宣言して review の whack-a-mole を止める

## 概要

静的 bash matcher で危険操作を捕捉する security hardening（reviewer の `.git` 書き込み遮断等）は、原理的に列挙を完全にできない（任意の write ツール・難読化形を静的に enumerate できない）。allowlist を「COMMON-SET, deliberately NOT exhaustive」とコード内で明示宣言し、列挙外ベクタは上位レイヤ（reviewer prompt = Layer 1）で担保すると設計スコープを固定でき、review の **whack-a-mole**（列挙外ベクタを 1 つずつ追加し続ける無限反復）を構造的に止められる。一方で「allowlist の列挙完全性の欠落」（設計上 Layer-1 担保 = 非 blocking）と「検出機構そのものの構造欠陥」（glob 汚染・無制限反復 = blocking）は **別クラス**として区別する。out-of-scope クラスの doc 追記は「網羅不能」の設計上際限がないため、指摘ゼロ（mergeable）を正常出口とし doc-note polish の無限ループに入らない。

## 詳細

起点事例（`pre-tool-bash-guard.sh` の reviewer `.git` 書き込み遮断 sub-block）の 6 cycle + follow-up 3 cycle の実測から得た経験則。cycle 2-5 で reviewer が value-quoted `dd of=` → interior/nested quote → backslash-escaped path → 難読化 verb 名 → `sponge`/`patch` と**別の難読化ベクタを毎 cycle 発見**し、fix が allowlist に追加し続ける whack-a-mole が発生した。

### whack-a-mole を止める構造宣言

- 静的 matcher の allowlist（`tee|cp|mv|ln|install|rsync|truncate|dd|sponge|patch`）を「COMMON-SET, deliberately NOT exhaustive」とコメントで明示宣言し、列挙外の write ツール（`sed -i` / `perl -pi` / interpreter 埋め込み / `$`展開 / heredoc-body redirect / pipe|xargs indirection 等）は **Layer-1-only**（reviewer prompt / READ-ONLY 契約）で担保すると文書化する。
- これにより「列挙外の別ベクタで bypass できる」という reviewer 指摘は、**本 PR が導入した新規欠陥でない限り finding にしない**という scope 判断が正当化される。宣言が無いと reviewer は列挙の穴を無限に指摘し続け、fix は列挙を無限に伸ばす（whack-a-mole）。
- AC 自体を「可能な範囲で（best-effort）」と framing しておくことも、列挙完全性を要求しない設計意図の宣言になる。

### 列挙完全性の欠落 vs 検出機構の構造欠陥（別クラス）

whack-a-mole を止める宣言があっても、**すべての指摘を非 blocking にしてはならない**。2 クラスを区別する:

- **列挙完全性の欠落（非 blocking）**: 「allowlist に無い verb X で bypass」型。設計上 Layer-1 担保のスコープ外。finding にしない（revert test でも本 PR 由来でない）。
- **検出機構そのものの構造欠陥（blocking）**: enumerate 済みベクタを検出する **tokenizer 機構自体**が壊れている型。起点事例では unquote `for _gd_tok in $_gdw` が glob 展開して (a) CWD 依存の over-DENY 誤検出、(b) glob 無制限展開→timeout→fail-open（enumerate 済みベクタもろとも素通し = 塞いだはずの経路の再開放）を起こしていた。これは列挙の穴ではなく検出器の欠陥であり blocking の HIGH（noglob 化の詳細は [security-hook-timeout-is-fail-open-bound-cost-by-input-size](./security-hook-timeout-is-fail-open-bound-cost-by-input-size.md) 参照）。
- 切り分けの判定: 「列挙を 1 つ増やせば直るか（=完全性欠落）」vs「検出器の共通経路が汚染・破綻しているか（=構造欠陥）」。後者は Grep/実証で triggering を示せる実在欠陥として報告する。

### mergeable を正常出口とし doc-note polish の無限ループに入らない

- 「COMMON-SET は網羅不能」が設計前提のため、out-of-scope クラスの doc 追記（glob-target が Layer-1 落ち、pipe/xargs indirection も Layer-1 落ち…）は際限がない。reviewer 自身が「修正不要・任意改善」と述べる境界 doc-note は candidate として扱わず、指摘ゼロ（mergeable）を正常出口とする。
- 収束判断: 全 reviewer が「可」かつ blocking finding ゼロなら mergeable。cycle 2 で mergeable 到達後、substantive な within-scope 推奨（同種 drift の doc sync・test coverage）は user 承認のうえ 1 polish commit で反映し cycle 3 で再収束させたが、それ以降の optional doc-note は反映しない。「もう 1 つ out-of-scope ベクタを documentation できる」は diminishing-returns の rabbit hole。
- pre-existing の同型パターン（兄弟の unquote glob loop 等）は複数 cycle で調査推奨に挙がり続けるが、revert test 上スコープ外のため本 PR で対応せず follow-up Issue として切り出す（scope discipline）。

### 併走する副次教訓

- **behavioral 主張を含むコメントは実挙動で実証する（comment rot 防止）**: 「noglob 下で `.git*/config` は literal 保持され component glob に不一致 → allow」のような runtime 挙動主張は、reviewer が実フックを直接叩いて確認する。doc テーブルの verb 列挙と code 側 allowlist は cycle をまたいで語彙同期を保ち、非網羅リストには「等」を明示する（片方だけ verb を追加すると deny メッセージの参照先契約と runtime deny がドリフトする）。

## 関連ページ

- [セキュリティ境界 hook の timeout は fail-open — 評価コストは入力サイズで O(1) 上限を設けて bound する](./security-hook-timeout-is-fail-open-bound-cost-by-input-size.md)
- [`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する](./scope-creep-rejection-empirical-gate.md)
- [Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない](./respect-reviewer-no-action-recommendation.md)

## ソース

- [PR #1865 fix results (cycle1) — reviewer bash/symlink 経由 .git 書き込み遮断の初回対応](../../raw/fixes/20260715T160953Z-pr-1865.md)
- [PR #1865 fix cycle2 — value-quoted `dd of=` 難読化 bypass を塞ぐ（whack-a-mole 1）](../../raw/fixes/20260715T163038Z-pr-1865.md)
- [PR #1865 fix cycle3 — interior/nested quote 難読化 bypass を塞ぐ（whack-a-mole 2）](../../raw/fixes/20260715T164655Z-pr-1865.md)
- [PR #1865 fix cycle4 — backslash-escaped path component 難読化 bypass を塞ぐ（whack-a-mole 3）](../../raw/fixes/20260715T171255Z-pr-1865.md)
- [PR #1865 fix cycle5 — 難読化 verb 名 dequote + sponge/patch 追加、allowlist を COMMON-SET（非網羅）と宣言（whack-a-mole 収束）](../../raw/fixes/20260715T173545Z-pr-1865.md)
- [PR #1865 review results (follow-up cycle1) — 検出機構の構造欠陥（unquote for-loop の glob 汚染）を列挙完全性とは別クラスの blocking HIGH として切り分け](../../raw/reviews/20260715T194532Z-pr-1865.md)
- [PR #1865 fix results (follow-up cycle1) — noglob 化 + scope discipline（pre-existing 兄弟ループは follow-up へ）](../../raw/fixes/20260715T195606Z-pr-1865.md)
- [PR #1865 review results (follow-up cycle3) — 全 reviewer「可」で mergeable 収束、out-of-scope doc-note は網羅不能につき polish 無限ループに入らない判断](../../raw/reviews/20260715T203920Z-pr-1865.md)
