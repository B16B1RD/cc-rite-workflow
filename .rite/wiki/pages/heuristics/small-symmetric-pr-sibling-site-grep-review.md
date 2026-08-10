---
title: "極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる"
domain: "heuristics"
description: "5 行程度の極小 refactor PR (特定 Phase の sibling site 対称化) では、複数の同型箇所を Grep + Read で網羅的に照合し変数名・ラベル以外の構造的差分を洗い出すことで、Confidence 80+ の「指摘事項 0 件 + merge 可」判定を短時間で出せる。過去のレビューで 4 sibling site (Phase 2.3/6.0 × separate/same) の照合として実測。副次技法にハードコード番号の `gh pr view` 実在性検証と scope 外推奨の別 Issue 候補化 (複数 reviewer 独立合意による triple cross-validation)。過去のレビューで 4-site `from=` discriminator pattern (lockdir cleanup observability 対称化、+22/-5 4 files) を累積 evidence として追加 — 3 reviewer 全員承認 + 隣接 site 非対称の scope 外別 Issue 化が複数 reviewer 独立に挙がり triple cross-validation 実証。過去のレビューで 2-site work memory lockdir 別系統対称化 (+13/-3, 2 files) を follow-up evidence として追加 — 過去のレビュー事例 cycle 1 で scope 外推奨された隣接 site が次 PR で自然に消化される運用パターンと、note 引用 consumer scope 一致の sub 技法を実証。過去のレビューで **locale pair (en↔ja) への拡張** を追加 — SPEC.md ↔ SPEC.ja.md の i18n parity fix を tree/表エントリの機械抽出 + token 集合 diff 照合 (TREE_SYNC_OK / TABLE_SYNC_OK) で検証し cycle 2 で blocking 0 mergeable。tech-writer の再利用可能 protocol (forward/reverse git ls-files 照合 + en/ja token diff + prose 主張の実装 grep) と、表 intro scope 宣言整合の検査観点 + nit-noted 受け流し経路 (関連する課題 M2) の実運用実証を併記。"
promote: rite-plugin
created: "2026-04-19T06:45:00Z"
updated: "2026-06-10T00:54:18Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260610T005202Z-pr-1341.md"
  - type: "reviews"
    ref: "raw/reviews/20260606T143925Z-pr-1294.md"
  - type: "fixes"
    ref: "raw/fixes/20260606T135607Z-pr-1294.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T062330Z-pr-592.md"
  - type: "reviews"
    ref: "raw/reviews/20260514T182616Z-pr-963.md"
  - type: "fixes"
    ref: "raw/fixes/20260514T223534Z-pr-967.md"
  - type: "reviews"
    ref: "raw/reviews/20260514T224021Z-pr-967.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T154013Z-pr-1151.md"
tags: []
confidence: high
---

# 極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる

## 概要

5 行程度の極小 refactor PR (特定 Phase の sibling site 対称化) では、複数の同型箇所 (例: 4 sibling site) を Grep + Read で網羅的に照合し、変数名とラベル以外の構造的差分を洗い出すことで、「指摘事項 0 件 + merge 可」の判定を短時間で Confidence 80+ として出せる。

## 詳細

**適用対象**: selective surface / stderr suppression / mktemp + trap / `LC_ALL=C` 適用等、プロジェクト内で意図的に繰り返される idiom の一部を対象とした対称化 PR。

**レビュー手順の骨子**:

1. **sibling site の全量列挙**: 対象 idiom の canonical 文字列 (例: `WARNING(cat hint):`, `head -3 "$index_err"`) を Grep で repo 全体から探す。hit した箇所が「本 PR で対称化すべき全 sibling site」の母集団になる。
2. **構造的差分の逐行照合**: Read で各 sibling を並べ、変数名・エラーラベル・ファイル path 以外の差分を抽出する。差分が「想定内の局所変数名のみ」なら構造的対称性は成立。
3. **Counter 宣言の検証** (該当する場合): 「N 箇所対称化」と PR / commit message に書かれている場合、Grep hit 数と照合する。drift があれば LOW 以上の finding として報告。

**なぜこれが有効か**:

- 極小 PR は変更行が少ないため、Grep で期待 pattern を repo 全体から拾い出す方が、diff を単体で読むより網羅的。
- 対称化タスクの本質 hazard は「対称位置への伝播漏れ」(既存 wiki: Asymmetric Fix Transcription) であり、これは diff 単体には現れず sibling site の grep でのみ検出できる。
- sibling 数が 4 以下の場合、Read で並べて照合する cost が Grep 以外のレビュー方式より低い。

**合わせて適用すべきサブ技法**:

- **ハードコード番号の実在性検証**: PR 本文やコメント内の `PR #NNN` / `Issue #NNN` 参照は `gh pr view` / `gh issue view` で実在と state を確認する。これは wiki の「Hallucinated canonical reference」anti-pattern をレビュー側で pre-block する対称技法。
- **Scope 外推奨事項の別 Issue 候補化**: 本 PR で同時対応すべきでない対称化余地 (例: `LC_ALL=C` の追加適用) は、レビューで明示的に「scope 外 / 別 Issue 候補」として推奨事項に残す。複数 reviewer が独立に同じ推奨を挙げた場合は候補の妥当性が triple cross-validation される。

**適用時の注意**:

- sibling 数が 5 以上になる場合は Grep 照合の読み込み量が増え、単純 diff レビューとの境界が曖昧になる。併用を検討する。
- idiom が意図的な非対称性 (例: `separate_branch` と `same_branch` で実装契約が異なる) を含む場合、構造的差分を「対称化すべきか意図的か」の二段階で分類する必要がある。

**4-site discriminator 事例の累積 evidence (`from=` discriminator pattern)**: 小規模 refactor PR (+22/-5, 4 files) で 0 blocking finding 1 cycle 着地。`LOCKDIR_CLEANUP_FAILED=1` emit の片肺問題を `from={start_md_termination,start_finalize_termination,session_start_cleanup,cleanup_work_memory}` という 4 値 discriminator で対称化した PR。3 reviewer (prompt-engineer / code-quality / error-handling) 全員が承認、推奨事項 LOW 3 + scope 外候補 MEDIUM 2 のみ。本ページの手順 (sibling site grep + 構造的差分照合 + counter 宣言検証) が hint:specific-assertion-pin で適用された case study であり、4 hit grep + 1 hit Note 内列挙の expected 数も PR 本文で事前宣言された。さらに「pre-existing drift (4-site-symmetry.test.sh の scope mismatch)」と「隣接 site (cleanup-work-memory.sh の per-file lockdir) の非対称」を **scope 外推奨事項 / 別 Issue 候補** として残す sub 技法 (本ページ既存記述) が複数 reviewer から独立に挙がり triple cross-validation された。

**lockdir 別系統事例の累積 evidence (2-site work memory lockdir 別系統対称化、4-site discriminator 事例の follow-up による sibling separation case)**: 4-site discriminator 事例の cycle 1 で reviewer が「scope 外推奨事項 / 別 Issue 候補」として挙げた「cleanup-work-memory.sh の per-file lockdir 非対称」を別 Issue として切り出した follow-up PR (+13/-3, 2 files)。global state lockdir (4 site、`from=cleanup_work_memory`) と per-issue work memory lockdir (2 site、`from=cleanup_work_memory_wm_dir` / `cleanup_work_memory_issue`) を **別系列として明示分離** したマッピング表を start-finalize.md に追加。cycle 1 で prompt-engineer reviewer が 1 MEDIUM (note 引用の consumer scope 不正確 — `pre-compact.sh:82` global state vs `work-memory-update.sh:153` per-issue の取り違え) を独立検出し、cycle 2 で 1-line wording fix により 3 reviewer 全員 0-finding mergeable 着地。本 case は (a) 別 Issue 化された scope 外推奨が次 PR で自然に消化される運用パターン、(b) 「対称化」と並行して「別系列の明示分離」が必要な場合の note 文言精度 (consumer 引用の scope 一致) が独立 finding として浮上する sub 技法を実証。`{n}-site mapping note を追加する PR では同名類似 idiom (例: lockdir cleanup) の consumer も grep で照合して引用 scope を verify する` という追加 hint を canonical 化。

**locale pair 事例の累積 evidence (locale pair への拡張 — en↔ja token 集合 diff による機械的対称検証)**: SPEC.md ↔ SPEC.ja.md の i18n parity fix (CFIC #6 違反 HIGH の解消) を、tree/表エントリの sed/awk/grep 機械抽出 + en↔ja token 集合 diff 照合 (TREE_SYNC_OK / TABLE_SYNC_OK) で検証し、cycle 2 で短時間・高確信 (blocking 0) の mergeable 判定に到達。「locale 同期 fix は機械的対称検証で短時間・高確信にレビューできる」が再実証された。本ページの「sibling site 照合」を **locale pair (en↔ja) の構造要素照合**へ拡張する実例で、tech-writer の検証 protocol は再利用可能: (1) forward/reverse 両方向の git ls-files 照合 (実在ファイル ↔ 列挙エントリの双方向)、(2) en/ja token 集合 diff、(3) prose 主張の実装 grep (hooks.json 登録 / source caller / 委譲関係)。副次観点 2 件: (a) 表エントリ追加時は**表 intro の scope 宣言との整合**も検査対象になる (列挙補完 PR 特有 — intro が「Non-hook helper scripts」と宣言する表に PostToolUse 登録 hook を追加すると表面的矛盾が生じる。行内説明が真実を開示していれば cosmetic で LOW × nit-noted が妥当)。(b) scope=nit-noted 受け流し経路 (M2) が実運用で機能し、LOW × nit-noted は assessment-rules §5.3.1 により mergeable countdown から除外され cosmetic 指摘での fix loop 空転を防いだ。

**大規模 rename 事例の累積 evidence (cross-product grep 必須化)**: 16 files / +484/-484 の Phase → ステップ rename PR で、cycle 1 で 18 件の callee→caller drift を fix した後、cycle 2 で 3 件の追加見落とし (`wiki/query.md` 9 site + `wiki/lint.md:1406`) が検出された。cycle 1 reviewer の scan scope が systematic でなかったため、partial scan が tail residue を生んだ典型例。教訓: **cycle N で 1 件の callee→caller drift を発見したら、同 PR 内の `全 callee × 全 Phase-maintaining caller` の cross-product grep を即座に実行する**。`for caller in {out_of_scope_callers}; do for callee in {scope_files}; do grep -n "$caller" "$callee" | grep -E "(Phase|ステップ) [0-9]"; done; done` のような全 cross-product を 1 commit で fix することで、cycle 2 の追加 finding を pre-empt できる。本 hint は本ページの「sibling site の全量列挙」を「caller × callee 行列の全量列挙」へ拡張する一般化 (sibling 数が 5+ の大規模 PR で特に有効)。詳細な anti-pattern 解説は [Rename PR の callee → caller 片方向 over-translation で Out-of-Scope の broken cross-ref を生成する](../anti-patterns/rename-pr-callee-caller-over-translation.md) を参照。

### 適用例: 置換側↔検証側の参照経路対称化（+8/-3、1 cycle mergeable）

review-comment-post.sh の post-condition awk sentinel を置換側と同じ `-v` 変数参照に統一する +8/-3 の対称化 refactor で、3 reviewer (security / error-handling / code-quality) が独立に以下を実施して cycle 1 で 0 findings / mergeable に到達:

- **sibling site 照合**: 置換側 awk と検証側 awk の needle 構築式 (`"\"" sentinel "\""`) の byte 一致を Grep + Read で確認、同ファイル内の SENTINEL literal 残存 (変数定義 / docstring のみ) を網羅
- **検出力等価性の実機比較**: 旧 regex `~` と新 index() を同一入力で実行し出力一致を確認 (SENTINEL 値が metacharacter 非含有のため等価)
- **mutation 注入**: 置換ループを neuter して post-condition の発火 (ERROR + exit 1) を runtime 確認

対称化 PR では「両 site の構造照合 + 等価性実機比較 + 検証ゲートの mutation」の 3 点セットが 1 cycle 収束の決め手になる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](../anti-patterns/hallucinated-canonical-reference.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](canonical-list-count-claim-drift-anchor.md)

## ソース

- [PR #1294 review results cycle 2 (locale pair 拡張: en↔ja token 集合 diff で i18n parity fix を機械検証し blocking 0 で mergeable。表 intro scope 宣言整合の検査観点 + nit-noted 受け流し経路の実運用実証)](../../raw/reviews/20260606T143925Z-pr-1294.md)
- [PR #1294 fix results (TREE_SYNC_OK / TABLE_SYNC_OK の機械的対称検証で locale 同期 fix を短時間・高確信に完了)](../../raw/fixes/20260606T135607Z-pr-1294.md)
- [PR #592 review results](../../raw/reviews/20260419T062330Z-pr-592.md)
- [PR #963 review results](../../raw/reviews/20260514T182616Z-pr-963.md)
- [PR #967 fix results](../../raw/fixes/20260514T223534Z-pr-967.md)
- [PR #967 review results (cycle 2 mergeable)](../../raw/reviews/20260514T224021Z-pr-967.md)
- [PR #1151 fix cycle 2 (cross-product grep hint)](../../raw/fixes/20260526T154013Z-pr-1151.md)
- [PR #1341 review results — 置換側↔検証側 sentinel 参照対称化を 3 reviewer が sibling 照合 + 等価性実機比較 + mutation で 1 cycle mergeable 判定](../../raw/reviews/20260610T005202Z-pr-1341.md)
