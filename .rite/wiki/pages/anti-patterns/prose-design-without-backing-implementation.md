---
title: "散文で宣言した設計は対応する実装契約がなければ機能しない"
domain: "anti-patterns"
promote: rite-plugin
created: "2026-04-17T04:30:00+00:00"
updated: "2026-07-24T10:32:51Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260417T035556Z-pr-559.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T104328Z-pr-623.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T105116Z-pr-623.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T173126Z-pr-705-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T122927Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T123811Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260501T025722Z-pr-756.md"
  - type: "reviews"
    ref: "raw/reviews/20260724T100356Z-pr-2005.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T100752Z-pr-2005.md"
  - type: "reviews"
    ref: "raw/reviews/20260724T102005Z-pr-2005.md"
tags: ["prose-design", "enforcement-gap", "machine-verification", "mvp-undefined-note", "prose-code-consistency", "defense-in-depth-claim-divergence", "phantom-marker-consumer"]
confidence: high
---

# 散文で宣言した設計は対応する実装契約がなければ機能しない

## 概要

設計意図を散文で記述しつつ、それを機能させる実装 / 契約 / consumer が存在しない状態を「Prose-only design」と呼ぶ。pinky-swear な safeguard として残存し、レビュー時に CRITICAL として検出される。起点事例の 3 CRITICAL + 5 HIGH のうち、4 件が同じ根 (Finding 1/2/4/5) に由来していた。

## 詳細

### 典型パターン

| 形態 | 具体例 |
|------|------|
| 1. 参照変数の未定義 | `fix.md` Phase 3.2.1 の `$commit_body` が Phase 3.2 で一切 export されていないのに grep 入力として使われる。毎回空文字列 → 常に `ROOT_CAUSE_GATE=missing` false-positive 発火 |
| 2. 書式規約の文書化忘れ | gate が `Root cause:` header を期待しているが、`contextual-commits.md` の action type 表に `root-cause(scope)` が列挙されていない。全 commit で gate が発火し続ける |
| 3. sentinel/marker の consumer 不在 | review.md が `[CONTEXT] QUALITY_SIGNAL=3_...` を emit する設計だが、start.md 側に grep 検出 + escalation routing のコードが存在しない。marker が stderr に流れるだけの dead code |
| 4. 散文のみの safeguard | 「100-iteration absolute safety limit」を散文で 2 箇所に記述するが、counter 変数 / `if [ $c -ge 100 ]` 相当のコード / incident emit の bash block がどこにも実装されていない |

### 共通メカニズム

すべての形態に共通する failure mode:

1. **設計レビュー時点では整合している**: 散文を読む限り意図は明確
2. **実装レビュー時に可視化**: レビュアーが「この変数はどこで定義される？」「この marker を grep している箇所は？」と掘ると初めて不在が判明
3. **dogfood 実行で false-positive 発火**: gate や sentinel の場合、毎回誤発火するため本番運用で即座に発覚

### 検出方法

実装レビュー時に以下の確認を必須化する:

- **変数参照**: 散文で言及した shell 変数は、同一 bash block 内 or tempfile 経由で確実に defined されているか (Bash tool は呼び出し間で state を継承しない)
- **書式規約の双方向性**: gate が期待する書式は、その書式を生成する caller 側ドキュメントに必ず列挙する
- **sentinel の consumer trace**: `grep -rn "CONTEXT] {MARKER}="` で consumer 実装が存在するか確認。0 件なら dead code
- **safeguard の実装 trace**: 「N iteration で force-exit する」のような prose があれば、counter 変数と分岐 bash を探索。存在しなければ prose を削除するか実装する

### 対処指針

Prose-only design を発見した場合の 3 択:

1. **実装を追加** (推奨): 最も労力が大きいが設計意図を実現する
2. **Prose を削除 or 意図を変更**: 実装しない / できないなら散文から除去して偽装を解く (例: 起点事例の 100-iteration limit は「意図的に cycle-count 上限を設けない」設計意図へ書き換え)
3. **LLM-semantic check に格上げ**: bash 実装が脆弱な場合、LLM に semantic な判定を委ねる形で明示化 (例: root-cause gate の書式検査を LLM-semantic に移行)

### "機械化" 宣言 vs hook 検証不在（F-03 の拡張）

prompt 側で LLM に evidence 出力 (例: `<!-- [routing-check] ingest=matched -->`) を MUST として義務化しつつ、対応する hook 側検出 logic (例: stop-guard.sh や workflow-incident-emit.sh での pattern 検査) が未実装だと「機械的強制」を謳う prose と実態が乖離する。routing dispatcher evidence 事例では Item 0 routing dispatcher の evidence 出力を prompt 側で義務化したが、LLM が silent skip した場合の検出 hook は scope 外として follow-up Issue 化された。

**判定 heuristic**: prompt に「機械的」「強制」「義務化」のような文言が出現し、かつ対応する hook/script 層での検出コードが grep で見つからない場合、prose-only design の亜種として分類する。PR scope 分割の選択肢は以下:

1. **fix cycle 内で hook 実装を同時追加** (完全解決、scope 拡大)
2. **follow-up Issue 化 + 当該 prose に Issue 番号を明記** (scope 管理、次 PR で解消)
3. **"prompt 側のみ強制" と明示的に prose を書き換え** (機械的強制の誤謬除去)

routing dispatcher evidence 事例の cycle 1 は (2) を選択。prose に follow-up Issue 番号を記載することで読者に「prose 側と hook 側の gap は現時点で意図的」ことを伝える。

### MVP の未定義部分は「Note で明示」する（cycle 2 で追加）

新規 SoT (Single Source of Truth) を MVP として作成する場合、すべての原則を完全実装できないことがある。その場合、未実装部分を **「曖昧に宣言する」のではなく「未定義であることを明示する Note」** で透明性を保つ。これにより読み手は「dead spec か / 後続定義予定か」を即座に判別できる。

コメント SoT 新設 MVP 事例の cycle 2 では、SoT 文書の「適用フェーズ」概要表と各原則の「Where to Apply」節の不整合に対し、MVP スコープ尊重のため「未定義であることを明示する Note」選択肢を採用:

```markdown
## 適用フェーズ

| 原則 | enforce される phase |
|------|---------------------|
| 原則 1 | implement.md Phase 3.X |
| 原則 6 | review.md Phase 6.5.X |
| ...    | ... |

> Note (MVP scope): 「適用フェーズ」概要表に列挙される phase と、各原則の「Where to Apply」節の対応関係は、本 MVP では未定義です。後続 Issue #N で双方向整合の機械検証を追加予定です。
```

これは原則 6 (Comment Rot is CRITICAL) と整合する透明性の高い対応で、Prose-only design の **逆方向** (prose で「未定義」を明示することで dead spec ではないと表明) として機能する。

### prose ↔ code 不整合（cycle 14 で追加）

prose ↔ code 不整合事例の cycle 14 review で、`commands/issue/start.md` Phase 5.5.2 metrics 周辺で以下の不整合が検出された (MEDIUM):

- **prose 宣言**: 「`state-read.sh` 失敗時に metrics output を skip する」
- **bash 実装**: `val=""` で継続 (空 substitute が下流 heredoc に流入し partial corruption silent landed 経路)

LLM 解釈時の二律背反として「prose が正なのか code が正なのか」が判別不能となり、再生成時に LLM が prose に従うか code に従うかが context によって不定。fix では `[CONTEXT] METRICS_SKIPPED=1` sentinel を emit する形で **prose の宣言を bash 実装で履行** し、Claude 向け skip 指示も明示化することで partial corruption 経路を遮断した。

**判定 heuristic**: prose で「失敗時に skip」「異常時に abort」のような分岐を宣言した場合、対応する bash 実装が:

1. **flag 変数で skip 状態を保持しているか**: `if state_read_failed; then skip_metrics=true; fi` のような明示的な分岐
2. **空文字 fall-through を許容していないか**: `val=$(state-read ...) || val=""` の `||` fallback は silent fall-through 経路
3. **下流 heredoc / template に空文字 substitute が流れる経路がないか**: `cat <<EOF >> file ... ${val} ... EOF` で `${val}` が空でも EOF が完了する partial corruption

3 点全てを verify しない PR は prose-only design の variant として cycle N+1 で再検出される。

### Defense-in-depth claim と実コード経路の race window 乖離（cycle 5 で追加）

race window 乖離事例の cycle 4 review で、`pre-compact.sh` / `post-compact.sh` の trap cleanup() 関数に追加した `_resolve_err` 削除参照が **dead code** として LOW × 1 (code-quality + error-handling 二重指摘) で検出された。具体的な構造:

- **コメント claim**: 「after trap install を防ぐ defense-in-depth として `_resolve_err` も trap cleanup で削除する」
- **実コード経路**: `_resolve_err` の同期 rm が **trap install 前** で完了しているため、trap が install されたタイミングで `_resolve_err` は既に空 (= rm 不要)。trap cleanup() 内の追加 rm は常に no-op で実行される

これは「prose-only design」の variant として、**実コード経路と claim の race window 想定が乖離している** 形態。trap install 前の同期 rm が「保護対象 race window」を消滅させているため、defense-in-depth として宣言した cleanup は機能しない (race window 自体が存在しない)。

**判定 heuristic** (defense-in-depth claim 系):

1. **race window の存在検証**: defense-in-depth コメントを書く際、「保護対象の race window が trap install 後に存在するか」を必ず確認する。同期 rm が trap install 前に完了している場合、cleanup 関数内の同 file 削除参照は dead code
2. **claim と実コード経路の対称化選択肢**: defense-in-depth が無効化されている場合の対処は (a) dead code を削除 (claim 撤回)、(b) 同期 rm を trap install 後に移動 (claim 実現) の 2 択。一方を選択し commit message で明示する
3. **trap cleanup の lifecycle scope**: trap cleanup() は「install 後に作成された tempfile」のみを対象とする。install 前に rm 済みの tempfile を再 rm する code は意味的 redundancy であり、reviewer が cycle 中に検出する LOW finding として顕在化する

race window 乖離事例の cycle 5 fix では (a) の dead code 削除を選択し、F-01 (line-number reference 削除) と統合修正することでコメント整合性を維持した。本 anti-pattern は「defense-in-depth コメントの claim と実コード経路の time-ordering 乖離」として、**race window が存在しない箇所での誇張 claim** を防ぐ canonical 検出経路を提示する。

**経験則の系譜**: 本 sub-pattern は prose ↔ code 不整合事例 (失敗時 skip 宣言 vs 空 substitute) に類似するが、以下の点で異なる:

- prose ↔ code 不整合事例: prose 宣言が **下流挙動への影響** を主張するが bash 実装が silent fall-through で履行しない
- race window 乖離事例: prose 宣言が **race window 保護** を主張するが、保護対象の race window が time-ordering 上存在しない (実コード経路の time line で window が消滅している)

両者とも prose-only design の sub-class だが、検出 heuristic が異なる (前者は下流の data flow trace、後者は code の time-ordering 検証)。

### data-contract emit の comment が phantom consumer を断定する（cycle 1-2 で追加）

phantom consumer 事例 (setup 依存検査追加) で、新設した `[CONTEXT] DEP_CHECK` marker の emit 行コメントと後段散文が **存在しない consumer を present-tense で断定** し、2 reviewer (prompt-engineer + tech-writer) が同一箇所で MEDIUM 指摘 (High Confidence)。典型パターン表 row 3「sentinel/marker の consumer 不在」の亜種だが、以下の nuance が異なる:

- **旧 row 3**: marker を emit するが consumer が無い = 純粋な dead code (marker に効果なし)
- **phantom consumer 事例**: marker emit 自体は正当な **data contract / observability 目的** (Issue の Interface が「機械可読 marker で後続フェーズに渡す」と要求)。しかしコメントが「Phase 4.5.0 が jq= を参照する」/ 散文が「後続フェーズが参照する」と **具体的な consumer 関係を断定** した。実際には Phase 4.5.0 は marker を機械 parse せず独立に `command -v jq` を再実行し、jq 案内の重複排除は **marker 消費ではなく prose 参照** (NO_JQ メッセージが Phase 1.0 を文言で指す) で達成されていた

**failure mode**: emit が「働いている」ため dead-code 検出 (row 3) では拾えない。marker の効果 (dedup) は別機構 (prose 参照) で実現されているのに、コメントが fictional な dataflow (marker → 4.5.0 が consume) を主張する。保守者に「marker が load-bearing」と誤認させる executable-spec 上の false claim。

**判定 heuristic** (data-contract emit 系):

1. **consumer 関係を書く前に grep 裏取り**: marker を「後続フェーズ / X が参照する / consume する」と書く前に `grep -rn "{MARKER}" .` で機械 parse する consumer の実在を確認する (row 3 の consumer trace と同一手段だが、**dead-code 判定ではなく comment の claim 精度**の裏取りとして適用)。0 件なら「参照する」と書いてはならない
2. **data contract と consumption を分離して記述**: marker が Issue の data-contract 要件で emit されるが機械 consumer が未実装/不要な場合、コメントは「data contract / observability 目的で全ケース emit。現状どの後続フェーズも機械 parse しない」と honest に書く。効果 (dedup 等) が別機構で達成されているならその機構 (prose 参照等) を明記し、marker 消費に依存しないことを述べる
3. **consumer 化への「修正」を安易に選ばない**: fictional な consumer を実在化する ([CONTEXT] marker 依存の分岐を後続フェーズに足す) 対処は、marker が会話 context から失われる resume / compaction で silent fallback を招く別のアンチパターン (`[[open-branch-gate-marker-context-dependency]]` 系) を再導入しうる。コメントを実態に合わせる (consumer は作らない) 一択が安全な場合が多い

**review→fix→verify アークでの grep 反射**: cycle 1 で 2 reviewer が `grep -rn DEP_CHECK` により consumer ゼロを提示して指摘 → fix でコメント/散文を実態 (機械 parse されない) に訂正 → cycle 2 で reviewer が **訂正後の universal-negative 主張「現状どの後続フェーズも機械 parse しない」を再び grep で独立検証** して解消確認。この「主張の真偽を反例 (consumer) の grep 探索で裏取りする」反射は [[docs-review-implementation-grep-verification]] と同根で、data-contract emit の comment 精度検証に一般化できる。

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](../patterns/exit-code-semantic-preservation.md)
- [同 file 内 MUST NOT vs MUST 衝突: bare form 禁止規約と bare form 出力義務の自己矛盾](./same-file-must-not-vs-must-conflict.md)

## ソース

- [PR #559 review results](../../raw/reviews/20260417T035556Z-pr-559.md)
- [PR #623 review cycle 1 (機械化宣言 without hook 検出指摘)](../../raw/reviews/20260420T104328Z-pr-623.md)
- [PR #623 fix cycle 1 (follow-up Issue 化戦略選択)](../../raw/fixes/20260420T105116Z-pr-623.md)
- [PR #705 cycle 2 fix (MVP 未定義部分の Note 明示選択)](../../raw/fixes/20260428T173126Z-pr-705-cycle2.md)
- [PR #688 cycle 14 review (prose ↔ code 不整合: state-read 失敗時の skip 宣言 vs 空 substitute)](../../raw/reviews/20260428T122927Z-pr-688.md)
- [PR #688 cycle 14 fix (METRICS_SKIPPED sentinel + Claude 向け skip 指示で prose-code 整合)](../../raw/fixes/20260428T123811Z-pr-688.md)
- [PR #756 cycle 5 fix (defense-in-depth claim と race window 乖離: dead code 削除選択)](../../raw/fixes/20260501T025722Z-pr-756.md)
- [PR #2005 review cycle 1 (DEP_CHECK marker の phantom consumer 断定を grep で検出)](../../raw/reviews/20260724T100356Z-pr-2005.md)
- [PR #2005 fix (marker コメント/散文を data-contract emit の実態に訂正)](../../raw/fixes/20260724T100752Z-pr-2005.md)
- [PR #2005 review cycle 2 (訂正後の universal-negative 主張を grep で再検証・解消確認)](../../raw/reviews/20260724T102005Z-pr-2005.md)
