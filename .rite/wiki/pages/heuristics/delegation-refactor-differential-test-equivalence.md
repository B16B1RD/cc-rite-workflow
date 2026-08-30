---
title: "委譲リファクタの動作保持は原実装との差分テストで機械的に立証する"
domain: "heuristics"
description: "inline ロジック (inline Python / bash 等) を helper や transform へ委譲しつつ「動作を verbatim 保持する」ことが hard constraint のリファクタでは、**原アルゴリズムを参照実装として再現し、新実装と同一入力で出力を byte 比較して全件一致を示す** differential equivalence test を verification の中核に据える。"
created: "2026-05-30T09:32:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260530T064117Z-pr-1204.md"
  - type: "reviews"
    resource: "raw/reviews/20260531T004233Z-pr-1208.md"
  - type: "reviews"
    resource: "raw/reviews/20260531T163857Z-pr-1218.md"
  - type: "fixes"
    resource: "raw/fixes/20260531T164546Z-pr-1218.md"
  - type: "reviews"
    resource: "raw/reviews/20260531T165600Z-pr-1218.md"
  - type: "reviews"
    resource: "raw/reviews/20260601T090546Z-pr-1229.md"
  - type: "fixes"
    resource: "raw/fixes/20260601T093706Z-pr-1229.md"
  - type: "reviews"
    resource: "raw/reviews/20260601T094425Z-pr-1229.md"
  - type: "reviews"
    resource: "raw/reviews/20260602T101920Z-pr-1249.md"
  - type: "fixes"
    resource: "raw/fixes/20260602T102600Z-pr-1249.md"
  - type: "reviews"
    resource: "raw/reviews/20260602T103357Z-pr-1249.md"
  - type: "reviews"
    resource: "raw/reviews/20260606T030501Z-pr-1286.md"
tags: ["refactor", "verification", "testing", "delegation"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-06T04:16:52Z" }
---

# 委譲リファクタの動作保持は原実装との差分テストで機械的に立証する

## 概要

inline ロジック (inline Python / bash 等) を helper や transform へ委譲しつつ「動作を verbatim 保持する」ことが hard constraint のリファクタでは、**原アルゴリズムを参照実装として再現し、新実装と同一入力で出力を byte 比較して全件一致を示す** differential equivalence test を verification の中核に据える。これにより「同じはずだ」という主張を、レビュー可能な機械的証明へ変換できる。

## 詳細

faithful-port 委譲の 1 例目は `archive-procedures.md` §3.5.2 の inline Python (~75 行、進捗 checklist の section merge) を `merge-checklist` transform へ委譲した (重量 inline bash の helper 委譲 umbrella の 1 ブロック)。hard constraint は原アルゴリズムの verbatim 保持 (全文・完全行 dedup / section 末尾挿入 / section 不在 no-op / 末尾改行保持)。

- **立証法**: 原 §3.5.2 アルゴリズムを参照実装として bash/Python で再現し、新 transform と同一の 7 エッジケース (EOF section ±末尾改行 / 中間 section / 末尾空行 / section 不在 / 部分 dedup / 全項目既出 / 末尾改行なし) で出力を byte 比較 → 全件一致を確認。
- **通常の unit test との違い**: 期待値を人手でハードコードする unit test は、原実装の**非自明な暗黙挙動** (section 不在時の silent drop、末尾改行の正規化、複数 section 時の挿入先 等) を取りこぼしやすい。期待値を「原実装の出力そのもの」に取ることで、これらの暗黙エッジまで含めて等価性を保証できる。
- **強い signal**: 1 例目では 5 レビュアー (prompt-engineer / code-quality / test / error-handling / security) のうち複数が、指示されずとも独立に「原 inline block と新実装の差分比較を byte 一致で確認する」手法を採用した。委譲リファクタの正当性検証として differential equivalence test が自然に選ばれることは、本 heuristic の有効性を裏付ける。結果は指摘 0 件 / 1 cycle 収束。
- **適用条件**: behavior-preserving な refactor 限定 (inline → helper 委譲 / 関数抽出 / 言語間移植 等)。動作を意図的に変える refactor には不適 (差分が出るのが正しいため)。

### 出力契約の verbatim 保持も差分検証の対象に含める

2 例目は `wiki/lint.md` §6.2 の `all_source_refs` 集合構築 (~240 行 inline bash) を `wiki-lint-source-refs.sh` へ委譲した (同 umbrella の別ブロック)。この例の特徴は、差分検証の対象がアルゴリズム等価性だけでなく **出力契約そのもの** に及ぶ点: marker block (`---all_source_refs_begin/end---`) と 3 値 enum (`unknown` / `true` / `io_error`) を verbatim 保持することが下流 step の分岐を壊さない hard constraint であり、reviewer は (a) develop inline 実装との byte-level diff、(b) 新規 test 34/34 pass、(c) 実機 injection 検証の 3 点で確認し、5 reviewer 全員 0 blocking / 1 cycle 収束。

- **最も効率的な検証経路**: 「inline 削除版 vs helper 新規版の機械 diff」+「既存テスト実行」+「出力契約 (marker block / enum) の verbatim 一致確認」の 3 点セット。先行事例に続く同 umbrella 内 2 例目の独立再現で、faithful-port 委譲の検証手法として differential equivalence + 出力契約 verbatim の組み合わせが定着していることを示す。
- **trust boundary を確定してから injection を評価する**: faithful-port の bash injection 評価では入力の trust boundary を明示するのが有効。本 PR の page/branch 入力は LLM 制御下の wiki ページパスで外部ユーザー入力ではなく、防御は double-quote + allowlist gate (placeholder residue / partial pollution) の二層。injection リスクは「入力が誰の制御下にあるか」を確定してから severity を評価する。

### doc 適用範囲の対称記述 (sub-insight)

同 PR で prompt-engineer が surface した非ブロッキング推奨: §3.5.1 (完了情報 / append-eof 委譲) は「`### 完了情報` は WM 初期テンプレに存在しない新規セクション」と section-novelty を明記していたが、対称位置の §3.5.2 (進捗 merge) は「対象 `### 進捗` が v1 legacy 限定で、default v2 WM (`### 進捗サマリー` table) では merge が常に no-op になる」という適用範囲を記述していなかった。委譲リファクタでは **(a) 動作の等価性 (差分テスト) と (b) doc の適用範囲記述の対称性** の両方を verify する。(b) は [[asymmetric-fix-transcription]] の doc レイヤー版。

### 抽出境界に取り残されるデッドコードも検出対象

3 例目は `pr/fix.md` ステップ1.2.0 Hybrid Review Source Resolution の Selection logic (~550 行) を新規 `review-source-resolve.sh` へ verbatim 抽出した。同 umbrella 内 **3 例目** の faithful-port 委譲で、検証は (a) `git show develop:...fix.md` の inline block との byte-level diff、(b) 同梱 test 37 assertions pass、(c) `distributed-fix-drift-check.sh` の新規 drift 0 (stash before/after 比較で delta=0) の **3 点セットを 1 例目 / 2 例目と同型に再現**し、cycle 2 で 0 findings 収束。

本 PR が新たに surface した failure mode は、差分検証では「意味論的差分ゼロ」と判定される一方で **抽出境界に取り残されるデッドコード** が混入する点。cycle 1 で 3 reviewer が独立検出した 3 件はすべて「抽出時に上流境界からコピーされたが、対になる依存が抽出範囲外に残ったため宙に浮いた」コード:

- **cleanup 変数の no-op 化**: `norm_tmp` / `handed_off_norm_tmp` の宣言 + trap 参照だけが helper にコピーされたが、対になる非空代入 (`norm_tmp=$(mktemp ...)`) は schema normalization block (fix.md 側の **別 bash fence = 別プロセス**) に残ったため、helper 内では cleanup が常に `rm -f "" ""` の no-op になる。Claude Code の Bash tool は呼び出しごとに別プロセスで shell 変数も trap も継承されないため、「block 終了時 trap で削除」というコメントの主張が cross-process で成立しない。
- **未使用変数の習慣的混入**: standalone 化の際に習慣で追加した `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` は、helper が sibling script を source/invoke しないため未使用。develop の inline block には存在しなかった。
- **誤った namespace の enumeration への reason 追加**: caller reason を、本来属する 1.2.0 `FIX_FALLBACK_FAILED` 系列ではなく、別 step (2.4.N `NIT_NOTED_REPLY_*`) の独立 namespace enumeration に重複追加していた (drift Pattern-5 の file-level union では hook error にならないが、表と enumeration の同期契約に違反)。

canonical 対策: faithful-port 委譲の review checklist に「コピーした **cleanup 変数の非空代入 site が helper 内に存在するか** (別 fence に残っていないか)」「standalone 化で追加した変数が実際に使われるか」「reason を **正しい step の namespace** に追加したか」を加える。これらは runtime 挙動を変えないため差分テスト・test pass では検出されず、reviewer の cross-file grep でのみ surface する。

加えて、cycle 2 で reviewer が検出した **pre-existing 事項** (severity_map fence の `norm_tmp` orphan / `json_commit_sha_err` の signal-window leak) は、いずれも develop 時点から存在し本 PR diff が原因でない (revert test FAIL) ため指摘事項から除外し、investigation 推奨 / follow-up Issue に再分類した。faithful-port 委譲のレビューでは **verbatim 保持スコープを尊重し pre-existing バグを current-pr 指摘に混ぜない** scope 規律が重要 ([[scope-creep-rejection-empirical-gate]] / 同 umbrella の別ブロックにおける verbatim 保持スコープ尊重と同型)。

### caller-doc の挙動列挙は helper の全 return 経路を catch-all で網羅する

4 例目は `commands/init.md` の inline Python (~44 行、`settings.local.json` から rite hook エントリを除去する JSON 編集) を `settings-local-rite-hook-cleanup.{py,sh}` へ委譲した。別 umbrella での faithful-port 委譲の独立再現で、検証は (a) 旧 inline `python3 -c` と新 helper の 5 fixture 差分比較 (出力・exit code 完全一致)、(b) `bash-heaviness-check.sh --all` の findings 8→7、(c) `/rite:lint` Phase 3.5-3.17 で新規 warning ゼロ、の 3 点セットを 1〜3 例目と同型に再現し、全 4 reviewer 0 blocking / 2 cycle 収束。差分テスト等価性手法が umbrella を跨いで安定再現することを示す。

本 PR が新たに surface した facet は、差分テストでは「動作等価」と判定される一方で **caller-doc の挙動列挙が helper の全 return 経路を catch-all で網羅していない** drift。cycle 1 で F-01 として検出された唯一の finding は、`init.md` の Helper contract 注記が `NO_RITE_HOOKS` を返す条件を「python3 不在・file 不在・対象 hook 不在」の **閉じたリスト** で列挙していたが、helper の実挙動はそれ以外の安全側ケース (不正 JSON / mktemp・mv 失敗) も全て `NO_RITE_HOOKS` に畳み込む **catch-all** だった点。cycle 1 fix で注記を「rite hook を実際に除去したときのみ `CLEANED`、それ以外の安全側ケースは全て `NO_RITE_HOOKS`」という catch-all 表現へ補強し (helper の全 `NO_RITE_HOOKS` 経路 .sh L27/34/44/47 を網羅)、cycle 2 で 0 finding 収束。

canonical 対策: 委譲リファクタの review checklist に **「caller-doc が列挙する helper の挙動が、helper の全 return 経路 (特に error/edge: 不正入力・mktemp/mv 失敗) を catch-all で網羅しているか」** を加える。閉じたリスト形式の列挙は helper の catch-all 実挙動と drift しやすく、symptom (列挙不足) でなく root-cause (注記が全 return 経路を網羅しない構造) に対処する。本 facet は #1226 / #1228 の `json_invalid` doc 精度ポリシー (実挙動を安全側表現で記述する) と同系統であり、§3.5.1 の「doc 適用範囲の対称記述」が *両 site の適用範囲記述の対称性* を扱うのに対し、本 facet は *caller doc 単体の return-path 網羅性* を扱う直交軸。

副次的に surface した非ブロッキング観察 (いずれも pre-existing / follow-up 候補、revert test FAIL のため current-pr 指摘から除外): helper の自動テスト (.test.sh) 未追加 (先例 `issue-comment-wm-sync.test.sh` あり)、mv 失敗時の stderr WARNING 欠如、`CLEANED` 経路で結果 file permission が mktemp 由来 0600 に厳格化。これらは [[scope-creep-rejection-empirical-gate]] の verbatim 保持スコープ尊重に従い follow-up に再分類した。

### 採用した hardening pattern に対応する sibling 回帰テストの登録対称性も差分テストの盲点

5 例目は `pr/review.md` の 6.1.c Skip Notification (~142 行 inline bash) を `review-skip-notification.sh` へ委譲した。faithful-port 委譲の独立再現で、検証は (a) develop 版 inline block との byte-level diff (gate 順序 / reason 語彙 6 種 / exit code 0/1/2 / heredoc 文言が byte-identical)、(b) `bash-heaviness-check.sh --all` の findings 2→0、(c) `distributed-fix-drift-check.sh` の新規 drift 0 (6.1.c reason の table→bullet 変換に中立) の 3 点セットを 1〜4 例目と同型に再現し、cycle 2 で 5 reviewer 全員 0 blocking / 2 cycle 収束。

5 例目が新たに surface した facet は、差分テストでは「動作等価」と判定される一方で、**新規 helper が採用した hardening pattern に対応する sibling 回帰テストへの登録対称性**が片落ちする drift。cycle 1 で唯一検出された F-01 (MEDIUM) は、helper が `shift; shift` (value-less flag による無限ループ予防) を当初から正しく採用していたにもかかわらず、対応する回帰テスト `shift2-loop-hardening.test.sh` への登録という対称契約 (helper file 内 test coverage 対称性 contract) を見落としていた点。「helper 本体の動作正しさ (runtime no-hang)」と「sibling 回帰テストへの登録」は独立した対称軸であり、後者は 3 reviewer (prompt-engineer / code-quality / error-handling) が独立検出する high-signal finding になった。cycle 1 fix は同一ファイル内 3 site の対称更新 (header Coverage コメント / run_no_hang リスト TC-6 追加 / anti-pattern guard ループ TC-6→TC-7 renumber + script list 追加) で完結し、着手時に外部からの TC 番号・ファイル参照ゼロを git grep で確認して cross-file 影響なしを立証してから renumber した。cycle 2 では test reviewer が mutation testing (`shift; shift` → `shift 2` 改変) により TC-6 (timeout 124) / TC-7 (実 shift 2 検出) の dual-layer 回帰検知を kill-test で実証した ([[mutation-testing-test-fidelity]])。

canonical 対策: 委譲リファクタの review checklist に **「新規 helper が採用した既存 hardening pattern (shift;shift 等) について、対応する sibling 回帰テストへの登録が helper 本体の実装と対称になっているか」** を加える。helper の動作正しさは回帰テスト登録の有無とは別軸であり、登録漏れは runtime 挙動を変えないため差分テスト・既存 test pass では検出されず、reviewer の sibling 照合でのみ surface する ([[asymmetric-fix-transcription]] の test レイヤー版、[[small-symmetric-pr-sibling-site-grep-review]] の sibling grep 手法と同系統)。本 facet は #1218 の「抽出境界デッドコード」・#1229 の「caller-doc return-path 網羅」と並ぶ、差分テストが捕捉しない第 3 の直交軸 (test coverage 対称性) である。

### 観測捕捉は外部観測可能な挙動の全域、in-process 中間変数は契約対象外

その follow-up PR は `pr/fix.md` 1.2.0 severity_map build (~154 行) の `review-findings-maps.sh` 委譲を含む MEDIUM 5 + LOW 1 件の重量 inline bash を helper 委譲 / args_json 分離で解消した。faithful-port 委譲の **6 例目** の独立再現で、3 cycle (1→2→0 blocking) 収束。本 PR は差分テストの**観測範囲そのもの**について双方向の線引きを確立した:

- **観測捕捉範囲の穴 (捕捉拡張方向)**: cycle 1 で test reviewer が、wiki-branch-init 差分テストの dump_state が commit subject (`%s`) のみ捕捉し **commit body の drift が観測網を素通りする**ことを mutation で実証 (MEDIUM) → wiki_body/main_body の捕捉追加 + verbatim assert pin で構造的解消。差分テストは「比較している」だけでは不十分で、比較対象が外部観測可能な挙動の全域 (rc / stdout / stderr / file / commit body) を捕捉しているかが独立の検証軸になる。
- **契約対象外の確定 (観測除外方向)**: cycle 3 で test reviewer の「helper 内部 validation 変数 (`severity_map_json`) が test で観測不能」MEDIUM が、prompt-engineer / code-quality / error-handling の「旧 inline でも stdout 非 emit の in-process validation 変数 = verbatim 契約」検証と衝突 → 討論フェーズで合意降格 (機能 regression なし、改変値は production 非消費)。**differential equivalence test の観測範囲は「外部観測可能な挙動 (rc/stdout/stderr/file)」であり、in-process 中間変数は契約対象外**という線引きを確立。

両者は同じ「観測範囲」軸の両端: 前者は外部観測可能なのに捕捉していなかった穴 (拡張すべき)、後者はそもそも外部観測不能な非契約対象 (要求すべきでない)。canonical 対策として、委譲リファクタの review checklist に「dump/capture helper が外部観測可能な全 channel を捕捉しているか (subject-only のような部分捕捉になっていないか)」を加え、逆に in-process 中間変数の観測可能性要求は demote する。

副次観察: 委譲 refactor で validation gate は片落ちせず純増 (numeric gate / placeholder gate 追加)、silent-failure hole 2 件解消 (projects の `jq -s` 未チェック / create.md の nested jq マスク)。cycle 2 の SoT universal MUST 文 vs 未移行 caller 2 件の矛盾は漸進移行 note (Option B: 責務分離の文書化を SoT 本文に明記) で解消 ([[asymmetric-fix-resolution-via-hub-creation]] の SoT-caller 軸適用例)。nit-noted 受け流し経路 (LOW 級 enumeration stale) は countdown 対象外として loop を阻害せず mergeable 到達 ([[respect-reviewer-no-action-recommendation]])。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Mutation testing で test の真正性を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる](./small-symmetric-pr-sibling-site-grep-review.md)

## ソース

- [PR #1204 review results](../../raw/reviews/20260530T064117Z-pr-1204.md)
- [PR #1208 review results](../../raw/reviews/20260531T004233Z-pr-1208.md)
- [PR #1218 review results (cycle 1)](../../raw/reviews/20260531T163857Z-pr-1218.md)
- [PR #1218 fix results](../../raw/fixes/20260531T164546Z-pr-1218.md)
- [PR #1218 review results (cycle 2)](../../raw/reviews/20260531T165600Z-pr-1218.md)
- [PR #1229 review results (cycle 1)](../../raw/reviews/20260601T090546Z-pr-1229.md)
- [PR #1229 fix results](../../raw/fixes/20260601T093706Z-pr-1229.md)
- [PR #1229 review results (cycle 2)](../../raw/reviews/20260601T094425Z-pr-1229.md)
- [PR #1249 review results (cycle 1)](../../raw/reviews/20260602T101920Z-pr-1249.md)
- [PR #1249 fix results](../../raw/fixes/20260602T102600Z-pr-1249.md)
- [PR #1249 review results (cycle 2)](../../raw/reviews/20260602T103357Z-pr-1249.md)
- [PR #1286 review results](../../raw/reviews/20260606T030501Z-pr-1286.md)
