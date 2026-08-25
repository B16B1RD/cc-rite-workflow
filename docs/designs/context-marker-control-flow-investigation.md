# `[CONTEXT]` marker 依存の制御フロー — 根本対策の調査と推奨方針

> **Status**: ✅ 方針決定（調査のみ。採用方針の実装は後続 Issue に委ねる）
>
> **本ドキュメントの位置付け**: `[CONTEXT]` marker（Bash tool 呼び出し境界を越えて LLM の会話コンテキスト経由で分岐値を受け渡す設計パターン）の全使用箇所を棚卸しし、marker 消失時の silent fallback 再発リスクを評価した上で、4 つの代替案を比較し推奨方針を決定する調査成果物。実装は本ドキュメントのスコープ外（Non-Target Files: `plugins/rite/skills/**`, `hooks/**`）。
>
> **関連ドキュメント**:
> - [`skills/wiki-lint/references/bash-cross-boundary-state-transfer.md`](../../plugins/rite/skills/wiki-lint/references/bash-cross-boundary-state-transfer.md) — `[CONTEXT] key=value` パターンそのものを明文化した既存の canonical reference。本調査はこのドキュメントを廃止するのではなく、判断基準を追加拡張する立場を取る。
> - [`skills/open/SKILL.md` 2.1-G](../../plugins/rite/skills/open/SKILL.md) — marker 消失対策として導入済みの唯一の hard gate 実装例。

<!-- Section ID: SPEC-BACKGROUND -->
## 1. 背景

rite workflow の各スキル (`.md`) は、複数の Bash tool 呼び出しにまたがる分岐ロジックを持つ。しかし Claude Code の Bash tool は呼び出しごとに独立した subprocess であり、シェル変数は呼び出し境界を越えて保持されない。この制約を回避するため、rite は以下のパターンを多用する:

```bash
# Bash 呼び出し A（値を計算し会話コンテキストに出力）
echo "[CONTEXT] MULTI_SESSION_ENABLED=true; WORKTREE_BASE=.rite/worktrees"
```

```
LLM (prose 指示): 「会話コンテキストから MULTI_SESSION_ENABLED の値を読み、true なら 2.2-W へ、false なら 2.2 へ分岐する」
```

```bash
# Bash 呼び出し B（LLM が読み取った値を literal に埋め込んで実行）
if [ "true" = "true" ]; then ...; fi
```

この設計は「LLM が会話コンテキストに残った marker 行を正しく読み取り、正しい値を次の Bash 呼び出しに literal substitute する」ことに制御フローの正しさを賭けている。会話コンテキストは以下の事象で失われる・変質しうる:

- **resume**: セッションが中断し `/rite:recover` で別ターンから再開する場合、marker を emit した Bash tool 呼び出し自体が会話履歴に無い
- **compact**: 長い会話が要約されるとき、`[CONTEXT]` marker 行が要約対象になり文字列として保持されない可能性がある
- **途中入場**: orchestrator（`/rite:batch-run`, `/rite:iterate` 等）が sub-skill を呼び出す際、sub-skill 内の marker が期待した粒度で親の会話コンテキストに伝播しないケース

**実例**: `open/SKILL.md` は元々「ステップ 1.4 で `MULTI_SESSION_ENABLED` を emit し、ステップ 2.2/2.3 の分岐でその値を会話コンテキストから読む」設計だった。resume / 途中入場で marker が context から失われると、「marker が見つからない → 従来の `false` 相当の経路（`git switch -c`）にフォールバックする」暗黙の挙動が発生し、`multi_session.enabled: true` であるにも関わらず main ツリーへ直接 `git switch -c` する silent fallback バグを生んだ。対策として「副作用（ブランチ作成）直前に marker を再確定する hard gate」（2.1-G）が導入されたが、これは対症療法であり、他のスキルの同種パターンには適用されていない。

<!-- Section ID: SPEC-AC1 -->
## 2. AC-1: `[CONTEXT]` marker 全使用箇所の棚卸し

### 2.1 再現コマンド

```bash
grep -rn '\[CONTEXT\]' plugins/rite/
```

実行時点（2026-07-07、develop HEAD）で **675 箇所 / 55 ファイル** がヒットする。

### 2.2 ファイル種別集計

| 種別 | 件数 | 主なファイル |
|---|---:|---|
| `skills/*.md`（SKILL.md 本体 + 同梱 references） | 416 | fix, review, resume, cleanup, open 等 |
| `scripts/*.sh`（plugin-root scripts） | 101 | review-source-resolve.sh, review-findings-maps.sh |
| `hooks/*.sh`（トップレベル hooks） | 73 | review-result-save.sh, review-comment-post.sh, review-skip-notification.sh |
| `hooks/scripts/*.sh`（lib/ 含む） | 43 | worktree-git.sh, wiki-lint-*.sh |
| `hooks/tests/*.sh` | 22 | distributed-fix-drift-check.test.sh |
| `references/*.md`（plugin-root 共有） | 20 | review-result-schema.md, sentinel-contract.md |
| **合計** | **675** | （内訳の和と一致） |

### 2.3 ファイル別上位15（降順）

| # | ファイル | 件数 |
|---:|---|---:|
| 1 | `skills/fix/SKILL.md` | **155** |
| 2 | `skills/pr-review/SKILL.md` | **92** |
| 3 | `scripts/review-source-resolve.sh` | 45 |
| 4 | `skills/resume/SKILL.md` | 41 |
| 5 | `hooks/review-result-save.sh` | 26 |
| 6 | `skills/cleanup/SKILL.md` | 23 |
| 7 | `skills/open/SKILL.md` | 20 |
| 8 | `hooks/review-comment-post.sh` | 20 |
| 9 | `scripts/review-findings-maps.sh` | 18 |
| 10 | `hooks/tests/distributed-fix-drift-check.test.sh` | 17 |
| 11 | `skills/issue-close/SKILL.md` | 16 |
| 12 | `hooks/review-skip-notification.sh` | 16 |
| 13 | `hooks/scripts/lib/worktree-git.sh` | 14 |
| 14 | `skills/wiki-lint/SKILL.md` | 13 |
| 15 | `skills/run/SKILL.md` ほか同率3ファイル | 12 |

残り約40ファイルで合計約100件（1〜9件/ファイルが大半）。

> **想定との差異**: 当初は review/cleanup/open が最大件数と想定していたが、実測では **`fix/SKILL.md` が単独最大（155件、全体の23%）** だった。review 結果の解析（`REVIEW_SOURCE_*` / `FIX_FALLBACK_FAILED` 等の多段 enum）を大量に持つため。この事実は §4 の代替案評価（特に (b)(c) の実装コスト見積り）に直接影響する。

### 2.4 emit / consume 内訳（概算）

grep ヒット行のうち:

- `echo` を含む行（emit 側、bash がstdout/stderrへ出力）: **約407件（60%）**
- `echo` を含まない行（大半が consume 側 — LLM prose 指示「会話コンテキストから読み取る」、marker 名の分岐表・文書内言及、grep/case 文でのパース記述）: **約268件（40%）**

1つの marker 定義に対し、分岐表・後続ステップ参照・エラーハンドリング表等で複数箇所言及されるケースが多く、ユニークな marker 種類ベースで見ると emit:consume の実質比率は前者よりさらに consume 側に偏ると推測される。

### 2.5 喪失リスクが高い「長距離パターン」代表例

以下は「marker の emit と consume の間に他の Bash 呼び出し（および場合によっては別スキルファイル）を挟む」パターンで、喪失時の影響が大きい代表例:

| # | 箇所 | 内容 | 距離 |
|---|---|---|---|
| 1 | `review/SKILL.md` ステップ7.1 → 7.7 / 8.0.2 | `PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={ID}; mode={mode}; choice={choice}; reason={reason}` を確認完了後に emit、review-fix ループの複数 cycle を跨いで2箇所（gate + gate reference）で consume。`iteration_id` による「最新行採用」に加え、`mode=` / `choice=` / `reason=` 欠落は未確認 emit として採用しない | 中〜高（cycle跨ぎ） |
| 2 | `fix/SKILL.md` ステップ1.0.1 → 1.2.0 | `REVIEW_FILE_PATH` / `REMAINING_ARGS` を emit、100行以上先の別ステップで `{review_file_path_from_phase_1_0_1}` として参照。さらに `REVIEW_SOURCE=<source>; review_source_path=<path>; pr_number=<n>` を別プロセス（helper script）が emit し、下流の severity_map 構築ブロックで再度参照 | 高（多段中継） |
| 3 | `resume/SKILL.md` `WT_ENSURE` 分岐表（SoT）→ `fix/SKILL.md`, `review/SKILL.md` 等 | resume 側で定義した分岐表を**別スキルファイル**が「resume の SoT 表に従う」と参照する、ファイル境界を跨ぐ最も遠いパターン | 最高（ファイル跨ぎ） |
| 4 | `cleanup/SKILL.md` ステップ5 → ステップ12 | `BRANCH_DELETED` / `BRANCH_DELETE_DEFERRED` 等の複数排他的 marker を emit、100行以上先の完了レポート生成ステップで分岐 | 中 |
| 5 | `cleanup/SKILL.md` ステップ9（wiki-ingest 呼び出し）→ 完了レポート | サブプロセス（wiki-ingest）の出力を cleanup が読み取り、さらに `[CONTEXT]` として再 emit する「中継」パターン | 中（サブスキル跨ぎ） |
| 6 | `wiki-lint/SKILL.md` ステップ4/5/6.0/6.2/7 → ステップ8.1 | 5つの独立 helper script がそれぞれ emit した enum を、最終ステップが fan-in 集約判定する | 中（ただし単一 lint 実行内で完結） |

### 2.6 既存の hard gate 対策

 由来の「marker 再生成による防御」は現状 **`open/SKILL.md` の 2.1-G のみ**:

- `open/SKILL.md` 2.1-G: 「ブランチ作成前の multi_session hard 再確定」。副作用（ブランチ作成）の**直前**にステップ1.4と同一パースロジックを再実行し、「marker が context に無いことを理由に旧経路へ進む分岐は存在しない」ことを構造的に保証する。
- `open/SKILL.md` `--require-worktree`: worktree path 不在のまま記録しようとした場合に `WORKTREE_INVARIANT=missing` を emit するデータ層検知（実行はブロックしない loud warning）。

review / fix / cleanup / wiki-lint 側には同種の「副作用直前の再生成ゲート」はまだ存在しない。

### 2.7 重複マッチ対策パターン（iteration_id）

`iteration_id` によるサイクル間重複マッチ回避は現状 **`review/SKILL.md` のみ**（ステップ2.2.1 と ステップ7.1/7.7/8.0.2 の2箇所）。他のスキルファイル（特に review-fix ループのように同一 marker が複数回 emit されうる箇所）には未展開。

<!-- Section ID: SPEC-RISK -->
## 3. 喪失シナリオごとのリスク評価

| シナリオ | 発生条件 | 影響を受けやすいパターン | リスク |
|---|---|---|---|
| **resume** | セッション中断後 `/rite:recover` で別ターン再開 | 長距離パターン（§2.5 全般）。resume 直後の会話コンテキストには中断前の marker が存在しない | 高 — 各スキルの resume dispatch は flow-state（`.rite-flow-state` 相当）の `phase` を SoT にしているため、marker 依存部分は「resume 直後の1回目の分岐」でのみ危険。2回目以降は同一ターン内で完結すれば安全 |
| **compact** | 長い会話が要約される | 全パターン。要約プロセスが `[CONTEXT]` 行を「重要でない中間出力」として圧縮対象にする可能性 | 中〜高 — 本ドキュメント作成セッション自体で「CRITICAL: Respond with TEXT ONLY... STOP. Compact detected」のような compact 発火を経験しており、実際に発生しうる事象であることを確認済み |
| **途中入場** | orchestrator が sub-skill を Skill ツール経由で呼び出す際、期待した marker 粒度が親の会話コンテキストに伝播しない | ファイル跨ぎパターン（§2.5 #3, #5） | 中 — Skill ツール呼び出しは通常同一ターン内の会話に統合されるため直接の欠落は稀だが、大量の中間出力がある場合に LLM の注意が逸れて「読み忘れる」リスクは marker 消失と同型の failure mode |

** の実例との対応**: 上記「途中入場」に近いシナリオ（`open/SKILL.md` が resume 経由で phase=branch から再開したときに、ステップ1.4 の marker が同一ターンに存在しない）で実際に発生した。

<!-- Section ID: SPEC-AC2 -->
## 4. AC-2: 代替案の比較評価

4つの代替案を「再発防止効果」「実装コスト」「互換性リスク」の3軸で評価する。

### (a) 現状維持 + hard gate 拡充

`open/SKILL.md` 2.1-G と同型の「副作用直前に marker を再生成するゲート」を、§2.5 で特定した高リスク長距離パターンに個別展開する。

| 軸 | 評価 | 根拠 |
|---|---|---|
| 再発防止効果 | 中 | ゲートを追加した箇所は構造的に安全になるが、**新しく追加される marker にゲートを付け忘れる**という同型の drift（Wiki 経験則「Asymmetric Fix Transcription」そのもの）が再発しうる。対策が「都度手動で気付いて追加する」運用に依存する限り、真の意味での「根本対策」にはならない |
| 実装コスト | 低〜中 | 1 ファイルずつ増分適用可能。スキーマ変更なし、既存パターンの複製で済む |
| 互換性リスク | 低 | 完全後方互換。フォーマット変更なし |

### (b) mktemp 経由の受け渡し

会話コンテキストへの echo に依存せず、既知パス（`/tmp/rite-{session}-{key}.state` や `.rite/state/` 配下）にファイルとして値を書き込み、後続の Bash 呼び出しが決定論的に読み戻す。

| 軸 | 評価 | 根拠 |
|---|---|---|
| 再発防止効果 | 高 | 「LLM が会話コンテキストに保持しているか」という不確実性を完全に排除し、ファイルシステムという確定的な媒体に置き換える |
| 実装コスト | 高 | 675 箇所（ユニーク marker 種類ベースでは概算 50〜100 程度、§2.4 の重複言及傾向より推測）の read/write 双方を変換する必要がある。特に `fix/SKILL.md`（155件）は変換対象が突出して多い |
| 互換性リスク | 中 | ファイルのライフサイクル管理（作成・cleanup・cycle 間の陳腐化）が新たな failure mode になる。cycle をまたいで古いファイルを誤って読む問題は、現在の `iteration_id` 方式が会話コンテキスト上で解決している問題を、ファイル名スコープ設計で**作り直す**必要がある（例: `{pr_number}-{cycle}.state` のような命名規則を新設しないと同種の stale-match バグを再生産する） |

### (c) flow-state への統合

既存の `.rite-flow-state`（`flow-state.sh get/set --field` で読み書きする、resume/compact を既に生き延びる実証済みの永続構造）に、これら中間値も統合する。

| 軸 | 評価 | 根拠 |
|---|---|---|
| 再発防止効果 | 高 | flow-state は既に resume/compact を前提に設計・実証済みの唯一の永続チャネル。`cycle_count` / `worktree` 等、性質的に「durable な flow state」である値は既にここに格納されており、その他の値も同じ仕組みに乗せることで一貫性が生まれる |
| 実装コスト | 非常に高 | flow-state スキーマが 50〜100+ の一時的・中間的な値を抱えることになり、スキーマ肥大化を招く。675 箇所の read/write 変換に加え、多くの値が「1ステップから次ステップへの単発受け渡し」であり「flow state」と呼ぶには短命すぎる（概念的な誤用）という設計的な違和感がある |
| 互換性リスク | 高 | 既存の schema_version マイグレーション運用（Wiki 経験則にも `schema_version 2→3` 等の前例あり）に加え、新規フィールド追加のたびに Target Files（spec/実装/ドキュメント）の同期が必要になり、Wiki が繰り返し指摘する Asymmetric Fix Transcription のリスク源をスキーマ自体に埋め込むことになる |

### (d) ハイブリッド

marker を「性質」で分類し、対策を使い分ける:

1. **真に永続的・cross-file な値**（worktree path, cycle_count, PR/Issue 番号等）→ **flow-state に統合**（実は多くが既にそうなっている）
2. **単一ステップ〜数ステップ内の短距離受け渡し**（大半の675箇所）→ **現状維持**（変更不要、リスクが低いため）
3. **副作用直前・かつ長距離**（§2.5 で特定した6パターン）→ **hard gate（(a) の再生成パターン）を適用**、または flow-state に昇格
4. **同一 marker が複数 cycle で再出現しうる箇所**→ **`iteration_id` 方式（review/SKILL.md で実証済み）を横展開**

| 軸 | 評価 | 根拠 |
|---|---|---|
| 再発防止効果 | 高 | 実際にリスクが高い箇所（長距離 × 副作用を伴う）にのみ対策を集中させるため、費用対効果が最大化される。「性質による判断基準」を明文化することで、新規追加時にも同じ基準で判断でき、(a) 単独の弱点（都度手動で気付く必要がある）を「判断基準の明文化」で緩和できる |
| 実装コスト | 中 | 675 箇所の大半（短距離・低リスク）は無変更で済み、§2.5 で特定した10〜20箇所程度の高リスクパターンのみに変更を集中できる。worktree path・cycle_count 等は既に flow-state に存在するため「昇格」はほぼ完了済み |
| 互換性リスク | 低〜中 | 大半のサイトは無変更のため後方互換。flow-state スキーマ変更は真に必要な少数の値に限定されるため (c) ほどのスキーマ肥大化を招かない |

<!-- Section ID: SPEC-AC3 -->
## 5. AC-3: 推奨方針と段階移行案

### 5.1 推奨: (d) ハイブリッド

理由: 675 箇所という規模に対して (b)(c) のような一律変換は費用対効果が低く、かつ (c) は flow-state という別の SoT にスキーマ肥大化という新しい technical debt を移し替えるだけになりかねない。(a) 単独では「都度気付いて対策する」運用依存が残る。(d) は既存の実証済み対策（`open/SKILL.md` 2.1-G のhard gate、`review/SKILL.md` の `iteration_id` dedup、worktree path 等の既存 flow-state フィールド）を**一般化された判断基準**として明文化し、真にリスクが高い箇所にのみ選択的に適用する。

### 5.2 判断基準（新規/既存 marker 追加時に適用する規約）

以下を `bash-cross-boundary-state-transfer.md` に追記する形で明文化する（既存ドキュメントの置き換えではなく拡張):

> ある `[CONTEXT]` marker が (1) 2つ以上の Bash tool 呼び出し境界を跨ぎ、かつ (2) git 操作・Issue/PR mutation・ブランチ作成等の不可逆的または重大な結果を招くアクションの分岐に使われる場合、以下のいずれかを **MUST** で満たす:
>
> - **(i) 副作用直前の hard gate**: アクション実行の直前に、marker の元になった条件を再計算・再emit するブロックを設置する（`open/SKILL.md` 2.1-G と同型）
> - **(ii) flow-state への昇格**: 値が性質的にセッション/PRのライフサイクル全体で意味を持つ「durable な状態」であれば、`.rite-flow-state` のフィールドとして格納する
>
> 上記いずれにも該当しない（= 単一ステップ〜数ステップ内で完結する、低リスクな受け渡し）場合は、現行の `[CONTEXT] echo` パターンのままでよい。
>
> 加えて、同一 marker が review-fix ループ等の**繰り返し実行**の中で複数回 emit されうる場合は、`iteration_id`（`{pr_number}-{epoch_seconds}` 形式）による最新値判定を付与する（`review/SKILL.md` ステップ2.2.1/7.1 と同型）。

### 5.3 段階移行案

| Stage | 内容 | 対象 |
|---|---|---|
| **Stage 1** | §5.2 の判断基準を `bash-cross-boundary-state-transfer.md` に追記。新規 marker 追加時のレビュー観点として `prompt-engineer-reviewer` の checklist に反映を検討 | ドキュメントのみ、コード変更なし |
| **Stage 2** | §2.5 で特定した高リスク長距離パターンのうち、最もリスクが高い2件（`resume/SKILL.md` の `WT_ENSURE` ファイル跨ぎ参照、`fix/SKILL.md` の `REVIEW_SOURCE`/`REVIEW_FILE_PATH` 多段中継）に hard gate を適用 | resume/SKILL.md, fix/SKILL.md |
| **Stage 3** | 残る長距離パターン（review/SKILL.md の追加ゲート化検討、cleanup/SKILL.md のブランチ削除分岐、wiki-lint/SKILL.md の fan-in 判定）に順次展開。`iteration_id` dedup パターンを review/SKILL.md 以外にも横展開 | review/SKILL.md, cleanup/SKILL.md, wiki-lint/SKILL.md |
| **Stage 4（任意）** | `sentinel-contract-check.sh` 型の静的検証を拡張し、「2 Bash 呼び出し以上を跨ぐ `[CONTEXT]` emit/consume ペアで hard gate も flow-state 裏付けも無いもの」を機械的に検出する lint を追加。棚卸しを一度きりの監査で終わらせず継続的な contract として維持する | 新規 lint script（別 Issue） |

Stage 1-2 が本調査の直接の follow-up として妥当な粒度。Stage 3-4 は Stage 2 の効果測定後に個別 Issue 化する。

## 6. まとめ

- `[CONTEXT]` marker は 675 箇所（55ファイル）に存在し、`fix/SKILL.md`（155件）が最大。
- 真にリスクが高いのは「長距離（複数 Bash 呼び出し・ファイル境界を跨ぐ）」かつ「副作用を伴う」パターンで、§2.5 に列挙した6件が代表例。
- 4代替案のうち、全数変換を要する (b)(c) は実装コストと新たな互換性リスクの見合いで見送り、既存の実証済み対策（(a) の hard gate、review/SKILL.md の iteration_id）を一般化する **(d) ハイブリッド** を推奨する。
- 判断基準の明文化（Stage 1）と高リスク2箇所への適用（Stage 2）を後続 Issue として起票する。
