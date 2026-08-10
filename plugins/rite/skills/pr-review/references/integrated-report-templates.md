# Integrated Report Templates

> `skills/pr-review/SKILL.md` ステップ 5.4 (Integrated Report Generation) が出力する統合レポートの
> テンプレート本文。SKILL.md 本体の Template selection 表 / emoji policy / `📎 reviewed_commit` 必須
> ルールに従い、`review_mode` に応じたテンプレートを選択して placeholder を展開する。
> reviewer 指示テンプレート ([reviewer-prompt-generator.md](reviewer-prompt-generator.md)) と同じ
> 「本文は references / 選択と実行は SKILL.md」の分担に従う。

## full-mode-template

**Full review mode (`review_mode == "full"`) template:**

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: {マージ可 / マージ不可（指摘あり） / 修正必要}
- **レビュアー数**: {count}人
- **変更規模**: {additions}+ / {deletions}- ({changedFiles} files)
- **起動の直列化**: {ステップ 4.6 の SPAWN_SPREAD 判定。`serialized` のとき `検出（spawn spread {spread}s > 閾値 {threshold}s）` / `undetermined` のとき `計測不能（reason={reason}）` / 計測不能を伴う `parallel` のとき `なし（{measured}/{reviewers} 名のみ計測）`。全員分が揃い閾値内だった場合は本行ごと省略する}

### レビュー範囲（cycle 2+ 差分スコープ）（該当がある場合のみ）
<!-- REVIEW_CYCLE_SCOPE == incremental のときのみ表示。full のときは本セクションごと省略する。
     E2E フローでも省略禁止 — cycle 2+ は E2E からしか発生しないため、ここを minimize すると
     観測性の要求が空文になる（SoT: cycle-scope.md §選抜結果の記録を E2E で省略しない理由）。 -->

- **スコープ**: 差分（`{cycle_base_sha}`..HEAD） — 未変更部は cycle 1 のフルレビューで審査済み
- **起動した reviewer**: {selected_reviewers_with_reason}
- **今サイクルはスキップした reviewer**: {skipped_reviewers_with_reason}

| reviewer | 今サイクル | 理由 |
|----------|-----------|------|
| {type} | 起動 / スキップ | 前サイクル finder（mandatory 合流）/ fix diff の領域担当（{matched_file_count} ファイル）/ fix diff に該当ファイルなし |

### レビューレーン（XS/S 軽量レーン）（該当がある場合のみ）
<!-- COMPLEXITY_LANE == light のときのみ表示。full のときは本セクションごと省略する。
     E2E フローでも省略禁止 — 本機能の主対象である Scenario 1（XS が 1 サイクル収束して
     自律マージされる）は E2E ループでしか起きず、そこを minimize すると「何名スキップし
     何を軽量化したか」が人間に届く唯一の同期経路が消える
     （SoT: complexity-lane.md §選抜結果の記録を E2E で省略しない理由）。 -->

- **レーン**: 軽量（Issue #{issue_number} の宣言 Complexity: {complexity}） — reviewer 上限 {effective_max}
- **軽量化した検証 mandate**: 全スイートの sandbox 複製実行と mutation 実験を実施せず、touched テストの実行までとした
- **不変**: 指摘の採否基準（4 必須自問 / Confidence / Observed Likelihood / 実測アンカー）、Cross-File Impact Check、実測必須ゲート、帰結クラス分類
- **レーンによりスキップした reviewer**: {lane_skipped_reviewers_with_reason}

| reviewer | 今サイクル | 理由 |
|----------|-----------|------|
| {type} | 起動 / スキップ | 領域担当（{matched_file_count} ファイル）/ 軽量レーンの上限 {effective_max} により除外（relevance 下位） |

### レビュアー合意状況

| レビュアー | 評価 | CRITICAL | HIGH | MEDIUM | LOW-MEDIUM | LOW |
|-----------|------|----------|------|--------|-----------|-----|
| {type} | {assessment} | {count} | {count} | {count} | {count} | {count} |

### 仕様との整合性（該当がある場合のみ）
<!-- ステップ 1.3.1 で Issue 仕様が取得できた場合のみ表示 -->

| 仕様項目 | 状態 | 備考 |
|---------|------|------|
| {spec_item} | 準拠 / 不整合 / 未実装 | {notes} |

### 討論結果（該当がある場合のみ）
<!-- ステップ 5.2.1 で討論が実行された場合のみ表示。矛盾が0件の場合はこのセクション自体を省略 -->

| ファイル:行 | レビュアー | 結果 | 合意内容 |
|------------|-----------|------|---------|
| {file:line} | {reviewer_a} vs {reviewer_b} | 合意 / エスカレーション | {resolution_summary} |

### 高信頼度の指摘（複数レビュアー合意）
<!-- 2人以上のレビュアーが同じ問題を指摘 -->

| 重要度 | ファイル:行 | 内容 | 指摘者 |
|--------|------------|------|--------|
| {severity} | {file:line} | {description} | {reviewers} |

### 外部仕様の検証結果（該当がある場合のみ）
<!-- Fact-Checking Phase で外部仕様の検証が実行された場合のみ表示。外部仕様の主張が0件の場合はこのセクション自体を省略 -->

| 指摘 | 主張 | 検証結果 | ソース |
|------|------|---------|--------|
| {file:line} ({reviewer}) | {claim_summary} | ✅ 検証済み / ⚠️ 未検証 | [source](URL) |

**ファクトチェック**: {verified}✅ {contradicted}❌ {unverified}⚠️

### 矛盾により除外された指摘（該当がある場合のみ）
<!-- CONTRADICTED 指摘がある場合のみ表示。0件の場合はこのセクション自体を省略 -->


| 重要度 | ファイル:行 | 当初の主張 | 公式ドキュメントの記述 | ソース |
|--------|------------|-----------|----------------------|--------|
| {severity} | {file:line} | {original_claim} | {correct_info} | [source](URL) |

### Doc-Heavy PR Mode 検証状態（該当がある場合のみ）
<!-- 表示条件 (決定論的、OR で評価):
 本セクションは以下の (a) または (b) のいずれかが成立する場合に表示する。両方とも成立しない場合は省略する:
 (a) doc_heavy_pr == true で ステップ 5.1.3 post-condition check が実行された場合
 (b) numstat_availability == "unavailable" の場合 (numstat 失敗の可視性のため、doc_heavy_pr の値に関係なく表示)

 非表示条件: 上記 (a) も (b) も成立しない場合 (= doc_heavy_pr == false かつ numstat_availability == "OK")
 → tech-writer が reviewer に存在するかどうかに関係なく省略する。tech-writer の存否は本セクションの
 表示判定に影響しない (本セクションは Doc-Heavy 機構と numstat 可用性の状態を可視化するためのものであり、
 tech-writer 単独のレビュー結果を表示するセクションではないため)。

 詳細: ステップ 5.1.3 末尾の「ステップ 5.4 表示責務の分離」段落を参照
 numstat 失敗時は numstat 可用性行に unavailable が表示される (Doc-Heavy 判定自体は ステップ 1.1 files 配列で完結するため skip されず通常通り実行される)

 placeholder 展開ルール (undefined 参照防止):
 - {numstat_availability}: "OK" or "unavailable" (ステップ 1.2.6 で必ず explicit set される)
 - {numstat_fallback_reason}: success path では空文字列 ""、failure path では 1 行要約 (ステップ 1.2.6 で必ず explicit set される)
 - {doc_heavy_pr_value}: true / false (ステップ 1.2.7 Determination ブロックで explicit set される)
 - {doc_heavy_pr_decision_summary}: ステップ 1.2.7 の生成ルール (Determination ブロック直下のコメント) に従って生成された文字列
 - {doc_heavy_post_condition}: passed / warning / error (ステップ 5.1.3 で set される)
 - {cross_reference_skip_status}: "なし" or "あり" (ステップ 5.1.3 / Cross-Reference 検証で set される)
 - {acknowledgement_status}: "不要" / "取得済み" / "未取得" (ステップ 5.1.3 で partial_skip 発生時のみ set、それ以外は "不要") -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| numstat 可用性 | {numstat_availability} | {numstat_fallback_reason} |
| Doc-Heavy 判定 | {doc_heavy_pr_value} | {doc_heavy_pr_decision_summary} |
| Post-condition | {doc_heavy_post_condition} | passed / **warning** / **error** のいずれか |
| tech-writer finding 件数 | {doc_heavy_finding_count} | {0 件の場合は META negative confirmation の有無} |
| Evidence 欠落 finding | {evidence_missing_count} 件 | {evidence_missing_list を箇条書き} |
| Cross-Reference partial skip | {cross_reference_skip_status} | なし / **あり** ({cross_reference_skip_details — external repo 情報}) |
| ユーザー acknowledgement | {acknowledgement_status} | 不要 / **取得済み** / **未取得** (partial_skip あり時のみ記載) |

**影響**: `post-condition == warning` または `error`、もしくは `evidence_missing_count >= 1`、または `cross_reference_partial_skip == true` かつ acknowledgement 未取得の場合、総合評価は自動的に **`修正必要`** に昇格する。

### Verification Mode Post-Condition 検証状態（該当がある場合のみ）
<!-- 表示条件: review_mode == "verification" のときのみ表示。full mode では ステップ 5.1.1.1 がスキップされるため省略する。

 placeholder 展開ルール (undefined 参照防止):
 - {verification_post_condition}: "passed" / "warning" / "error" (ステップ 5.1.1.1 で set される。review_mode == "full" では "passed" 固定)
 - {verification_post_condition_retry_summary}: per-reviewer retry counter の 1 行要約 (例: "tech-writer: 1 retry, others: 0")

 両 template (full mode / verification mode) で同一内容の drift 防止コメントは ステップ 5.1.3 後の "Doc-Heavy PR Mode セクションの drift 防止" note を参照 -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| Verification post-condition | {verification_post_condition} | passed / **warning** / **error** (ステップ 5.1.1.1 の `### 修正検証結果` テーブル出力チェック結果) |
| Retry 回数サマリー | {verification_post_condition_retry_summary} | per-reviewer retry counter の集計 |

**影響**: `verification_post_condition == warning` または `error` の場合、該当 reviewer の指摘は全件 blocking 扱いとなり、総合評価は **`修正必要`** に昇格する。
ここでの「全件 blocking 扱い」は verification-mode / severity 軸での降格を禁止する意味であり、ステップ 5.3.0.M の実測必須ゲートは orthogonal に後段で適用される (`Verification:` アンカーを持たない指摘は non-blocking に分類され `total_findings` から外れる)。escalation は総合評価を昇格させるが sentinel routing は `total_findings` が確定させる (詳細は pr-review/SKILL.md ステップ 5.1.1.1 の「escalation の効力範囲」注記)。


### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}
- **所見**: {summary}

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| {severity} | {scope} | {file:line} | {description} | {recommendation} |

<!-- 各レビュアーの結果を繰り返し -->

### 推奨事項（該当がある場合のみ）
<!-- ステップ 5.1 で収集した recommendation_items (全 item、classification 必須) + ステップ 5.3.0 で降格された Hypothetical findings がある場合のみ表示。0件の場合はこのセクション自体を省略。

**aggregate label 禁止**: 本テーブルは各 item の分類を必ず明示する。「推奨 N 件」「follow-up 候補 N 件」のような件数のみの集計は本テーブルでも、PR コメント (ステップ 6.1.a) でも、result line (ステップ 8.1) でも禁止。ステップ 7.7 post-condition gate により aggregate label 単独報告は機械的に block される。 -->

| レビュアー | 分類 | 内容 | トリアージ対象 |
|-----------|------|------|:------------:|
| {reviewer_type} | {actionable / design_confirmation / boundary} | {recommendation_content} | {✅ if classification == actionable OR (boundary AND user approves), — otherwise} |


### Observed Likelihood 降格結果（該当がある場合のみ）
<!-- ステップ 5.3.0 Observed Likelihood Gate (Post-Reviewer Safety Net) で降格された finding がある場合のみ表示。0件の場合はこのセクション自体を省略。
 両 template (full mode / verification mode) で同一内容で同期すること (drift 防止) -->


| 元重要度 | 降格後 | ファイル:行 | 内容 | 降格理由 |
|---------|-------|------------|------|---------|
| {severity} | 推奨事項 / （削除） | {file:line} | {description} | Likelihood-Evidence marker 未提示 / LOW × Hypothetical は報告禁止 |

### Guardrail 監査ログ（該当がある場合のみ）
<!-- reviewer の `### 監査ログ` から収集した Category #2 行がある場合のみ表示。0 件なら省略。
 audit-only で評価・finding 件数・merge 判定には影響しない。既定 post_comment:false でも人間が確認できるよう、
 guardrail_audit_count > 0 のとき E2E でも省略禁止。永続 JSON の guardrail_audit_log[] と同じ集合を描画する。 -->

| レビュアー | Filter Category | 元重要度 | ファイル:行 | 除外した内容 | 除外理由 | 実測 |
|-----------|-----------------|----------|------------|--------------|----------|------|
| {reviewer} | Category #2 | {original_severity} | {file_line} | {description} | {filter_reason} | {verification or なし} |

### 実測なし指摘 (non-blocking)（該当がある場合のみ）
<!-- ステップ 5.3.0.M 実測必須ゲートで non-blocking に分類された non_blocking_findings がある場合のみ表示。0件の場合はこのセクション自体を省略。
 blocking ではない (mergeable countdown 対象外)。severity は明示する (非実測 CRITICAL/HIGH の人間可視化)。
 記録先は 4 経路 (永続 JSON の non_blocking_findings[] / ステップ 6.1.d の PR 記録コメント / 本 section / E2E output line の件数 suffix) で破棄経路は存在しない。
 本 section は E2E でも省略禁止 (non_blocking_count > 0 のとき)。
 両 template (full mode / verification mode) で同一内容で同期すること (drift 防止) -->


| レビュアー | 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|-----------|--------|----------|------------|------|---------|
| {reviewer_type} | {severity} | {scope} | {file:line} | {description} | {suggestion} |

### 調査推奨（該当がある場合のみ）
<!-- ステップ 5.1 で収集した investigation_suggestions がある場合のみ表示。blocking ではない。0件の場合はこのセクション自体を省略。
 両 template (full mode / verification mode) で同一内容で同期すること (drift 防止)。
 column 構成は ステップ 4.5 reviewer template の「調査推奨」3 列 (ファイル / 気になる点 / 補足) に
 レビュアー列を追加した 4 列で、reviewer の notes が silent drop しないように揃えてある -->


| ファイル | 気になる点 | 補足 | レビュアー |
|---------|-----------|------|-----------|
| {file} | {concern_description} | {notes} | {reviewer_type} |

---

### 次のステップ
{recommendation に応じた具体的アクション}

📎 reviewed_commit: {current_commit_sha}
```

## verification-mode-template

**Verification mode (`review_mode == "verification"`) template:**

```markdown
## 📜 rite レビュー結果

### Guardrail 監査ログ（該当がある場合のみ）
<!-- reviewer の `### 監査ログ` から収集した Category #2 行がある場合のみ表示。0 件なら省略。
 audit-only で評価・finding 件数・merge 判定には影響しない。既定 post_comment:false でも人間が確認できるよう、
 guardrail_audit_count > 0 のとき E2E でも省略禁止。永続 JSON の guardrail_audit_log[] と同じ集合を描画する。 -->

| レビュアー | Filter Category | 元重要度 | ファイル:行 | 除外した内容 | 除外理由 | 実測 |
|-----------|-----------------|----------|------------|--------------|----------|------|
| {reviewer} | Category #2 | {original_severity} | {file_line} | {description} | {filter_reason} | {verification or なし} |

### 総合評価
- **推奨**: {マージ可 / マージ不可（指摘あり） / 修正必要}
- **レビューモード**: 検証 + フル
- **レビュアー数**: {count}人
- **変更規模**: {additions}+ / {deletions}- ({changedFiles} files)
- **起動の直列化**: {ステップ 4.6 の SPAWN_SPREAD 判定。`serialized` のとき `検出（spawn spread {spread}s > 閾値 {threshold}s）` / `undetermined` のとき `計測不能（reason={reason}）` / 計測不能を伴う `parallel` のとき `なし（{measured}/{reviewers} 名のみ計測）`。全員分が揃い閾値内だった場合は本行ごと省略する}

### 修正検証サマリー

| 項目 | 件数 |
|------|------|
| 前回の指摘総数 | {total_previous} |
| FIXED（修正済み） | {fixed_count} |
| NOT_FIXED（未修正） | {not_fixed_count} |
| PARTIAL（部分修正） | {partial_count} |
| リグレッション（新規） | {regression_count} |

### レビューレーン（XS/S 軽量レーン）（該当がある場合のみ）
<!-- full mode template と同一。COMPLEXITY_LANE == light のときのみ表示し full では省略する。
     描画条件は review_mode に依存しないため、verification mode でも同じ section を持つ。 -->

- **レーン**: 軽量（Issue #{issue_number} の宣言 Complexity: {complexity}） — reviewer 上限 {effective_max}
- **軽量化した検証 mandate**: 全スイートの sandbox 複製実行と mutation 実験を実施せず、touched テストの実行までとした
- **不変**: 指摘の採否基準（4 必須自問 / Confidence / Observed Likelihood / 実測アンカー）、Cross-File Impact Check、実測必須ゲート、帰結クラス分類
- **レーンによりスキップした reviewer**: {lane_skipped_reviewers_with_reason}

### レビュアー合意状況

| レビュアー | 評価 | NOT_FIXED | PARTIAL | REGRESSION |
|-----------|------|-----------|---------|------------|
| {type} | {assessment} | {count} | {count} | {count} |

### 未修正の指摘（NOT_FIXED / PARTIAL）

| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |
|---|--------|------------|------|------|------|
| {n} | {severity} | {file:line} | {description} | {NOT_FIXED/PARTIAL} | {notes} |

### リグレッション（修正差分で検出）

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| {severity} | {scope} | {file:line} | {description} | {recommendation} |

### 討論結果（該当がある場合のみ）
<!-- ステップ 5.2.1 で討論が実行された場合のみ表示。矛盾が0件の場合はこのセクション自体を省略 -->

| ファイル:行 | レビュアー | 結果 | 合意内容 |
|------------|-----------|------|---------|
| {file:line} | {reviewer_a} vs {reviewer_b} | 合意 / エスカレーション | {resolution_summary} |

### 仕様との整合性（該当がある場合のみ）
<!-- ステップ 1.3.1 で Issue 仕様が取得できた場合のみ表示 -->

| 仕様項目 | 状態 | 備考 |
|---------|------|------|
| {spec_item} | 準拠 / 不整合 / 未実装 | {notes} |

### 高信頼度の指摘（複数レビュアー合意）
<!-- 2人以上のレビュアーが同じ問題を指摘 -->

| 重要度 | ファイル:行 | 内容 | 指摘者 |
|--------|------------|------|--------|
| {severity} | {file:line} | {description} | {reviewers} |

### 外部仕様の検証結果（該当がある場合のみ）
<!-- Fact-Checking Phase で外部仕様の検証が実行された場合のみ表示。外部仕様の主張が0件の場合はこのセクション自体を省略 -->

| 指摘 | 主張 | 検証結果 | ソース |
|------|------|---------|--------|
| {file:line} ({reviewer}) | {claim_summary} | ✅ 検証済み / ⚠️ 未検証 | [source](URL) |

**ファクトチェック**: {verified}✅ {contradicted}❌ {unverified}⚠️

### 矛盾により除外された指摘（該当がある場合のみ）
<!-- CONTRADICTED 指摘がある場合のみ表示。0件の場合はこのセクション自体を省略 -->


| 重要度 | ファイル:行 | 当初の主張 | 公式ドキュメントの記述 | ソース |
|--------|------------|-----------|----------------------|--------|
| {severity} | {file:line} | {original_claim} | {correct_info} | [source](URL) |

### Doc-Heavy PR Mode 検証状態（該当がある場合のみ）
<!-- 表示条件 (決定論的、OR で評価) — full mode template と同一内容:
 本セクションは以下の (a) または (b) のいずれかが成立する場合に表示する。両方とも成立しない場合は省略する:
 (a) doc_heavy_pr == true で ステップ 5.1.3 post-condition check が実行された場合
 (b) numstat_availability == "unavailable" の場合 (numstat 失敗の可視性のため、doc_heavy_pr の値に関係なく表示)

 非表示条件: 上記 (a) も (b) も成立しない場合 (= doc_heavy_pr == false かつ numstat_availability == "OK")
 → tech-writer が reviewer に存在するかどうかに関係なく省略する。tech-writer の存否は本セクションの
 表示判定に影響しない (本セクションは Doc-Heavy 機構と numstat 可用性の状態を可視化するためのものであり、
 tech-writer 単独のレビュー結果を表示するセクションではないため)。

 詳細: ステップ 5.1.3 末尾の「ステップ 5.4 表示責務の分離」段落を参照
 numstat 失敗時は numstat 可用性行に unavailable が表示される (Doc-Heavy 判定自体は ステップ 1.1 files 配列で完結するため skip されず通常通り実行される)
 verification mode template にも本セクションを含める (ステップ 5.1.3 は review_mode に依存しないため、
 verification mode + Doc-Heavy PR の組み合わせでも post-condition check は実行される)

 placeholder 展開ルール (undefined 参照防止、full mode template と同一):
 - {numstat_availability}: "OK" or "unavailable" (ステップ 1.2.6 で必ず explicit set される)
 - {numstat_fallback_reason}: success path では空文字列 ""、failure path では 1 行要約 (ステップ 1.2.6 で必ず explicit set される)
 - {doc_heavy_pr_value}: true / false (ステップ 1.2.7 Determination ブロックで explicit set される)
 - {doc_heavy_pr_decision_summary}: ステップ 1.2.7 の生成ルール (Determination ブロック直下のコメント) に従って生成された文字列
 - {doc_heavy_post_condition}: passed / warning / error (ステップ 5.1.3 で set される)
 - {cross_reference_skip_status}: "なし" or "あり" (ステップ 5.1.3 / Cross-Reference 検証で set される)
 - {acknowledgement_status}: "不要" / "取得済み" / "未取得" (ステップ 5.1.3 で partial_skip 発生時のみ set、それ以外は "不要") -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| numstat 可用性 | {numstat_availability} | {numstat_fallback_reason} |
| Doc-Heavy 判定 | {doc_heavy_pr_value} | {doc_heavy_pr_decision_summary} |
| Post-condition | {doc_heavy_post_condition} | passed / **warning** / **error** のいずれか |
| tech-writer finding 件数 | {doc_heavy_finding_count} | {0 件の場合は META negative confirmation の有無} |
| Evidence 欠落 finding | {evidence_missing_count} 件 | {evidence_missing_list を箇条書き} |
| Cross-Reference partial skip | {cross_reference_skip_status} | なし / **あり** ({cross_reference_skip_details — external repo 情報}) |
| ユーザー acknowledgement | {acknowledgement_status} | 不要 / **取得済み** / **未取得** (partial_skip あり時のみ記載) |

**影響**: `post-condition == warning` または `error`、もしくは `evidence_missing_count >= 1`、または `cross_reference_partial_skip == true` かつ acknowledgement 未取得の場合、総合評価は自動的に **`修正必要`** に昇格する。

### Verification Mode Post-Condition 検証状態（該当がある場合のみ）
<!-- 表示条件: review_mode == "verification" のときのみ表示。本 template は verification mode template なので常に表示対象。
 full mode template 側にも同一セクションが重複定義されている (drift 防止のため) -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| Verification post-condition | {verification_post_condition} | passed / **warning** / **error** (ステップ 5.1.1.1 の `### 修正検証結果` テーブル出力チェック結果) |
| Retry 回数サマリー | {verification_post_condition_retry_summary} | per-reviewer retry counter の集計 |

**影響**: `verification_post_condition == warning` または `error` の場合、該当 reviewer の指摘は全件 blocking 扱いとなり、総合評価は **`修正必要`** に昇格する。
ここでの「全件 blocking 扱い」は verification-mode / severity 軸での降格を禁止する意味であり、ステップ 5.3.0.M の実測必須ゲートは orthogonal に後段で適用される (`Verification:` アンカーを持たない指摘は non-blocking に分類され `total_findings` から外れる)。escalation は総合評価を昇格させるが sentinel routing は `total_findings` が確定させる (詳細は pr-review/SKILL.md ステップ 5.1.1.1 の「escalation の効力範囲」注記)。


### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}
- **所見**: {summary}

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| {severity} | {scope} | {file:line} | {description} | {recommendation} |

<!-- 各レビュアーの結果を繰り返し -->

### 推奨事項（該当がある場合のみ）
<!-- ステップ 5.1 で収集した recommendation_items (全 item、classification 必須) + ステップ 5.3.0 で降格された Hypothetical findings がある場合のみ表示。0件の場合はこのセクション自体を省略。

**aggregate label 禁止**: 本テーブルは各 item の分類を必ず明示する。「推奨 N 件」「follow-up 候補 N 件」のような件数のみの集計は本テーブルでも、PR コメント (ステップ 6.1.a) でも、result line (ステップ 8.1) でも禁止。ステップ 7.7 post-condition gate により aggregate label 単独報告は機械的に block される。 -->

| レビュアー | 分類 | 内容 | トリアージ対象 |
|-----------|------|------|:------------:|
| {reviewer_type} | {actionable / design_confirmation / boundary} | {recommendation_content} | {✅ if classification == actionable OR (boundary AND user approves), — otherwise} |


### Observed Likelihood 降格結果（該当がある場合のみ）
<!-- ステップ 5.3.0 Observed Likelihood Gate (Post-Reviewer Safety Net) で降格された finding がある場合のみ表示。0件の場合はこのセクション自体を省略。
 両 template (full mode / verification mode) で同一内容で同期すること (drift 防止) -->


| 元重要度 | 降格後 | ファイル:行 | 内容 | 降格理由 |
|---------|-------|------------|------|---------|
| {severity} | 推奨事項 / （削除） | {file:line} | {description} | Likelihood-Evidence marker 未提示 / LOW × Hypothetical は報告禁止 |

### 実測なし指摘 (non-blocking)（該当がある場合のみ）
<!-- ステップ 5.3.0.M 実測必須ゲートで non-blocking に分類された non_blocking_findings がある場合のみ表示。0件の場合はこのセクション自体を省略。
 blocking ではない (mergeable countdown 対象外)。severity は明示する (非実測 CRITICAL/HIGH の人間可視化)。
 記録先は 4 経路 (永続 JSON の non_blocking_findings[] / ステップ 6.1.d の PR 記録コメント / 本 section / E2E output line の件数 suffix) で破棄経路は存在しない。
 本 section は E2E でも省略禁止 (non_blocking_count > 0 のとき)。
 両 template (full mode / verification mode) で同一内容で同期すること (drift 防止) -->


| レビュアー | 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|-----------|--------|----------|------------|------|---------|
| {reviewer_type} | {severity} | {scope} | {file:line} | {description} | {suggestion} |

### 調査推奨（該当がある場合のみ）
<!-- ステップ 5.1 で収集した investigation_suggestions がある場合のみ表示。blocking ではない。0件の場合はこのセクション自体を省略。
 両 template (full mode / verification mode) で同一内容で同期すること (drift 防止)。
 column 構成は ステップ 4.5 reviewer template の「調査推奨」3 列 (ファイル / 気になる点 / 補足) に
 レビュアー列を追加した 4 列で、reviewer の notes が silent drop しないように揃えてある -->


| ファイル | 気になる点 | 補足 | レビュアー |
|---------|-----------|------|-----------|
| {file} | {concern_description} | {notes} | {reviewer_type} |

### Stability Concerns ({count} 件)
<!-- 未変更コードに対する新規 MEDIUM/LOW-MEDIUM/LOW 指摘。AI の非決定性による可能性あり。 -->
<!-- stability_concern が 0 件の場合はこのセクション自体を省略 -->

*未変更コードに対する新規指摘。AI の非決定性による可能性があります。対応は任意です。*

| 重要度 | ファイル:行 | 内容 | 備考 |
|--------|------------|------|------|
| {severity} | {file:line} | {description} | 前回未検出；コード未変更 |

---

### 次のステップ
{recommendation に応じた具体的アクション}

📎 reviewed_commit: {current_commit_sha}
```
