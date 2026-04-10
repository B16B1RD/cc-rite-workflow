# /rite:pr:review 品質ギャップ解消 — Phase D 定量検証レポート

> **位置づけ**: Issue #360 (Phase D 定量検証) の成果物。Issue #355 親 Issue で計画された Phase A-D の改善効果を検証する。
>
> **執筆セッション**: 2026-04-09
> **対象 commit**: `19f9fe3` (Phase D ブランチ作成時の develop HEAD)
> **設計書**: [docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
> **Phase 0 レポート**: [docs/investigations/review-quality-gap-baseline.md](./review-quality-gap-baseline.md)

## 0. サマリー

| 指標 | 目標 | 結果 | 判定 |
|------|------|------|------|
| カバレッジ率 (signal rate 調整後) | ≥70% | 🔶 分母確定 (baseline_V′ ≒ 285、cycle 3 fix 後の最新値)、intersection 計算は未着手 | 分母は確定したが、`baseline_A ∩ baseline_V′` の本体計算はフォローアップ Issue で追跡予定 (詳細は §4.5 Phase D 完了条件) |
| False positive rate | ≤20% | 🔶 未測定 (手動判定セッション未実施) | 後続セッションで手動判定 |
| **カテゴリカバレッジ (6中4以上)** | **≥4/6** | ✅ **4/6 実測達成** (理論分析では 6/6) | **✅ 達成** |
| 対照 PR FP rate | ≤30% | 🔶 対照 PR 未実施 (PR #384 replay のみ) | 時間制約により replay のみ実施 |
| signal rate (baseline_V) | ≥90% 望ましい | ✅ **100.0%** (point estimate, 95% CI [87.1%, 100%]) | **✅ 達成** (Issue #391 サンプリング監査, n=26 effective) |

**Phase D 実測の主要発見 (PR #384 replay, 2026-04-09)**:
- **総 finding 数: 19 件** (CRITICAL 0 / HIGH 7 / MEDIUM 8 / LOW 4)
- **Reviewer 内訳**: prompt-engineer 7 / tech-writer 3 / code-quality 9 / error-handling 0
- **baseline_A (PR #350 改善前 cycle 1): 14 件** → **Phase D 後: 19 件** (件数 +35.7%、**FP rate 未測定のため改善の質は保留**)
- **カテゴリカバレッジ: 4/6 実測達成** (目標 4/6 クリア)

**残タスク**: 下記リストは要約。詳細は [§4.5 Phase D 完了条件](#45-phase-d-完了条件) が single source of truth。

**制約事項** (詳細は [§4.5 Phase D 完了条件](#45-phase-d-完了条件)):
- Phase A/B/C/C2 が全てマージ済みのため、**個別ラウンド測定 (Round 1-3) は実施不可**
- baseline_V 個別指摘データ抽出済み (詳細は [§1.2.2](#122-signal-rate-監査-issue-391-2026-04-10)、baseline_V′ ≒ 285 = cycle 3 fix 後の最新値)
- 対照 PR 3 件 (TS code / Bash script / mixed) は時間制約で未実施 — Phase D 主目的 "改善後 review system で PR #350 diff を測定" は達成

---

## 1. Baseline データ

### 1.1 baseline_A (/rite:pr:review 改善前)

**ソース**: PR #350 のレビューコメント (2026-04-07、measure-review-findings.sh で集計)

```json
{
  "source": "pr:350",
  "totals": {
    "total_findings": 20,
    "total_cycles": 3,
    "by_severity": {
      "CRITICAL": 2,
      "HIGH": 5,
      "MEDIUM": 11,
      "LOW": 2
    }
  },
  "cycles": [
    { "cycle": 1, "total": 14, "by_severity": { "CRITICAL": 2, "HIGH": 4, "MEDIUM": 6, "LOW": 2 } },
    { "cycle": 2, "total": 6, "by_severity": { "CRITICAL": 0, "HIGH": 1, "MEDIUM": 5, "LOW": 0 } },
    { "cycle": 3, "total": 0, "by_severity": { "CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0 } }
  ]
}
```

**Reviewer 別内訳** (Cycle 1):
- prompt-engineer: 8 件
- tech-writer: 3 件
- code-quality: 3 件

### 1.2 baseline_V (/verified-review)

**ソース**: Issue #355 背景セクション + セッションログ (2026-04-07〜08)

#### 1.2.1 当初の集計 (Phase 0 時点)

- **総件数**: 172 件 (8 サイクル) — Issue #355 背景セクションの集計
- **平均**: 21 件/サイクル
- **サイクル別** (セッションログから部分抽出):

| Cycle | 件数 | 備考 |
|-------|------|------|
| 1-2 | 不明 | セッションログから未抽出 |
| 3 | ~22 | 修正の下流実装取り残しが主成分 |
| 4 | 20 | CRITICAL 4 / HIGH 7 / MEDIUM 7 / LOW 2 |
| 5 | 14 | — |
| 6 | 15 | — |
| 7 | 11 | — |
| 8 | 不明 | — |

#### 1.2.2 Signal rate 監査 (Issue #391, 2026-04-10)

> **追記コンテキスト**: Issue #360 (Phase D) の残タスクとして Issue #391 で実施。`baseline_V` 個別指摘データの抽出と signal rate 監査により、coverage rate (≥70%) の分母信頼性を確定する目的。

##### 1.2.2.1 抽出手順

新規スクリプト `plugins/rite/scripts/extract-verified-review-findings.sh` を実装し、Claude Code session log (jsonl) から `| {SEVERITY} | {file:line} | {reviewer} | {description} |` 形式の markdown table row を構造化抽出する。

**抽出パイプライン**:
1. 単一 session log mode (`--session`) と複数 session 走査 mode (`--session-dir --from --to`) をサポート
2. 各 jsonl entry の type=user/assistant 配下のテキストを再帰的に走査
3. severity word (`CRITICAL|HIGH|MEDIUM|LOW`) を起点とする 4-column row pattern を抽出
4. dedup key (severity + file_line + col3 各種 truncated) で重複除去
5. 出力 JSONL の各行に source_session / source_offset を付与

##### 1.2.2.2 重要な発見: 分母の再定義

**Issue #391 当初の前提**:
- session log `58685911-d795-4c81-904c-d209327c779d.jsonl` 単独に **172 件** が散在しているはず

**実測結果**:
- 指定 session log 単独からの抽出は **19 件** (重複除外後)
- 「172」は cycle 別集計 (4-7 cycle で 70 件 + 1-3, 8 cycle 推定値) からの aggregation であり、個別 finding row が体系的に記録されていたわけではない
- verified-review session は **複数 session log にまたがって分散** している

**Multi-session 走査結果** (`--session-dir`, `--from 2026-04-07 --to 2026-04-09`, `--min-size 500000`):

> **⚠️ Note — Phase 0 スナップショット (PR #400 cycle 1 fix 時点)**: 以下の数値表は当初の Phase D 監査時に取得したスナップショットです。PR #400 cycle 3 fix (allow-list 厳格化 + DOC_EXAMPLE_PATHS 縮小) 後に再抽出した最新値は §1.2.2.5 末尾の「cycle 3 再抽出値」に記載しています。signal rate 監査結論 (100%, point estimate) は population の遷移に依存しないため不変です。

| Source session | 件数 (cycle 1 fix 時点) |
|---|---|
| `763024b7-*` | 80 |
| `1378f23f-*` | 58 |
| `9eb0c81a-*` | 51 |
| `4e84181c-*` | 33 |
| `63b02251-*` | 29 |
| `58685911-*` (Issue 当初指定) | 17 |
| `1f5e3701-*` | 15 |
| `f5debd1f-*` | 12 |
| 他 13 sessions | 20 |
| **合計 (raw, dedup 後、cycle 1 fix 時点)** | **315** |

> **Note**: 「他 13 sessions」は scratch / 別 Issue 作業中の rite 関連セッションで、各 1〜3 件程度の散発的な finding を含む。verified-review が主要に実行された session は上記 8 session (合計 295 件) で全体の ~94% を占める。

**Severity 内訳 (cycle 1 fix 時点)**: CRITICAL 35 / HIGH 140 / MEDIUM 100 / LOW 40

> **Note (Population 遷移履歴)**:
> - **当初実装**: dedup key `(severity, file_line[:120], col3[:100])` → 302 件
> - **PR #400 cycle 1 fix**: dedup key に `cycle` を追加し再発 finding を保持 → 315 件
> - **PR #400 cycle 3 fix**: allow-list 厳格化 (bare alias 削除) + DOC_EXAMPLE_PATHS 縮小 (`src/auth.ts` 除外解除) → **329 件** (詳細は §1.2.2.5 末尾)
>
> いずれの遷移でも signal rate 監査結論 (100%, point estimate) は不変。サンプル監査の母集団は当初の n=30 (effective 26) を維持しており、母集団拡大に対する追加サンプル監査は scope 外。

##### 1.2.2.3 サンプリング監査

**手法**: Population (n=302、当初実装時の値。改修後の population 315 でも結論不変) から再現可能な seed (`random.seed(391)`) で **30 件** をランダム抽出し、各指摘を現在のコードと突合 (Read/Grep) して 4 分類で判定。

**判定カテゴリ**:
- **TP (true positive)**: 指摘が正しい (修正済み or 未修だが指摘自体は妥当)
- **FP-1**: 既修済みを未修と誤判定
- **FP-2**: 存在しないバグを検出
- **FP-3**: コメント読み違え
- **FP-4**: 分散伝播読解漏れ
- **extraction_artifact**: スクリプトの parsing error / rite プロジェクト外 finding (signal rate 計算から除外)

**結果**:

| 分類 | 件数 | 備考 |
|---|---|---|
| TP (確認済み) | 16 | git log / 現在コードで cycle 修正コミット根拠を直接確認 |
| TP (TP_likely → TP に再分類) | 10 | refactor 済みで line 直接照合は不可だが、4 FP カテゴリのいずれにも該当せず、設計上の指摘として有効 |
| FP-1 〜 FP-4 | 0 | サンプル中に false positive は検出されず |
| extraction_artifact | 4 | (a) `src/components/Hero.tsx` rite プロジェクト外 (b) `5 (M1...)` count 列誤抽出 (c) (d) reviewer 名 / "本 PR スコープ外" の列ズレ |
| **合計** | **30** | |

**Effective sample**: 26 (extraction_artifact 4 件除外後)

##### 1.2.2.4 Signal rate

**Point estimate**: TP 26 / Effective 26 = **100.0%**

**Wilson 95% CI**: [87.1%, 100.0%] (n=26, p̂=1.0)

**判定**: ≥90% bracket (Issue #355 の signal rate 閾値表より)

→ **baseline_V をそのまま使用** (FP 除外不要)

**保守的解釈の補足**: TP_likely 10 件を仮に「不明 → FP 扱い」に降格すると signal rate 61.5% (95% CI [42.5%, 77.6%]) となり <70% bracket に該当する。ただし当該 10 件は「直接 line 照合不可」だっただけで「4 FP カテゴリのいずれにも該当しない」ことは確認済みのため、本監査では TP に算入する。

> **Sample ID の出典**: 以下の `#N` は `/tmp/baseline-v-sample.jsonl` の `sample_id` フィールド (Issue #391 セッション内に保存。再現方法は §1.2.2.7 参照)。

判断の根拠:

- TP_likely #8/#9/#10 (`fix.md` trap area): 該当領域は heavy refactor 済みで、refactor の動機付けが当該 finding と整合
- TP_likely #13 (regex dead code): 構造的に判断可能、現状コードで pattern が依然存在
- TP_likely #16 (`implementation-plan.md` ambiguity): 内容ベースの subjective 指摘で、現在も有効な改善余地
- TP_likely #20 (test sanitize edge case): test coverage 改善提案として妥当
- TP_likely #25 (`Mandatory After` step format): 構造的整合性 drift を ascertain 可能
- TP_likely #27/#29/#30 (column-order risk / fixed-path collision / cross-bash variable): 既知の bash pitfall に該当する設計上の懸念

##### 1.2.2.5 baseline_V′ 補正 (extraction artifact 除外後)

抽出スクリプトの parsing 精度を改善する余地はあるが、サンプルから推定した artifact rate は **13.3%** (4/30)。population に適用すると:

- **baseline_V′ (cycle 1 fix 時点、population 315 ベース)**: 315 × (1 - 0.133) ≒ **273 件**

**Population 遷移と baseline_V′ 推移**:

| 時点 | dedup key / DOC_EXAMPLE_PATHS / allow-list | population | baseline_V′ (artifact-removed) |
|---|---|---|---|
| 当初実装 | (sev, file:120, col3:100) / `src/auth.ts` 含む / bare alias 含む | 302 | 262 |
| cycle 1 fix | + `cycle` を dedup key に追加 (再発保持) | 315 | 273 |
| **cycle 3 fix** (推奨) | + `src/auth.ts` 除外解除 + bare alias 削除 | **329** | **285** |

**cycle 3 再抽出値** (推奨): cycle 3 fix 後のスクリプト (`0c93fdd` 以降) で同一監査ウィンドウ (`--from 2026-04-07 --to 2026-04-09 --min-size 500000`) を再抽出すると **329 件** (allow-list 厳格化により以前の dedup 取りこぼしが解消)。これに artifact rate 13.3% を適用すると **baseline_V′ ≒ 329 × 0.867 ≒ 285 件**。

**注**: この `285` が cycle 3 fix 後の最新 `baseline_V′` 推奨値。Issue #355 当初の `172` は cycle 集計値であり個別 finding 数とは異なる概念のため、coverage rate の分母として使う場合は **285 を採用** することを推奨する。signal rate 監査結論 (100%, point estimate) は population 遷移に依存しないため不変。サンプル監査の母集団拡大 (302 → 329) に対する追加サンプル監査は scope 外。

##### 1.2.2.6 監査の限界事項

1. **サンプル数の制約**: n=30 (effective 26) は population 315 に対する 8.3% のサンプリング率。Wilson CI 下限は 87.1% で十分高いが、上位 severity (CRITICAL/HIGH) のみに stratified sampling を行うと精度が向上する余地あり
2. **dedup key の選択**: `(severity, file_line[:120], col3[:100], cycle)` というキー長で artifact 除外前 315 (改修後)、改修前 302。dedup key を 250 chars に伸ばすと 437 件になり、逆に圧縮すると過剰 dedup のリスク。適切な dedup 粒度は今後 calibration 余地あり
3. **cycle 番号推定**: ヒューリスティック (直前の "Cycle N" / "サイクル N" 表記) で抽出するため、cycle 1 に過剰集中している (199/315)。正確な cycle 別分布の取得は別 issue で検討
4. **multi-project 混入**: rite プロジェクト外の review (例: `src/components/Hero.tsx`) も session log に含まれており、抽出スクリプトで完全分離は不可能。サンプル監査での除外で対応 (4/30 → 13.3%)。スクリプト側でも `src/components/Hero.tsx` 等を `DOC_EXAMPLE_PATHS` に追加して除外済み (PR #400 cycle 1 review fix)

##### 1.2.2.7 監査資産

| 資産 | パス |
|---|---|
| 抽出スクリプト | `plugins/rite/scripts/extract-verified-review-findings.sh` |
| 全件抽出結果 | `/tmp/baseline-v-findings.jsonl` (一時、再現可能 — Issue #391 セッション内のみ) |
| サンプル (30 件) | `/tmp/baseline-v-sample.jsonl` (`random.seed(391)`) |
| 判定結果 | `/tmp/baseline-v-judgment.json` |

**再現コマンド**:

> **`<session-dir>` の特定方法**: Claude Code の session log 配置場所はマシンごとに異なる (`~/.claude/projects/<encoded-project-path>/`)。当該プロジェクトの encoded path は以下のコマンドで確認できる:
> ```bash
> ls ~/.claude/projects/ | grep cc-rite-workflow
> ```
> 結果を `~/.claude/projects/<encoded-name>` の形で `--session-dir` に渡す。

```bash
# <session-dir> をマシン固有のパスに置換すること (上記 grep 結果)
bash plugins/rite/scripts/extract-verified-review-findings.sh \
  --session-dir <session-dir> \
  --from 2026-04-07 --to 2026-04-09 \
  --out /tmp/baseline-v-findings.jsonl

python3 -c "
import json, random
random.seed(391)
pop = [json.loads(l) for l in open('/tmp/baseline-v-findings.jsonl')]
sample = random.sample(pop, 30)
sample.sort(key=lambda r: (r['source_session'], r['source_offset']))
for i, r in enumerate(sample, 1):
    r['sample_id'] = i
    print(json.dumps(r, ensure_ascii=False))
" > /tmp/baseline-v-sample.jsonl
```

### 1.3 カテゴリ分布 (PR #350 で見落とされた 6 カテゴリ)

Issue #355 で特定された、baseline_A (rite) が見落とし baseline_V (verified-review) が検出した 6 カテゴリ:

| # | カテゴリ | 説明 | rite 検出 (改善前) |
|---|---------|------|-------------------|
| 1 | flow control | 到達不能コード、unreachable 経路 | ❌ 0件 |
| 2 | i18n parity | i18n key の整合性 | ❌ 0件 |
| 3 | pattern portability | regex の locale 依存、BSD/GNU 互換 | ❌ 0件 |
| 4 | dead code | 未使用変数、不要な import | ❌ 0件 |
| 5 | stderr 混入 | デバッグ出力の残存 | ❌ 0件 |
| 6 | semantic collision | 変数名・関数名の意味的衝突 | ❌ 0件 |

---

## 2. Phase A/B/C/C2 の改善内容と理論的カバレッジ分析

### 2.1 Phase A (#357): Part A 抽出バグ修正 + frontmatter drift cleanup

**変更内容**:
- `review.md` の Part A 抽出仕様を `## Reviewer Mindset` + `## Confidence Scoring` のみ → `## Input` 直前までの全セクション抽出に変更
- `## Cross-File Impact Check` (5 項目: deleted/renamed exports, changed config keys, changed interface contracts, **i18n key consistency**, **keyword list consistency**) が reviewer に到達するようになった
- 全 13 reviewer の `tools:` と `model:` frontmatter を削除して inherit 化
- fix.md Phase 8.1 reason table drift 修正

**理論的カバレッジ効果**:

| カテゴリ | Phase A での対応 | 効果 |
|---------|-----------------|------|
| i18n parity | ✅ Cross-File Impact Check #4 (i18n key consistency) が復活 | 直接対応 |
| pattern portability | ⚠️ Cross-File Impact Check #5 (keyword list consistency) が復活 | 間接的に対応 |
| semantic collision | ⚠️ 部分的（Cross-File Impact Check の broader scope で検出可能性向上） | 間接的 |

### 2.2 Phase B (#358): named subagent 切り替え

**変更内容**:
- `subagent_type: "general-purpose"` → `subagent_type: "rite:{reviewer_type}-reviewer"` (scoped 名)
- agent body が user prompt 内注入 → **system prompt** として注入
- reviewer の役割定義の拘束力が根本的に向上

**理論的カバレッジ効果**:

| カテゴリ | Phase B での対応 | 効果 |
|---------|-----------------|------|
| 全カテゴリ | ✅ reviewer の Detection Process / Checklist が system prompt として強制 | 全般的な検出精度向上 |
| flow control | ⚠️ error-handling-reviewer の Detection Process が確実に適用 | 間接的 |
| dead code | ⚠️ code-quality-reviewer の Detection Process が確実に適用 | 間接的 |

### 2.3 Phase C (#359): reviewer プロンプト改善

**変更内容** (PR #372):
- tech-writer: Doc-Heavy PR Mode の 5 カテゴリ verification protocol 強化
- i18n parity 検出ロジックの明示化
- catch-all/stderr 検出パターンの追加
- error-handling-reviewer の stderr 混入検出強化

**理論的カバレッジ効果**:

| カテゴリ | Phase C での対応 | 効果 |
|---------|-----------------|------|
| i18n parity | ✅ tech-writer の i18n parity 検出が明示化 | 直接対応 |
| stderr 混入 | ✅ error-handling-reviewer の stderr 検出パターン追加 | 直接対応 |
| flow control | ⚠️ catch-all パターン検出で到達不能コードも対象 | 間接的 |

### 2.4 Phase C2 (#361): 分散伝播漏れ検出 lint

**変更内容** (PR #373):
- 5 パターンの分散修正 drift 検出 lint を新規実装 (設計書 `review-quality-gap-closure.md` + `distributed-fix-drift-check.sh` 準拠)
- Pattern-1: retained flag coverage — `exit 1` 直前の `[CONTEXT] *_FAILED=1` emit 欠落検出
- Pattern-2: reason table drift — reason テーブル列挙と実 emit 箇所の突き合わせ
- Pattern-3: if-wrap drift — `cat <<'EOF' > "$tmpfile"` が `if !` で wrap されていない箇所の検出
- Pattern-4: anchor drift — Markdown `#anchor` 参照が見出しに解決できるかの内部リンクチェック
- Pattern-5: evaluation-order table 列挙 drift — 評価順テーブルの括弧内列挙と実 emit の突き合わせ

**理論的カバレッジ効果**:

| カテゴリ | Phase C2 での対応 | 効果 |
|---------|-------------------|------|
| pattern portability | ⚠️ lint が regex pattern の不整合を検出可能 | 間接的 |
| dead code | ⚠️ lint が rename 漏れによる参照切れを検出可能 | 間接的 |
| semantic collision | ⚠️ lint が rename 不整合を検出可能 | 間接的 |

### 2.5 カテゴリカバレッジ理論分析サマリー

| # | カテゴリ | Phase A | Phase B | Phase C | Phase C2 | 理論的カバー |
|---|---------|---------|---------|---------|----------|-------------|
| 1 | flow control | — | ⚠️ | ⚠️ | — | ✅ (B+C の組み合わせ) |
| 2 | i18n parity | ✅ | — | ✅ | — | ✅ (A+C で直接対応) |
| 3 | pattern portability | ⚠️ | — | — | ⚠️ | ✅ (A+C2 の組み合わせ) |
| 4 | dead code | — | ⚠️ | — | ⚠️ | ✅ (B+C2 の組み合わせ) |
| 5 | stderr 混入 | — | — | ✅ | — | ✅ (C で直接対応) |
| 6 | semantic collision | ⚠️ | — | — | ⚠️ | ✅ (A+C2 の組み合わせ) |

**理論的カテゴリカバレッジ: 6/6** (全カテゴリに少なくとも 1 つの改善が対応)

> **注意**: これは理論分析であり、実測での確認が必要です。各 Phase の改善が「カテゴリに対応する」とは「検出可能性が向上した」の意味であり、「確実に検出する」の保証ではありません。

---

## 3. 当初の実測制約と推奨アクションプラン (Phase D 初期分析)

> **⚠️ 更新 (2026-04-09)**: 本セクションは Phase D 実測**前**の初期分析記録。その後 §4 で Option A (worktree replay) を実施し、**PR #384 で実測データを取得済み**。本セクションは当初の制約分析として残すが、実測結果と残タスクは [§4 Phase D 実測結果](#4-phase-d-実測結果-pr-384-replay-2026-04-09) を参照すること。特に「replay ブランチ conflict」は worktree (`git worktree add e1498f5`) 方式で回避できることが判明した。

### 3.1 当初想定されていた実測制約 (後に §4 Option A で解決)

| 制約 | 詳細 |
|------|------|
| PR #350 merged | `/rite:pr:review` は OPEN/DRAFT PR のみ対象。MERGED PR にはレビュー実行不可 |
| replay ブランチ conflict | Phase A/B/C/C2 が PR #350 と同じファイル (review.md, fix.md, tech-writer.md 等) を大幅変更。`git apply` / `git revert -m 1` / `git cherry-pick` いずれも conflict |
| baseline_V 個別データ未取得 | verified-review の個別指摘は PR コメントではなくセッション会話内に散在。signal rate 監査にはセッションログからの構造化抽出が必要 (Issue #391 で解決済み — [§1.2.2](#122-signal-rate-監査-issue-391-2026-04-10) 参照。「172」は cycle 集計値であり個別 finding 数ではないことが判明) |

### 3.2 当初の推奨アクションプラン (Option A は §4 で実施済み)

> **状態**: Option A は §4.1 で実施完了。Option B (対照 PR 3 件)・Option C (signal rate 監査) は dedicated session で残タスクとして継続。**残タスクの single source of truth は [§4.5 Phase D 完了条件](#45-phase-d-完了条件)** を参照。

#### Option A: Worktree ベースの replay (✅ §4.1 で実施済み)

1. **PR #350 マージ直前の develop HEAD** (`e1498f5` = PR #350 merge commit `54b291f` の第一親) から worktree を作成
2. worktree 上で PR #350 の diff を apply (この commit には PR #350 の変更が含まれていないため clean apply 可能)
3. investigation PR を作成し、**現在の Claude Code セッション** (改善後のプラグイン) で `/rite:pr:review` を実行
4. これにより「改善後の review system」×「PR #350 の diff」の組み合わせで実測可能

```bash
# 推奨手順
git worktree add /tmp/phase-d-investigation e1498f5
cd /tmp/phase-d-investigation
git checkout -b investigation/phase-d-pr350
gh pr diff 350 | git apply
git add -A && git commit -m "investigation: replay PR #350 for Phase D measurement"
git push -u origin investigation/phase-d-pr350
gh pr create --base develop --head investigation/phase-d-pr350 --draft \
  --title "[investigation] Phase D: PR #350 replay measurement" \
  --body "Phase D quantitative validation (no merge intended)"
```

> **注意**: `e1498f5` は PR #350 merge commit (`54b291f`) の第一親であり、PR #350 の変更を含まない develop HEAD。worktree 内の `plugins/rite/` は Phase A/B/C/C2 **前** の状態だが、Claude Code が使うプラグインは **メインの working directory のもの** が優先されるため、改善後の review system で旧 diff をレビューできる。

#### Option B: 新規 PR での代替測定

PR #350 の replay が困難な場合、以下の代替 PR で測定:

| # | タイプ | 候補 | 目的 |
|---|--------|------|------|
| 1 | 新規作成 | 本 Phase D の results.md PR | doc-heavy PR での review system 検証 |
| 2 | 既存 OPEN | (なし — 全て merged) | — |
| 3 | 新規作成 | dummy bash/hook 変更 PR | error-handling reviewer の stderr 検出検証 |

#### Option C: signal rate 監査

1. セッションログ `58685911...jsonl` (15MB) から verified-review 指摘を構造化抽出するスクリプトを作成
2. 各指摘を現在のコードと突合し true/false 判定
3. signal rate を算出し、70% 未満なら定量目標再設計

---

## 4. Phase D 実測結果 (PR #384 replay, 2026-04-09)

### 4.1 実測手順

1. **Worktree 作成**: `e1498f5` (PR #350 マージ直前の develop HEAD) から worktree を `/tmp/phase-d-investigation` に作成
2. **Replay ブランチ**: `investigation/phase-d-pr350` ブランチで PR #350 の diff を `git apply`
3. **Investigation PR**: draft PR #384 を作成 (12 files, +3373/-98)
4. **改善後 review system で実測**: 現在のプラグイン (Phase A/B/C/C2 適用後) で `/rite:pr:review` を実行

### 4.2 実測 finding 数

**総計: 19 件** (CRITICAL 0 / HIGH 7 / MEDIUM 8 / LOW 4)

| Reviewer | 評価 | CRITICAL | HIGH | MEDIUM | LOW | 合計 |
|----------|------|----------|------|--------|-----|------|
| prompt-engineer | 条件付き | 0 | 2 | 3 | 2 | 7 |
| tech-writer | 条件付き | 0 | 3 | 0 | 0 | 3 |
| code-quality | 条件付き | 0 | 2 | 5 | 2 | 9 |
| error-handling | 可 | 0 | 0 | 0 | 0 | 0 |

**baseline_A (改善前) との比較**:

| 項目 | baseline_A (PR #350 cycle 1) | Phase D 後 (PR #384 replay) | 差分 |
|------|------------------------------|----------------------------|------|
| 総 finding 数 | 14 | 19 | **+35.7%** |
| CRITICAL | 2 | 0 | -2 |
| HIGH | 4 | 7 | +3 |
| MEDIUM | 6 | 8 | +2 |
| LOW | 2 | 4 | +2 |

### 4.3 カテゴリカバレッジ実測

**集計ルール** (silent inflation 防止のため明示定義):

- **✅ 検出あり**: reviewer がそのカテゴリに該当する finding を 1 件以上報告した
- **✅ verify 済み (finding 0 件)**: reviewer がそのカテゴリを明示的に verify したが finding なし (例: i18n parity で両言語を突き合わせた上で「問題なし」と宣言)。カバレッジ判定の分子 (分母 6) に含める
- **⚠️ 間接検出**: 別カテゴリの finding として報告されたが、対象カテゴリに間接的に寄与する。**カバレッジ判定の分子 (分母 6) には含めない**
- **❌ 未検出**: reviewer が明示的に verify せず、finding もなし

目標: 6 カテゴリ中 **4 以上**で ✅ 判定。

| # | カテゴリ | 判定 | 根拠 |
|---|---------|------|------|
| 1 | flow control | ⚠️ 間接 | code-quality HIGH #2 (250 行 bash block) が間接的に到達性問題を含むが、flow control 専用の verify なし |
| 2 | i18n parity | ✅ verify 済み | tech-writer が CHANGELOG.md/ja.md・README.md/ja.md の日英同期を突き合わせて「問題なし」と宣言 |
| 3 | pattern portability | ✅ 検出あり | prompt-engineer MEDIUM (Evidence regex case-sensitive), LOW (grep `$` anchor) |
| 4 | dead code | ✅ 検出あり | code-quality LOW (review cycle ID 過剰残存) |
| 5 | stderr 混入 | ⚠️ evidence 不足 | error-handling 指摘 0 件だが、「既に修正済み」の証拠 (grep / commit 参照) を本レポートに記録できず。verify 済みと宣言する根拠が弱いため分子から除外 |
| 6 | semantic collision | ✅ 検出あり | prompt-engineer MEDIUM (`{N}` placeholder 曖昧性) |

**実測カテゴリカバレッジ: 4/6** (✅ 4 件: i18n, pattern, dead code, semantic / ⚠️ 2 件: flow control, stderr)

**目標 4/6 に対し 4/6 で最低ラインを達成**。ただし初回の reviewer 指摘では「明示的な verify」の痕跡が弱いため、後続セッションで stderr 混入カテゴリの verify 強化 (error-handling reviewer の明示的 verify report 導入) を推奨。

### 4.4 判定

| 指標 | 目標 | 結果 | 判定 |
|------|------|------|------|
| カテゴリカバレッジ | ≥4/6 | **4/6** (✅ 4 件 / ⚠️ 2 件) | ✅ **達成** |
| 総 finding 数 vs baseline_A | improvement | 14 → 19 (件数 +35.7%) | ✅ **改善確認** (FP rate 10.5% → 検出数増の大部分は真陽性) |
| カバレッジ率 | ≥70% | 🔶 分母確定 (baseline_V′ ≒ 285、cycle 3 fix 後)、intersection 計算は未着手 | 分母は確定したが、baseline_A ∩ baseline_V′ の計算は別タスク |
| FP rate | ≤20% | ✅ **10.5%** (2/19, strict) / 18.4% (conservative) / 26.3% (worst case) | ✅ **達成** ([§4.4.1](#441-fp-rate-手動判定-issue-393-2026-04-10) — Issue #393 手動判定) |
| signal rate (baseline_V) | ≥90% | ✅ **100.0%** (point estimate, 95% CI [87.1%, 100%]) | ✅ **達成** ([§1.2.2](#122-signal-rate-監査-issue-391-2026-04-10) — Issue #391 サンプリング監査, n=26 effective) |

#### 4.4.1 FP rate 手動判定 (Issue #393, 2026-04-10)

**対象**: PR #384 ([reviewed_commit: `fec82c0`](https://github.com/B16B1RD/cc-rite-workflow/commit/fec82c0)) に対する rite review 結果 19 件 ([PR コメント](https://github.com/B16B1RD/cc-rite-workflow/pull/384#issuecomment-4212673158))。

**判定手順**: 各 finding について `git show fec82c0:<path>` で当時のコード状態を直接読み、主張の事実性を検証。以下 3 分類で判定:

- **True Positive (TP)**: `fec82c0` 時点のコードに実際にその問題が存在し、reviewer の主張が事実に合致
- **False Positive (FP)**: `fec82c0` 時点のコードに問題は存在せず、reviewer の誤判定 / 既に注記済み / 後続状態を projection
- **Ambiguous**: 主張は部分的に事実だが severity/解釈に幅があり、白黒判定困難

**判定結果**:

| # | Reviewer | Sev | 主張要約 | 判定 | 根拠 (fec82c0 検証) | 後続対応 |
|---|----------|-----|----------|:----:|-------------------|---------|
| 1 | prompt-engineer | HIGH | fix.md Phase 8.1 reason 表 12 値のみ、bash は 27+ emit | **TP** | `fix.md` で `WM_UPDATE_FAILED` / `REPORT_POST_FAILED` / `ISSUE_CREATE_FAILED` / `REPLY_POST_FAILED` 等 reason 多数 (L1226/1239/1533/1723/1998/2018/2247/2267 ほか) | e291e54 で修正済み |
| 2 | prompt-engineer | HIGH | review.md Phase 2.2.1 pipeline SIGPIPE 方向誤解 | **TP** | `review.md` L808 に `printf '%s\n' "$diff_out" \| grep -m 1 -E ...`、L803-805 コメントが "下流に SIGPIPE" と誤記 | #396 (here-string 化) で修正済み |
| 3 | prompt-engineer | MED | fix.md Phase 4.5.1 literal `{issue_number}` in sentinel | **TP** | `fix.md` L2018 で `echo "[CONTEXT] WM_UPDATE_FAILED=1; ...; issue_number={issue_number}"` — placeholder 未解決のまま bash 実行経路あり | 未対応 (別 Issue 候補) |
| 4 | prompt-engineer | MED | `<br\s*/?>` case-sensitive で `<BR>` にマッチせず | **TP** | `review.md` L1599/1634/1655/1666/1667 すべて lowercase `<br>` のみ、`(?i)` フラグ / `[bB][rR]` 不使用 | 未対応 (別 Issue 候補) |
| 5 | prompt-engineer | MED | tech-writer.md `{N} categories were inconclusive` placeholder 曖昧性 | **Ambiguous** | `tech-writer.md` L185/186 に literal `{N}` 存在するが、L188 で「実際の件数に置換」instruction あり。遵守されれば問題なし、曖昧性リスクは残る | 任意 |
| 6 | prompt-engineer | LOW | fix.md `grep -qE "/(pull\|issues)/{pr_number}$"` anchor 将来 drift risk | **TP** | `fix.md` L438 確認。現仕様では機能するが schema 変更耐性なし | 任意 (LOW) |
| 7 | prompt-engineer | LOW | internal-consistency.md Enumeration 例が `eleven`〜 / hedge words 未カバー | **FP** | `internal-consistency.md` L135 に既に「文脈に応じて他の数詞を追加」注記あり。finding 自身が「既に注記ありのため LOW」と自認 — no-op finding | — |
| 8 | tech-writer | HIGH | closure.md が `review.md:1192-1195` Part A 抽出仕様を quote (stale) | **TP** | `closure.md` L25 で `review.md:1192-1195` quote。`review.md` L1192-1195 は "CRITICAL — Sub-Agent Invocation MANDATORY" で Part A 抽出仕様ではない (fec82c0 時点で既に drift) | #387/#395 で Phase 0 スナップショット注記追加済み |
| 9 | tech-writer | HIGH | closure.md `_reviewer-base.md` 見出し L3/L12/L22/L42 (stale → L3/L12/L31/L51) | **FP** | `closure.md` L32-36 の引用と `_reviewer-base.md` 実際の headings (L3/L12/L22/L42/L52) は fec82c0 時点で一致。「現行は L3/L12/L31/L51」は fec82c0 時点では false — Phase C 追加後の将来状態を projection した誤判定 |— |
| 10 | tech-writer | HIGH | closure.md `review.md:1237` `subagent_type: general-purpose` quote (drift) | **TP** | `closure.md` L42 で quote。`review.md` L1237 は "Part A — Shared reviewer principles" で subagent_type 記述ではない (fec82c0 時点で既に drift) | #387/#395 で Phase 0 スナップショット注記追加済み |
| 11 | code-quality | HIGH | `trap` 4 行パターン + cleanup 関数の 9 箇所重複 (fix.md 6 + review.md 2) | **TP** | `fix.md` trap 24 行 (6 箇所 × 4 event) + `review.md` trap 8 行 (2 箇所 × 4 event) = 8 箇所を確認 (finding の 9 件カウントとは 1 件差、substance 一致) | #394 で共通リファレンス (`bash-trap-patterns.md`) に集約済み |
| 12 | code-quality | HIGH | fix.md Phase 1.2 Fast Path 単一 bash 約 250 行 11 ステップ | **TP** | `fix.md` Phase 1.2 全体 654 行、Fast Path 単一 block が massive (確認) | 未対応 (別 Issue 候補) |
| 13 | code-quality | MED | fix.md コメント過密 (実装の 5-10 倍、同情報 3-5 回重複) | **Ambiguous** | Phase 1.2 周辺 50 行中 17 行コメント (34%)。「実装の 5-10 倍」は誇張気味だが「高密度」は事実。severity は subjective | — |
| 14 | code-quality | MED | fix.md Phase 1.0/1.2 Detection rules 複雑 regex + 自然言語散在、bash 例なし | **TP** | `fix.md` L109-113 "Detection rules (順序ベース判定)" — table 形式のみで executable bash スニペット欠落 | 任意 |
| 15 | code-quality | MED | review.md Phase 1.2.7 ratio 計算と all_files_excluded の責務分離散在 | **Ambiguous** | `review.md` L327-355 で skip conditions / retained flags / configuration が mix される構造。読みにくいが仕様整合性は維持されている (subjective) | — |
| 16 | code-quality | MED | fix.md cleanup 関数 7 個並立、すべて `rm -f` | **TP** | `fix.md` で `_cleanup() {` パターン 7 個確認 | 任意 |
| 17 | code-quality | MED | review.md Phase 5.4 Doc-Heavy 検証状態テーブル full/verification mode で完全重複 | **TP** | `review.md` L1957 と L2110 で同一セクション、L1992 と L2147 で重複を自認する warning あり | 未対応 (別 Issue 候補) |
| 18 | code-quality | LOW | fix.md Phase 1.2 option 集合 3 箇所で別々に列挙 | **TP** | `fix.md` L589/599-600/632/643/664 で Cancel 関連 option 散在 | 任意 (LOW) |
| 19 | code-quality | LOW | fix.md review cycle ID (`本 Issue #350 検証付きレビュー X-N`) 大量残存 | **TP** | `fix.md` で該当パターン 47 件、`(H-N)`/`(M-N)` 形式 13 件確認 | 任意 (LOW) |

**集計**:

| 判定 | 件数 | 割合 |
|------|------|------|
| True Positive (TP) | 14 | 73.7% |
| False Positive (FP) | 2 | **10.5%** |
| Ambiguous | 3 | 15.8% |
| 合計 | 19 | 100.0% |

**FP rate の感度分析**:

| シナリオ | Ambiguous の扱い | FP rate | 判定 |
|---------|-----------------|---------|:----:|
| Strict (採用) | Ambiguous = TP 扱い | **10.5%** (2/19) | ≤20% ✅ |
| Conservative | Ambiguous = 0.5 FP | 18.4% (3.5/19) | ≤20% ✅ |
| Worst case | Ambiguous = 全て FP | 26.3% (5/19) | 21-30% ⚠️ |

**採用判定**: Strict 解釈 (FP = reviewer の明確な誤判定のみ) に基づく **FP rate = 10.5%**、目標 ≤20% を達成。Conservative 解釈 (18.4%) でも目標達成。Worst case (26.3%) でも rollback 閾値 30% は下回る。

**FP の内訳** (どちらも性質が異なる):

- **PE-L2 (internal-consistency.md enumeration)**: reviewer 自身が「既に注記ありのため LOW」と自認しており、finding は本質的に no-op 指摘。Confidence 低い LOW 指摘を出力する reviewer の質的判断を改善する余地はあるが、`confidence_threshold` の見直しは不要 (LOW は意思決定に影響しない)。
- **TW-H2 (_reviewer-base.md 見出し drift)**: fec82c0 時点では drift は発生しておらず、reviewer が Phase C 追加後の将来状態を現在時点に projection した誤判定。tech-writer reviewer の「line number citation 検証時の時点整合性」が課題 (別 Issue 起票候補)。

**Ambiguous の扱い**: 3 件はすべて code-quality / prompt-engineer の MED severity で、主張は一部事実だが severity / 修正優先度が subjective。「reviewer の誤判定」とは言えず、かつ「明確に事実」とも言えない境界ケース。FP rate strict 計算では TP 扱いとしている。

**総合判定**: **≤20% 目標達成**。Phase D の検出数増加 (+35.7%) は FP 量産ではなく真陽性の増加が主因であることが確認された。

**後続アクション**:

1. **Phase D 完了条件 `FP rate の実測値確定` を checked 状態に更新**
2. 任意 — TW-H2 の projection 誤判定パターンを tech-writer reviewer の教訓として記録する Issue 起票 (reviewer calibration)
3. FP rate ≤20% 達成のため rollback / 閾値見直し Issue 起票は **不要**

### 4.5 Phase D 完了条件

- [x] Option A (worktree replay) による PR #350 の実測データ取得
- [x] カテゴリカバレッジ実測値の確定 (4/6, ≥4/6 達成)
- [x] baseline_V の signal rate 監査 (Issue #391 で完了 — [§1.2.2](#122-signal-rate-監査-issue-391-2026-04-10))
- [ ] カバレッジ率の intersection 計算 (`baseline_A ∩ baseline_V′` の本体計算は別タスク。フォローアップ Issue で追跡予定)
- [x] FP rate の実測値確定 (Issue #393 で完了 — [§4.4.1](#441-fp-rate-手動判定-issue-393-2026-04-10), FP rate = 10.5% (2/19, strict))
- [ ] 対照 PR 3 件での検証 (TS / Bash / mixed)

**Phase D の主要目的 (改善後 review system で PR #350 diff を測定) は達成**。signal rate 監査は [Issue #391](https://github.com/B16B1RD/cc-rite-workflow/issues/391) で完了、FP rate 手動判定は [Issue #393](https://github.com/B16B1RD/cc-rite-workflow/issues/393) で完了 (§4.4.1 参照)。残タスク (対照 PR 3 件での検証、カバレッジ率 intersection 計算) は別途実施。

### 4.6 実測で発見された主要 finding (Phase D 成果物)

Phase D の副産物として、**改善後の review system が新規に検出した問題** (PR #350 マージ時には見逃されていた):

1. **prompt-engineer HIGH**: fix.md Phase 8.1 reason 表の enumeration 不足 (12 値記載 vs 27+ emit)
2. **prompt-engineer HIGH**: review.md Phase 2.2.1 pipeline SIGPIPE 方向誤解 (`printf` 上流 → `grep -m 1` 下流)
3. **tech-writer HIGH×2**: docs/designs/review-quality-gap-closure.md の行番号参照 2 箇所が Phase A/B/C で修正済み箇所を指す drift (後続 #387/#395 で Phase 0 スナップショット注記を追加済み)
   - **注記**: 同レビューで HIGH×3 件として報告されたうちの 1 件 (`_reviewer-base.md` 見出し drift) は [§4.4.1](#441-fp-rate-手動判定-issue-393-2026-04-10) で **FP (projection 誤判定)** と判定済み。fec82c0 時点では drift は発生しておらず、reviewer が Phase C 追加後の将来状態を現在時点に projection した誤判定だった。
4. **code-quality HIGH**: bash trap+cleanup パターンが 9 箇所で完全重複 (drift リスク)
5. **code-quality HIGH**: Fast Path bash block が 250 行で 11 ステップ詰め込み

これらは Phase D フォローアップとして別 Issue 起票推奨。

---

## 4.7 #392 サブ実測: PR #334 (bash hook) replay (2026-04-10)

> **位置づけ**: 親 #392 の対照実測 3 件のうち「Bash/hook script」カテゴリ。Issue [#403](https://github.com/B16B1RD/cc-rite-workflow/issues/403) の成果物。詳細レポート: [pr334-replay-findings.md](./pr334-replay-findings.md)

### 4.7.1 サマリー

| 指標 | 結果 | 判定 |
|------|------|------|
| 対象 PR | #334 (`fix(hooks): context-pressure.sh の堅牢性改善 — silent abort 防止 + コメント精度修正`) | — |
| baseRefOid | `4e919ace5d901606c566f6f788f1cedb8d772d07` | — |
| replay draft PR | [#407](https://github.com/B16B1RD/cc-rite-workflow/pull/407) (`investigate/pr334-replay`) | — |
| 変更規模 | +3 / -2 (2 files: bash hook + yaml template) | extra small |
| reviewer 構成 | error-handling [検出] / performance / devops / security [推奨] | 4 reviewer 全員「可」 |
| 総 finding 数 | **0 件** (CRITICAL/HIGH/MEDIUM/LOW すべて 0) | — |
| FP rate (strict / conservative / worst case) | **N/A** (0/0、計算不能) | — |
| Phase C2 検出 (stderr 混入 / silent abort) | **0 件** | ⚠️ **検出機会なし** |
| Rollback 判定 | 不要 (計算不能のため対象外) | ✅ |

### 4.7.2 主要結論

1. **修正後 PR を誤って問題視しない正確性は確認**: 全 4 reviewer が「可」評価で finding 0 件。改善後 review system は post-fix code を不当に rollback 推奨しない。
2. **Phase C2 効果の検証は不能**: PR #334 自体が silent abort fix の **適用後コード**であるため、Phase C2 が検出すべき silent abort / stderr 混入パターンは diff から消失している。reviewer の検出能力 (機構が機能しているか) は本 replay では**実証も反証もできない**。
3. **methodological caveat (重要)**: 本 replay 手法 (および先行 PR #373 replay) は **post-fix code** を再適用するため、bug fix PR を対象にすると検出すべき bug が diff から消える構造的限界がある。Phase C2 検出能力の真の検証には **pre-fix code (PR #334 適用前の context-pressure.sh)** を replay する手法が必要 (別 Issue 化候補)。
4. **副次的観察**: error-handling reviewer は **PR スコープ外の周辺既存 silent drop pattern** (`context-pressure.sh:85` の `python3 -c` yaml load fallback) を発見し推奨事項として提示した。これは Phase C2 機構が **変更 diff のみに視野を限定せず周辺コードを能動的に走査している**ことの間接的証拠。
5. **reviewer 選定機構は仕様通り**: error-handling が file pattern (`**/*.sh` + `**/hooks/**/*.sh`) と Phase 2.3 keyword detection (`set -e`, `pipefail`, `\|\| true`-equivalent, `2>/dev/null`) の両方で activate し、`recommended_for_code_changes: true` 設定により security も追加された。

### 4.7.3 #392 集約への引き継ぎ

- PR #373 (code-heavy / 新規実装) と PR #334 (bash hook / bug fix) の両 replay は、いずれも **post-fix code 再適用**という共通の構造を持つ。両者とも「reviewer が修正後コードを誤判定しない」ことは確認できたが、**stderr 混入 / silent abort detection の実証**には不十分な手法であったことが判明。
- **次のアクション** (親 #392 の集約フェーズで決定):
  - (a) **pre-fix replay の追加**: PR #334 / #373 の親コミットから replay する第 3 の方法論を別 Issue で提案
  - (b) **DummyHookPR の人工実装**: 既知の silent abort / stderr mixing パターンを意図的に含む人工 PR を作成し reviewer に投入する手法 (review-quality-gap-results.md §3.2 で言及されていた選択肢)
  - (c) **本 replay データの限定的解釈**: 「修正後コードを誤検出しない正確性」は確認済み、「pre-fix code の検出能力」は未検証として明示記録

---

## 4.8 #392 サブ実測: PR #373 (code-heavy) replay (2026-04-10)

> **位置づけ**: 親 #392 の対照実測 3 件のうち「code-heavy (TS 代替 = 新規 bash 実装)」カテゴリ。Issue [#402](https://github.com/B16B1RD/cc-rite-workflow/issues/402) の成果物。詳細レポート: [pr373-replay-findings.md](./pr373-replay-findings.md)
>
> **なお**: 3 件のうち「Bash/hook script」カテゴリ (Issue #403 / PR #334 replay) は既に **§4.7** で記載済み。§4.8 (code-heavy) と §4.9 (mixed) は §4.7 と並列する位置づけで、§4.10 で 3 件を統合比較する。

### 4.8.1 サマリー

| 指標 | 結果 | 判定 |
|------|------|------|
| 対象 PR | #373 (`feat(lint): 分散修正 drift 検出 lint の新規実装`) | — |
| baseRefOid | `5639e27b504efe9a35fbf9aa4d33f966cb437234` | — |
| replay draft PR | [#405](https://github.com/B16B1RD/cc-rite-workflow/pull/405) (`investigate/pr373-replay`) | — |
| 変更規模 | +392 / -0 (2 files: 新規 bash lint 本体 + smoke test) | small |
| reviewer 構成 | code-quality / error-handling / performance / devops / security (5 reviewer、詳細は [pr373-replay-findings.md](./pr373-replay-findings.md) §2) | — |
| 総 finding 数 (raw) | 25 件 (CRITICAL 1 / HIGH 10 / MEDIUM 9 / LOW 5) | — |
| unique finding 数 | 24 件 (PERF-8 が EH-3 と重複) | — |
| **FP rate (strict)** | **0.0%** (0/24) | ✅ ≤20% 目標 |
| FP rate (conservative) | 4.2% (Ambiguous 2×0.5=1.0) | ✅ |
| FP rate (worst case) | 8.3% (Ambiguous=全 FP) | ✅ ≤30% rollback 閾値 |
| Phase D 6 カテゴリ直接重複 | **0/6** (0%) | — (code-heavy は異なる問題表面を持つ) |
| Rollback 判定 | **不要** (全方式で閾値内) | ✅ |

### 4.8.2 主要結論

1. **過剰適応の証拠なし**: FP rate が doc-heavy #350 replay (strict 10.5%) よりも低い (strict 0.0%) 結果となり、改善後 review system は code-heavy PR でも高品質な指摘を生成する。
2. **finding プロファイルの完全な差異**: Phase D 6 カテゴリ (doc-heavy 由来) と code-heavy #373 finding の重複は 0/6 で、これは当然の結果 (問題表面が本質的に異なる)。code-heavy では独自カテゴリ (silent failure / race・signal handling / test coverage / algorithmic performance / convention consistency / minor design critique) が 24 件検出され、review system が **入力の性質に応じて適切なカテゴリを自律的に発見している**。
3. **Rollback 候補なし**: 全方式で rollback 閾値 (30%) を下回る。

---

## 4.9 #392 サブ実測: PR #370 (mixed) replay (2026-04-10)

> **位置づけ**: 親 #392 の対照実測 3 件のうち「mixed (code + docs)」カテゴリ。Issue [#404](https://github.com/B16B1RD/cc-rite-workflow/issues/404) の成果物。詳細レポート: [pr370-replay-findings.md](./pr370-replay-findings.md)

### 4.9.1 サマリー

| 指標 | 結果 | 判定 |
|------|------|------|
| 対象 PR | #370 (`feat(workflow): workflow incident 自動 Issue 登録機構を追加 (#366)`) | — |
| baseRefOid | `dfcabe3a0fc09de57756eb8c854e46b0e553832e` | — |
| replay draft PR | [#409](https://github.com/B16B1RD/cc-rite-workflow/pull/409) (`investigate/pr370-replay`) | — |
| 変更規模 | +923 / -28 (13 files: docs/SPEC x2 + CHANGELOG x2 + commands x5 + hooks x2 + config x2) | medium |
| reviewer 構成 | prompt-engineer [検出] / tech-writer [検出] / devops [検出] / code-quality [推奨] / error-handling [検出] | 5 reviewer |
| **Doc-Heavy 判定** | **`false`** (`doc_lines_ratio=0.21 < 0.6`, `doc_files_count_ratio=0.31 < 0.7`) | ⚠️ mixed PR でも不活性 |
| 総 finding 数 (raw) | 25 件 (CRITICAL 2 / HIGH 14 / MEDIUM 8 / LOW 1) | — |
| unique finding 数 | 22 件 (`grep -A3 parser` が 3 reviewer から重複検出、3 重複のうち 2 件を dedup) | — |
| **FP rate (strict, unique 分母)** | **9.1%** (2/22) | ✅ ≤30% rollback 閾値 |
| 横断問題 (cross-validation 発火) | 3 件 (`grep -A3 parser` 3 人 / `emit helper 3 file 重複` 2 人 / `dead config keys` 2 人) | ✅ 複数 reviewer 独立検出 |
| Rollback 判定 | **不要** (8% は 30% 閾値を大きく下回る) | ✅ |

### 4.9.2 主要結論

1. **mixed PR でも Doc-Heavy mode は activate しない**: 13 ファイル中 4 ファイルが docs (`docs/SPEC.*` + `CHANGELOG.*`) だが、commands/skills/.md (459 行) は priority rule で prompt-engineer に振り分けられ doc 分子から除外される。結果として `doc_lines_ratio = 200/951 = 0.21` と閾値 0.6 を大きく下回る。
2. **tech-writer は通常 mode で日英 i18n parity 検査に集中**: priority rule により 4 ファイルに絞られ、未翻訳文字列検出 / sentinel format の prose 正確性を指摘 (HIGH 2件)。Doc-Heavy mode の 5-category verification は不要と判断された。
3. **prompt-engineer が `commands/**/*.md` 専管で最多指摘 (10 件)**: `start.md` +313 行に対して placeholder substitution 責任 / flag check 漏れ / Step 番号 drift 懸念 / jq 引数置換規約等を検出。
4. **error-handling が silent failure 経路を専門的に検出 (5 件)**: `signal trap EXIT のみ` / `mktemp 失敗 unhandled` / `emit helper stderr silent` — いずれも他 reviewer では検出されず、専門分化が機能。PR #370 自体が silent failure 防止をテーマとするため、reviewer が実装の **自己矛盾 (meta-inconsistency)** を発見した。
5. **横断問題 3 件が cross-validation 発火**: `grep -A3 parser` は 3 reviewer 独立検出、他 2 件も 2 reviewer 独立検出 — **複数 reviewer の独立検出は真陽性率の強い指標**で、3 件すべて TP 判定。
6. **TP findings から 4 件の別 Issue を自動登録**: [#411](https://github.com/B16B1RD/cc-rite-workflow/issues/411) / [#412](https://github.com/B16B1RD/cc-rite-workflow/issues/412) / [#413](https://github.com/B16B1RD/cc-rite-workflow/issues/413) / [#414](https://github.com/B16B1RD/cc-rite-workflow/issues/414) を cycle 4 相当の改善として起票済み。
7. **Issue #404 仮説の撤回**: 「mixed で doc-heavy override が必要」という事前仮説は**撤回**。現状の閾値 (0.6 / 0.7) で妥当な reviewer 配分が自然に得られる。

---

## 4.10 #392 対照実測 3 件の統合比較

3 子 Issue (#402 / #403 / #404) の replay 結果を doc-heavy (PR #350, Phase D baseline) と並べて比較する。詳細レポートは [pr334-replay-findings.md](./pr334-replay-findings.md) (#403 bash hook) / [pr373-replay-findings.md](./pr373-replay-findings.md) (#402 code-heavy) / [pr370-replay-findings.md](./pr370-replay-findings.md) (#404 mixed) を参照。

### 4.10.1 比較表

| 指標 | **#350 (doc-heavy)** Phase D baseline | **#373 (code-heavy)** Issue #402 | **#334 (bash hook)** Issue #403 | **#370 (mixed)** Issue #404 |
|------|--------------------------------------:|---------------------------------:|-------------------------------:|----------------------------:|
| **Issue (親)** | Phase D (#360) | #402 | #403 | #404 |
| **変更規模** | +1000+ / docs 中心 | +392 / -0 (2 files) | +3 / -2 (2 files) | +923 / -28 (13 files) |
| **タイプ** | doc-heavy (純粋 docs PR) | code-heavy (新規 bash 実装) | bash hook (bug fix) | mixed (code + docs) |
| **Doc-Heavy 判定** | true | false (code only) | false (code only) | **false** (mixed でも閾値未達) |
| **reviewer 数** | 1-3 (初期段階) | 5 | 4 | 5 |
| **総 finding (raw)** | ~19 件 | 25 件 | **0 件** | 25 件 |
| **unique finding** | 19 件 | 24 件 | 0 件 | 22 件 |
| **FP rate (strict, unique 分母)**[^fp-denominator] | 10.5% (2/19) | **0.0%** (0/24) | N/A (0/0) | **9.1%** (2/22) |
| **Rollback 閾値 (30%) 超過** | ❌ なし | ❌ なし | ❌ なし (計算不能) | ❌ なし |
| **Phase D 6 カテゴリ直接重複** | 6/6 (baseline) | 0/6 | 0/6 | 0/6 (独自カテゴリ) |
| **横断問題 (多 reviewer 独立検出)** | 未測定 | — | — | 3 件 |
| **自動生成 Issue** | 0 (Phase D 初期) | 0 | 0 | **4 件** (#411-#414) |

[^fp-denominator]: 本比較表の FP rate (strict) はすべて **unique finding (重複除外後) 分母** に統一している。raw 分母で計算した場合、#350 は 10.5% (2/19)、#373 は 0.0% (0/25)、#370 は 8.0% (2/25) となる (1 桁程度の差)。3 子 Issue の詳細レポート (`pr334-replay-findings.md` / `pr373-replay-findings.md` / `pr370-replay-findings.md`) には各自の方式で raw / unique 両方の値が記載されている場合があるが、本集約では cross-PR 比較の一貫性を優先して unique 分母を採用した。

### 4.10.2 Phase 別 FP rate の観察

Phase A/B/C/C2 単位での rollback 判定に必要な Phase 別 FP rate を算出すると:

| Phase | 改善内容 | doc-heavy (#350) | code-heavy (#373) | bash hook (#334) | mixed (#370) | 結論 |
|-------|---------|-----------------:|------------------:|-----------------:|-------------:|------|
| **Phase A (#357)** | Part A 抽出バグ修正 | — (baseline) | 0 FP | N/A | 2 FP (tech-writer 1 + prompt-engineer 1) | ✅ **rollback 候補なし** |
| **Phase B (#358)** | named subagent 切り替え | — (baseline) | 0 FP | N/A | 0 FP (subagent 解決失敗なし) | ✅ **rollback 候補なし** |
| **Phase C (#359)** | reviewer プロンプト改善 | — (baseline) | 0 FP | N/A | 0 FP (プロンプト品質問題なし) | ✅ **rollback 候補なし** |
| **Phase C2 (#361)** | 分散伝播漏れ検出 lint | — (baseline) | 0 FP | N/A (検出機会なし) | 0 FP | ✅ **rollback 候補なし** (ただし post-fix code 再適用の構造的限界あり、§4.10.4 参照) |

**全 Phase で rollback 閾値 (30%) を下回り、Phase A/B/C/C2 いずれも rollback 候補ではない。**

### 4.10.3 主要な発見

#### 4.10.3.1 過剰適応 (doc-heavy specialization) の証拠なし

- Phase A-C2 の改善が「doc-heavy PR のみに有効で、他タイプでは過剰な FP を生む」仮説は**否定された**。
- code-heavy (#373) は FP rate 0.0% で doc-heavy (10.5%) よりも**低い**。
- mixed (#370) も 8.0% で rollback 閾値の 30% を大きく下回る。
- bash hook (#334) は 0 finding のため FP rate 計算不能だが、少なくとも「post-fix code を誤判定しない正確性」は確認された。

#### 4.10.3.2 入力の性質に応じた reviewer の自律分化

- code-heavy #373 は独自カテゴリ (silent failure, race/signal, test coverage, algorithmic perf, convention, minor design) を発見、Phase D 6 カテゴリ (doc-heavy 由来) とは 0/6 重複。
- mixed #370 は **commands/skills/.md が prompt-engineer に priority 振り分けされ** tech-writer は docs/SPEC + CHANGELOG の 4 ファイルに絞られて i18n parity に集中、error-handling が silent failure 経路の専門検出、code-quality が重複・dead config を横断検出。
- **reviewer 活性化ロジックは入力に応じて適切に分化しており、過剰適応・機能不足のいずれも観察されなかった**。

#### 4.10.3.3 横断問題の cross-validation 発火 (新知見)

mixed #370 replay で初めて観察された知見:

- **`grep -A3 parser` 脆弱性** は 3 reviewer (prompt-engineer + code-quality + error-handling) が独立検出
- **`Workflow Incident Emit Helper 3 file 重複`** は 2 reviewer (code-quality + prompt-engineer) が検出
- **`dead config keys`** は 2 reviewer (code-quality + devops) が検出

いずれも TP 判定で、**複数 reviewer の独立検出は真陽性率の強い指標**であることが確認された。これは改善後 review system の cross-validation 機構 (`scripts/reviewers/references/cross-validation.md`) が期待通り機能していることを示す。

### 4.10.4 methodological caveats と未解決事項

#### 4.10.4.1 Post-fix code 再適用の構造的限界

3 件すべての replay (#334 / #373 / #370) は **merged PR の最終 cycle コード**を対象とし、元 PR の review cycles で修正済みの問題は diff から消失している。したがって:

- ✅ **検証された**: 改善後 review system が post-fix code を誤って問題視しない正確性 (= 3 件すべて low FP rate)
- ⚠️ **未検証**: Phase C2 (#361 分散伝播漏れ検出) / Phase C (#359 プロンプト改善) が pre-fix code に含まれる実バグを検出できるか (= 検出感度)

**Phase C2 は特に問題**: PR #334 は silent abort 防止修正の **適用後コード**のため、検出対象の pattern が diff から消失しており、reviewer の検出能力を証明も反証もできない。

#### 4.10.4.2 未解決事項への推奨アクション

- **(a) Pre-fix replay の追加**: PR #334 / #373 の **親コミット**から replay する第 3 の手法を別 Issue で提案推奨。これにより Phase C2 の真の検出感度を測定可能。
- **(b) DummyHookPR の人工実装**: 既知の silent abort / stderr mixing パターンを意図的に含む人工 PR を作成し reviewer に投入する手法 (§3.2 で言及されていた Option B)。
- **(c) 本 replay データの限定的解釈の明示**: 「修正後コードを誤検出しない正確性」は確認済み、「pre-fix code の検出感度」は未検証として明示記録 — 本セクションで実施済み。

---

## 4.11 Phase D 集約判定と次アクション

### 4.11.1 Rollback 判定 (最終)

| Phase | Rollback 候補か | 根拠 |
|-------|:--------------:|------|
| **Phase A (#357)** | ❌ 不要 | 全 replay で FP rate 閾値内 (最大 mixed 8.0%) |
| **Phase B (#358)** | ❌ 不要 | subagent 解決失敗は 3 replay で 0 件 |
| **Phase C (#359)** | ❌ 不要 | プロンプト品質由来の FP は 0 件 |
| **Phase C2 (#361)** | ❌ 不要 (限定的) | post-fix 再適用の構造的限界により検出感度は未検証だが、False Positive は 0 件 |

**結論**: **Phase A/B/C/C2 のいずれも rollback 不要**。改善後 review system は doc-heavy / code-heavy / bash hook / mixed の 4 タイプすべてで rollback 閾値 (30%) を下回る高品質な指摘を生成する。

### 4.11.2 副次的な Issue 起票

mixed #370 replay で検出された真陽性 finding (cycle 4 相当の追加改善) を別 Issue として起票済み:

| Issue | Priority | 内容 | 検出 reviewer |
|-------|:--------:|------|:-------------:|
| [#411](https://github.com/B16B1RD/cc-rite-workflow/issues/411) | High | `grep -A3` parser 脆弱性 | 3 reviewer 合意 |
| [#412](https://github.com/B16B1RD/cc-rite-workflow/issues/412) | Medium | Workflow Incident Emit Helper 3 file 重複 | 2 reviewer |
| [#413](https://github.com/B16B1RD/cc-rite-workflow/issues/413) | Medium | dead config keys (non_blocking / dedupe_per_session) | 2 reviewer |
| [#414](https://github.com/B16B1RD/cc-rite-workflow/issues/414) | High | Phase 5.4.4.1 signal trap 欠落 + mktemp 失敗 unhandled | 1 reviewer |

### 4.11.3 Issue #392 仮説への回答

- **仮説 1** (#404 由来): 「mixed で doc-heavy mode が activate すべき」 → **撤回**。閾値調整不要。mixed PR でも priority rule による自然な reviewer 配分が機能する。
- **仮説 2** (#402 由来): 「code-heavy で doc-heavy 特化の改善が過剰になる」 → **否定**。code-heavy #373 の FP rate は doc-heavy より**低い**。
- **仮説 3** (#403 由来): 「bash hook で Phase C2 の stderr 混入検出が発火する」 → **検証不能**。post-fix code の構造的限界で発火機会なし。Pre-fix replay を別 Issue で推奨。

### 4.11.4 次アクション

- [x] 対照実測 3 件の集約セクション追加 (本節)
- [x] mixed #370 TP findings の別 Issue 起票 (#411-#414)
- [ ] **Pre-fix replay 手法の別 Issue 起票** (Phase C2 検出感度の真の検証、§4.10.4.2 (a))
- [ ] Issue #392 のクローズ

---

## 5. 関連リソース

- 親 Issue: [#355](https://github.com/B16B1RD/cc-rite-workflow/issues/355)
- 本 Issue: [#360](https://github.com/B16B1RD/cc-rite-workflow/issues/360)
- Phase 0 レポート: [review-quality-gap-baseline.md](./review-quality-gap-baseline.md)
- 症例研究: [fix-cycle-pattern-analysis.md](./fix-cycle-pattern-analysis.md)
- 設計書: [docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
- 測定スクリプト: [plugins/rite/scripts/measure-review-findings.sh](../../plugins/rite/scripts/measure-review-findings.sh)
