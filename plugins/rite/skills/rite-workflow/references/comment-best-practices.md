# Comment Best Practices Reference

rite workflow がコードを生成・修正する際に従うべきコメントの SoT (Single Source of Truth)。
業界標準 (Clean Code 4 章 / Google Style Guide / JSDoc・TSDoc / Hillel Wayne) と
rite workflow 独自の主張 (Contract Rigour / Output Contract / Naming is documentation) を統合する。

> **前提**: 業界標準のコメント規律（WHY > WHAT、comment rot の害、密度調整など）はモデルの既知として本ファイルでは再教育しない。各原則は Summary + Rules のみを記す。rite 固有の契約 — 禁止句リスト (SoT)・廃止判定ルール・§C Detection Heuristics（parity test 対象）・§D・Whitelist — は機械検証・外部参照の対象のため全文を保持する。reviewer 側の Detection Checklist 統合は後続 Issue (Issue 2a) の責務。

## 適用スコープ

本 SoT が扱う「説明・ジャーナル目的の Issue/PR/commit 番号参照」の廃止は、コード内コメントに限らず**永続成果物全般**を対象とする。具体的には次を含む。

| スコープ | 対象例 |
|---------|--------|
| in-source コメント | Edit/Write で生成するコード内コメント全般 |
| ドキュメント散文 | `docs/`（SPEC ほか）・command/skill markdown の手順書本文・各種 reference・成果物テンプレート |
| Wiki ページ | `.rite/wiki/` の経験則ページ・テンプレート |

「番号を辿っても得るものが少なく、辿る手間に見合わない」ため、永続成果物には番号を残さず、残すべき背景（Why）は**散文として成果物そのものに書く**。番号リンクは commit message / PR description（git/PR メタデータ）にのみ残す。永続成果物の裸の `#NNN` は一律禁止（次節）。

## 適用フェーズ

| Phase | 適用箇所 |
|-------|----------|
| Phase 3 (Implementation Plan) | コメント生成方針の宣言（「Implementation Plan 内で本 SoT を参照する」宣言レベル。具体化は後続 Issue） |
| Phase 5.1 (Implementation) | 実装中のコメント記述 |
| Phase 5.4 (Review/Fix) | レビュー時のコメント品質判定、修正時の不要コメント削除 |

> `skills/fix/SKILL.md` ステップ 2.3 / 2.4 の修正生成 gate は、原則 2 の禁止句リスト (SoT) サブ節「適用範囲」表を参照する形で実装される（in-source コメント / reviewer 返信 / docstring が共通の禁止句リストを参照する）。

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

## 廃止判定ルール (説明的参照 vs 前方ポインタ)

永続成果物の裸の番号トークン（`#NNN`）は一律禁止。検出器は `number-reference-check.sh`。

| 参照の種類 | 判定 | 理由 |
|-----------|------|------|
| **説明的参照**（「詳細は #N 参照」「PR #N で対応」「(refs #N)」等、Why の代替として貼られたもの） | **削除** → Why を散文化 | 番号を辿っても背景は得られず、辿る手間に見合わない。背景が必要なら Why を散文で残す |
| **TODO / FIXME に添えた追跡番号** | **禁止**（例外ではない） | TODO 行に Issue 番号を維持しない。TODO/FIXME は番号なしで存在してよい |
| **test 契約・semantic アンカーとしてのファイル名参照**（`xxx.test.sh` 等） | **維持** | `#NNN` トークンではない。drift-check や test 契約のアンカーとして機能し、rename 追従可能 |
| **commit message / PR description 内の番号** | **対象外**（許可） | git/PR メタデータは番号の正しい受け皿。永続成果物（コード・ドキュメント・Wiki）ではない |

検出機構は本ルールに従う。TODO/FIXME 追跡番号を検出除外とする番号例外は置かない。ファイル名アンカーは `#NNN` ではないので対象外。parity test は禁止句リスト（SoT）と §C Detection Heuristics の forward 包含（SoT ⊆ Heuristics）を検証するリスト整合テストであり、検出対象/除外そのものを区別する機構ではない。

## A. 6 原則 (Principle Details)

### 1. why_over_what (WHY > WHAT)

**Summary**: コードで自明な「何をするか (WHAT)」は書かない。書くべきは「なぜそうするか (WHY)」、特にコードからは読み取れない隠れた制約・不変条件・回避策・歴史的経緯。書くべき WHY には、却下した代替案の明示（Why not = なぜこの方法を選んだのか・他の方法ではダメだった理由）を含む。

**Rules**:

1. WHAT を書きたくなったら、まず識別子 (関数名・変数名) で表現できないか検討する (Naming is documentation)
2. 書く WHY は次のいずれかに該当するもの: 隠れた制約 / 不変条件 / 回避策 / 驚き要素 / Why not（却下した代替案）
3. 「コメントを消したら未来の読み手が混乱する」を判定基準にする。混乱しないなら書かない
4. **Why not のルーティング基準**: 「未来の読者がコードを見て、その場で誤った『改善』（却下案への差し戻し）をするリスクがあるか？」— Yes → 現在形の制約文としてコメントに残す（コードと同じ場所に居続ける唯一の文書であり、退行防止ガードレールとして最も腐りにくい）。No → commit message body に却下理由を書けば十分。両方に書く場合は同文コピーせず、コメント側は**現在形の制約文のみ**（経緯・番号・検討プロセスを持ち込まない — 原則 2 と整合）、commit 側は「何を検討して、なぜ却下したか」という経緯

### 2. no_journal_comment (ジャーナルコメント禁止)

**Summary**: 個別の review cycle / fix / PR / Issue の経緯をコード内コメントやドキュメント散文・Wiki ページに残してはならない。番号を伴う経緯は PR description / commit message（git/PR メタデータ）に書く。経験則として一般化できる Why は Wiki に**散文で**（番号を持ち込まず）残す。

**Failure Patterns**:

- `# verified-review cycle X F-Y で導入` のようなコードレビュー履歴・cycle / finding ID 参照
- `# 旧実装は ～。PR #N で修正` のような変更履歴
- `# In the old code we used X; now we use Y` のような英語版変更履歴

**Why MUST**: 該当 cycle / PR の文脈は時間経過で失われ、未来の読み手にとって意味不明な暗号になる（Comment Rot の温床）。修正を重ねるたびジャーナルが累積し、コード:コメント比が逆転する（実測: `state-read.sh` 草案で 60% がコメント、うち 70% がレビュー経緯）。番号を伴うジャーナルは PR description / commit message が受け皿として機能していれば、コード内コメントには WHY のみが残る。

**Rules**:

1. cycle / fix / review finding / PR 番号 を参照するコメントは原則禁止
2. その変更の動機を残したい場合は、commit message → PR description に書く。経験則化に値する Why は Wiki に**散文で**残す（番号は持ち込まず、Why そのものを書く）
3. コードに残してよいのは「未来の読み手が同じ罠にハマらないための WHY」(原則 1) のみ。「過去にハマった」記録ではなく「これから来る読み手への警告」として書く

#### 禁止句リスト (SoT)

本原則の機械的検出ガイドライン (Detection Heuristics) を補完する **禁止句リスト**。
以下の語句は **in-source コメント** / **レビュアー返信** / **docstring** / **ドキュメント散文** / **Wiki ページ** いずれの場面でも記述してはならない (commit message / PR description への記載のみ許可)。Wiki は番号の受け皿ではなく、経験則を自己完結した Why 散文で残す場所であるため番号参照の許可先から除く。

| 言語 | カテゴリ | 禁止句 |
|------|---------|--------|
| 英語 | commit 参照 | `Fixed in commit {sha}` / `Fixed in {sha}` / `Resolved in commit ...` |
| 英語 | Issue / PR 参照 | `See PR #{N}` / `See #{N}` / `Refs PR #{N}` |
| 英語 | Issue / PR 参照 | `Related to #{issue}` / `Closes #{issue}` / `Fixes #{issue}` |
| 英語 | commit 参照 | `In commit {sha}` / `Pushed as {sha}` |
| 英語 | cycle / finding ID 参照 | `verified-review cycle N` / `cycle N F-M` / `F-NN HIGH` 等 |
| 英語 | 旧版表現 | `In the old code ...` 等 (本原則 Failure Patterns の用例 `# In the old code we used X; now we use Y` の禁止句化) |
| 日本語 | Issue / PR 参照 / commit 参照 | 「コミット {sha} で対応しました」「PR #{N} で対応」「#{N} で別途対応」 |
| 日本語 | cycle / finding ID 参照 | 「サイクル N で導入」「cycle N F-M で確立」等 |
| 日本語 | 旧版表現 | 「旧実装は ...」「旧コードでは ...」等 (本原則 Failure Patterns の用例 `# 旧実装は ～。PR #N で修正` と対応) |

**適用範囲**:

| 適用先 | 出典 |
|--------|------|
| in-source コメント (Edit/Write で生成するコード内コメント全般) | 本ドキュメント (SoT) |
| `templates/review/reply.md` のレビュアー返信本文 | 本ドキュメントを参照 |
| `skills/fix/SKILL.md` ステップ 2.3 / 2.4 の修正生成時 | 本ドキュメントを参照 |
| ドキュメント散文 (`docs/`・command/skill markdown 手順書本文・reference・成果物テンプレート) | 本ドキュメントを参照 |
| Wiki ページ (`.rite/wiki/` の経験則ページ・テンプレート) | 本ドキュメントを参照（具体反映は Wiki レイヤ整合タスク） |

**理由**: コメントやドキュメント散文・Wiki に番号や履歴を書くと、後追いで読むレビュアーが GitHub の commit / PR / Issue ページを行き来する負担が増える。番号は将来の rename / squash で意味を失う。**「なぜそうしたか」(Why) が分かれば commit history は code から辿れる** ため、本文は Why に集中する。

#### 変更動機散文（番号なし）のサブ分類

番号・cycle・旧版表現を伴わなくても、コメントが「**この変更を行った理由・経緯**」（変更イベント）を語っている場合は本原則の違反とする（例: 「〜対応のため追加」「リファクタに伴い変更」「新機能 X 用に導入」）。変更動機（Why）の受け皿は commit message body（free-form の why 散文）であり、コードと共に残してよいのは**現在形の制約・不変条件・Why not**（原則 1）のみ。

判定軸は「コメントの主語が**変更イベント（過去の行為）**か、**コードの現在の性質・制約**か」で、前者のみ違反とする。番号・cycle・旧版表現を伴う場合は禁止句リスト（SoT）由来の検出が先に適用される（二重 flag 禁止）。本サブ分類は regex で機械検出できないため禁止句リスト（SoT）には含めず、reviewer の **LLM 判定**（severity MEDIUM）で扱う。

### 3. no_line_or_cycle_reference (行番号 / cycle 番号参照禁止)

**Summary**: コメント内で他ファイルや同ファイルの **行番号** を参照しない。`cycle X F-Y` のような review サイクル番号も同様。これらはコード変更で容易にずれて陳腐化し (drift)、参照側が自動更新されないため原則 6 (Comment Rot) の主要源になる。

**Rules**:

1. 他ファイルの参照はファイル名 + **意味的アンカー** (関数名・セクション見出し・identifier) で行う
2. cycle 番号 / review finding ID は原則 2 (no_journal_comment) で既に禁止だが、本原則で追加に「行番号」も禁止する
3. やむを得ず行番号を書く場合 (e.g., 外部仕様の特定行を引用) は **immutable な版** を明示する (例: `RFC 7231 Section 6.5.1` のように仕様 ID + section)

### 4. no_jargon_abuse (独自社内ジャーゴン濫用禁止)

**Summary**: プロジェクト外の読み手にとって意味不明な独自ジャーゴンをコメントに濫用しない。ただし、プロジェクト内で確立されたジャーゴン (whitelist 参照) は exception として許容する。

**Rules**:

1. 一度だけの discussion で生まれた造語は使わない。3 回以上独立に登場し、かつドキュメント化された語のみ使う
2. プロジェクト内で確立された語は whitelist (本ファイル末尾参照) を介して許容する
3. 外部読者が困らない第一義の説明 (1 行) を最初に書き、ジャーゴンはその後に出す

### 5. density_by_audience (公開 API と内部で密度を変える)

**Summary**: コメント密度は読み手によって最適点が異なる。公開 API (外部から呼ばれる関数・データ型) は密に、内部 helper はコードと naming で語らせる。両者を同じ密度で書くと、内部 helper が冗長になり (原則 1 違反)、公開 API が説明不足になる。

**Rules**:

1. **公開 API**: docstring で Summary / Args / Returns / Raises・Throws / 副作用・不変条件 を必ず記述する
2. **内部 helper**: naming + 関数本体で意味が通るなら docstring 不要。WHY を書く必要があるときのみインラインコメント
3. 密度の数値目安と例外は [D. Density Guideline](#d-density-guideline-公開-api-vs-内部-helper) を SoT とする。reviewer は密度比が大幅に逆転している (内部 helper > 公開 API) 場合のみ指摘する

### 6. comment_rot_is_critical (Comment Rot は CRITICAL)

**Summary**: コードと不一致なコメント (= コメントが嘘になっている状態) は **無コメントより悪い**。なぜなら未来の読み手はコメントを信じてコードを読み、誤った判断をする。

**Rules**:

1. コードを変更したら、影響範囲のコメントも同 commit 内で更新する (commit に閉じる)
2. 削除されたコードへのコメント参照を残してはならない
3. 「TODO」「FIXME」は追跡番号なしで存在してよい。Issue/PR 番号（`#NNN`）を添えるよう指示しない
4. レビュー時、コメントが現コードと整合しているかを必ず確認する (severity: CRITICAL)

---

## C. Detection Heuristics (reviewer 用)

reviewer (人間 + LLM) が原則違反を機械的に検出するためのヒューリスティクス。
将来 Issue 2a で `tech-writer-reviewer` の Detection Checklist に統合する。本セクションはその素案。

| 原則 | Heuristic | 検出例 |
|------|-----------|--------|
| 1. why_over_what | 関数名・変数名と docstring summary が同義語 | `get_user_id` の docstring に「user id を取得」 |
| 2. no_journal_comment | コメント内に以下いずれかが含まれる (whitelist 例外あり): **cycle / finding ID 参照** (`cycle\s*\d+`, `F-\d+`, `verified-review`, `サイクル\s*\d+`), **Issue / PR 参照** (`Issue\s*#\d+`, `PR\s*#\d+`, `(See\|Refs\|Related\s+to\|Closes\|Fixes)\s+#\d+`), **commit 参照** (`(Fixed\|Resolved)\s+in(\s+commit)?\s+\S+`, `In\s+commit\s+\S+`, `Pushed\s+as\s+\S+`), **日本語版** (`コミット\s*\S+\s*で対応`, `#\d+\s*で(別途)?対応`), **旧版表現** (`旧実装は`, `旧コードでは`, `In\s+the\s+old\s+code`) | `# verified-review cycle 35 fix (F-04 HIGH)` / `# Fixed in commit abc1234` / `# Closes #456` / `# コミット abc1234 で対応` / `# 旧実装は ～` |
| 3. no_line_or_cycle_reference | コメント内に `[a-zA-Z0-9_./-]+\.\w+:\d+` (file:line) パターン (ハイフン含むファイル名 例: `work-memory-update.sh:42` を取りこぼさないため `-` も許容) | `# state-read.sh:93 と同じ` / `# work-memory-update.sh:42 と同型` |
| 4. no_jargon_abuse | コメント内のトークンが whitelist にも辞書にも存在しない造語 | (LLM 判定。プロジェクト内 3 回以上の独立登場の有無) |
| 5. density_by_audience | 公開 API のコメント密度 < 内部 helper のコメント密度 | docstring 0 行の export 関数 + docstring 5 行の static helper |
| 6. comment_rot_is_critical | docstring の Args / Returns 名と関数シグネチャの引数名が不一致 | docstring に `Args: email: ...` だが関数は `def f(addr):` |

reviewer は本ヒューリスティクスを参照しつつ、grep / regex で機械検出可能な原則 (2, 3, 6 の一部) を優先的に finding として上げる。
原則 1, 4, 5、および原則 2 の変更動機散文（番号なし）サブ分類は LLM の判定を伴うが、severity を MEDIUM 以下にして意見の余地を残す。

> **Maintenance Invariant (forward parity 保持)**: 上記表 row 2 (原則 2 `no_journal_comment`) の正規表現は、`no_journal_comment` 原則本体 (§A) 内の「禁止句リスト (SoT)」表 (3 列構造: 言語 / カテゴリ / 禁止句) に列挙された各禁止句を **少なくとも 1 つの regex で必ず match する** (forward 方向の包含関係: SoT ⊆ Heuristics)。SoT に新カテゴリを追加する際は本表 row 2 の regex も同期更新し、forward 方向の包含を保証する。reverse 方向 (Heuristics ⊆ SoT) は best-effort であり、Heuristics の regex (例: bare `Issue\s*#\d+` / `PR\s*#\d+`) が SoT 列挙より広く catch することは許容する — reviewer 側の sensitivity を意図的に高めるための設計判断。両者が forward 方向で drift すると、生成側 (LLM 駆動の fix.md gate) と reviewer 側 (regex 駆動の tech-writer.md heuristic) の検出範囲が乖離する。
>
> **機械検証**: 本 invariant の forward subset (= SoT ⊆ Heuristics) は `plugins/rite/hooks/tests/comment-best-practices-parity.test.sh` で機械的に検証される。`bash plugins/rite/hooks/tests/run-tests.sh` 経由で auto-discovery 実行されるほか、`bash plugins/rite/hooks/tests/comment-best-practices-parity.test.sh` で個別実行も可能。test は SoT の各 probe が Heuristics regex の少なくとも 1 つで match することを assert する。**サブグループ ↔ カテゴリ mapping は宣言で保証せず、parity test の合格 (forward subset 成立) によって機械的に担保する** (declarative wording の self-meta-conflict を避けるため、本 note では 1 対 1 / 言語横断 / composite 等の cross-axis mapping は明示せず、test の green を contract とする)。

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

## Whitelist (プロジェクト固有ジャーゴン)

原則 4 (no_jargon_abuse) の exception。次のジャーゴンは rite workflow プロジェクト内で確立されており、コメントで使用してよい。

| ジャーゴン | 意味 | 出典 |
|-----------|------|------|
| `sentinel` | hook / grep 契約のためのマーカー (`[review:mergeable]` 等) | `plugins/rite/skills/rite-workflow/references/workflow-identity.md` |
| `verified-review` | ファクトチェック付き PR レビュー (Observed Likelihood Gate / Doc-Heavy Mode) | `plugins/rite/agents/_reviewer-base.md` |
| `flow-state` | legacy single-file 形式 / `.rite/sessions/{id}.flow-state` の状態管理 | `plugins/rite/hooks/flow-state.sh` |
| `Mandatory After` | sub-skill 完了後に caller が必ず実行する遷移 step | `plugins/rite/skills/iterate/SKILL.md` |
| `Pre-write` | sub-skill 起動前に caller が必ず行う flow state 更新 | `plugins/rite/skills/iterate/SKILL.md` |
| `defense-in-depth` | sub-skill 内で caller の責務と並行に行う冗長な状態更新 | `plugins/rite/skills/pr-review/SKILL.md` ほか |
| `epic` / `parent issue` / `child issue` | Issue 間の親子関係 | `plugins/rite/references/epic-detection.md` |
| `wiki ingest` / `wiki query` | Experience Wiki の経験則蓄積・参照 | `plugins/rite/skills/wiki-ingest/`, `plugins/rite/skills/wiki-query/` |
| `oracle` | 既存の正しい実装を参照実装として使うパターン | `plugins/rite/references/bottleneck-detection.md` (Oracle Discovery) |

> **Note (撤去済みジャーゴン)**: 過去に `stop-guard` (rite workflow の Stop hook ガード機構、`plugins/rite/hooks/stop-guard.sh`) も whitelist に含まれていたが、commit e2dfae0 で機構ごと撤去された (途中停止問題の根本対策)。現在の rite plugin に該当ファイルは存在せず、新規コードで `stop-guard` をジャーゴンとして使用してはならない。歴史的経緯は git log e2dfae0 を参照。

### Whitelist の拡張・上書き

将来的に `rite-config.yml` の `comment_best_practices.jargon_whitelist`（文字列リスト）で project ごとに上書き・追記できるようにする想定。本 MVP では schema 拡張は行わず、ドキュメントとして記述する。reviewer は本リストを参照しつつ、リスト外の造語は原則 4 の finding として候補に上げる (severity LOW)。

## 関連参照

- [coding-principles.md](./coding-principles.md) — `simplicity_enforcement` / `dead_code_hygiene` 等、コメント以外のコーディング原則。`knowledge_routing`（4 チャネル知識ルーティング）の上位原則がコメント = Why not の位置づけを定義する
- [common-principles.md](./common-principles.md) — `AskUserQuestion` 濫用回避
- [workflow-identity.md](./workflow-identity.md) — workflow 全体の identity (品質 > 時間 / context)
