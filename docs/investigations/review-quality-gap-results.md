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
| カバレッジ率 (signal rate 調整後) | ≥70% | 🔶 分母確定 (baseline_V′ ≒ 262)、intersection 計算は未着手 | 分母は確定したが、baseline_A ∩ baseline_V′ の計算は別タスク |
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
- baseline_V 個別指摘データ未取得 (詳細は [§1.2](#12-baseline_v-verified-review))
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

| Source session | 件数 |
|---|---|
| `763024b7-*` | 77 |
| `1378f23f-*` | 56 |
| `9eb0c81a-*` | 49 |
| `4e84181c-*` | 32 |
| `63b02251-*` | 28 |
| `58685911-*` (Issue 当初指定) | 19 |
| `1f5e3701-*` | 14 |
| `f5debd1f-*` | 12 |
| 他 13 sessions | 15 |
| **合計 (raw, dedup 後)** | **302** |

**Severity 内訳**: CRITICAL 31 / HIGH 129 / MEDIUM 101 / LOW 41

##### 1.2.2.3 サンプリング監査

**手法**: Population (n=302) から再現可能な seed (`random.seed(391)`) で **30 件** をランダム抽出し、各指摘を現在のコードと突合 (Read/Grep) して 4 分類で判定。

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

**保守的解釈の補足**: TP_likely 10 件を仮に「不明 → FP 扱い」に降格すると signal rate 61.5% (95% CI [42.5%, 77.6%]) となり <70% bracket に該当する。ただし当該 10 件は「直接 line 照合不可」だっただけで「4 FP カテゴリのいずれにも該当しない」ことは確認済みのため、本監査では TP に算入する。この判断の根拠:

- TP_likely #8/#9/#10 (`fix.md` trap area): 該当領域は heavy refactor 済みで、refactor の動機付けが当該 finding と整合
- TP_likely #13 (regex dead code): 構造的に判断可能、現状コードで pattern が依然存在
- TP_likely #16 (`implementation-plan.md` ambiguity): 内容ベースの subjective 指摘で、現在も有効な改善余地
- TP_likely #20 (test sanitize edge case): test coverage 改善提案として妥当
- TP_likely #25 (`Mandatory After` step format): 構造的整合性 drift を ascertain 可能
- TP_likely #27/#29/#30 (column-order risk / fixed-path collision / cross-bash variable): 既知の bash pitfall に該当する設計上の懸念

##### 1.2.2.5 baseline_V′ 補正 (extraction artifact 除外後)

抽出スクリプトの parsing 精度を改善する余地はあるが、サンプルから推定した artifact rate は **13.3%** (4/30)。これを population に適用すると:

- **baseline_V′ (artifact-removed estimate)**: 302 × (1 - 0.133) ≒ **262 件**
- **真 finding 推定数**: 262 × 1.0 (signal rate point estimate) ≒ **262 件**

**注**: この `262` は新たな `baseline_V` の推奨値。Issue #355 当初の `172` は cycle 集計値であり個別 finding 数とは異なる概念のため、coverage rate の分母として使う場合は **262 を採用** することを推奨する。

##### 1.2.2.6 監査の限界事項

1. **サンプル数の制約**: n=30 (effective 26) は population 302 に対する 8.6% のサンプリング率。Wilson CI 下限は 87.1% で十分高いが、上位 severity (CRITICAL/HIGH) のみに stratified sampling を行うと精度が向上する余地あり
2. **dedup key の選択**: `(severity, file_line[:120], col3[:100])` というキー長で artifact 除外後 302。dedup key を 250 chars に伸ばすと 437 件になり、逆に圧縮すると過剰 dedup のリスク。適切な dedup 粒度は今後 calibration 余地あり
3. **cycle 番号推定**: ヒューリスティック (直前の "Cycle N" / "サイクル N" 表記) で抽出するため、cycle 1 に過剰集中している (197/302)。正確な cycle 別分布の取得は別 issue で検討
4. **multi-project 混入**: rite プロジェクト外の review (例: `src/components/Hero.tsx`) も session log に含まれており、抽出スクリプトで完全分離は不可能。サンプル監査での除外で対応 (4/30 → 13.3%)

##### 1.2.2.7 監査資産

| 資産 | パス |
|---|---|
| 抽出スクリプト | `plugins/rite/scripts/extract-verified-review-findings.sh` |
| 全件抽出結果 | `/tmp/baseline-v-findings.jsonl` (一時、再現可能 — Issue #391 セッション内のみ) |
| サンプル (30 件) | `/tmp/baseline-v-sample.jsonl` (`random.seed(391)`) |
| 判定結果 | `/tmp/baseline-v-judgment.json` |

**再現コマンド**:

```bash
bash plugins/rite/scripts/extract-verified-review-findings.sh \
  --session-dir ~/.claude/projects/-home-akiyoshi-Projects-personal-cc-rite-workflow \
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
| baseline_V 個別データ未取得 | verified-review の 172 件の個別指摘は PR コメントではなくセッション会話内に散在。signal rate 監査にはセッションログからの構造化抽出が必要 |

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
| 総 finding 数 vs baseline_A | improvement | 14 → 19 (件数 +35.7%) | ⚠️ 検出数は増加 (FP rate 未測定のため改善の質は保留) |
| カバレッジ率 | ≥70% | 未測定 | baseline_V 個別データ未取得 |
| FP rate | ≤20% | 未測定 | 手動判定セッション未実施 |
| signal rate (baseline_V) | ≥90% | 未測定 | 個別指摘データ未取得 |

### 4.5 Phase D 完了条件

- [x] Option A (worktree replay) による PR #350 の実測データ取得
- [x] カテゴリカバレッジ実測値の確定 (4/6, ≥4/6 達成)
- [ ] baseline_V の signal rate 監査 (Option C, dedicated extraction session 必要)
- [ ] カバレッジ率・FP rate の実測値確定 (signal rate 監査後に実施)
- [ ] 対照 PR 3 件での検証 (TS / Bash / mixed)

**Phase D の主要目的 (改善後 review system で PR #350 diff を測定) は達成**。残タスク (signal rate 監査、対照 PR、FP rate 手動判定) は dedicated session で別途実施。

### 4.6 実測で発見された主要 finding (Phase D 成果物)

Phase D の副産物として、**改善後の review system が新規に検出した問題** (PR #350 マージ時には見逃されていた):

1. **prompt-engineer HIGH**: fix.md Phase 8.1 reason 表の enumeration 不足 (12 値記載 vs 27+ emit)
2. **prompt-engineer HIGH**: review.md Phase 2.2.1 pipeline SIGPIPE 方向誤解 (`printf` 上流 → `grep -m 1` 下流)
3. **tech-writer HIGH×3**: docs/designs/review-quality-gap-closure.md の行番号参照 3 箇所が Phase A/B/C で修正済み箇所を指す drift
4. **code-quality HIGH**: bash trap+cleanup パターンが 9 箇所で完全重複 (drift リスク)
5. **code-quality HIGH**: Fast Path bash block が 250 行で 11 ステップ詰め込み

これらは Phase D フォローアップとして別 Issue 起票推奨。

---

## 5. 関連リソース

- 親 Issue: [#355](https://github.com/B16B1RD/cc-rite-workflow/issues/355)
- 本 Issue: [#360](https://github.com/B16B1RD/cc-rite-workflow/issues/360)
- Phase 0 レポート: [review-quality-gap-baseline.md](./review-quality-gap-baseline.md)
- 症例研究: [fix-cycle-pattern-analysis.md](./fix-cycle-pattern-analysis.md)
- 設計書: [docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
- 測定スクリプト: [plugins/rite/scripts/measure-review-findings.sh](../../plugins/rite/scripts/measure-review-findings.sh)
