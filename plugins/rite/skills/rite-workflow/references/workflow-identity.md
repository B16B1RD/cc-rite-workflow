# Workflow Identity Reference (品質 > 時間/context)

rite workflow が守る価値観と、LLM (Claude Code) が `/rite:*` コマンド実行中に逸脱してはならない identity を定義する。CLAUDE.md (リポジトリ root) はマーケットプレイス経由インストール時に配布されないため、identity は本ファイルで完結させ、SKILL.md と各 command からここを参照する。

## Core Identity

**品質 > 時間/context**。rite workflow は「時間的制約」「context 残量」を犠牲にしてでも、ワークフローで定義された step を全て実行し、生成物の品質を担保することを最優先する。speed/efficiency 最適化は本ワークフローの目的ではない。

## Principle List

| Principle ID | Principle Name |
|--------------|----------------|
| `no_step_omission` | 定義された step を省略しない |
| `no_context_introspection` | context 残量を推論しない |
| `clear_resume_is_canonical` | context 枯渇時は `/clear` + `/rite:resume` が唯一の正規経路 |
| `quality_over_expediency` | 時間/context を理由に品質を下げない |
| `no_mid_workflow_stop` | sub-skill return tag で turn を閉じない (継続トリガとして同 turn 内で次 phase へ) |
| `meaningful_terminal_output` | ワークフロー完了時の user-visible な最終行は sentinel marker ではなく人間可読な完了メッセージ |

---

## Principle Details

### no_step_omission (step を省略しない)

**Summary**: ワークフローで定義された step は、時間・context 状況にかかわらず、例外なく全て実行する。

**Failure Patterns (Anti-pattern)**:
- 「時間が足りないので X step をスキップします」
- 「context が圧迫しているので Y 段階をまとめて省略します」
- 「重要度が低そうなので Z を割愛します」
- 「手順書の一部を要約して実行した気になる (特に Wiki ingest / lint / review-fix ループ)」

**Rules**:
1. commands/*.md や skills/*.md に MUST として書かれた step は、実行時間やトークン消費量を理由に skip してはならない。
2. step をスキップする正当な条件は、各 command に明示された「Skip condition」(設定値 off、対象 0 件、等) のみである。
3. 自己判断による「省略」は Skip condition ではない。

**Correct Pattern**:
- 定義された順序と step 数のとおりに実行する。
- 実行困難な状況に陥った場合は、勝手に省略せず、`AskUserQuestion` でユーザーに判断を委ねるか、`/clear` + `/rite:resume` 経路に誘導する。

### no_context_introspection (context 残量を推論しない)

**Summary**: LLM は自分の context 残量・残りトークン数・「pressure」を推論してはならない。それらは fact ではなく、主観的印象にすぎない。

**Failure Patterns (Anti-pattern)**:
- 「context が残り少ないので先に結論を出します」
- 「context が圧迫しているので details を省きます」
- 「残量が不安なので review を早めに切り上げます」
- 「残量を理由にしたショートカットを『気を利かせた最適化』として正当化します」

**Rules**:
1. context 残量を fact-check できる機構は LLM 側にない。残量 %・残トークン数を推論値として判断材料にしない。
2. 残量への言及そのものを出力に含めない (ユーザーを誤誘導する)。
3. 長くなりそうだと感じた場合でも、定義された step は実行し、実際に context window が逼迫した場合は CLI/ハーネス側の自動 compaction か、`/clear` + `/rite:resume` に委ねる。

**Correct Pattern**:
- step を愚直に実行する。
- compact/context 切れが発生したら、CLI が自動で session を継続するか、ユーザーが `/clear` + `/rite:resume` を実行する (後述)。LLM の仕事は「省略判断」ではなく「手順どおりに実行」。

### clear_resume_is_canonical (`/clear` + `/rite:resume` が唯一の正規経路)

**Summary**: context が実際に枯渇した、あるいはセッションを完全にリセットしたい場合の正規経路は `/clear` (Claude Code 組み込みコマンドで会話履歴をリセット) に続く `/rite:resume` である。LLM が勝手に step を省いて context を節約する経路は存在しない。

**Failure Patterns (Anti-pattern)**:
- 「context を節約する目的で step を省略します」
- 「context が切れそうなので続きは次回のセッションで実行します」
- 「context が足りなそうという直感で手順短縮版のワークフローを自作します」

**Rules**:
1. context 切れ / 再開は `/clear` + `/rite:resume` で行う (`/rite:resume` は `.rite-flow-state` と work memory を読み直し、中断点から継続する)。
2. LLM は「`/clear` + `/rite:resume` を使うべき状況」と「手順どおり最後まで実行する状況」のどちらかしか選べない。その中間に「手順を縮めて実行する」選択肢はない。
3. ユーザーに `/clear` + `/rite:resume` を案内する必要があると判断した場合は、`AskUserQuestion` または通常の出力で明示的に伝える。

**Correct Pattern**:
- context 残量の推論はしない。残量への不安を理由にした短縮は禁止。
- 本当に継続困難な場合のみ、ユーザーに `/clear` + `/rite:resume` の使用を案内し、work memory / `.rite-flow-state` に中断点を残す。

### no_mid_workflow_stop (sub-skill return tag で turn を閉じない)

**Summary**: sub-skill (create-interview / create-register / create-decompose / lint / pr:review / pr:fix / pr:ready 等) が return tag (`[interview:completed]`, `[create:completed:{N}]`, `[review:mergeable]`, `[fix:pushed]`, 等) を出力して制御を返した時、LLM は **同 turn 内で** orchestrator の `🚨 Mandatory After ...` セクションを実行して次 phase へ継続すること。return tag は turn 境界ではなく **継続トリガ** である。

**Failure Patterns (Anti-pattern)**:
- sub-skill が `[interview:skipped]` を出力して return した直後に LLM が turn を閉じ、ユーザーが `continue` 入力を余儀なくされる (Issue #525 / #552 / #561 で再発確認)
- return tag を見て「sub-skill が完了したので workflow も完了」と誤認し、orchestrator の Mandatory After を実行せずに停止する
- `[create:completed:{N}]` を出力した terminal sub-skill の直後に turn を閉じる前に orchestrator の defense-in-depth (Step 1-3) が走らないケース (terminal では Step 1/2 が no-op のため実害は少ないが、marker 欠落時の Step 3 が走らないと UX 不明瞭)

**Rules**:
1. return tag は **契約上の継続トリガ** であり、turn を閉じるシグナルではない。
2. orchestrator の `🚨 Mandatory After ...` セクションは、return tag 出力直後に **同 response turn 内で** 実行する。
3. stop-guard hook が `.rite-flow-state.active=true` かつ継続必須 phase (例: `create_post_interview` / `create_delegation` / `phase5_post_review` 等) で stop を block し、`workflow_incident sentinel` + WORKFLOW_HINT を stderr 経由で feed back する。
4. sentinel marker は HTML コメント (`<!-- [tag:value] -->`) 化することで LLM の turn 境界 heuristic の誤 triggering を抑制する (`meaningful_terminal_output` principle と coupling)。

**Correct Pattern**:
- return tag を受信したら即座に Mandatory After の手順を続行。orchestrator 内のチェックリストを読み、次 phase の Pre-write + Skill 呼び出し or 完了処理を実行する。
- 文章 enforcement だけでなく stop-guard + flow-state + phase-transition-whitelist + HTML コメント sentinel の機械的 enforcement レイヤーに依拠する。
- 本当に継続困難な場合のみ `/clear` + `/rite:resume` に委ねる (`clear_resume_is_canonical` 経路)。

### meaningful_terminal_output (完了時の user-visible 最終行は人間可読メッセージ)

**Summary**: `/rite:issue:create` / `/rite:issue:start` など一連のワークフロー完了時、ユーザーに見える最終行は `[create:completed:{N}]` のような sentinel marker ではなく、`✅ Issue #{N} を作成しました: {url}` のような「完了したと即座に理解できる」人間可読メッセージであること。sentinel marker は hook/grep 契約のため出力自体は保持するが、HTML コメント化 (`<!-- [create:completed:{N}] -->`) 等で user-visible な末端に孤立させない。

**Failure Patterns (Anti-pattern)**:
- Terminal Completion の最終行が `[create:completed:1234]` のようなブラケット付きトークンで終わり、user が「本当に完了したのか」判断できない
- 完了メッセージ (`✅ ...`) は存在するが、その後に sentinel を「absolute last line」として配置し user の視線が sentinel に到達する

**Rules**:
1. user-visible な最終行は完了メッセージ (例: `✅ Issue #{N} を作成しました: {url}`, `✅ PR をレビュー可能にしました`, 等) とする。
2. sentinel marker (`[create:completed:{N}]`, `[interview:completed]`, `[ready:completed]`, 等) は hook/grep 契約のため出力は保持する。配置方法は実装者判断で HTML コメント化 / stderr / 専用ファイル等から選択する。
3. HTML コメント (`<!-- [create:completed:{N}] -->`) 化を採用する場合、grep は内部の `[create:completed:N]` 文字列を matchable なので既存 hook/test は非 regression。
4. Terminal Completion の出力順序テンプレートを変更する際は同時に orchestrator (例: `create.md` Mandatory After Delegation) の fallback template も同期更新する (drift 防止)。

**Correct Pattern**:
- `create-register.md` Phase 4 / `create-decompose.md` Phase 1.0 の出力テンプレートを「flow-state deactivation → ✅ 完了メッセージ → 次のステップ → `<!-- [create:completed:{N}] -->` (HTML コメント最終行)」の順序で統一する。
- user 視点では `✅ ...` + 次のステップが最終コンテンツとして視覚的に残る。sentinel は HTML コメント化されレンダリング時に不可視。

### quality_over_expediency (時間/context を理由に品質を下げない)

**Summary**: rite workflow の目的は「高品質な成果物の生成」であり、「最短時間でのワークフロー完了」ではない。expediency (便宜) のために quality (品質) を犠牲にしない。

**Failure Patterns (Anti-pattern)**:
- 「レビュー指摘を『時間がないので見送り』にして PR を ready にします」
- 「wiki ingest を『cleanup が長くなるから』skip します」
- 「テスト実行を『context が不安なので』省きます」
- 「計画段階の自己レビューループを『サイクル数を増やすと重い』からと 1 回で打ち切ります」

**Rules**:
1. MUST として定義された品質ゲート (lint、review、wiki ingest、metrics 記録、等) は時間・context 状況にかかわらず通過する。
2. AC / Definition of Done は全件クリアまでワークフローを終了させない。
3. 時間的な圧力は、省略判断の根拠にはならない。

**Correct Pattern**:
- 時間がかかっても定義された step をすべて踏む。
- 継続困難な場合は `/clear` + `/rite:resume` で人間にセッション継続を委ねる。

---

## How to Reference This Document

- **SKILL.md**: ファイル先頭付近 (Auto-Activation Keywords / Context 節の直後) に `## Workflow Identity` 節を置き、本ファイルへのリンクを掲載する。
- **各 command (start / review / fix / ready / lint / cleanup / create / resume 等)**: step 省略が発生しやすい箇所に 1-2 行で「identity 参照」を追加し、本ファイルの該当 principle にリンクする。
- **agent / reviewer の prompt**: 必要に応じて identity を注入する。

### Recommended reference template

新規 command / 既存 command の step 省略リスク箇所に identity reference を追加する際は、以下の **blockquote 形式**を推奨する。drift 抑制のため全 caller で同一 style に揃える:

```markdown
> **Identity reference**: [workflow-identity.md](<相対パス>) の `{principle_id_1}` / `{principle_id_2}` principle 参照。{short context，例: "時間・context を理由にした step 省略は禁止"}。
```

**Placeholder 展開ルール**:

| Placeholder | 値 |
|-------------|----|
| `<相対パス>` | caller の depth に応じて `../skills/rite-workflow/references/workflow-identity.md` (commands/ 直下) または `../../skills/rite-workflow/references/workflow-identity.md` (commands/pr/ / commands/issue/ 配下) |
| `{principle_id_*}` | 関連する principle ID (`no_step_omission` / `no_context_introspection` / `clear_resume_is_canonical` / `quality_over_expediency` のいずれか 1-2 個) |

**Example (commands/pr/cleanup.md Phase 4.W.2 より)**:

```markdown
> **Identity reference**: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md) の `no_step_omission` / `no_context_introspection` / `clear_resume_is_canonical` / `quality_over_expediency` principle を参照。
```

**既存 variance の扱い**: 既存 caller の 3 style (blockquote / inline / 後置) はそのまま維持してよい (retrospective な書き換えは scope creep)。新規追加時のみ本 template に従うこと。

## Non-goal

- CLAUDE.md (リポジトリ root) への identity 記述: 配布対象外のため採用しない。
- hook による機械的 enforcement: MAY (必要に応じて検討)。本 reference による文書的 enforcement を先行させる。
