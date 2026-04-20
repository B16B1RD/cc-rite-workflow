---
title: "Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする"
domain: "heuristics"
created: "2026-04-17T08:55:00+00:00"
updated: "2026-04-20T04:50:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260417T082023Z-pr-562.md"
  - type: "reviews"
    ref: "raw/reviews/20260417T084133Z-pr-562.md"
  - type: "reviews"
    ref: "raw/reviews/20260417T084700Z-pr-562.md"
  - type: "fixes"
    ref: "raw/fixes/20260417T082346Z-pr-562.md"
  - type: "fixes"
    ref: "raw/fixes/20260417T083042Z-pr-562.md"
  - type: "fixes"
    ref: "raw/fixes/20260417T083649Z-pr-562.md"
  - type: "fixes"
    ref: "raw/fixes/20260417T084423Z-pr-562.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T071459Z-pr-564.md"
  - type: "reviews"
    ref: "raw/reviews/20260418T072254Z-pr-564-rerun.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T072121Z-pr-594.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T130127Z-pr-601.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T035100Z-pr-616.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T042759Z-pr-617.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T043015Z-pr-617-fix1.md"
tags: ["identity", "documentation", "drift-prevention", "terminology", "scope", "yaml-frontmatter", "i18n-style"]
confidence: high
---

# Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする

## 概要

reference document (SKILL.md / `references/*.md` / 関連 commands) で identity / principle を明文化する際、用語統一を「単語 X 単独」のスコープで実施すると、同一段落内の類義語群 (効率・最適化・圧迫・枯渇 等) が統一漏れとして残り、cycle 2-3 の review-fix ループに持ち越される。文脈ベースの類義語群全体を対象にすることで 1 cycle で収束させる。

## 詳細

### Observed pattern (PR #562 で実測)

PR #562 (workflow-identity reference の新規追加 + 7 commands への波及) で cycle 1-3 に渡って同じ root cause の drift が繰り返された:

- **cycle 1**: `コンテキスト残量` → `context 残量` に統一したが、reference document に限定。`SKILL.md` / `commands/pr/cleanup.md` / `commands/pr/review.md` の同一表現が未統一で残った
- **cycle 2**: 上記 3 ファイルで `コンテキスト残量` を統一したが、同一 blockquote 内の類義語 (`コンテキスト効率` / `コンテキスト最適化` / `コンテキスト圧迫`) が手付かず
- **cycle 3**: 同一 blockquote 内の類義語を統一。ここで初めて収束した

根本原因: 「単語 X を統一する」という narrow scope の指示は、**類義語マッピング表を事前に作らない限り**、同一段落内の近縁語を見逃す。

### Correct pattern

1. **最初の統一処理で repo 全体 grep を実行**し、「統一対象の単語 X」と「同じ文脈で使われる類義語群 (X の効率 / X の最適化 / X の圧迫 / X の枯渇 / X window 等)」を**同時に**列挙する
2. 類義語群を**単一のコミット内で**一括統一する
3. `grep -n <単語 X> plugins/rite/**/*.md` の結果に対し、文脈で類義語が隣接しているか (同一段落 / 同一 blockquote / 同一 table row) を目視確認する

### Applicable sub-heuristics

本パターンは以下の 5 つの drift source を一括して扱う上位抽象:

#### 1. Reference document の自己記述 drift

reference document 内で実装側の位置 (SKILL.md の節位置 / Phase の番号 等) を「**冒頭に置き**」「**先頭の**」のような**絶対表現**で書くと、実配置が 3 番目の H2 等に移動した時点で drift する。

→ **Correct**: 「ファイル先頭付近 (Auto-Activation Keywords / Context 節の直後)」等の **relative 表現** にする。実配置の微調整に耐える。

#### 2. LLM recall 対象文書の表記揺れ

Principle ID は snake_case 英字 (`no_context_introspection`) で定義しているのに、説明文で `コンテキスト残量` とカタカナを使うと、grep による self-recall で hit 漏れが発生する。

→ **Correct**: Principle ID と同じ表記 (英字 context / snake_case 等) に文書内用語を揃える。日本語カタカナは user-facing 冒頭サマリーに限定するか、英字 と併記する。

#### 3. Failure Patterns bullet 粒度の混在

Anti-pattern bullet で self-talk「〜します」と meta 抽象記述 (「～する」「～するのを正当化する」) を混在させると、LLM が anti-pattern を self-detect する際の match 精度が下がる。

→ **Correct**: 同一 principle 内の全 bullet を self-talk「」付き形式に揃える。meta rule は別セクション (Rules / Correct Pattern) に分離する。

#### 4. Enumeration drift between sibling files

SKILL.md / reference document / PR body / 各 commands 内コメント等に caller command 列挙を重複記述すると、新規 caller 追加時の同期漏れが発生する。

→ **Correct**:
- 短期: drift 検出時は**全箇所を単一コミットで一括同期**する (cycle 2 で create が追加されたら SKILL.md / workflow-identity.md / PR body の全 enumeration を同じコミットで更新)
- 長期: `grep -l <reference-marker> plugins/rite/commands/**/*.md` ベースで自動抽出する pattern に置き換える (drift-resistant)

#### 6. YAML frontmatter description と本文階層 drift (PR #564 で追加)

本文側で階層構造 (例: 「5 ブロッキング + 1 informational」の 2 層分類) に変更しても、YAML frontmatter `description:` / `SKILL.md` の一覧説明は flat 列挙 (`5 項目`) のまま残存しやすい。description は Skill 一覧で最初に表示される文字列なので、ユーザの期待値ずれを直接生む。

→ **Correct**: 本文階層を変更する PR では、frontmatter `description` と関連する全 SKILL.md description を同期更新する責務を明示する。grep 対象として「`description:` + `SKILL.md` の `description` フィールド」を PR 内で一括検索する。

##### Successful application: PR #594 (wiki SKILL.md drift fix)

PR #594 は本 sub-heuristic を直接適用した成功例 (1 file / +4 / -3 の minimal PR、両 reviewer が 0 findings で承認)。`plugins/rite/skills/wiki/SKILL.md` の **description block L9-15** と **Auto-Activation Keywords body L27** の lint カテゴリ集合が drift していた (既存 3 日本語キーワード `矛盾チェック` / `陳腐化` / `孤児ページ` が description block に未列挙)。**frontmatter description と本文階層の両方を同時に** canonical 順 (`lint.md` SoT) へ整列させることで 1 PR で解消。

##### Successful application: PR #601 (lint.md 冒頭テーブル列挙順 drift fix — 2 例目)

PR #601 は本 sub-heuristic の **2 例目 canonical SoT 単一化成功適用** (1 file / +1 / -1 の 2 行 swap 極小 PR、両 reviewer が 0 findings で承認)。`plugins/rite/commands/wiki/lint.md` 内部で canonical SoT 自身の列挙順が 2 通り共存していた: **L2 frontmatter description** は「5 ブロッキング → 1 informational 末尾隔離」(矛盾 → 陳腐化 → 孤児 → 欠落概念 → 壊れた相互参照 → 未登録 raw)、**L11-16 本文冒頭テーブル** は「未登録 raw が中間挿入」(矛盾 → 陳腐化 → 孤児ページ → 欠落概念 → **未登録 raw** → 壊れた相互参照)。本文冒頭テーブルを frontmatter description 順に整列させることで canonical SoT を単一化。PR #594 の「frontmatter description と本文階層の同時整列」heuristic を canonical SoT **内部** (同一ファイル内 L2 description vs L11-16 body table) にも拡張適用した事例であり、drift 解消の適用範囲が「cross-file」(SKILL.md ↔ lint.md) から「intra-file」(lint.md L2 ↔ L11-16) に広がることを実証した。副次観点として、両 reviewer がサブエージェント full review で同一ファイル内の関連 drift (完了レポート UX 順序 / SKILL.md EN description) を scope 外推奨事項として並行検出し、revert test で「本 PR を revert してもこれらの drift は消えない」と判定して scope discipline を守った。

##### Successful application: PR #616 (SKILL.md EN description — 3 例目、同一 SKILL.md 内 3 箇所 intra-file 整列の完結)

PR #616 は本 sub-heuristic の **3 例目 canonical SoT 単一化成功適用** (1 file / +1 / -1 の 1 行 swap 極小 PR、両 reviewer が 0 findings で承認)。PR #601 後に `plugins/rite/skills/wiki/SKILL.md` 内部で**最後の drift 源**として残存していた EN frontmatter description L7-8 (`unregistered raw sources, and broken references`) を canonical 順 (`broken references, and unregistered raw sources`) へ swap。同一 SKILL.md 内 3 箇所 (EN description L7-8 / JA Activates L12-13 / JA Auto-Activation L27) の列挙順が canonical SoT (`lint.md` 冒頭テーブル) と完全整列した。**PR #594 (cross-file: SKILL.md ↔ lint.md) → PR #601 (intra-file: lint.md L2 vs L11-16) → PR #616 (intra-file: SKILL.md L7-8 vs L12-13 vs L27) の 3 段で canonical SoT 単一化適用範囲が拡張** された連続実測例となる。PR #594 → #601 → #616 は「frontmatter description と本文階層の同時整列」heuristic が (a) cross-file、(b) canonical SoT 内部、(c) downstream reference document 内部 の 3 スコープに順次拡張されたことを示す。

##### Corollary: canonical SoT 内部でも列挙順序は観点により異なる

drift 判定では「どの canonical 順を採用するか」を明示する必要がある。例: `lint.md` L2 description は blocking → informational 順、L11-16 テーブルは blocking 列 Yes/No グループ順で、未登録 raw の位置が異なる。canonical SoT 内部の順序差は drift ではなく観点の差であり、downstream (SKILL.md / ingest.md 等) が参照する際はどちらを canonical とするかを明示することで pair 順一貫性を担保する (PR #594 では「`lint.md` canonical 順」と明示)。

#### 5. PR body AC metadata の cross-cycle 更新責務

PR description の AC 検証行 (「N commands で参照 / N ファイル PASS」等の数値) は cycle 2+ で caller 追加があれば更新漏れが発生しやすい。

→ **Correct**: AC-N 検証側 (reviewer / author) は PR description metadata の数値も再検証する責務を持つ。LLM に AC verification を依頼する際「PR body の数値も含めて」と明示する。

#### 7. UI メッセージの多言語混在 style drift (PR #617 で追加)

同一 scope (同一コマンド出力 / 同一 Phase の Hint メッセージ群 / 同一 reference 文書の警告群) において、既存メッセージが英文統一されているのに新規追加メッセージで日英混在 (例: `Hint: 詳細は spec を確認してください`) を使うと、style drift として検出される。canonical SoT は「同 scope 多数派の言語選択」であり、新規追加側を既存多数派に合わせる。

→ **Correct**:

1. 新規メッセージ追加時に同 scope (同一コマンド / 同一 Phase / 同一 reference 文書) の既存メッセージを `grep` し、言語選択 (英文 / 和文 / 日英並記) の多数派を確認する
2. `Hint:` / `Warning:` / `Error:` / `Note:` のような prefix が標準化されている場合、prefix 後の本文も同 prefix を持つ既存メッセージと同言語に統一する
3. user-facing メッセージ (CLI 出力 / log メッセージ) と internal documentation (commands/*.md prose / reference 文書) で言語選択が異なる場合、その分界を尊重する (両者を同一視しない)

##### Successful application: PR #617 (jp/en mixed Hint message style drift)

PR #617 cycle 1 で LOW finding として、新規追加した Hint メッセージが日英混在で他の同 scope Hint が英文統一されている既存パターンと style drift を起こしていた。fix では「他同種メッセージと style drift を起こす場合、新規追加側を既存多数派に合わせて統一する」原則で英文統一に揃えて 1 cycle で解消。**i18n / multilingual style policy も identity / reference 文書の用語統一の sub-heuristic** として扱える (用語 X 単独ではなく「同 scope の言語選択全体」を canonical SoT として捉える)。

### Identity scope の厳守 (AC-10 Non-regression)

本 PR で identity 文脈の用語統一 (`context 残量 / 効率 / 最適化 / 圧迫`) を行った際、identity 文脈**外**で使われている同じ用語 (例: `sub-issue-link-handler.md` の「LLM 冗長性説明」、`review-context-optimization.md` の「diff passing optimization」) は reviewer が未指摘だったため**触らなかった**。これは AC-10 Non-regression の尊重として正しい判断。

→ **Correct**: scope を広げる前に revert test を実施する。「本 PR を revert したらこの drift は消えるか」を問い、No ならば pre-existing / scope 外として扱う。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [兄弟 shell script の重複 helper は shared lib 抽出で解く](./shell-script-shared-lib-extraction.md)

## ソース

- [PR #562 review cycle 1 results](raw/reviews/20260417T082023Z-pr-562.md)
- [PR #562 review cycle 4 convergence](raw/reviews/20260417T084133Z-pr-562.md)
- [PR #562 review cycle 5 final](raw/reviews/20260417T084700Z-pr-562.md)
- [PR #562 fix cycle 1](raw/fixes/20260417T082346Z-pr-562.md)
- [PR #562 fix cycle 2 (scope waterfall)](raw/fixes/20260417T083042Z-pr-562.md)
- [PR #562 fix cycle 3 (blockquote synonyms)](raw/fixes/20260417T083649Z-pr-562.md)
- [PR #562 fix cycle 5 (recommendation-driven)](raw/fixes/20260417T084423Z-pr-562.md)
- [PR #594 review: SKILL.md description drift fix (successful application)](raw/reviews/20260419T072121Z-pr-594.md)
- [PR #601 review: lint.md 冒頭テーブル列挙順 drift fix (2nd successful application, intra-file SoT unification)](raw/reviews/20260419T130127Z-pr-601.md)
- [PR #616 review: SKILL.md EN description canonical alignment (3rd successful application, intra-file SKILL.md 3-site symmetric unification)](raw/reviews/20260420T035100Z-pr-616.md)
- [PR #617 review: jp/en mixed Hint message style drift (i18n style sub-heuristic 追加)](raw/reviews/20260420T042759Z-pr-617.md)
- [PR #617 fix: 既存多数派 (英文) への統一 1 cycle 解消](raw/fixes/20260420T043015Z-pr-617-fix1.md)
