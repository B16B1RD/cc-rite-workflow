---
title: "reviewer の regression 主張は revert test (git show / git diff) で PR 由来か pre-existing かを独立検証する"
domain: "heuristics"
description: "reviewer が「この PR が導入した regression」「revert すれば消える」と CRITICAL を主張しても、orchestrator はその attribution (帰属) を鵜呑みにしてはならない。"
promote: rite-plugin
created: "2026-06-02T01:52:19Z"
updated: "2026-07-22T13:15:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260722T025804Z-pr-1967.md"
  - type: "reviews"
    ref: "raw/reviews/20260602T012648Z-pr-1240.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T070751Z-pr-1721.md"
tags: ["verification-protocol", "regression-attribution", "revert-test", "reviewer-claim", "git-show", "pre-existing", "delegation-refactor", "acceptance-criteria-override"]
confidence: high
---

# reviewer の regression 主張は revert test (git show / git diff) で PR 由来か pre-existing かを独立検証する

## 概要

reviewer が「この PR が導入した regression」「revert すれば消える」と CRITICAL を主張しても、orchestrator はその attribution (帰属) を鵜呑みにしてはならない。現象 (failure mode) の実在と、それが **PR 由来か pre-existing か** は別の問いであり、後者は revert test を `git show <base>:<file>` / `git diff` で独立に再現して初めて確定する。reviewer の repro が現象の実在を示しても attribution の証明にはならず、reviewer は旧コード構造を fabricate しうる (「`git show main:` で確認した」と書きながら実際の旧コードと異なる)。特に **CRITICAL かつ他 reviewer と矛盾する** finding では独立検証を必須とする。

## 詳細

### 背景となった起点事例

`session-start.sh` の settings.local.json 修復経路にあったインライン python3 ブロックを削除し、既存の共有スクリプト `settings-local-rite-hook-cleanup.py` への委譲 (stdin→stdout) に置き換える delegation refactor。`RITE_HOOK_RE` の実行定義を `.py` 1 箇所に単一化する目的。3 reviewer (prompt-engineer / code-quality / security) は「可」、code-quality は委譲の挙動等価性 (stdin→stdout I/O 契約・exit code 0/1/2・regex・json.dump フォーマット) を 45 契約テスト + 4 ケース実測で確認していた。

### reviewer の attribution が誤っていた経緯

error-handling reviewer のみ CRITICAL ×2 を指摘した:

> 「`set -e` 下で python3 単独文が rc≠0 で hook abort し、エラー報告分岐が dead code 化する」

この**現象自体は経験的に再現でき実在する**。問題は attribution の framing にあった。reviewer は次のように主張した:

> 「旧コードは `if [ -n "$_repair_tmp" ] && python3 -c` の `&&` 形式で `set -e` を免除されていた。本 PR がこの guard を解体したことで導入された regression である」

orchestrator が `git show develop:session-start.sh` で旧実装を直接確認した結果:

- **旧コードも python3 を単独文として置いていた (`&&` なし)**
- 新旧で python3 の実行構造が完全同一
- すなわち revert test は不成立 = この潜在バグは **pre-existing**
- reviewer は旧コード構造を fabricate していた (「`git show main:` で確認」と書いたが実際の develop HEAD と異なる)

### なぜ attribution の独立検証が必要か

| 問い | reviewer repro が示すこと | 独立検証が必要なこと |
|------|---------------------------|----------------------|
| 現象 (failure mode) は実在するか | ✅ 示せる (repro で再現) | — |
| この PR が原因か (PR 由来) | ❌ 示せない | revert test = `git show <base>:<file>` で旧構造を確認 |
| revert すれば消えるか | ❌ 推測のみ | 旧構造に同じ failure mode があるかを diff で確認 |

reviewer の repro は「現象の実在」を立証するが、「PR がそれを導入した」という因果 (attribution) までは立証しない。この 2 つを混同すると、pre-existing なバグを PR の blocking finding に誤って昇格させ、本来 mergeable な PR を不当に足止めする。

### revert test の独立検証手順

CRITICAL / HIGH で「revert で消える regression」と主張された場合、orchestrator は:

1. `git show <base_branch>:<path>` で旧実装の該当箇所を取得する (reviewer の旧コード引用を信用しない)
2. 主張された failure mode の構造的前提 (例: `&&` guard の有無、`set -e` 免除の成否) が**旧コードにも存在するか**を確認する
3. 旧コードに同じ構造があれば revert test 不成立 = pre-existing と確定し、blocking から外す
4. 旧コードに無く新コードのみにあれば PR 由来と確定し、blocking finding として扱う

この revert-test-for-attribution 原則を bash-heaviness exempt / pipe-refactor レビューという特定文脈で適用した先例が [operational-bash-heaviness の exempt / pipe-refactor レビューは claim を信用せず empirical 検証で gate する](./bash-heaviness-exempt-refactor-review-verification.md) (3 検証点の 1 つが「先例との非対称が本 PR diff 由来か revert test で pre-existing 判定」)。本 page はその attribution 検証軸を refactor 一般 + reviewer の旧コード fabrication 検出まで一般化したもの。

### Asymmetric Fix Transcription との関係 (real failure mode だが本件は非該当)

「inline → delegate refactor で wrapper guard が片方落ちる」のは [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) で実測済みの**実在する** failure mode であり、reviewer がこの prior をもって「guard が落ちた」と疑ったこと自体は妥当な仮説だった。しかし本件では guard (python3 の実行構造) は新旧とも同形で「落ちていない」。**有名な failure mode の prior があっても、個別ケースで実際にその mode が発火したかは git show で実体確認する**。prior が strong であるほど確証バイアスで「落ちたはず」と framing しやすいため、attribution 検証はむしろ重要になる。

### pre-existing 確定後の扱い

pre-existing と判明した潜在バグは rite の scope ルール (revert test 不成立 = 本 PR 由来でない) により blocking finding にせず、別 Issue (#1241) として切り出した。最終的にユーザー escalation で「マージ可 + 別 Issue 化」を選択。これは [Issue body 内 scope 外指摘ハンドリングポリシーで reviewer advisory finding を降格する](./issue-body-scope-out-policy-demotes-advisory-finding.md) の attribution 版 — 「scope 外」判定の根拠が「PR 由来でない (pre-existing)」であるケース。

### 適用範囲

- reviewer が「revert で消える」「この PR が導入した」と regression を attribution した finding (特に CRITICAL / HIGH)
- reviewer が旧コードを引用 (「`git show main:` で確認」等) して主張を補強しているケース — 引用自体を git show で再検証する
- inline → delegate / wrapper 解体系の refactor PR (Asymmetric Fix Transcription の prior が確証バイアスを生みやすい)
- 単一 reviewer の CRITICAL が他 reviewer の「可」判定と矛盾するケース (cross-validation 不成立は独立検証の trigger)

### 例外: Issue acceptance criteria が明確な場合は討論フェーズで revert test を上書きできる

ドキュメントを v0.7 フローへ追随させた PR の 2 回目レビューで、2 reviewer 間に cross-validation disagreement が発生した: getting-started/SKILL.md:131 の `/rite:cleanup <PR>` という誤記について、prompt-engineer reviewer は「本 PR が Phase 3.4 を修正した結果、同一ファイル内で新たに矛盾が顕在化した」として HIGH (current-pr scope) を主張、code-quality reviewer は「line 131 自体は本 PR の diff に含まれない pre-existing 行であり、revert test は厳密には FAIL する」として指摘事項に計上せず調査推奨に留めた。

討論フェーズ (debate phase) で両者の主張を検討した結果、以下の判断で合意した:

- **revert test の技術的解釈**: line 131 自体の内容は本 PR の diff で変更されていない (`git diff develop...HEAD` に含まれない)、かつ `git blame` で本 PR より前の別コミット由来と確認できるため、狭義の revert test は不成立 (pre-existing)。
- **しかし Issue の acceptance criteria (AC-4: 「getting-started の Phase 3.1 / 3.2 Option B / 3.4 が相互に矛盾しない」) が明確に本 PR のスコープとして矛盾解消を要求している**。本 PR が Phase 3.4 を修正したことで初めて Phase 3.1 との矛盾が顕在化したという事実は、たとえ line 131 自体が unchanged でも、「本 PR の目的そのもの (v0.7 フローへの追随・矛盾解消) に照らして対応すべき」という判断を正当化する。
- 前回 HIGH 指摘 (`/rite:cleanup <PR>` の引数不一致) と完全に同一の実害 (コマンド実行失敗) を持つことも、本 PR scope 内での修正を後押しした。

**一般化された原則**: revert test は「このバグが技術的に PR diff 由来か」を判定する厳密な gate として機能するが、**Issue の acceptance criteria が明示的にファイル全体・セクション間の相互無矛盾を要求している場合**、revert test で pre-existing と判定された箇所でも、その pre-existing な内容が本 PR の変更と直接的に矛盾する結果になった (本 PR が変更した箇所との整合性が本 PR によって初めて破れた) なら、討論フェーズを経て本 PR scope 内での修正が正当化されうる。これは revert test 原則の無効化ではなく、「PR の目的 (Issue acceptance criteria) がスコープをどう定義しているか」という別の判断軸との重み付けの問題である。

### 変種: pre-existing 行が本 PR の意味論変更で「不活性でなくなった」場合は revert test が PR 由来と判定する

reap manifest からの branch エントリ消費処理を追加した PR で、消費処理自体より前から存在していた（本 PR の diff に含まれない）1 行が review 対象として浮上した。line 単体の `git diff` だけを見ると「この行は pre-existing で本 PR の変更ではない」と早合点しやすいが、実際に**行単位ではなく PR 全体を revert する** revert test を行うと、この pre-existing 行は本 PR が導入した新しい消費ロジックと組み合わさって初めて到達可能になっていた (revert 前は他のコードパスから到達不能な死んだ分岐で、本 PR の変更が「その分岐を活性化」した) ため、PR 全体を revert すると問題も一緒に消えた。すなわち **狭義の revert test (`git show <base>:<file>` で該当行だけを比較) は pre-existing と判定するが、広義の revert test (PR 全体の diff を revert して現象が再現しなくなるか確認) は PR 由来と判定する** — 両者が食い違うケースである。

**教訓**: revert test を「変更された行だけを diff で比較する」狭い意味で実施すると、pre-existing な行が **本 PR の他の変更によって不活性から活性状態に遷移した**ケースを見逃す。正しい revert test は「行単位の diff 有無」ではなく「PR 全体を revert したときに現象が再現するか」を基準にする。同一 PR 内に同じファミリーの silent 経路（今回は best-effort ブロックの兄弟失敗経路、[[asymmetric-fix-transcription]] 参照）が複数存在する場合、活性化した pre-existing 行を発見したら、それを起点に PR 内で同型の経路を全対称化して収束させる方が手戻りが少ない。

## 関連ページ

- [operational-bash-heaviness の exempt / pipe-refactor レビューは claim を信用せず empirical 検証で gate する](./bash-heaviness-exempt-refactor-review-verification.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md)
- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](./prose-cited-implementation-behavioral-verification.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](../anti-patterns/hallucinated-canonical-reference.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1967 fix results cycle 5 (pre-existing 行が本 PR の意味論変更で活性化、revert test が PR 由来と判定)](../../raw/fixes/20260722T025804Z-pr-1967.md)
- [PR #1240 review results](../../raw/reviews/20260602T012648Z-pr-1240.md)
