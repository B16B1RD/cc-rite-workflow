# Review Result JSON Schema

`/rite:pr-review` が生成し、`/rite:fix` が読取するレビュー結果 JSON のスキーマ定義。「ローカルファイル経由の review → fix 連携」の Single Source of Truth。

## 保存場所

レビュー結果は以下のパスにタイムスタンプ付きで保存される (ルートは `state-path-resolve.sh` の解決結果 — セッション worktree 内から保存しても main checkout と同一パスに解決される。`--results-dir` 明示指定時はそちらを優先):

```
{state_root}/.rite/review-results/{pr_number}-{timestamp}.json
```

- `{state_root}`: `state-path-resolve.sh` が解決するリポジトリ共通の state ルート (単一 checkout ではリポジトリ root と同一)
- `{pr_number}`: PR 番号（整数）
- `{timestamp}`: `YYYYMMDDHHMMSS` 形式の JST (例: `20260411123456`)
- 同一 PR の過去レビューは **best-effort で履歴保持** する。1 秒解像度のため、同一 PR に対し同一秒以内に 2 回 `/rite:pr-review` を実行すると file path が衝突する。pr-review.md ステップ 6.1.a は collision 検出時に `~<4桁hex>` suffix (`~$(printf '%04x' "${RANDOM:-0}")` 相当) で衝突回避を試みるが、完全な一意性保証ではない (best-effort tradeoff)。separator には `~` (0x7E) を使用する。ファイル名 `{ts}~{hex}.json` と `{ts}.json` の分岐点で `.` (0x2E) < `~` (0x7E) となるため、collision-resolved 版が lexicographic 大となり `sort -r` で先頭に並ぶ
- **並列実行は未サポート**: 同一 PR に対する `/rite:pr-review` の同時並列実行 (複数ターミナル / CI 並列 job 等) は未サポート。`mv` の atomicity と `[ -e ]` check の TOCTOU race window により、後勝ちでファイル上書きが発生する可能性がある。POSIX `mv` の標準オプションは `-f`/`-i` のみで、`-n` は POSIX 非標準 (GNU coreutils / BSD 拡張) のため、POSIX 準拠の観点から採用しない ([mv(1p) POSIX](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html) 参照)。並列実行する場合はユーザー自身が時系列をずらす責務を持つ (verified-review cycle 12 I-2 対応で旧 rationale 「bash 3.2 + POSIX utilities 前提と矛盾」を削除。本 plugin は [bash-compat-guard.md](./bash-compat-guard.md) で `mapfile` builtin 必須 = bash 4.0+ 前提であり、bash 3.2 portable 前提は成立しないため)
- `.rite/review-results/` は `.gitignore` で除外される

## Schema Version (Single Source of Truth)

<a id="schema-version-sot"></a>

現行スキーマバージョン: **1.1.0**

**受理される値** (読取側): `"1.0.0"` (canonical 1.0) / legacy エイリアス `"1.0"` (semver `MAJOR.MINOR` のみ、1.0.0 と semantic 等価、v2.0 まで受理) / `"1.1.0"` (canonical 1.1) の **3 値**。`"1.0.0"` / `"1.0"` で受信した JSON は `findings[].scope` / `findings[].pre_existing` フィールドが欠落している。read 側が severity ベースの default mapping を適用するのは **`scope` のみ**で、`pre_existing` は欠落のまま保持し Cross-field invariant #5 を発火させない (詳細は [後方互換性 (schema 1.0 ↔ 1.1.0)](#後方互換性-schema-10--110) 参照)。詳細経緯は CHANGELOG を参照。

**`verification` は 1.1.0 内で additive 追加された optional field** — したがって **`"1.1.0"` で受信した JSON でも `findings[].verification` は欠落しうる**。読取側 accept list 4 箇所の同期変更を避けるため schema_version は bump しない。「`schema_version == "1.1.0"` ならば `verification` が存在する」と読んではならない。欠落時は `measured=false` の default mapping を適用する (同じく [後方互換性](#後方互換性-schema-10--110) 参照)。ただし **blocking 判定 consumer は欠落を「未判定」= blocking と解釈する** — 同節の「3 値モデルへの上書き」を参照。

**`pre_existing` も 1.1.0 内で欠落を許容する additive optional field** — canonical write 側は reviewer の revert test 結果を収集しないため、`"1.1.0"` を出力しても `findings[].pre_existing` を書かない。read 側は schema_version に依らず default mapping を適用せず、欠落時は Cross-field invariant #5 を発火させない。`scope` は同じ 1.1.0 の field でも canonical write 側で必須であり、この optional 契約を適用してはならない。

**`reviewer_timings` / `reviewer_spawn_serialized` / `reviewer_spawn_spread_seconds` も 1.1.0 内で additive 追加した optional field** — audit-only で判定 consumer を持たず、read 側 accept list の同期義務も生まない。同じく version を bump しないため、`schema_version == "1.1.0"` から存在を推論してはならない ([reviewer_timings と直列化フラグ](#reviewer_timings-と直列化フラグ) 参照)。

**`verdict` / `reviewers` も 1.1.0 内で additive 追加した** — こちらは write 側必須だが、**version は bump しない**。理由は 2 つある: (a) 唯一の判定 consumer である merge ゲートは `schema_version` の**値**を見ず、`verdict` / `reviewers` の**キー存在**で新旧を判別する。version を上げても判別は 1 mm も変わらない。(b) bump すると読取側 accept list 4 箇所と `hooks/tests/review-schema-write-version-parity.test.sh` の literal を同時更新する義務が発生し、機能上の利得ゼロに対して 5 箇所の同期コストだけが増える。**したがって `schema_version == "1.1.0"` から `verdict` / `reviewers` の存在を推論してはならない** (`verification` と同じ注意。本変更より前に保存された 1.1.0 JSON は両キーを持たない)。存在を要求する側は必ずキーを直接検査すること。

**検証箇所の同期義務** (verified-review cycle 8 L-4 対応で本セクションを SoT 化、cycle 10 I-E 対応で read/write 非対称を明示、1.1.0 を accept list に追加):

**読取側 (3 値受理義務、4 箇所で完全同期)**:

- `scripts/review-source-resolve.sh` Priority 0 (`--review-file` case 文。`fix.md` ステップ 1.2.0 が呼ぶ helper 側に在る)
- `scripts/review-source-resolve.sh` Priority 2 (local file case 文。同上)
- `fix.md` ステップ 1.2.0 Priority 3 (PR comment Raw JSON case 文)
- `hooks/scripts/review-trend-divergence.sh` (収束トレンド判定の入力として `findings[]` を読む case 文)

上記 4 箇所の `case "$schema_version" in "1.0.0"|"1.0"|"1.1.0")` は常に同じ accept list を持つ。将来 `"1.2.0"` 追加 / legacy `"1.0"` 廃止時は 4 箇所を同時更新すること。

> 4 番目の読取側 (`review-trend-divergence.sh`) は accept list 外の値に遭遇したとき、fix.md の 3 箇所のような Priority fallthrough を持たず **判定不能 (`reason=schema_version_unknown`) として発火せずに返す**。これは silent skip ではなく、理由付きで `[CONTEXT] TREND_DIVERGENCE=insufficient` を emit した上で `safety.max_review_cycles` の backstop に判定を委ねる設計 (未知スキーマで発散と判定して健全な run を殺すより安全側)。

**書込側 (canonical 値のみ出力、同期義務なし)**:

- `pr-review.md` ステップ 6.1.a — canonical `"1.1.0"` のみを出力する。`findings[].scope` は必須だが、`findings[].pre_existing` は上記 additive optional 契約により出力しない。case 文は存在せず、post-condition jq validation は `schema_version | type == "string" and length > 0` の型チェックのみで値の同期対象外 (読取側 accept list と独立に進化してよい)

本セクションが Single Source of Truth であり、読取側 4 箇所の accept list を本ドキュメントと同一に保つ義務がある。`plugins/rite/hooks/tests/review-schema-write-version-parity.test.sh` が 4 箇所の accept list リテラルと site 数を固定するため、本ドキュメントを変更する際は 4 箇所を同時に同期させること（`plugins/rite/hooks/scripts/review-schema-version-check.sh` は `.rite/review-results/*.json` の schema_version 値を検査する別用途の helper）。

**失敗時の遷移** (Priority 別):

- **Priority 0 (`--review-file`)** 失敗時: 直接 **Priority 4 (対話式 fallback)** へ遷移 (ユーザーの明示意図を尊重、Priority 1-3 には fallthrough しない)
- **Priority 2 (ローカルファイル)** 失敗時: WARNING を出して **Priority 3 (PR コメント)** へ routing (古い timestamp ファイルには fallback しない)
- **Priority 3 (PR コメント Raw JSON)** 失敗時: legacy Markdown parser へ fallthrough (後方互換経路)

詳細は fix.md ステップ 1.2.0 Hybrid Review Source Resolution の Priority 0 / Priority 2 / Priority 3 selection logic bash block を参照。

## JSON Schema

```json
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "2026-04-11T12:34:56+09:00",
  "commit_sha": "abc1234",
  "overall_assessment": "fix-needed",
  "verdict": "fix-needed",
  "reviewers": ["code-quality-reviewer", "security-reviewer"],
  "findings": [
    {
      "id": "F-01",
      "reviewer": "code-quality-reviewer",
      "category": "code_quality",
      "severity": "HIGH",
      "scope": "current-pr",
      "pre_existing": false,
      "verification": {
        "measured": true,
        "repro": "node dist/cli.js --input empty.json => TypeError: Cannot read properties of undefined",
        "failing_test": null
      },
      "file": "path/to/file.ts",
      "line": 42,
      "description": "エラーハンドリングが不足",
      "suggestion": "try-catch を追加",
      "status": "open"
    },
    {
      "id": "F-02",
      "reviewer": "security-reviewer",
      "category": "security",
      "severity": "MEDIUM",
      "scope": "nit-noted",
      "pre_existing": true,
      "nit_reason": "本 PR の責務範囲外の既存設定ファイル整形 — 単発修正で完了する localized 改善",
      "verification": {
        "measured": false,
        "repro": null,
        "failing_test": null
      },
      "file": "path/to/config.ts",
      "line": null,
      "description": "ファイル全体への指摘 (行非依存)",
      "suggestion": "設定ファイルヘッダにコンテキスト説明を追加",
      "status": "acknowledged"
    },
    {
      "id": "F-04",
      "reviewer": "code-quality-reviewer",
      "category": "code_quality",
      "severity": "LOW",
      "scope": "nit-noted",
      "pre_existing": true,
      "verification": {
        "measured": true,
        "repro": "node dist/cli.js --legacy => WARN: deprecated flag",
        "failing_test": null
      },
      "file": "path/to/legacy.ts",
      "line": 7,
      "description": "非推奨フラグの警告文が古い",
      "suggestion": "文言を更新",
      "status": "open"
    }
  ],
  "non_blocking_findings": [
    {
      "id": "F-03",
      "reviewer": "code-quality-reviewer",
      "category": "code_quality",
      "severity": "LOW",
      "scope": "follow-up",
      "pre_existing": false,
      "original_severity": "MEDIUM",
      "verification": {
        "measured": false,
        "repro": null,
        "failing_test": null
      },
      "file": "path/to/utils.ts",
      "line": 100,
      "description": "Refactoring候補 — 動作には影響しない (実測なし → 実測必須ゲートで non-blocking)",
      "suggestion": "別 PR で対応",
      "status": "deferred"
    }
  ],
  "guardrail_audit_log": [
    {
      "reviewer": "security-reviewer",
      "filter_category": "Category #2",
      "original_severity": "MEDIUM",
      "file_line": "path/to/file.ts:55",
      "description": "共有ホスト向けの追加 hardening",
      "filter_reason": "宣言済みの単一ユーザー環境では到達しない",
      "verification": "Verification: repro command => observed output"
    }
  ]
}
```

> 上例は `findings[]` = post-5.3.0.M の `全指摘事項` (blocking 指摘 + nit-noted 指摘)、`non_blocking_findings[]` = 実測必須ゲートで降格した非実測指摘 (scope ∈ {current-pr, follow-up})、という分離を示す。`id` は 2 配列の**和集合で一意** (`F-01` / `F-02` / `F-04` / `F-03`) かつ全件が書式 `^F-[0-9]{2,}$` に適合する。**0 件のときも `"non_blocking_findings": []` を出力する** (下記 [non_blocking_findings 配列](#non_blocking_findings-配列) 参照)。

## フィールド定義

### トップレベル

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `schema_version` | string | ✅ | スキーマバージョン (semver `MAJOR.MINOR.PATCH`)。詳細は [Schema Version](#schema-version-sot) セクション参照 (受理値と legacy エイリアスの SoT) |
| `pr_number` | integer | ✅ | PR 番号 (>= 1) |
| `timestamp` | string | ✅ | レビュー実行時刻 (ISO 8601 `YYYY-MM-DDTHH:MM:SS+TZ`) |
| `commit_sha` | string | ✅ | レビュー対象の commit SHA。用途: (a) verification mode 用の diff 起点、(b) Priority 0/2/3 の stale file detection 用の HEAD 比較キー (後述の「読取優先順位 (fix)」表 failure mode 列 `*_commit_sha_mismatch` を参照)、(c) `pr-review.md` ステップ 8.0.4 positive 検査の**判定軸** — 「本 cycle の JSON か」を prefix 一致で判定する (両オペランドとも 16 進 7 桁以上が下限。7 桁未満の帰結はオペランドで異なる: JSON 側は一致候補から外れ `save_result_json_absent` で fail (exit 1)、`--commit-sha` 側は入力検査で `save_result_json_undecidable` = degraded (exit 0) へ降りる)。write 側の値源は ステップ 1.2.5 で記録した commit SHA で、書き手 `hooks/review-result-save.sh` は本フィールドを検査しないため形状の担保は write 側の規約のみ。read 側 (`fix.md` ステップ 1.2.0) は各 Priority success 経路で `json_commit_sha` vs 現 HEAD を比較し、mismatch 時は WARNING + `[CONTEXT] REVIEW_SOURCE_STALE=1; reason=*_commit_sha_mismatch` emit + 次 Priority への routing を実行する (stale file protection) |
| `overall_assessment` | **enum** (string) | ✅ | 総合評価。**受理値**: `"mergeable"` / `"fix-needed"` の 2 値のみ。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value` を stderr に出力し、Priority に応じた fallback/routing を実行する (P0: fallback、P2: Priority 3 routing、P3: legacy parser fallthrough。詳細は fix.md failure reasons table `overall_assessment_unknown_value` 参照) |
| `verdict` | **enum** (string) | ✅ | 本 cycle の最終判定。**受理値**: `"mergeable"` / `"fix-needed"` の 2 値のみ (`overall_assessment` と同一語彙で、`pr-review.md` ステップ 8.1 の terminal sentinel `[review:mergeable]` / `[review:fix-needed:{n}]` と対応する)。**merge ゲート (`hooks/pre-tool-bash-guard.sh`) が読む必須キー**。`overall_assessment` と**同値であることが不変条件**で、両者は `scripts/review-measured-gate.sh` の単一の blocking 件数式から同時に代入される。下記 [verdict と reviewers](#verdict-と-reviewers) 参照 |
| `reviewers` | array (string) | ✅ (非空) | 本 cycle で **ステップ 5.1 が Task 結果を回収できた** reviewer agent の名簿。`findings` とは独立で、findings 0 件の mergeable cycle でも非空になる。値は `plugins/rite/agents/*-reviewer.md` の basename (拡張子を除く、接尾辞 `-reviewer` を含む) と一致する — `findings[].reviewer` と同じ参照整合性規則。下記 [verdict と reviewers](#verdict-と-reviewers) 参照 |
| `findings` | array | ✅ | `/rite:pr-review` ステップ 5.3.0.M 通過後の `全指摘事項` (0 件でも空配列として存在)。**blocking 指摘 + `scope == "nit-noted"` 指摘**を含む — nit-noted は本ゲートの対象外 (`assessment-rules.md` §5.3.0.M) のため非実測でも本配列に残る。ゲートで降格した非実測指摘 (scope ∈ {current-pr, follow-up}) のみが下記 `non_blocking_findings` に分離される |
| `non_blocking_findings` | array | **write 側 ✅ (0 件でも `[]`)** / read 側は欠落許容 | 実測必須ゲート ([severity-levels.md §実測必須ゲート](./severity-levels.md#実測必須ゲート-measured-confirmed-gate)) で non-blocking に降格した非実測指摘の配列 (要素の形は `findings[]` と同一)。下記 [non_blocking_findings 配列](#non_blocking_findings-配列) 参照 |
| `guardrail_audit_log` | array | **write 側 ✅ (0 件でも `[]`)** / read 側は欠落許容 | Finding Quality Guardrail Category #2 で `指摘事項` から除外した候補の監査記録。audit-only で判定 consumer は無視する。各要素は `reviewer`, `filter_category` (`Category #2`), `original_severity`, `file_line`, `description`, `filter_reason`, `verification` を持つ |
| `reviewer_timings` | array | (任意、1.1.0+) | 本 cycle で回収できた各 reviewer の起動時刻。要素は `{reviewer, started_at}` で、`reviewer` は `findings[].reviewer` と同じ参照整合性規則 (`agents/*-reviewer.md` の basename)、`started_at` は ISO 8601 UTC の正規形 (`YYYY-MM-DDThh:mm:ssZ`) または `null` (取得不能)。値源は `pr-review.md` ステップ 4.6。audit-only で、判定 consumer (`/rite:fix` / merge ゲート / 収束トレンド判定) は無視する。下記 [reviewer_timings と直列化フラグ](#reviewer_timings-と直列化フラグ) 参照 |
| `reviewer_spawn_serialized` | bool | (任意、1.1.0+) | 起動時刻の拡がり (spawn spread) が閾値を超えたか。書き手は `hooks/scripts/review-spawn-spread-check.sh` のみ。**計測不能のときはキーごと欠落する** — `true` / `false` / 欠落 (= 未判定) の 3 値モデルで、`verification.measured` と同じ (下記参照) |
| `reviewer_spawn_spread_seconds` | integer | (任意、1.1.0+) | 実測した spawn spread (秒、`max(started_at) - min(started_at)`)。`reviewer_spawn_serialized` と同時に書かれ、同時に欠落する |

### `findings[]` 要素

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `id` | string | ✅ | 指摘 ID (`F-NN` 形式、最小 2 桁ゼロパディング可変長連番、正規表現 `^F-[0-9]{2,}$`)。例: `F-01`, `F-42`, `F-99`, `F-100`, `F-999`。レビュー内ユニーク。99 件以下は 2 桁、100 件以上は 3 桁以上に自然成長する。write 側 (`pr-review.md` ステップ 6.1.a) の machine-enforced jq validation と read 側 (`fix.md`) の正規表現は同一パターンで検証される |
| `reviewer` | string | ✅ | レビュアー種別 (例: `code-quality-reviewer`, `security-reviewer`, `tech-writer-reviewer`)。**参照整合性**: 値は `plugins/rite/agents/*-reviewer.md` の basename (拡張子を除く、接尾辞 `-reviewer` を含む) と一致する。新 reviewer を追加する際は agents/ 側のファイル追加と合わせて本ドキュメントにも追記すること (drift-check による自動検証はないため手動同期)。 |
| `category` | string | ✅ | カテゴリ (例: `code_quality`, `security`, `performance`, `error_handling`) |
| `severity` | **enum** (string) | ✅ | 重要度。**受理値**: `"CRITICAL"` / `"HIGH"` / `"MEDIUM"` / `"LOW-MEDIUM"` / `"LOW"` の 5 値のみ (LOW-MEDIUM は `severity-levels.md` Severity Levels 表で正式定義された first-class severity で、`COMMENT_QUALITY` 軸の独自ジャーゴン濫用 等の bounded blast radius 違反に使う)。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=severity_unknown_value; value=<val>` を stderr 出力し、該当 finding を `MEDIUM` にフォールバック (silent skip は禁止)。外部ツール出力の別名は下記「severity 別名マッピング表」に従って read 側で正規化してから本 enum に落とす |
| `scope` | **enum** (string) | ✅ (1.1.0+) | 指摘の scope 分類 (1.1.0 から追加)。**受理値**: `"current-pr"` (本 PR で修正必須) / `"follow-up"` (本 PR では対応せず別 Issue として deferred) / `"nit-noted"` (情報共有のみ、修正不要 — `acknowledged` で受け流し) の 3 値。1.0 / 1.0.0 JSON では本フィールドは欠落しているため、read 側で severity ベースの default mapping を適用する (詳細は [後方互換性](#後方互換性-schema-10--110))。Cross-field invariant #4 (CRITICAL/HIGH × nit-noted FAIL) / #5 (pre_existing=false × nit-noted auto-correct) を参照 |
| `pre_existing` | bool | (任意、1.1.0+) | 当該 finding の triggering condition が本 PR の diff 適用前から存在していたか (1.1.0 から追加)。`true` = pre-existing (本 PR で混入していない) / `false` = 本 PR で新規導入。判定は revert test (reviewer が当該 diff を mentally revert して finding が依然成立するかを確認) ベース。canonical 1.1.0 write 側を含め本フィールドは欠落しうる。欠落時は default mapping を適用せず、Cross-field invariant #5 は発火しない (詳細は [後方互換性](#後方互換性-schema-10--110)) |
| `original_severity` | string | (任意、1.1.0+) | severity 自己降格 (reviewer が CRITICAL 判定後 PR scope 不適合と判断し scope=follow-up や nit-noted へ送る際に severity を MEDIUM 等へ降格) 時の元値を保持。**自己降格 trace 用途のみ**で、cross-field invariant 評価には使わない。omit 可 (1.0 / 1.0.0 互換、降格していない finding には不要)。値の domain は `severity` enum 5 値と同じ |
| `nit_reason` | string | (条件付き必須、1.1.0+) | `severity == "MEDIUM"` ∧ `scope == "nit-noted"` の組み合わせ時は **必須**。それ以外は omit 可。MEDIUM 級の指摘を「nit として受け流す」判断には bounded blast radius (localized で単発修正で完了する) の根拠が必要なため、reviewer に明示的に reason を記載させて auditability を担保する |
| `verification` | object | (任意、1.1.0+) | **`"1.1.0"` JSON でも欠落しうる** (schema_version を bump しない additive 追加のため — [Schema Version](#schema-version-sot) 参照)。runtime 実測の記録 `{measured, repro, failing_test}` (下記 [verification サブフィールド](#verification-サブフィールド) 参照)。**欠落時は記録・表示経路では `measured=false` 扱い** ([後方互換性](#後方互換性-schema-10--110) の verification default mapping)。**値は blocking / mergeable 判定の入力として消費される** （実測必須ゲートの定義: [severity-levels.md §実測必須ゲート](./severity-levels.md#実測必須ゲート-measured-confirmed-gate))。判定 consumer は `measured` を **3 値** (`true` / `false` / 欠落 = **未判定**) として扱い、未判定はゲート対象外 = 従来どおり blocking とする ([3 値モデルへの上書き](#3値モデルへの上書き) 参照)。**型は判定に使われる**: read 側の型ガードが object/boolean 制約を検証し、違反時は当該 review-result file 全体の routing を変える ([verification 型ガード (read 側)](#verification-型ガード-read-側)) |
| `file` | string | ✅ | 対象ファイルのリポジトリルート相対パス (絶対パス禁止、`..` による親ディレクトリ参照禁止) |
| `line` | integer \| null | ✅ | 対象行番号 (正の整数 >= 1)、または `null` (行非依存指摘の sentinel)。負数は無効 (read 側での挙動は未定義)。cycle 10 S-4 対応で旧「`0` を行非依存 sentinel として扱う」設計から `null` 許容に変更。severity_map 構築時は `line == null` を `"anchor"` key に正規化して同一ファイル複数指摘の key 衝突を防ぐ (fix.md ステップ 1.2.0 severity_map 構築参照)。**後方互換**: 読取側は `line: 0` を引き続き legacy sentinel として受理し、`null` と同じ扱いにする |
| `description` | string | ✅ | 指摘内容 |
| `suggestion` | string | ✅ | 推奨対応 |
| `status` | **enum** (string) | ✅ | 対応状態。**受理値**: `"open"` / `"fixed"` / `"replied"` / `"deferred"` / `"acknowledged"` の **5 値**。現行実装では `/rite:pr-review` ステップ 6.1.a は常に `"open"` を出力する (将来の state machine 拡張で `/rite:fix` 完了時に `"fixed"` / `"acknowledged"` 等を書き戻す slot を予約)。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=status_unknown_value; value=<val>` を stderr 出力する |

### `verdict` と `reviewers`

<a id="verdict-と-reviewers"></a>

merge ゲート (`hooks/pre-tool-bash-guard.sh` の `merge-review-*` 検査) が結果 JSON に要求する 2 つのトップレベル必須キー。**要求側 (ゲート) と生成側 (writer) が同一契約を持つことが本節の目的**であり、要求キー集合の一致は `hooks/tests/review-verdict-reviewers-contract.test.sh` が機械的に pin する。

#### `verdict` — 書き手は実測必須ゲート helper のみ

`scripts/review-measured-gate.sh` の変換 jq が、`overall_assessment` を確定するのと**同一の blocking 件数式**から `verdict` を代入する。したがって両者は構造上つねに同値であり、乖離しうる経路を持たない。

- **`pr-review.md` ステップ 5.3.0.M step 1 の Claude は `verdict` を書かない**。helper は既存値ガードを持たず**無条件に代入する**ため、step 1 で書いた値は必ず捨てられる。しかも step 1 時点では移送後の blocking 件数が未確定なので、書けば必ず推測値になる（`overall_assessment` を暫定値でよいとしているのと同じ理由）。`findings[].verification` とは強制の向きが逆で、あちらは preset を尊重する（だから `--reject-preset-verification` がある）のに対し `verdict` は上書きされる。ゲート helper を経ずに保存へ回った JSON は `verdict` を欠き `hooks/review-result-save.sh` が fail-loud で拒否する — ただしこの遮断が成立するのは、上記「step 1 は書かない」という散文規約が守られている限りにおいてであり、save helper 側に helper 由来と caller 由来を区別する手段は無い
- **なぜ `overall_assessment` と別キーなのか**: merge ゲートの必須キー契約が `verdict` を名指ししており、ゲート側の要求緩和は本スキーマの守備範囲外だから。値としては同一判定の別名であり、consumer が違う (`verdict` → merge ゲート / `overall_assessment` → `/rite:fix` の読取経路)。**同値性は save helper では検査しない** — 検査すると、手で組み立てた復旧用 JSON が「保存されない」ことで merge も不能になり、救済経路を閉じる。同値性の担保は上記の単一代入式と契約テストが持つ
- **検査水準も両側で非対称**: save helper は `verdict` を 2 値 enum として検査するが、merge ゲートは**キーの存在しか見ない**（値は読まない）。したがって `verdict: "fix-needed"` の結果 JSON が存在する状態でもゲート自体は allow する — merge を止めるのは `/rite:iterate` の収束判定であってゲートではない

#### `reviewers` — 実回収名簿、findings とは独立

**本 cycle で `pr-review.md` ステップ 5.1 が Task 結果を回収できた reviewer** を、ステップ 5.3.0.M step 1 の Claude が書く。値は各 `reviewer_type` に `-reviewer` を付した形（`security` → `security-reviewer`。`rite:` prefix は付けない）で、`plugins/rite/agents/*-reviewer.md` の basename と一致する。ゲート helper は本キーに触れない (変換 jq は `.findings` / `.non_blocking_findings` / `.overall_assessment` / `.verdict` 以外のトップレベルキーをそのまま保持する)。

**「実回収」を唯一の基準にする理由**: 選定時点のスナップショットを基準にすると、その後に集合が変わる経路（ステップ 3.3 standalone 確認での追加・削除、ステップ 4.4 の `incomplete` マーク）ごとに除外規則を書き足すことになり、書き漏らした経路が名簿の過大・過少計上として残る。回収できたかどうかは全経路の帰結を 1 つの述語で表すため、規則が 1 本で済む。

- **`findings[].reviewer` から導出してはならない**: マージ直前の最終 cycle は findings 0 件が正常形であり、そこから名簿を導出すると「誰もレビューしていない」形になって sole-reviewer guard が成立しなくなる
- **名簿を水増ししてはならない**: 回収できなかった reviewer を載せると、実際には走っていないレビューで sole-reviewer guard の floor 2 を満たせてしまう。回収の結果 1 名になった cycle は保存は通りマージは deny される — それが正しい挙動である
- **下限がゲートと save helper で非対称**: save helper は**非空**のみを要求し、merge ゲートは**長さ 2 以上** (sole-reviewer guard floor) を要求する。`review.min_reviewers: 1` の下で、どの reviewer パターンにもマッチせず code-quality が単独 fallback になった cycle は 1 名になりうる（`skills/pr-review/SKILL.md` ステップ 2.3 の sole-reviewer guard は「code-quality が既に単独のときは追加しない」という明示的例外を持つ）。その結果は**保存はできるがマージはできない**。save helper 側を 2 に揃えると、その 1 名レビューの結果が永続チャネルから丸ごと消える。**なお XS/S 軽量レーンはこの経路ではない** — 軽量レーンが渡すのは上限 (`complexity_max = 3`) だけで、`skills/reviewers/SKILL.md` Phase 5 の effective floor `max(min_reviewers, sole_reviewer_guard_floor)` が最終 clamp で常に勝つ
- **1 名 cycle の解消手段は 2 種で、原因によって効くものが違う**: (a) パターン無マッチで code-quality が単独 fallback になった cycle は、同じ diff で再レビューしても選定が同一なので **`review.security_reviewer.mandatory: true` を設定する**（ゲートの deny メッセージが案内する「再レビュー」だけでは floor 2 に到達しない）。**`review.min_reviewers` を上げても効かない** — `skills/reviewers/SKILL.md` Phase 4 は本キーを「どの reviewer にもマッチしなかったときに code-quality を選ぶ」fallback のラベルとしてのみ使い（`- min_reviewers: Minimum reviewers to select` の宣言行と見出し `Apply Minimum Limit` は下限の表明に留まり、選定数をその値まで**増やす手続き規則を持たない**）、Phase 5 は `effective_max`（上限）の floor と narrowing 時の保持フロアとして使う。どちらも「選定数が足りないから reviewer を足す」向きには働かず、ステップ 2.3 の sole-reviewer guard は code-quality が既に単独のとき明示的に追加しない。(b) 2 名選定のうち片方が spawn に失敗して回収できなかった cycle は、失敗が一過性なら**再レビューで解消する**。**どちらの場合も名簿の水増しで通してはならない**（`reviewers` の一意性は save helper が検査するが、実在名での水増しは機械的に塞げない — 散文規約が唯一の担保である）
- **一意性は save helper が検査する**: ゲートは長さしか見ないため、`["security-reviewer", "security-reviewer"]` のような重複ロスターは floor 2 を機械的に満たしてしまう。これを塞ぐのは writer 側の責務で、`hooks/review-result-save.sh` が重複を fail-loud で拒否する（floor 2 自体は save 側へ持ち込まない — 一意性と下限は独立した検査であり、1 名 cycle の保存性は変わらない）

#### 旧形式 JSON の非救済

両キーを欠く既存の結果 JSON (本変更より前に保存されたもの) は merge ゲートに deny され続ける。ゲートは version 値ではなく**キー存在**で新旧を判別するため、遡及補正や version による例外は入れない。復旧経路は `/rite:pr-review` の再実行 (= 正典 writer による書き直し) のみ。

### `reviewer_timings` と直列化フラグ

<a id="reviewer_timings-と直列化フラグ"></a>

reviewer の並列起動が実際に並列だったかを事後に観測するための audit-only な 3 キー。`pr-review.md` ステップ 4.6 が収集し `hooks/scripts/review-spawn-spread-check.sh` が判定して、ステップ 5.3.0.M step 1 が結果 JSON へ転記する。

**なぜ記録するのか**: 並列起動は SKILL.md が MUST で多重に宣言しているが、実測では長時間セッションの後半で reviewer が逐次完走し、レビュー壁時計が数倍化した run がある。その違反はどこにも残らず、事後に検出する計器が存在しなかった。**強制ではなく観測**に留めるのは、Task 発行が LLM の応答構造そのもので hook から強制できないため。

**判定 consumer への影響はゼロ**: 直列化は効率違反であって品質低下ではない (成果は有効のまま) ため、`overall_assessment` / `verdict` / merge ゲート / 収束トレンド判定のいずれもこの 3 キーを読まない。`review-result-save.sh` も必須フィールドとして要求しないため、3 キーが揃わない結果 JSON も従来どおり保存され merge できる。

**3 値モデル (`true` / `false` / 欠落)**: `reviewer_spawn_serialized` と `reviewer_spawn_spread_seconds` は**判定できたときのみ**書かれ、計測不能ではキーごと欠落する。「並列だった」と「測れなかった」を `false` に丸めると、計測失敗が直列化の隠れ蓑になるため。何が測れなかったかは `reviewer_timings[].started_at` の `null` に残る。計測不能の理由自体は helper が `[CONTEXT] SPAWN_SPREAD=undetermined; reason=` として会話へ出すもので、本 JSON には持たない (永続化する意味を持つのは計測値であって、その cycle 限りの失敗理由ではない)。

**schema_version は bump しない**: `verification` / `verdict` / `reviewers` と同じ additive 追加の方針で、読取側 accept list 4 箇所の同期変更を避ける。read 側は未知キーを無視するため旧 reader でも壊れない。**`schema_version == "1.1.0"` から本 3 キーの存在を推論してはならない**。

### `non_blocking_findings` 配列

<a id="non_blocking_findings-配列"></a>

`/rite:pr-review` ステップ 5.3.0.M の実測必須ゲートで **non-blocking に降格した非実測指摘**を保持するトップレベル配列。要素のスキーマは `findings[]` と**同一** (上記 [findings[] 要素](#json-schema) の表の全フィールド — `pre_existing` を含む。本節では再掲しない)。

**設計判断 — なぜ `findings[]` に混ぜないか**: `findings[]` は「merge を止める集合」という単一の意味を持ち、`overall_assessment` / `total_findings` / cross-field invariant #2 のいずれもその前提で書かれている。非実測指摘を同配列に混ぜると invariant #2 (mergeable × open CRITICAL/HIGH 禁止) を read 側 3 経路 + 本 SoT で同時に緩める必要が生じる。独立配列にすれば `findings[]` の契約を一切変えずに記録だけを永続化できる。

**なぜ optional で schema_version を bump しないか**: `verification` と同じ additive 追加の方針。読取側 accept list 4 箇所の同期変更を避ける。read 側は未知キーを無視するため旧 reader でも壊れない。

**0 件のときも空配列 `[]` を出力する** (キー省略との区別): キー自体が無い JSON は「本ゲート適用前の世代」を意味し、空配列は「本ゲートを適用したが降格ゼロ」を意味する。両者を区別できないと、降格が起きたのに記録されなかった事故を後から検出できない。

**本配列側の欠陥はすべて非ブロッキング**: `hooks/review-result-save.sh` は以下を WARNING + observability marker で報告するが、**いずれも保存を続行する** (`JSON_SAVED=true`)。`LOCAL_SAVE_FAILED` 経路にすると `JSON_SAVED=false` でファイルごと保存されず、advisory な監査記録の欠陥を理由に blocking findings まで永続チャネルから失う fail-unsafe になるため (救おうとした対象より大きなものを落とす)。

| 検出内容 | marker |
|---|---|
| キー欠落 / 非配列 (string / number / bool / object / null) | `[CONTEXT] NON_BLOCKING_FINDINGS_KEY_MISSING=1; pr={n}` |
| 和集合での id 重複 / 書式違反 (本配列側に起因) | `[CONTEXT] NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION=1; pr={n}` |

**hard fail は `findings[]` 側の id 欠陥に限る** (`LOCAL_SAVE_FAILED=1; reason=finding_id_format_or_uniqueness_violation`)。また型 check は id 検証より**前**に置く — 後ろに置くと非配列で `length` が非 0 になる値 (`"abc"`→3 / `3`→3 / `{"a":1}`→1) が和集合の件数を水増しし、非ブロッキングと宣言した経路が型によって hard fail に化ける。

**`id` は 2 配列の和集合で一意**: 5.3.0.M の降格時に `id` を振り直さず元の `F-NN` を維持する。根拠は **JSON 単体の監査可読性** — 永続 JSON を読む人間が 2 配列を跨いで finding を一意に参照できるようにするため (5.4 統合レポートのテーブルは `id` 列を持たないので、JSON ↔ レポート間の id 相互参照は成立しない。それを目的とした規則ではない)。強制層は `hooks/review-result-save.sh` の id 検証で、`findings[]` と `non_blocking_findings[]` の和集合に対して書式 + 一意性を評価する (本配列側に閉じた違反は上記の非ブロッキング marker で報告され、保存は続行する)。

**read 側の扱い**: 現時点で本配列を消費する read 経路は無い (`/rite:fix` は `findings[]` のみを読む)。本配列は **人間がマージ後に拾い直すための監査記録**である。既定構成 (`pr_review.post_comment: false`) では PR 本体のレビュー結果コメントが投稿されないため、非実測指摘の永続チャネルは `.rite/review-results/*.json` と、`post_comment` と独立に投稿される記録コメント (`## 📜 rite 非実測指摘の記録`、ステップ 6.1.d) の 2 つになる。前者はローカルの永続チャネル (`state-path-resolve.sh` によりセッション worktree 内からでも main checkout と同一パスに解決される。§保存場所 参照)、後者は PR 上で共有可能な永続チャネルであり、`.rite/review-results/` は gitignore 対象のためレビュアーと共有できるのは後者のみ — **ただし後者が共有するのは reviewer / severity / `file:line` のポインタまでで、`description` / `suggestion` の全文は本配列にしか存在せず共有経路を持たない**。マージ後も全文を残すため、`/rite:cleanup` ステップ 6 は本配列が非空の結果 JSON を削除せず `.rite/review-results/archive/` へ退避する (詳細: [`severity-levels.md` §実測必須ゲート](./severity-levels.md#実測必須ゲート-measured-confirmed-gate))。

### `verification` サブフィールド

<a id="verification-サブフィールド"></a>

`findings[].verification` オブジェクトのサブフィールド定義。「実測」の記録形式を LLM の自由裁量に委ねると後段で機械処理できないため、**write 側が `verification` を出力する際に守るべき形式を本表で固定する**。

**write 側の配線**: `pr-review.md` ステップ 5.3.0.M の [`scripts/review-measured-gate.sh`](../scripts/review-measured-gate.sh) が、`findings[].description` の `Verification:` アンカーから本表の形式で `verification` を設定する**唯一の書き手**である。**ただし全 finding に設定するとは限らない** — gate 対象 scope (`current-pr` / `follow-up`) の finding のうち、アンカー文字列と `=>` が**同一セグメント内**にあるのに検出 regex に match しない形式崩れのものには、`measured=false` と確定させずに **`verification` を設定しない**ことで「未判定」を表現する。したがってゲート適用後の JSON でも `verification` は欠落しうる ([3 値モデルへの上書き](#3値モデルへの上書き) の判定 consumer 側規定がそのまま効く)。同ステップの生成規約は Claude が `verification` を書くことを禁じており (先に書かれた boolean を helper が既存値として尊重してしまい、アンカー検出を経ない値が blocking 判定へ入るため)、本表は helper が満たす形式契約として読む。read 側の受理範囲は本表より広い — [verification 型ガード (read 側)](#verification-型ガード-read-側) を参照 (`verification: {}` や `measured` 欠落も受理する。記録・表示経路では default mapping で `measured=false` に畳み、**判定 consumer では「未判定」= blocking として扱う** — [3 値モデルへの上書き](#3値モデルへの上書き)):

| フィールド | 型 | 必須 (write 側が出力する場合) | read 側の受理 | 説明 |
|-----------|-----|------|------|------|
| `measured` | bool | ✅ (出力するなら 3 キーをすべて埋める) | 欠落 / null 許容 (記録・表示経路では `measured=false` 扱い、**判定 consumer では「未判定」= blocking** — [3 値モデルへの上書き](#3値モデルへの上書き))。**型は boolean/null のみ** (型ガード) | runtime 実測の有無。`true` には `repro` / `failing_test` の**少なくとも一方が非 null かつ非空文字列**であることが必須 (Cross-field invariant #6) |
| `repro` | string \| null | ✅ (null 可) | 欠落 / null 許容 (read 側は値を jq 評価しないため型制約なし) | 再現手順。**形式固定**: `<再現コマンド> => <観測される誤動作>` (`=>` 区切り)。例: `bash hooks/foo.sh --bad-arg => ERROR: unbound variable`。`内容` 列に raw `|` (パイプ) を含めない制約は本フィールドにも及ぶ (理由と代替表記は `agents/_reviewer-base.md` の §Verification: runtime 実測の添付 の Rules) |
| `failing_test` | string \| null | ✅ (null 可) | 同上 | failing test。**形式固定**: `<テストパス> => <失敗出力>` (`=>` 区切り)。例: `hooks/tests/test-foo.sh => TC-03 FAILED: expected 0 got 1`。raw パイプ制約は `repro` と同じ |

### severity 別名マッピング表

外部レビューツール (`/verified-review`, `pr-review-toolkit:review-pr`, 手動コメント等) が出力する severity 表記を、本 schema の 5 値 enum (`CRITICAL`/`HIGH`/`MEDIUM`/`LOW-MEDIUM`/`LOW`) に正規化する際の受理可能な別名一覧。**比較は必ず case-insensitive で行うこと** (例: `Critical` / `critical` / `CRITICAL` はいずれも `CRITICAL` にマッチ)。

| 認識される別名 (case-insensitive) | 正規化先 enum 値 |
|-----------------------------------|------------------|
| `Critical`, `CRITICAL`, `BLOCKER`, `CRIT`, `🔴`, `重大`, `致命` | `CRITICAL` |
| `Important`, `IMPORTANT`, `MAJOR`, `HIGH`, `High`, `🟠`, `重要`, `高` | `HIGH` |
| `Minor`, `MINOR`, `MEDIUM`, `Medium`, `Normal`, `🟡`, `中` | `MEDIUM` |
| `Low-Medium`, `LOW-MEDIUM`, `LowMedium`, `low_medium`, `中低`, `軽中` | `LOW-MEDIUM` |
| `Low`, `LOW`, `INFO`, `TRIVIAL`, `Nit`, `NIT`, `🔵`, `低`, `情報` | `LOW` |

**運用ポリシーとの関係**: schema enum 5 値 / reviewer checklist 見出し / 運用 3 段の対応関係は [`severity-levels.md` Severity 語彙 3 系統 Crosswalk](./severity-levels.md#severity-vocabulary-crosswalk) を単一 SoT とする(本ファイルでは再定義しない)。write 側 (`pr-review.md` ステップ 6.1.a) は必ず schema enum 5 値で出力し、read 側 (`fix.md` ステップ 1.2 best-effort parser) が外部ツール由来の別名を上記マッピング表で正規化する。

**絵文字エイリアスの実運用検証状況**: 絵文字 (`🔴`/`🟠`/`🟡`/`🔵`) は将来の互換性のため列挙しているが、主要な外部ツールが絵文字を出力する事例は未検証。新しい外部レビューツールへの対応として絵文字エイリアスを追加した場合は、本表の下に注記を追加すること。

**LOW-MEDIUM 日本語別名 (`中低` / `軽中`) の実運用検証状況**: これらは LOW-MEDIUM の新造語 alias であり、主要な外部ツールが出力する事例は未検証。canonical な schema variants (`Low-Medium`, `LOW-MEDIUM`, `LowMedium`, `low_medium`) で十分な可能性があるため、運用上不要と判明した場合は本表から削除を検討すること。新しい外部ツールが日本語別名を出力する事例を確認した場合は、その出典を本表の下に追記すること。

### Cross-field invariants (型レベルで表現しきれない制約)

以下の制約は単一フィールドの型では表現できないため、write 側 (`pr-review.md` ステップ 6.1.a) が生成時に守る義務があり、read 側 (`fix.md` ステップ 1.2.0) は post-condition jq として検証する:

1. **ファイル名 ↔ JSON `pr_number` 同期**: `.rite/review-results/{pr_number}-{timestamp}.json` の `{pr_number}` prefix と JSON 内 `.pr_number` の値は必ず一致する。不一致時は read 側で WARNING + `[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_number_mismatch` を emit して legacy parser fallthrough。手動でファイルを rename した場合のみ発火しうる。
2. **`overall_assessment == "mergeable"` ∧ CRITICAL/HIGH open finding 存在禁止**: `overall_assessment` が `"mergeable"` のとき、`findings[]` に `severity ∈ {"CRITICAL", "HIGH"}` かつ `status == "open"` の要素が含まれてはならない。違反時は read 側で WARNING + `[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=mergeable_has_open_blockers` を emit して legacy parser fallthrough (手書き JSON で fix ループを silent に 0 件脱出させる bypass を防ぐ)。
3. **ファイル名 timestamp ↔ JSON `timestamp` 同期**: `{timestamp}` prefix (JST `YYYYMMDDHHMMSS`) と JSON 内 `.timestamp` (ISO 8601) は同一瞬間を指す。ただし本不変条件は read 側で検証せず (ファイル rename 時にしか破綻しえないため)、write 側が ステップ 6.1.a で一度に生成することで担保する。
4. **`severity ∈ {CRITICAL, HIGH}` ∧ `scope == "nit-noted"` 禁止**: blocker (CRITICAL/HIGH) 級の指摘は「修正不要の nit」として受け流すことができない。違反時は read 側で WARNING + `[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason={priority_prefix}_critical_high_scope_nit_noted` を emit して **legacy parser fallthrough** (invariant #2 と同じ FAIL routing)。canonical jq expression: `[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0`。reviewer が CRITICAL を nit に降格させたい場合は severity を MEDIUM/LOW へ自己降格し、`original_severity` フィールドに元値を保持すること。本 invariant は 1.1.0 JSON にのみ適用される (1.0/1.0.0 では `scope` フィールドが欠落しているため後方互換 default mapping 経由で評価)。
5. **`pre_existing == false` ∧ `scope == "nit-noted"` 禁止**: 本 PR で **新規に導入された** finding (`pre_existing == false`) を「修正不要の nit」として受け流すことは、本 PR の責任範囲内の問題を silent に放置することを意味するため禁止。違反時は read 側で WARNING + `[CONTEXT] REVIEW_SOURCE_AUTO_CORRECTED=1; reason=pre_existing_false_scope_nit_noted; count={n}` を emit し、該当 finding の `scope` を **自動で `"current-pr"` に書き換え** (auto-correct) して severity_map 構築を続行する。canonical jq mutation: `(.findings[] | select(.pre_existing == false and .scope == "nit-noted") | .scope) |= "current-pr"`。本 invariant は **#4 と異なり FAIL ではなく auto-correct** のため、JSON read 全体を fallthrough させない。1.0/1.0.0 JSON では `pre_existing` フィールドが欠落しているため本 invariant は発火しない (default mapping は scope を severity ベースで補完するのみで、`pre_existing` は補完しない)。
6. **`verification.measured == true` ∧ `repro`/`failing_test` とも null/空 禁止 (write 側 auto-correct 降格)**: 実測の証跡なしに `measured: true` を宣言することは、記録された実測フラグを無意味にするため禁止。**本 invariant は形式契約であり、現時点の配線状況の記述ではない** — `pr-review.md` ステップ 6.1.a に本自己点検を行う手順は存在しない。主経路では `review-measured-gate.sh` の `computed_verification` が `measured: true` を設定するとき、検出したアンカーから必ず `repro` または `failing_test` の片方を同時に設定するため、この組は生成されない。ただし `has_measured_bool` が保持する caller preset は別で、`--reject-preset-verification` は算出した measured 分類と食い違う preset だけを弾くため、分類が一致する `measured: true` preset の空証跡は残りうる。したがって preset 残存経路を含む invariant 自体の機械配線は後続スコープである。以下は**配線後に** write 側が守るべき挙動を規定する。**検出主体は write 側のみ** — `pr-review.md` ステップ 6.1.a が JSON 生成時に `measured=true` ∧ `repro`/`failing_test` とも null/空文字の組を検出したら `measured` を **`false` に書き換え** (auto-correct) し、WARNING を stderr に出力して続行する。これは機械 helper (`review-result-save.sh` は `verification` を検証しない) ではなく **Claude の生成時自己点検**であり、canonical jq mutation はその自己点検に使う参照式: `(.findings[] | select((.verification.measured // false) == true and ((.verification.repro // "") == "") and ((.verification.failing_test // "") == "")) | .verification.measured) |= false`。**read 側 (`fix.md` ステップ 1.2.0) は auto-correct を実装しない** (#5 が read 側 auto-correct を持つのと異なる) — 実測証跡の空検出は write 側と `pr-review.md` ステップ 5.3.0.M の anchor regex 層が担い、read 側で二重に降格させると同一 finding が 2 経路で non-blocking 化して降格理由の帰属が失われるため。ただし**型**は read 側で検証する (違反は専用 reason で reject — [verification 型ガード (read 側)](#verification-型ガード-read-側))。`verification` フィールド自体が欠落している finding は本 invariant の対象外 (判定 consumer からは未判定、記録・表示経路では `measured=false` の default mapping が適用されるのみ)。

## 後方互換性 (schema 1.0 ↔ 1.1.0)

<a id="後方互換性-schema-10--110"></a>

1.1.0 で導入された `findings[].scope` / `findings[].pre_existing` フィールドは 1.0 / 1.0.0 JSON には欠落しているため、read 側 (`fix.md` ステップ 1.2.0) は schema_version が `"1.0.0"` または `"1.0"` の場合、下記 `scope` 節の default mapping を適用する。`pre_existing` は 1.1.0 JSON でも欠落しうる additive optional field であり、schema_version に依らず default mapping を**適用しない** — 下記 `pre_existing` 節参照。欠落のまま保持することが invariant #5 の後方互換の前提になっている。

**`verification` の default mapping のみ schema_version に依らず適用される** — `verification` は 1.1.0 内で additive 追加されたため 1.1.0 JSON でも欠落しうる ([Schema Version](#schema-version-sot) 参照)。schema_version で gate してはならない。

### scope の default mapping

`findings[].scope` が欠落している場合、`findings[].severity` から以下のルールで補完する:

| severity | default scope |
|----------|--------------|
| `CRITICAL` | `current-pr` |
| `HIGH` | `current-pr` |
| `MEDIUM` | `current-pr` |
| `LOW-MEDIUM` | `nit-noted` |
| `LOW` | `nit-noted` |

canonical jq expression (1.0/1.0.0 受信時に適用):

```
.findings |= map(
  if has("scope") then .
  else .scope = (
    if .severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" then "current-pr"
    else "nit-noted"
    end
  )
  end
)
```

### pre_existing の default mapping (適用しない)

`findings[].pre_existing` が欠落している場合、**default mapping は適用しない** (フィールドを欠落させたまま保持する)。これは:

- `pre_existing` の判定には revert test (reviewer による mental revert) が必要で、severity 等の他フィールドから機械的に推論できない
- 欠落のままにすることで Cross-field invariant #5 (`pre_existing == false × scope == nit-noted`) が **発火しない** (`null != false`)
- 1.0/1.0.0 JSON と、`pre_existing` を出力しない canonical 1.1.0 write path の finding は invariant #5 の auto-correct 対象外となる

### verification の default mapping (記録・表示経路のみ、measured=false 扱い)

**適用範囲**: 本節の default mapping が有効なのは **記録・表示・後方互換の非エラー化** を目的とする読取経路に限る。`measured` を **blocking 判定の入力として消費する層** には適用しない (下記「3 値モデルへの上書き」参照)。

`findings[].verification` が欠落している場合 (schema 1.0 / 1.0.0 の旧形式、verification 導入前に生成された 1.1.0 JSON、および実測必須ゲートが形式崩れアンカーを未判定として残した現行世代 JSON)、記録・表示経路は当該 finding を **`measured=false` (実測なし)** として扱う。フィールドの物理的な補完は不要で、値を参照する側が `(.verification.measured // false)` で評価すればよい (jq の `//` が欠落・null を false に畳む)。エラーにはしない:

```
(.verification.measured // false) == true   # 記録・表示経路の評価式 (欠落 = false)。判定経路では使用禁止 — 下記「3 値モデルへの上書き」参照
```

- 旧形式 JSON を read してもエラーなく処理が続行される (既存の抽出ロジックは `verification` を参照しないため無影響)
- `scope` の default mapping とは独立に適用される (scope は severity から補完、verification は一律 `measured=false`)
- Cross-field invariant #6 は verification 欠落時には発火しない (対象は `measured: true` を明示宣言した finding のみ)

<a id="3値モデルへの上書き"></a>

> **3 値モデルへの上書き (以降、判定 consumer に限る)**: 上記 default mapping は `measured` が **判定に使われない記録専用フィールド**だった時点の規定であり、`measured` を **blocking 判定の入力として消費する層**には適用しない。実測必須ゲート ([severity-levels.md §実測必須ゲート](./severity-levels.md#実測必須ゲート-measured-confirmed-gate)) の consumer は `measured` を **3 値** (`true` / `false` / **未判定**) として扱い、**`verification` 欠落 / `verification.measured` 欠落は「未判定」= ゲート対象外 = 従来どおり blocking** と解釈する — 降格するのは `measured: false` を**明示宣言**した finding のみ。判定経路で `(.verification.measured // false)` を使ってはならない (jq の `//` が欠落と `false` を同一視するため、write 側が `verification` を出力しない世代の JSON で全 finding が non-blocking に畳まれ、レビューループが指摘を解消しないまま空転する)。判定経路の canonical 述語は「`.verification` が object かつ `.verification.measured` が boolean のときのみ登録し、値をそのまま採用する」で、SoT は [`fix/SKILL.md`](../skills/fix/SKILL.md) ステップ 1.2.1 step 6 / ステップ 1.3 measured lookup。
>
> 本節の default mapping は依然として**判定以外の読取 (記録・表示・後方互換の非エラー化)** に有効であり、型ガードが `verification: {}` を受理することにも変更はない。

<a id="verification-型ガード-read-側"></a>

**verification 型ガード (read 側)**: `findings[].verification` は **object または欠落 (null)** のみ、`findings[].verification.measured` は **boolean または欠落 (null)** のみ受理する。read 側 (`scripts/review-source-resolve.sh` の Priority 0 / Priority 2) は invariant 評価の**前段**で両方の型を検証し、違反時は専用 reason `{explicit_file|local_file}_verification_type_invalid` で WARNING + routing する (P0 → fallback、P2 → Priority 3 + `.corrupt-{epoch}` rename)。`measured` の**存在**は要求しない (`verification: {}` は型ガードを通過する。判定 consumer からは `measured` 未登録 = **未判定** として扱われる — [3 値モデルへの上書き](#3値モデルへの上書き) 参照)。silent 受理 (`.measured?` での握り潰し) は型崩れという schema 違反シグナルを消すため採用しない。canonical jq: `all(.findings[]?; (.verification == null) or (((.verification | type) == "object") and ((.verification.measured == null) or ((.verification.measured | type) == "boolean"))))`

**ガードを invariant の前段に置く理由（prospective）**: 現時点の read 経路に `.verification.measured` を評価する式は本ガード自身以外に存在せず、後段の invariant #2 / #4 / enum チェックはいずれも `.verification` を参照しない。したがって「非 object の verification が後段を rc=5 にして誤合流する」ことは**現在は起きない**。前段配置が守るのは、`.verification` が object かつ `.verification.measured` が boolean のときのみ値を採用する **3 値判定 consumer** (`fix/SKILL.md` ステップ 1.2.1 step 6 / ステップ 1.3 measured lookup) であり、型崩れを弾いておく予防的配置である。判定 consumer は default mapping 節の `(.verification.measured // false)` 形を**使わない** (同節「3 値モデルへの上書き」参照) (invariant #6 の自己点検式は write 側の責務なので、read 経路に置いた本ガードの保護対象には含まれない)。P0/P2 で先に弾くのは、これらが永続ファイル (次回以降も再読込されうる入力) を入力に取るため — うち `.corrupt-{epoch}` rename を伴うのは P2 のみで、P0 は fallback に倒すだけである (上記 routing 参照)。順序が現時点で生む観測可能な差は reason ラベルと P2 の rename 有無で、`scripts/tests/review-source-resolve.test.sh` の順序 pin fixture (`overall_assessment: "mergeable"` + 型崩れ) がこれを機械的に固定している。

**jq 実行失敗と型崩れの分離**: ガードの jq が rc>=2 (findings 要素が非 object で nested access がランタイムエラー / jq バイナリ異常 / IO エラー) で終了した場合、型崩れ (rc=1) と同じ reason に融合してはならない。`verification` を一切持たない JSON にも `verification_type_invalid` が付いて診断が事実とずれるため、read 側は専用 reason `{explicit_file|local_file}_verification_guard_jq_failed` で routing し、**P2 では rename しない** (破損が未証明のまま破壊的操作を conflated signal で駆動しないため)。

**Priority 3 (PR コメント Raw JSON) には型ガードを置かない**: P0/P2 との違いは「その経路が `verification` を参照するか」ではなく (前述のとおり現時点ではどの read 経路も参照しない)、**入力が永続ファイルかどうか**にある。P3 の入力は PR コメント本文で、`.corrupt-{epoch}` rename に相当する退避経路を持たず、reject すると legacy Markdown parser への fallthrough による情報損失のほうが大きい。`verification` を持つ Raw JSON は P3 でも従来どおり受理される。

**P3 にガードを追加すべきトリガ** (2 つの独立した軸で判定する): (a) P3 の入力が永続ファイル化した場合 (退避経路を持てるようになるため P0/P2 と同じ扱いに揃う)、または (b) P3 の parse 経路自身が `.verification` を評価する式を持った場合 (その式が型崩れで rc=5 になるため、前段で弾く実益が生じる)。いずれかが成立した時点で本節の判定式を P0/P2 と同形で追加すること。

### REVIEW_SOURCE_SCOPE_DEFAULTED emit

scope を補完した finding が 1 件以上ある場合、read 側は以下の `[CONTEXT]` flag を stderr に emit する:

```
[CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1; reason=scope_omitted_in_v1_0; count={n}; schema_version={value}
```

- `count`: scope を default mapping で補完した finding 数
- `schema_version`: 受信した JSON の schema_version (`"1.0.0"` または `"1.0"`)
- `reason`: 常に `scope_omitted_in_v1_0`

emit の目的は observability — 「どの review-result file が 1.0 schema 由来で default mapping を被ったか」を fix workflow / debug log で trace 可能にする。1.1.0 JSON では本 flag は emit されない。

### Cross-field invariants と後方互換の相互作用

- **invariant #4** (CRITICAL/HIGH × nit-noted FAIL): 1.0/1.0.0 では CRITICAL/HIGH → `current-pr` に default mapping されるため、invariant #4 は **発火しない** (規約的に違反不可能な状態)
- **invariant #5** (pre_existing=false × nit-noted auto-correct): 1.0/1.0.0 では `pre_existing` が欠落 (`null`) のため、invariant #5 は **発火しない**
- **invariant #6** (measured=true × 証跡なし): `verification` が欠落した JSON (1.0/1.0.0 全般、および verification 導入前の 1.1.0) では `measured` を明示宣言していないため **発火しない**。型ガードも `verification == null` を受理するため、旧形式は前段でも reject されない

つまり 1.0/1.0.0 JSON は read 後の severity_map 構築段階で invariant #4/#5 を確定的に pass する。これは「1.0 互換性を保ったまま 1.1.0 invariants を追加する」設計判断 — 既存 PR で生成された 1.0 JSON を re-read しても新規 invariant 違反で fallthrough しないことを保証する。

## PR コメント形式 (opt-in)

`--post-comment` または `rite-config.yml` の `pr_review.post_comment: true` 指定時、PR コメントには以下の形式で投稿される (外側 4-backtick fence で内側 3-backtick fence を透過的に含む):

````markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: 修正必要

### 全指摘事項

#### code-quality-reviewer
- **評価**: 要修正

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| HIGH | current-pr | path/to/file.ts:42 | エラーハンドリングが不足 | try-catch を追加 |

---

### 📄 Raw JSON

```json
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "2026-04-11T12:34:56+09:00",
  "commit_sha": "abc1234",
  "overall_assessment": "fix-needed",
  "verdict": "fix-needed",
  "reviewers": ["code-quality-reviewer", "security-reviewer"],
  "findings": [
    {
      "id": "F-01",
      "reviewer": "code-quality-reviewer",
      "category": "code_quality",
      "severity": "HIGH",
      "scope": "current-pr",
      "pre_existing": false,
      "verification": {
        "measured": true,
        "repro": "node dist/cli.js --input empty.json => TypeError: Cannot read properties of undefined",
        "failing_test": null
      },
      "file": "path/to/file.ts",
      "line": 42,
      "description": "エラーハンドリングが不足",
      "suggestion": "try-catch を追加",
      "status": "open"
    }
  ],
  "non_blocking_findings": []
}
```
````

- 既存の Markdown テーブル形式は保持 (後方互換、人間可読性)
- 末尾に `### 📄 Raw JSON` セクションを追加し、code fence で JSON を埋め込む
- `/rite:fix` ステップ 1.2.0 Priority 3 は code fence 内の JSON を `---` separator 以降の **最後** の `### 📄 Raw JSON` section に scope 限定して抽出する。awk パーサの対象は PR コメント本文 (`gh pr view --json comments` で取得した文字列) のみで、リポジトリ内の本ドキュメント (schema.md) を読むことはない。scope 限定の目的は、finding の `description` / `suggestion` 列内に literal `### 📄 Raw JSON` 文字列が含まれる場合 (本 PR 自身が該当) の誤捕捉を防ぐこと。POSIX awk のみで動作する 1-pass + END 逆方向スキャン実装は fix.md ステップ 1.2.0 の bash block を参照

## 読取優先順位 (fix)

`/rite:fix` は以下の優先順位でレビュー結果を取得する:

| Priority | ソース | 発動条件 | 失敗時の動作 |
|----------|-------|---------|-------------|
| 0 | **明示的ファイル指定** | `--review-file <path>` 指定時 | 指定パスを読取。**6 種の失敗モード** (パス不在 / JSON 不正 / schema_version 不明 / `explicit_file_verification_type_invalid` (verification が object/null 以外、または measured が boolean/null 以外 — 型ガード) / `explicit_file_verification_guard_jq_failed` (型ガードの jq が rc>=2 で失敗) / `explicit_file_commit_sha_mismatch` (json commit_sha が HEAD と不一致、stale file protection)) のいずれでも Priority 1-3 にフォールスルーせず直接 Priority 4 (対話式 fallback) へ遷移 (ユーザーの明示意図を尊重) |
| 1 | **会話コンテキスト** | 同一セッション内で `/rite:pr-review` が直前に実行されていれば、その結果を直接利用。**採用時は `[CONTEXT] REVIEW_SOURCE=conversation; pr_number={pr_number}` を stderr に emit する義務がある** (observability 義務、後段の provenance log に必要) | Claude が会話履歴に rite review 結果を見つけられなかった場合は次の Priority へ |
| 2 | **ローカルファイル** | `.rite/review-results/{pr_number}-*.json` の中で最新 `timestamp` のファイル (lexicographic sort) | **6 種の失敗モードいずれも** WARNING を出して **Priority 3 (PR コメント) に直接 routing** する: (a) `local_file_json_parse_failure` (`jq empty` で JSON syntax invalid、`.corrupt-{epoch}` rename あり)、(b) `local_file_schema_required_fields_missing` (parse 可能だが `schema_version` 非空文字列 / `pr_number` 数値型 / `findings[]` 配列型のいずれかが欠落、rename あり)、(c) `local_file_verification_type_invalid` (verification が object/null 以外、または measured が boolean/null 以外 — 型ガード、rename あり)、(d) `local_file_verification_guard_jq_failed` (型ガードの jq が rc>=2 で失敗 — **rename なし**。破損が未証明のため破壊的操作をしない)、(e) `local_file_schema_version_unknown` (schema_version 未知、**rename なし**)、(f) `local_file_commit_sha_mismatch` (json commit_sha が現 HEAD と不一致、stale file protection、**rename なし**)。古い timestamp ファイルには fallback しない |
| 3 | **PR コメント (後方互換)** | PR コメントの `## 📜 rite レビュー結果` セクション (新形式: `### 📄 Raw JSON` 付き → awk で Raw JSON section-scoped 抽出。旧形式: Markdown テーブル → 既存パースロジック) | 失敗モード: (a) `pr_comment_raw_json_parse_failure`、(b) `pr_comment_schema_required_fields_missing`、(c) `pr_comment_schema_version_unknown` は legacy Markdown parser へ fallthrough。(d) `pr_comment_commit_sha_mismatch` は **WARNING のみで continue** (Raw JSON の severity_map 構築を続行。PR コメントは最新 push 後に投稿される可能性が高く、legacy parser への fallthrough はむしろ情報損失になるため) |
| 4 | **対話式 fallback** | 上記すべて欠落時 | `AskUserQuestion` で「レビュー実行 / ファイルパス指定 / 中止」を提示 (ファイルパス指定は 1 回のみ再実行する one-shot。retry ループ・state file hard gate なし。再実行でも invalid なら `[fix:error]` で終了) |

**Priority 1 emit 義務の理由**: Priority 1 は Claude の自然言語判断に依存する経路で bash の if-else では捕捉できない。後段の ステップ 4.5.3 / 4.6 で `{review_source}` を log に出すため、conversation 経由で取り込んだ場合も他の Priority と同様に provenance を残す必要がある。emit 忘れは silent provenance loss となり、fix 後のトラブルシュートが困難になる。

**Priority 0 の non-trivial 挙動**: `--review-file` 失敗時は Priority 1-3 にフォールスルーせず直接 Priority 4 (対話式 fallback) に遷移する。これはユーザーが明示的に特定のファイルを指定した意図を尊重するため — silent に別ソースから読み込むと予期しない finding が fix 対象になるリスクがある。

**Priority 2 schema_version 不明時の挙動**: lexicographic sort で選ばれた最新ファイルが未知 schema の場合、古い timestamp ファイルには fallback せず、直接 Priority 3 (PR コメント) に routing する。これは「古い schema のファイルを選ぶより、最新の通信経路 (PR コメント) を信頼する」という設計判断。

**Stale file detection (Priority 0/2/3 共通の commit_sha mismatch routing)**: `fix.md` ステップ 1.2.0 は各 Priority の success 経路で `json_commit_sha` を `git rev-parse HEAD` と比較し、不一致時は以下の routing を実行する (cycle 12 I-4 で本 table に明記):

- Priority 0 mismatch → Priority 1-3 にフォールスルーせず **Priority 4 (対話式 fallback)** へ直接遷移 (ユーザー意図尊重)
- Priority 2 mismatch → **Priority 3 (PR コメント)** へ routing
- Priority 3 mismatch → **WARNING のみで continue** (Raw JSON の severity_map 構築を続行、legacy Markdown parser への fallthrough はしない)。**注意: Priority 2 も stale で Priority 3 に routing された場合、Priority 3 の stale データが WARNING のみで消費されるカスケードが発生しうる** (WARNING には P2 stale 経由であることを明示する文言を含む)

retained flag: `[CONTEXT] REVIEW_SOURCE_STALE=1; reason={explicit_file|local_file|pr_comment}_commit_sha_mismatch` を stderr に emit。これは「review した時点の commit と現 HEAD が異なる場合、findings は既に修正済み / 意味を失っている可能性がある」という invariant を守るための defense-in-depth。`fix.md` ステップ 1.2.0 の bash block 内の各 Priority success 経路にある `commit_sha stale detection` コメントアンカーを参照。

## 明示的ファイル指定

`/rite:fix --review-file <path>` で任意のファイルパスを直接指定可能。パスが存在しない / JSON パース失敗時はエラーを表示して対話式 fallback に誘導する (上記 Priority 0 行参照)。fix.md ステップ 1.0.1 で `$ARGUMENTS` から `--review-file` トークンを pre-strip し、ステップ 1.0 Detection rules は残りの引数のみを評価する。

## エラーハンドリング

> **Priority 別の routing ルールは上記「読取優先順位 (fix)」表が Single Source of Truth**。本セクションは write 側 (`/rite:pr-review`) と引数整合性のエラーのみを扱う。read 側 (`/rite:fix`) の失敗経路は Priority 別に大きく挙動が異なるため、本表では要約せず Priority 表と直下の「Priority 0 の non-trivial 挙動」「Priority 2 schema_version 不明時の挙動」の注記を参照のこと。特に `--review-file` (Priority 0) の失敗は Priority 1-3 にフォールスルーせず直接 Priority 4 に遷移する点、およびローカルファイル (Priority 2) の parse/schema 失敗は古い timestamp ファイルではなく Priority 3 に直接 routing する点は、旧版の「次の優先順位のソースを試行」要約と異なる。

### Write 側 (`/rite:pr-review`) のエラー

| 条件 | 挙動 |
|------|------|
| `.rite/review-results/` ディレクトリ作成不可 | 警告表示し、会話コンテキストのみで続行 (`/rite:pr-review` 全体は失敗扱いにしない — D-04 non-blocking contract) |
| JSON 書き込み失敗 | 警告表示し、PR コメント投稿または会話コンテキスト経由で続行 (D-04 non-blocking contract、ただし `post_comment=false` ∧ save 失敗時は H-1 で WARNING に昇格し復旧手順を提示) |
| 同一秒連続実行での file path 衝突 | collision 検出時に `~<4桁hex>` suffix (`~$(printf '%04x' "${RANDOM:-0}")` 相当) で回避を試みる (best-effort、完全保証ではない — M-2 tradeoff)。separator は `~` (0x7E) を使用。ファイル名分岐点で `.` (0x2E) < `~` (0x7E) のため collision-resolved 版が lexicographic 大 → `sort -r` で先頭に並ぶ (cycle 8 M-2 で `-` から変更済み) |

### 引数整合性のエラー

| 条件 | 挙動 |
|------|------|
| `--post-comment` と `--no-post-comment` 同時指定 | エラーメッセージを表示して終了 (レビューもコメント投稿も実行しない — AC-8) |

## クリーンアップ

`/rite:cleanup` は PR マージ後のブランチ削除時に、該当 PR 番号のローカル artifact を **削除または退避** する。レビュー結果ファイルだけが条件付き退避で、それ以外は無条件削除。reason 語彙の単一の真実の源は artifact ごとに異なる — レビュー結果ファイルは helper (`hooks/scripts/review-results-archive-or-rm.sh`) の docstring、それ以外は `cleanup.md` ステップ 6 (双方向リンク。旧 Phase 2.5 から ステップ 6 へ flat 化済):

1. **レビュー結果ファイル**: `.rite/review-results/{pr_number}-*.json*` — **`non_blocking_findings[]` が非空なら削除せず `.rite/review-results/archive/` へ退避する**。記録コメント (`pr-review.md` ステップ 6.1.d) がポインタしか載せないため、無条件削除すると非実測指摘の全文が merge 直後にどこにも残らない。中身を判定できない場合 (jq 不在 / parse 失敗 / query error / 空ファイル) もすべて退避側 (安全側) へ倒し、判定不能が起きた事実を `{label}_undecidable` marker で残す。**glob が `.json` ではなく `.json*` なのは `.json.corrupt-*` を同じ経路に載せるため** — corrupt は「中身を判定できない」状態そのものなので、別経路で無条件削除すると同一ステップ内に「判定不能は保全」と「判定不能は削除」の 2 ポリシーが並ぶ (`scripts/review-source-resolve.sh` の corrupt rename 3 経路のうち 2 つは構造的に valid な JSON で、`non_blocking_findings[]` の全文を保持しうる)
2. **fix retry state file（legacy）**: `.rite/state/fix-fallback-retry-{pr_number}.count` — 旧 retry-counter 機構が生成した orphan の回収。retry-counter 機構の廃止により `fix.md` は現在このファイルを生成しないが、旧版が残した file を掃除するため削除対象に残す

上記のほか、`fix-cycle-state/{pr_number}.json` / legacy `fix-cycle-state.json` / `accepted-fingerprints-{pr_number}.txt` / `review-run-since-{pr_number}.txt` も同ステップで無条件削除される (完全な列挙は `cleanup.md` ステップ 6 の bash block が単一源)。

**`archive/` 配下は自動削除されない** — 退避したファイルは PR ごとに蓄積する。掃除機構は実需が出るまで設けない (`no_speculative_structure`)。不要になったら手動削除する。走査系 helper (`review-schema-version-check.sh` / `review-trend-divergence.sh`) はいずれも `-maxdepth 1` のため退避先を拾わない。

wildcard は PR 番号 prefix 固定とし、他 PR のファイルを誤って削除しないよう保証する。state file は specific path (`{pr_number}.count` 完全一致) で削除する。

## 関連ファイル

- `plugins/rite/skills/pr-review/SKILL.md` ステップ 6.1: JSON 生成と保存ロジック (AC-1 default stop / AC-2 opt-in posting / D-04 non-blocking contract)
- `plugins/rite/skills/fix/SKILL.md` ステップ 1.2.0: ハイブリッド読取ロジック (AC-3/4 会話/ファイル優先 / AC-5 後方互換 / AC-6 対話式 fallback)
- `plugins/rite/skills/cleanup/SKILL.md` ステップ 6: 自動削除/退避ロジック (レビュー結果ファイルは `non_blocking_findings[]` 非空 / 判定不能なら `archive/` へ退避、それ以外の state file は無条件削除)。レビュー結果ファイルの reason 語彙は `hooks/scripts/review-results-archive-or-rm.sh` の docstring、それ以外の failure reason と eval-order enumeration は cleanup.md 側を単一源とする。
- `rite-config.yml` `pr_review.post_comment`: グローバル設定
- `.gitignore`: `.rite/review-results/` 除外設定
