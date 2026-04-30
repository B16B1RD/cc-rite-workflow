# Comment Best Practices Reference

rite workflow がコードを生成・修正する際に従うべきコメントの SoT (Single Source of Truth)。
業界標準 (Clean Code 4 章 / Google Style Guide / JSDoc・TSDoc / Hillel Wayne) と
rite workflow 独自の主張 (Contract Rigour / Output Contract / Naming is documentation) を統合する。

> **MVP スコープ**: 本ドキュメントは Issue #699 の MVP として 6 原則 + Bad/Good 例 + Detection Heuristics + Density Guideline + Whitelist 条文を提供する。
> reviewer 側の Detection Checklist 統合は後続 Issue (Issue 2a) の責務。

## 適用フェーズ

| Phase | 適用箇所 |
|-------|----------|
| Phase 3 (Implementation Plan) | コメント生成方針の宣言 (本 MVP では各原則の Where to Apply に未反映、後続 Issue で具体化) |
| Phase 5.1 (Implementation) | 実装中のコメント記述 |
| Phase 5.4 (Review/Fix) | レビュー時のコメント品質判定、修正時の不要コメント削除 |

> **本 MVP のスコープ**: 6 原則の各 Where to Apply 節は Phase 5.1 / 5.4 の 2 フェーズのみを対象とする。Phase 3 (Implementation Plan) での適用は「Implementation Plan 内で本 SoT を参照する」という宣言レベルに留め、各原則の具体的な Phase 3 ステップ (例: 計画段階で生成予定コメントの方針を declarative に記述する仕組み) は後続 Issue で reviewer Detection Checklist 統合と合わせて定義する。

## 原則一覧

| Principle ID | Principle Name | 強さ |
|--------------|----------------|------|
| `why_over_what` | WHY > WHAT | MUST |
| `no_journal_comment` | ジャーナルコメント禁止 | MUST |
| `no_line_or_cycle_reference` | 行番号 / cycle 番号参照禁止 | MUST |
| `no_jargon_abuse` | 独自社内ジャーゴン濫用禁止 (whitelist 経由で除外) | SHOULD |
| `density_by_audience` | 公開 API と内部で密度を変える | SHOULD |
| `comment_rot_is_critical` | Comment Rot は CRITICAL (嘘のコメントは無コメントより悪い) | MUST |

---

## A. 6 原則 (Principle Details)

### 1. why_over_what (WHY > WHAT)

**Summary**: コードで自明な「何をするか (WHAT)」は書かない。書くべきは「なぜそうするか (WHY)」、特にコードからは読み取れない隠れた制約・不変条件・回避策・歴史的経緯。

**Failure Patterns**:

- 関数の処理を逐語訳した docstring (`# user の id を返す` を `getUserId()` の前に書く)
- リテラル値の意味を説明しない (`MAX_RETRY = 3` の `3` がなぜ 3 なのか不明)
- 自明なループ・条件分岐の解説 (`# i が 0 から N まで増える間ループ`)

**Rules**:

1. WHAT を書きたくなったら、まず識別子 (関数名・変数名) で表現できないか検討する (Naming is documentation)
2. 書く WHY は次のいずれかに該当するもの:
   - 隠れた制約 (例: `// Postgres の identifier は 63 byte 上限`)
   - 不変条件 (例: `// 呼び出し元で lock 取得済みであることが前提`)
   - 回避策 (例: `// gh CLI 1.x の bug を回避するため --jq を使わない`)
   - 驚き要素 (例: `// 一見 O(n) に見えるが actually O(1) — ハッシュテーブル経由`)
3. 「コメントを消したら未来の読み手が混乱する」を判定基準にする。混乱しないなら書かない。

**Where to Apply**:

- Phase 5.1 (Implementation): コード生成時に WHAT 系コメントを排除
- Phase 5.4 (Review): WHAT 系コメントを finding として指摘

**Example (Bad → Good)**:

```python
# Bad: WHAT を逐語訳
# user_id をデータベースから取得する
def get_user_id(email: str) -> int:
    ...

# Good: WHY を残す (それも必要なときだけ)
def get_user_id(email: str) -> int:
    # email の case-folding は MySQL collation に任せる (Python 側で .lower() しない)
    ...
```

---

### 2. no_journal_comment (ジャーナルコメント禁止)

**Summary**: 個別の review cycle / fix / PR / Issue の経緯をコード内コメントに残してはならない。それらは PR description / commit message / Wiki / 経験則ページに書く。

**Failure Patterns**:

- `# verified-review cycle X F-Y で導入` のようなコードレビュー履歴
- `# 旧実装は ～。PR #N で修正` のような変更履歴
- `# cycle 38 F-04 で確立した pattern` のような cycle 番号参照
- `# F-01 regression 経路の防止のため` のような review finding ID 参照
- `# (PR #688 cycle 9 F-06 で指摘)` のような PR 内サイクル番号

**Why MUST**:

ジャーナルコメントは次の理由で技術的負債を生む。

1. **Comment Rot の温床**: 該当 cycle / PR の文脈は時間経過で失われ、未来の読み手にとっては意味不明な暗号になる
2. **ノイズ比率の暴走**: 1 つの修正で数 cycle 経るたびにジャーナルが累積し、コード:コメント比が逆転する (PR #688 `state-read.sh` で 60% コメント、うち 70% がレビュー経緯)
3. **正しい場所が空洞化**: PR description / commit message / Wiki がジャーナル受け皿として機能していれば、コード内コメントには WHY のみが残るべき

**Rules**:

1. cycle / fix / review finding / PR 番号 を参照するコメントは原則禁止
2. その変更の動機を残したい場合は、commit message → PR description → (経験則化に値するなら) Wiki に書く
3. コードに残してよいのは「未来の読み手が同じ罠にハマらないための WHY」(原則 1) のみ。「過去にハマった」記録ではなく「これから来る読み手への警告」として書く

**Where to Apply**:

- Phase 5.1 (Implementation): コード生成時にジャーナルコメントを生成しない
- Phase 5.4 (Review): ジャーナルコメントを finding として指摘し、削除を提案
- Phase 5.4 (Fix): レビュー指摘対応時にジャーナルコメントを生成しない (修正経緯は commit message に書く)

**Example (Bad → Good)**:

```bash
# Bad: cycle 番号 + PR 番号 + 過去の経緯
# verified-review cycle 35 fix (F-04 HIGH): if/else pattern instead of if! pattern.
# Bash spec: `if ! cmd; then rc=$?` always yields rc=0 because 「!」 negates the
# pipeline and `then` branch sees the negation result (always 0). Use `if cmd; then :; else rc=$?; fi`
# to capture the actual exit code. Empirical: `bash -c 'if ! curr=$(exit 42); then rc=$?; echo $rc; fi'` → 0.
if curr=$(bash state-read.sh --field phase); then
  :
else
  rc=$?
  ...
fi

# Good: WHY のみ (原則 1 を満たす範囲)
# `if ! var=$(...)` は 「!」 が pipeline 全体を反転するため $? が常に 0 になる。
# capture と exit code を両方取る場合は if/else に分ける。
if curr=$(bash state-read.sh --field phase); then
  :
else
  rc=$?
  ...
fi
```

---

### 3. no_line_or_cycle_reference (行番号 / cycle 番号参照禁止)

**Summary**: コメント内で他ファイルや同ファイルの **行番号** を参照しない。`cycle X F-Y` のような review サイクル番号も同様。これらはコード変更で容易にずれて陳腐化する (drift)。

**Failure Patterns**:

- `# state-read.sh:93 と同じパターン` (行番号は編集で容易にずれる)
- `# cycle 38 F-04 で確立した pattern` (cycle 番号は意味を持つ session が消えれば不明な符号になる)
- `# work-memory-update.sh:97-104 の関数と対称` (関数移動でずれる)

**Why MUST**:

行番号・cycle 番号参照は **DRIFT-CHECK ANCHOR** として機能しない。コード変更時に参照側が自動更新されないため、参照先と内容が時間経過で乖離する。これは原則 6 (Comment Rot is CRITICAL) の主要源。

**Rules**:

1. 他ファイルの参照はファイル名 + **意味的アンカー** (関数名・セクション見出し・identifier) で行う
2. cycle 番号 / review finding ID は原則 2 (no_journal_comment) で既に禁止だが、本原則で追加に「行番号」も禁止する
3. やむを得ず行番号を書く場合 (e.g., 外部仕様の特定行を引用) は **immutable な版** を明示する (例: `RFC 7231 Section 6.5.1` のように仕様 ID + section)

**Where to Apply**:

- Phase 5.1 (Implementation)
- Phase 5.4 (Review)

**Example (Bad → Good)**:

```bash
# Bad: 行番号と cycle 番号
# state-read.sh:93 と同じ canonical capture pattern を使う (cycle 38 F-02 で確立)
if val=$(bash state-read.sh --field foo); then ...

# Good: semantic anchor
# state-read.sh の `read_field` 関数と同じ canonical capture pattern を使う
if val=$(bash state-read.sh --field foo); then ...
```

---

### 4. no_jargon_abuse (独自社内ジャーゴン濫用禁止)

**Summary**: プロジェクト外の読み手にとって意味不明な独自ジャーゴンをコメントに濫用しない。ただし、プロジェクト内で確立されたジャーゴン (whitelist 参照) は exception として許容する。

**Failure Patterns**:

- 一度だけの discussion で生まれた造語をコメントに書く (例: `# Aki-fu pattern`)
- LLM 生成プロンプト内の造語をそのままコメントに転用する (例: `# 神 step として扱う`)

**Rules**:

1. 一度だけの discussion で生まれた造語は使わない。3 回以上独立に登場し、かつドキュメント化された語のみ使う
2. プロジェクト内で確立された語は whitelist (本ファイル末尾参照) を介して許容する
3. 外部読者が困らない第一義の説明 (1 行) を最初に書き、ジャーゴンはその後に出す

**Where to Apply**:

- Phase 5.1 (Implementation)
- Phase 5.4 (Review)

---

### 5. density_by_audience (公開 API と内部で密度を変える)

**Summary**: コメント密度は読み手によって最適点が異なる。公開 API (外部から呼ばれる関数・データ型) は密に、内部 helper はコードと naming で語らせる。両者を同じ密度で書くと、内部 helper が冗長になり (原則 1 違反)、公開 API が説明不足になる。

**Failure Patterns**:

- 内部 helper 関数すべてに JSDoc / Python docstring を書く (本来は naming で十分)
- 公開 API に WHAT のみの 1 行コメント (引数・戻り値・例外・副作用が記述されない)

**Rules**:

1. **公開 API**: docstring で次を必ず記述する
   - Summary (1 行で何をする関数か)
   - Args (型・意味・制約)
   - Returns (型・意味)
   - Raises / Throws (例外条件)
   - 副作用 / 不変条件 (DB 更新、グローバル状態変更など)
2. **内部 helper**: naming + 関数本体で意味が通るなら docstring 不要。WHY を書く必要があるときのみインラインコメント

**Density Guideline**:

公開 API の comment-to-code 比 ≥ 内部 helper の comment-to-code 比 × 1.5 を目安とする。
これは厳密な閾値ではなく方向性。reviewer は両者の密度比が大幅に逆転している (内部 helper > 公開 API) 場合のみ指摘する。

**Where to Apply**:

- Phase 5.1 (Implementation)
- Phase 5.4 (Review)

---

### 6. comment_rot_is_critical (Comment Rot は CRITICAL)

**Summary**: コードと不一致なコメント (= コメントが嘘になっている状態) は **無コメントより悪い**。なぜなら未来の読み手はコメントを信じてコードを読み、誤った判断をする。

**Failure Patterns**:

- 関数のシグネチャが変わったのに docstring の Args / Returns が古いまま
- アルゴリズムが変わったのにコメントが旧アルゴリズムを説明している
- 「TODO: ～」が解決済みなのにコメントが残っている

**Rules**:

1. コードを変更したら、影響範囲のコメントも同 commit 内で更新する (commit に閉じる)
2. 削除されたコードへのコメント参照を残してはならない
3. 「TODO」「FIXME」を書くなら必ず関連 Issue / PR 番号を添えて未来の取り扱い経路を明示する。野良 TODO は禁止
4. レビュー時、コメントが現コードと整合しているかを必ず確認する (severity: CRITICAL)

**Where to Apply**:

- Phase 5.1 (Implementation)
- Phase 5.4 (Review): 整合性確認が CRITICAL severity
- Phase 5.4 (Fix): コード変更と同じ commit でコメントを更新

---

## B. Bad / Good Examples (実プロジェクト由来)

PR #688 (本 SoT 起草時点で OPEN / 未マージ、branch `fix/issue-687-wiki-ingest-auto-lint-stop`) の `plugins/rite/hooks/state-read.sh` 草案から抜粋した Bad ↔ Good 対比。

> **Note**: 引用元は origin/develop ではなく未マージブランチに存在する。Bad 例の本来の意図は「本 SoT が解消すべきジャーナルコメント大量発生の典型例を示す」ことであり、引用元のファイルが develop に存在することは保証されない。本 PR の後続でジャーナルコメント禁止が強制されれば、PR #688 の cycle 系コメントは Wiki に移管されて消滅する想定。

### B.1 Bad — ジャーナル + 行番号 + cycle 番号の重畳

```bash
# verified-review cycle 35 fix (F-04 HIGH): if/else pattern instead of if! pattern.
# Bash spec: `if ! cmd; then rc=$?` always yields rc=0 because 「!」 negates the
# pipeline and `then` branch sees the negation result (always 0). Use `if cmd; then :; else rc=$?; fi`
# to capture the actual exit code. Empirical: `bash -c 'if ! curr=$(exit 42); then rc=$?; echo $rc; fi'` → 0.
# verified-review cycle 41 I-03: 本警告は **capture 文脈に限定** — `if ! var=$(cmd)` 形式のみ NG。
# capture を伴わない `if ! cmd; then ...` (例: `if ! mapfile -t arr < <(...)` / `if ! gh pr view ...`) は
# 「!」 の挙動が異なるため本ガードの適用範囲外。canonical 説明は `_emit-cross-session-incident.sh` の
# cycle 38 F-16 LOW コメント (capture 文脈限定の正式記述) を参照。
# This invariant ("helper 起動失敗 と pre-condition 失敗を区別可能") was the core reason
# state-read.sh introduction in Issue #687 AC-4. Symmetric with work-memory-update.sh の
# `update_local_work_memory` 関数内 `_phase` / `pr_num` / `loop_cnt` capture blocks
# (canonical `if cmd; then :; else rc=$?; fi` pattern を共有)。
# verified-review cycle 38 F-10 MEDIUM: 旧コメント `work-memory-update.sh:97-104 / 177-183 / 184-190` の
# 行番号参照は Wiki 経験則「DRIFT-CHECK ANCHOR は semantic name 参照で記述する — line 番号禁止」
# (.rite/wiki/index.md) に違反し、function 内の挿入で immediately drift する fragile pattern だった。
# 関数名 `update_local_work_memory` + capture target 変数名 (`_phase` / `pr_num` / `loop_cnt`) で参照する
# semantic anchor 形式に置換した (resume.md / 本 PR cycle 38 F-03/F-04/F-15 系統と整合)。
if curr=$(bash state-read.sh --field phase); then
  :
else
  rc=$?
  ...
fi
```

問題点:
- cycle 番号 (35 / 41 / 38) 参照 → 原則 2 (no_journal_comment) 違反
- finding ID (F-04 / I-03 / F-10 / F-16 / F-03 / F-04 / F-15) 参照 → 原則 2 違反
- 行番号参照 (`work-memory-update.sh:97-104 / 177-183 / 184-190`) → 原則 3 (no_line_or_cycle_reference) 違反
- ファイル名参照 (`_emit-cross-session-incident.sh`) は許容範囲だが、語られる内容が cycle/F-ID 参照 → 連鎖違反
- 比率: コメント 17 行 : コード 5 行 → 原則 5 (density_by_audience) 違反 (内部 bash の helper)

### B.2 Good — WHY のみ残す

```bash
# `if ! var=$(...)` は 「!」 が pipeline 全体を反転するため $? が常に 0 になる。
# capture と exit code を両方取る場合は必ず if/else に分けること。
# (capture を伴わない `if ! cmd` は別仕様で本注意の対象外)
if curr=$(bash state-read.sh --field phase); then
  :
else
  rc=$?
  ...
fi
```

修正点:
- cycle / finding / PR 番号をすべて削除 (commit message と PR description に移管)
- 行番号参照を削除 (semantic anchor も不要なほど局所的な注意)
- WHY (なぜ if/else パターンが必要か) のみ 3 行で残す
- 比率: コメント 3 行 : コード 5 行 → 妥当

### B.3 Bad — WHAT を逐語訳した docstring

```python
def get_user_id(email: str) -> int:
    """
    email から user_id を取得する関数。

    Args:
        email: ユーザーのメールアドレス
    Returns:
        ユーザーの ID
    """
    return db.query("SELECT id FROM users WHERE email = ?", email)
```

問題点:
- 識別子 (`get_user_id`, `email`, `int`) で表現できる内容を逐語訳 → 原則 1 違反
- 隠れた制約・不変条件・回避策・驚き要素のいずれも書かれていない

### B.4 Good — 隠れた制約のみ書く

```python
def get_user_id(email: str) -> int:
    # email の case-folding は MySQL collation (utf8mb4_unicode_ci) に任せる。
    # Python 側で .lower() すると Turkish-i 問題で test 環境のみ失敗する経路がある。
    return db.query("SELECT id FROM users WHERE email = ?", email)
```

修正点:
- 隠れた制約 (collation 依存・Turkish-i 問題) を書く
- 自明な Args / Returns docstring を削除

---

## C. Detection Heuristics (reviewer 用)

reviewer (人間 + LLM) が原則違反を機械的に検出するためのヒューリスティクス。
将来 Issue 2a で `tech-writer-reviewer` の Detection Checklist に統合する。本セクションはその素案。

| 原則 | Heuristic | 検出例 |
|------|-----------|--------|
| 1. why_over_what | 関数名・変数名と docstring summary が同義語 | `get_user_id` の docstring に「user id を取得」 |
| 2. no_journal_comment | コメント内に `cycle\s*\d+`, `F-\d+`, `PR\s*#\d+`, `verified-review`, `Issue\s*#\d+`, `旧実装は` のいずれかが含まれる (whitelist 例外あり) | `# verified-review cycle 35 fix (F-04 HIGH)` |
| 3. no_line_or_cycle_reference | コメント内に `[a-zA-Z0-9_./-]+\.\w+:\d+` (file:line) パターン (ハイフン含むファイル名 例: `_emit-cross-session-incident.sh:42` を取りこぼさないため `-` も許容) | `# state-read.sh:93 と同じ` / `# _emit-cross-session-incident.sh:42 と同型` |
| 4. no_jargon_abuse | コメント内のトークンが whitelist にも辞書にも存在しない造語 | (LLM 判定。プロジェクト内 3 回以上の独立登場の有無) |
| 5. density_by_audience | 公開 API のコメント密度 < 内部 helper のコメント密度 | docstring 0 行の export 関数 + docstring 5 行の static helper |
| 6. comment_rot_is_critical | docstring の Args / Returns 名と関数シグネチャの引数名が不一致 | docstring に `Args: email: ...` だが関数は `def f(addr):` |

reviewer は本ヒューリスティクスを参照しつつ、grep / regex で機械検出可能な原則 (2, 3, 6 の一部) を優先的に finding として上げる。
原則 1, 4, 5 は LLM の判定を伴うが、severity を MEDIUM 以下にして意見の余地を残す。

---

## D. Density Guideline (公開 API vs 内部 helper)

| 区分 | comment-to-code ratio (目安) | 必須記述 |
|------|----------------------------|---------|
| 公開 API (export / 外部呼び出しあり) | 0.3 〜 0.5 | Summary / Args / Returns / Raises / 副作用 |
| 内部 helper (同モジュール内のみ呼ばれる) | 0.0 〜 0.2 | naming で意味が通る限りコメント不要。WHY のみ書く |

**比率の意味**: 公開 API は内部 helper の **1.5 倍以上** の密度を持つことを目安とする。逆転 (内部 helper > 公開 API) は finding 対象。

**測定方法 (簡易)**: 関数本体に対するコメント行数の比。空行・閉じ括弧のみの行は分母から除く。

**例外**:

- 公開 API でも自明なゲッター・セッター・データクラスは Summary 1 行で足りる
- 内部 helper でも非自明なアルゴリズム・パフォーマンス特性・並行性は WHY を書く
- 状態機械 / プロトコル実装は内部 helper でもステート遷移図のリンクを書く

---

## Whitelist (プロジェクト固有ジャーゴン)

原則 4 (no_jargon_abuse) の exception。次のジャーゴンは rite workflow プロジェクト内で確立されており、コメントで使用してよい。

| ジャーゴン | 意味 | 出典 |
|-----------|------|------|
| `sentinel` | hook / grep 契約のためのマーカー (`[review:mergeable]` 等) | `plugins/rite/skills/rite-workflow/references/workflow-identity.md` |
| `verified-review` | ファクトチェック付き PR レビュー (Observed Likelihood Gate / Doc-Heavy Mode) | `plugins/rite/agents/_reviewer-base.md` |
| `workflow-incident-emit` | workflow incident 検出 sentinel emit | `plugins/rite/hooks/workflow-incident-emit.sh` |
| `flow-state` | legacy single-file 形式 / `.rite/sessions/{id}.flow-state` の状態管理 | `plugins/rite/hooks/flow-state-update.sh` |
| `Mandatory After` | sub-skill 完了後に caller が必ず実行する遷移 step | `plugins/rite/commands/issue/start.md` |
| `Pre-write` | sub-skill 起動前に caller が必ず行う flow state 更新 | `plugins/rite/commands/issue/start.md` |
| `defense-in-depth` | sub-skill 内で caller の責務と並行に行う冗長な状態更新 | `plugins/rite/commands/pr/review.md` ほか |
| `epic` / `parent issue` / `child issue` | Issue 間の親子関係 | `plugins/rite/references/epic-detection.md` |
| `wiki ingest` / `wiki query` | Experience Wiki の経験則蓄積・参照 | `plugins/rite/skills/wiki/` |
| `oracle` | 既存の正しい実装を参照実装として使うパターン | `plugins/rite/references/bottleneck-detection.md` (Oracle Discovery Protocol) |

> **Note (撤去済みジャーゴン)**: 過去に `stop-guard` (rite workflow の Stop hook ガード機構、`plugins/rite/hooks/stop-guard.sh`) も whitelist に含まれていたが、commit e2dfae0 で機構ごと撤去された (途中停止問題の根本対策)。現在の rite plugin に該当ファイルは存在せず、新規コードで `stop-guard` をジャーゴンとして使用してはならない。歴史的経緯は git log e2dfae0 を参照。

### Whitelist の拡張・上書き

将来的に `rite-config.yml` で project ごとに上書き・追記できるようにする想定。本 MVP では schema 拡張は行わず、ドキュメントとして記述する。

```yaml
# 想定 (本 MVP では未実装):
comment_best_practices:
  jargon_whitelist:
    - "sentinel"
    - "flow-state"
    # project 固有の語を追加
    - "my-app-handshake"
```

reviewer は本リストを参照しつつ、リスト外の造語は原則 4 の finding として候補に上げる (severity LOW)。

---

## 関連参照

- [coding-principles.md](./coding-principles.md) — `simplicity_enforcement` / `dead_code_hygiene` 等、コメント以外のコーディング原則
- [common-principles.md](./common-principles.md) — `AskUserQuestion` 濫用回避
- [workflow-identity.md](./workflow-identity.md) — workflow 全体の identity (品質 > 時間 / context)
