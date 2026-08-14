---
title: "DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）"
domain: "patterns"
description: "drift 防止を目的とする anchor comment で literal 行番号 (例: `(L1331-1332)`) を埋め込むと、そのアンカー自身が drift 源になる。"
promote: rite-plugin
created: "2026-04-18T12:50:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260418T122454Z-pr-579.md"
  - type: "fixes"
    resource: "raw/fixes/20260418T122707Z-pr-579.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T034237Z-pr-586-cycle5.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T122543Z-pr-600.md"
  - type: "fixes"
    resource: "raw/fixes/20260419T122750Z-pr-600.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T123103Z-pr-600.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T134838Z-pr-605.md"
  - type: "reviews"
    resource: "raw/reviews/20260420T042759Z-pr-617.md"
  - type: "fixes"
    resource: "raw/fixes/20260420T043015Z-pr-617-fix1.md"
  - type: "reviews"
    resource: "raw/reviews/20260420T052907Z-pr-619.md"
  - type: "reviews"
    resource: "raw/reviews/20260420T145943Z-pr-624-cycle2.md"
  - type: "reviews"
    resource: "raw/reviews/20260420T160140Z-pr-626.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T133145Z-pr-661.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T161137Z-pr-661.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T165246Z-pr-661.md"
  - type: "fixes"
    resource: "raw/fixes/20260425T154517Z-pr-661-cycle-1.md"
  - type: "fixes"
    resource: "raw/fixes/20260425T161635Z-pr-661.md"
  - type: "fixes"
    resource: "raw/fixes/20260425T165546Z-pr-661.md"
  - type: "reviews"
    resource: "raw/reviews/20260501T024847Z-pr-756.md"
  - type: "fixes"
    resource: "raw/fixes/20260501T025722Z-pr-756.md"
  - type: "reviews"
    resource: "raw/reviews/20260509T053632Z-pr-913.md"
  - type: "reviews"
    resource: "raw/reviews/20260518T024436Z-pr-1035.md"
  - type: "fixes"
    resource: "raw/fixes/20260518T024749Z-pr-1035.md"
  - type: "fixes"
    resource: "raw/fixes/20260518T032735Z-pr-1035.md"
  - type: "reviews"
    resource: "raw/reviews/20260518T035931Z-pr-1035.md"
  - type: "reviews"
    resource: "raw/reviews/20260529T055839Z-pr-1187.md"
  - type: "reviews"
    resource: "raw/reviews/20260529T065341Z-pr-1188.md"
  - type: "reviews"
    resource: "raw/reviews/20260608T121819Z-pr-1306.md"
  - type: "fixes"
    resource: "raw/fixes/20260608T122037Z-pr-1306.md"
  - type: "reviews"
    resource: "raw/reviews/20260717T062934Z-pr-1887.md"
  - type: "reviews"
    resource: "raw/reviews/20260717T064500Z-pr-1887.md"
  - type: "fixes"
    resource: "raw/fixes/20260717T063251Z-pr-1887.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-17T06:45:00+00:00" }
---

# DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）

## 概要

drift 防止を目的とする anchor comment で literal 行番号 (例: `(L1331-1332)`) を埋め込むと、そのアンカー自身が drift 源になる。`# >>> DRIFT-CHECK ANCHOR: <canonical-semantic-name> <<<` 形式 (+ END marker) で semantic name 参照として記述するのが canonical。ingest.md Phase 5.0.c の 4 site が既存 reference implementation。

## 詳細

### 問題: literal 行番号の自己撞着

ファイル内で「他所と一字一句同期すべき」ことを示す DRIFT-CHECK ANCHOR コメントに `参照: L1331-1332` と literal 行番号を書くと、同ファイル自身が以下の通り「行番号は drift するため Phase 番号と semantic 名のみで参照する」と 3 site で規範化している既存方針に反する:

- line 番号はファイル編集で容易に shift する
- anchor 本体が指す target と anchor 自身が drift する経路ができる
- 将来の読者は「行番号が当たらない anchor」を noise として無視するようになる

### Canonical 形式（cycle 1 で統一）

```bash
# >>> DRIFT-CHECK ANCHOR: Phase 5.0.c canonical commit message <<<
commit_msg="..."
# >>> END DRIFT-CHECK ANCHOR <<<
```

semantic name は canonical SoT への参照として機能し、`grep` で target を特定可能にする。ingest.md Phase 5.0.c canonical / Phase 5.0.c canonical placeholder-residue gate の 4 site が reference implementation。

### 3 箇所 explicit sync の契約

Phase 5.1 / Phase 5.2 / Phase 5.0.c のように同一 semantic の記述が複数 site にまたがる場合は、explicit sync の契約を prose で明示する:

> 本 `commit_msg` 文字列と直下の placeholder-residue gate は Phase 5.0.c canonical と Phase 5.1 / Phase 5.2 の同一文字列と 3 箇所 explicit sync を契約。変更時は 3 箇所同時更新必須。

将来 `/rite:lint` で grep ベースの drift 検出を実装可能にする設計意図も含む。

### 大量行挿入時のコメント内行番号参照 drift（cycle 5 の実測）

大量行挿入事例の cycle 4 fix で Phase 1.3 ブロック (約 235 行) を init.md の Phase 1.2 と Phase 2 の間に挿入した結果、cycle 4 fix の F-02 修正コメント自身が「同一ファイル内 L555」を参照していたが、実際の対象行は L563 にずれた (8 行 drift)。cycle 5 review で F-02 として検出。

本原則は DRIFT-CHECK ANCHOR コメントだけでなく、**fix コメント / 設計メモ / 概要説明など**「同一ファイル内の他箇所を参照するあらゆる散文」に拡張される:

1. **参照は anchor / Phase 番号 / heading / function 名で書く**: drift 耐性が高い
2. **大量行挿入を伴う PR では最終 commit 後に行番号参照を grep で走査**: `grep -nE 'L[0-9]+' <file>` で全件取り出して目視再確認
3. **将来的に `/rite:lint` でコメント内行番号参照を検出する lint を追加する候補**: `L[0-9]+` を含むコメントは機械検証できないため、anchor / Phase 番号への置換を促す

### code slice 参照による semantic identifier の canonical 実証（実測）

code slice 参照事例の cycle 1 では `plugins/rite/commands/wiki/lint.md` のコメント内に `Phase 6.0 (line 698)` という「Phase 番号 + literal 行番号」の混成表現が残っていた。同 PR の +2 行差分で実体は L700 に shift し、コメントが即 stale 化した。cycle 2 fix で `(line 698)` を `LC_ALL=C cat .rite/wiki/log.md` という **対象コードの特徴的コード片による論理参照** に置換することで完全解消。両 reviewer (prompt-engineer / code-quality) が以下を独立して高く評価:

- **Grep で実体存在が機械検証可能**: 将来の読者が `grep 'LC_ALL=C cat .rite/wiki/log.md' lint.md` で target を確実に特定できる
- **PR の +N 行差分で stale 化しない**: 行番号 anchor のように shift しない
- **Phase 番号 + code slice の組み合わせ**: Phase 番号が「どの論理階層か」を示し、code slice が「その階層のどの具体行か」を指す 2 段階の semantic identifier として機能

canonical 記法の階層 (drift 耐性が高い順):

1. **Phase 番号 + 特徴的コード片** (最推奨、code slice 参照事例で実証): `Phase 6.0 の \`LC_ALL=C cat .rite/wiki/log.md\``
2. **Phase 番号 + heading / function 名**: `Phase 5.0.c canonical commit message`
3. **DRIFT-CHECK ANCHOR の semantic name**: `# >>> DRIFT-CHECK ANCHOR: ... <<<`
4. **literal 行番号** (禁止): `(line 698)` / `L1331-1332`

既存 convention を再導入時に違反する self-drift pattern として、commit 前 `grep -nE '\(line [0-9]+\)' <file>` で検出できる。

### line 番号 literal の brittleness 実証 + bidirectional backlink 拡張（実測）

backlink 導入事例で init.md L253 / L320 のコメント内に残存していた `L270-277` / `L84-L113` / `L281 付近` を semantic anchor 参照に置換した際、次の 2 点が実証された:

1. **brittleness 実証**: 旧 `L270-277` は実際の該当コード (L275-L282) と **±3 行ずれ** ていた。参照先 `gitignore-health-check.sh` が minor revision を重ねるうち silent に drift した典型例で、「行番号 literal は書いた時点から陳腐化が始まる」原理を裏付けた。anchor 参照であれば grep で実体を再同定できるため、この drift は発生しない。
2. **bidirectional backlink sub-pattern (新規)**: canonical 側 ANCHOR コメントに `# Downstream reference: <downstream-file>:<semantic-name>` という **逆方向のリンク** を併記することで、canonical 側から downstream (参照元) を grep 1 発で特定可能になる。片方向リンク (downstream → canonical のみ) では、canonical を編集する開発者が「この ANCHOR が他のどこから参照されているか」を知る手段がなく silent drift を誘発する。code-quality reviewer 推奨の強化策。

canonical 側のテンプレート拡張例:

```bash
# >>> DRIFT-CHECK ANCHOR: same_branch add_dry_run rc capture <<<
# Downstream reference: plugins/rite/commands/wiki/init.md:Phase 1.3.4
add_dry_err=$(mktemp ...)
if ! git add ... 2>"$add_dry_err"; then
  ...
fi
# >>> END DRIFT-CHECK ANCHOR <<<
```

### 入れ子追加時の outer/inner END 順序による well-formed nesting（実測）

入れ子 ANCHOR 事例で `.gitignore` 既存 `negation verification canonical` ANCHOR を inner として、それを包む outer ANCHOR `same_branch verification-first setup steps` を追加した際、HIGH finding として **「outer END を inner END より前に配置すると bracket matching が crossing 構造になる」** failure mode が検出された:

```
[crossing 構造 — 禁止]
# >>> START outer <<<
# >>> START inner <<<
...
# >>> END outer <<<        ← outer END が inner END より前
# >>> END inner <<<
```

```
[well-formed nesting — canonical]
# >>> START outer <<<
# >>> START inner <<<
...
# >>> END inner <<<        ← inner END が先
# >>> END outer <<<        ← outer END は inner END の直後
```

crossing 構造は以下の機械検証経路を破壊する:

1. **grep-based lint**: `awk '/START.*<<</{depth++} /END.*<<</{depth--}' anchors.md` 形式の depth tracking lint で `depth < 0` を一時的に発生させ、validator が誤検出または異常終了する
2. **sed range extraction**: `sed -n '/START outer/,/END outer/p' file` で範囲抽出すると inner END が outer END より後にあるため、抽出範囲が意図より狭くなる (inner END の手前で打ち切られる)
3. **bracket matching IDE 機能**: 多くの editor の bracket pair highlighter は LIFO scan のため crossing で false-positive 警告を出す

**Canonical 適用手順**（fix で確立）:

1. 既存 inner anchor の包含範囲 (どの節を含むか) を最初に確認する
2. outer END の位置は **inner END の直後** に配置することを最優先で決める
3. outer START の位置を inner START より前に配置する
4. commit 前に `awk` で depth tracking 検証: `awk '/START.*<<</{d++} /END.*<<</{d--; if(d<0){print "DEPTH_NEGATIVE at NR="NR; exit 1}}' file`

本原則は `# >>> DRIFT-CHECK ANCHOR <<<` だけでなく、HEREDOC marker (`<<EOF` / `EOF`) や Markdown code fence (` ``` `) のような **対称 delimiter を持つすべての構造** に適用される。

### bidirectional backlink の team guideline 拡張と allowed redundancy（実測）

backlink 導入事例で導入された bidirectional backlink sub-pattern (`# Downstream reference: <downstream-file>`) を、backlink 一律適用事例で **既存 5 ANCHOR (ingest.md Phase 5.1/5.2 の 4 site + lint.md Phase 8.1 の 1 site) に team guideline として一律適用** した。これにより新規 ANCHOR と既存 ANCHOR の表記が統一され、canonical 側を編集する開発者が「downstream をどこから探せばよいか」を全 ANCHOR で grep 1 発で特定できる状態になった (片方向リンク残存による silent drift 経路を排除)。

両 reviewer (prompt-engineer / code-quality) が独立して以下の **allowed redundancy** 観察を確認:

- 既存 sibling sync 契約 prose (例: 「本 commit_msg 文字列と直下の placeholder-residue gate は Phase 5.0.c canonical と Phase 5.1 / Phase 5.2 の同一文字列と 3 箇所 explicit sync を契約。変更時は 3 箇所同時更新必須」) と、新規追加した backlink 行 (例: `Downstream reference: same file:Phase 5.2 — sibling sync 契約相手`) は、**同じ対称化相手を異なる文言で 2 度参照する**冗長表現になる
- これは **意図的に許容される redundancy** であり、撤去対象ではない:
  - prose は **意図と契約の説明** (なぜ 3 箇所同期が必要か / 変更時の手続き)
  - backlink 行は **機械検証可能な逆方向ポインタ** (grep 1 発で downstream を特定)
  - 役割が異なるため一方を削除すると他方の機能が劣化する (prose 削除 → 設計意図喪失、backlink 削除 → drift 検出機能喪失)

**Canonical 適用フロー**:

1. 既存 ANCHOR に backlink を追加する PR では、既存の sibling sync 契約 prose を **撤去・統合せず** 並置する
2. backlink 行は END marker には付けない（慣習: canonical reference は START のみに記載）
3. team guideline 適用 PR (本 PR のような「複数の既存 ANCHOR への一律拡張」) は scope を絞って 5-15 行程度に収め、Confidence 80+ の blocking 指摘 0 件で短時間 review 可能な極小対称化 PR として運用する

### bidirectional backlink の canonical format 統一（実測）

backlink 導入事例で bidirectional backlink sub-pattern を導入した時点と、backlink 一律適用事例で team guideline として 5 ANCHOR に一律適用した時点で、以下の 3 つの format dialect が並存していた:

1. **コロン記法 (Wiki canonical)**: `Downstream reference: plugins/rite/commands/wiki/init.md:Phase 1.3.4`
2. **スペース区切り（初期実装の dialect）**: `Downstream reference: plugins/rite/commands/wiki/init.md Phase 1.3.4 verification`
3. **括弧記法（team guideline 拡張時の dialect）**: `Downstream reference: same file Phase 5.2 (DRIFT-CHECK ANCHOR: Phase 5.0.c canonical commit message) — sibling sync 契約相手`

実害はないが grep ベースの drift 検出 lint を将来実装する際に 3 形式を parse する必要が生じ、機械検証の困難化を招く。その後 **コロン記法** を canonical format として team 合意・一律適用した。

**Canonical 形式（統一後）**:

```bash
# 単一 reference
# Downstream reference: plugins/rite/commands/wiki/init.md:Phase 1.3.4

# 複数 reference (カンマ区切り)
# Downstream reference: lint.md:Phase 8.3, same file:Phase 5.1 — sibling sync 契約相手
```

**適用原則**:

1. **`<file>:<Phase X.Y>` の最小形**: ファイルパスと Phase 番号を `:` で連結する
2. **括弧注記は禁止**: `(DRIFT-CHECK ANCHOR: <name>)` 等の semantic name 補足は書かない。`<file>:<Phase X.Y>` で anchor は unique 特定可能 (各 Phase 内に同名 anchor は高々数個)
3. **複数 reference はカンマ区切り**: `lint.md:Phase 8.3, same file:Phase 5.2` のように並記する
4. **契約説明 prose は `—` 以降に保持**: `— sibling sync 契約相手` や `— 本 emit 値 (...) を ... の single source of truth として参照する` 等の契約説明は drift 検出対象外の自由記述として保持してよい

**機械検証の expected pattern**:

```bash
grep -E 'Downstream reference: [^ ]+:Phase [0-9]+\.[0-9]+' <file>
```

NG pattern (将来 lint で検出):

- `Downstream reference: <file> Phase X.Y` (スペース区切り) — backlink 導入事例の旧 dialect
- `Downstream reference: <file> Phase X.Y (DRIFT-CHECK ANCHOR: ...)` (括弧記法) — backlink 一律適用事例の旧 dialect

**refactor 着地の cross-validation**（実測）: canonical format 統一 refactor を develop へ merge する PR の multi-reviewer review (prompt-engineer / code-quality) で 0 findings / severity 全 0 の healthy landing を確認。extract された observation は以下の 4 点で、いずれも「format 統一 refactor を scope 外汚染なく着地させる」canonical application として機能した:

- **dialect unification の 9 site 1:1 対応**: 並存していた 3 format (コロン / スペース / 括弧) を全 9 site で canonical コロン記法に変換、unification 完遂
- **semantic 情報の保全**: 括弧注記 (`(DRIFT-CHECK ANCHOR: <name>)`) を削除しても `<file>:<Phase X.Y>` で anchor unique 特定が維持される (各 Phase 内に同名 anchor は高々数個という前提の再確認)
- **scope 境界の明確性**: bidirectional backlink sub-pattern 対象の 8 site のみ変更、一般 prose 内の参照 ( `plugins/rite/commands/...` 等) は意図的に scope 外として保持
- **wiki branch 別 commit 分離**: Wiki canonical page 更新を develop branch PR から分離、dev ブランチ diff に Wiki 変更が混入しない worktree ベース運用を維持

本 cross-validation は「canonical format を team guideline として確立する PR」→「canonical format を一律適用する refactor PR」の 2 段階着地が、極小対称化 PR の運用 heuristic に乗る形で短時間 review 可能であることの追加実証にもなっている (findings 0 件 + merge 可の decisive 判定)。

### 直前 merge PR 規約への後続 PR 違反（cycle 2 の実測）

「line 番号 literal 禁止 / semantic anchor 化」規約を確立した PR の merge 直後に作成された後続 PR が、その規約を設計メモ記述で破る G4 HIGH が cycle 2 で検出された:

- 規約を確立した入れ子 ANCHOR 事例の merge timestamp: 2026-04-20T04:30 頃
- 後続 PR の初回 commit timestamp: 2026-04-20T14:33 頃 (約 10 時間後)
- 違反箇所: 後続 PR の Phase 9.1 設計メモの非レンダリング注釈内で Step 番号 ↔ Output ordering の対応を literal 行番号参照で記述

直前 merge PR で確立した規約は、当該 repository の contributors 全員が把握しているとは限らない。特に複数の PR を並行で手掛けている場合、merge 済み PR の PR body から抽出すべき規約の認知に gap が発生し、同規約の violation が 1 日以内に発生する。

**canonical 対策（cycle 2 fix で確立）**:

1. **後続 PR の review 時に直近 merged PR 一覧を参照**: `git log --oneline --merges -10` で直近 10 件の merged PR 一覧を取得し、各 PR の主要規約を PR body の "確立規約" セクション (あれば) から抽出する
2. **commit 時系列を意識した review**: 「この PR が作成された時点で既に merge 済みの規約 PR」を reviewer が明示的に確認する。review プロンプトに「直近 1 週間の merged PR で確立された規約を list して遵守確認」を含める
3. **PR body の "確立規約" セクション記述**: 規約を確立する PR では PR body に `## 確立規約` セクションを設け、grep-matchable な形で後続 PR reviewer が検出できるようにする (例: `semantic anchor 規約: DRIFT-CHECK ANCHOR に line 番号 literal を書かない`)
4. **pre-PR self-check**: PR 作成者自身が commit 前に `grep -nE 'L[0-9]+|\(line [0-9]+\)' <changed_files>` を実行して line 番号 literal 残存を検出する

本原則は semantic anchor 規約に限らず、**最近の PR で確立された任意の規約** (コメント規約、naming convention、test pattern 等) に一般化される。team velocity の高い repository ほど規約 velocity も高く、直前 PR の規約違反が 24 時間以内に発生する risk が上昇する。

### 実測された 5 種表記の散文形式 drift

4-arg 拡張事例では 4-arg DRIFT-CHECK ANCHOR 拡張時に、cycle 1 で **2 site 同時に** hardcoded line-number reference が新規導入された:

| Site | 表記形式 | 違反内容 |
|------|---------|---------|
| `cleanup.md:1674` | parenthesized form | `(line 1659, 1680)` |
| `create-interview.md:605` | 散文形式 | `本セクション直前の line 588 / 597 caller HTML inline literal` + `create.md:580 / create-interview.md:22 の DRIFT-CHECK ANCHOR` |

cycle 2 fix で cleanup.md の `(line N, M)` 表記を structural reference 化したが、**propagation scan logic が `(line N, M)` 形式に限定されていた**ため、create-interview.md:605 の散文形式は検出できず cycle 3 まで残留。prompt-engineer + code-quality の cross-validation で発覚した。

**stop-guard.sh で 3 箇所明文化されている project convention (line-number 参照を避ける、cycle 8 F-05) は本ページの canonical reference**。本 PR cycle 1 fix の commit message も `learned: ANCHOR comment の prose 内 bash 引数 enumeration は literal block と同等の同期義務がある` と教訓化していたにもかかわらず、横展開検査が cleanup.md 1 ファイルに留まり、create-interview.md は scope 外に落ちた。

**5 種表記すべてを scan 対象にする canonical 拡張**: drift-check-anchor lint pattern を以下の 5 種すべてに対応させる必要がある (REC-04 として 4-arg 拡張事例で別 Issue 候補化):

1. `(line N, M)` parenthesized form
2. `(L<num>)` short form (bracket variant)
3. `<file>:<num>` colon form
4. `本セクション直前の line N` 散文形式 (Japanese inline)
5. `Line <num>` capitalized form (English title case)

### 4-arg DRIFT-CHECK ANCHOR symmetry 拡張の canonical procedure

既存の symmetry 概念に新しい引数を昇格させる作業 (3-arg → 4-arg) は、影響を受ける anchor location 全件を事前列挙してチェックリスト化することで drift を防げる。4-arg 拡張事例では:

| Site | 4-arg 化対象 | Result |
|------|-------------|--------|
| `commands/issue/create.md` Step 0 | literal block + ANCHOR comment prose | cycle 1 で同期完了 |
| `commands/issue/create-interview.md` Pre-flight + Return Output re-patch | literal block (×2) | cycle 1 で同期完了 |
| `commands/pr/cleanup.md` Step 0 | literal block | cycle 1 で同期完了 |
| `hooks/stop-guard.sh` case arm WORKFLOW_HINT | literal block | cycle 1 で同期完了 |
| `commands/issue/create-interview.md` の enhancement blockquote | **prose 側 1 site のみ 3-arg 表記残留 (cycle 2 で検出)** | cycle 2 で同期完了 |

**ANCHOR comment と literal の pair sync invariant**: ANCHOR comment と literal は同期 invariant を持つ。片方を更新する PR は対称先の comment も同時更新しないと、後続 PR で comment と literal の drift を見て「3-arg が正」と誤判断するリスクが残る (cycle 1 で 3 箇所同時に発覚した HIGH 3 件はこの構造)。

### approximation 接尾辞 `~` も含めた全パターン禁止と SoT lint 自動化

cycle 4 review で `(line ~N)` のような **approximation 接尾辞 `~` 付き** literal 行番号参照が cycle 2 fix 時に 2 箇所、cycle 4 fix 時に 3 箇所新規導入された自己撞着が HIGH × 1 (code-quality reviewer) で検出された。SoT 原則 3 (no_line_or_cycle_reference) は「cycle/finding ID 参照だけでなく行番号参照も禁止」だが、approximation 接尾辞 `~` を含むケースが「概数だから drift しない」と誤認されやすく、5 種表記に **6 種目** として追加すべき pattern であることが実測された。

`~` 接尾辞禁止事例の cycle 5 fix で 5 箇所 (cycle 4 fix 3 箇所 + cycle 2 fix 2 箇所) を全て削除し、`grep -E '\(line[s]?\s*[~]?[0-9]+'` を SoT 側に lint 自動化することを wiki 経験則として蓄積。

**禁止対象 6 種表記の canonical list**（6 種目は後から追加）:

| # | 表記形式 | 例 | 検出 regex |
|---|---------|-----|-----------|
| 1 | parenthesized form | `(line 1659, 1680)` | `\(line[s]?\s*[0-9]+` |
| 2 | bracket short form | `(L1234)` / `L270-277` | `L[0-9]+(-[0-9]+)?` |
| 3 | colon form | `cleanup.md:1674` | `[a-zA-Z_-]+\.md:[0-9]+` |
| 4 | 散文形式 (Japanese) | `本セクション直前の line 588` | `line\s+[0-9]+` (within prose) |
| 5 | capitalized form (English) | `Line 698` | `Line\s+[0-9]+` |
| 6 | **approximation 接尾辞** | `(line ~N)` / `(line ~588)` | `\(line[s]?\s*~[0-9]+` |

**SoT lint 自動化提案**: hardcoded-line-number-check.sh の P-A/P-B/P-C パターンに **P-D (approximation 接尾辞)** を追加し、6 種すべてを mechanical 検出可能にする。fix サイクルで「概数だから drift しない」誤認を防ぐ canonical 対策。

**self-introduce drift の経路**: cycle 内 fix で self-aware に「行番号参照禁止」を意識していても、approximation 接尾辞 `~` が「概数 marker」として機能性を持つため、reviewer / fix 担当が「これは literal 行番号と異なる」と認知してしまう。本 anti-pattern は累積対策 PR で fix 自体が drift を導入する fractal pattern (`fix-induced-drift-in-cumulative-defense.md`) の延長線上にあり、grep pattern を 6 種に拡張することで decisive 検出を維持する。

### 観察された meta-self-undercut の再発

`start-md-charter.test.sh` の latent edge case 2 件に対応した PR の review (test-reviewer / code-quality-reviewer) で、Severity Distribution は CRITICAL/HIGH/MEDIUM/LOW 全 0 件 (healthy landing) でありながら、recommendations の中に Confidence 90 の R-04 finding として「機械保護のない line-number 参照 (L131-138) が drift している」が検出された。

本事例の構造的特徴:

- **Same-file 3-site sync 経験則を本 PR が遵守して PR description に明記している** にもかかわらず、その PR description 自身が他文書を `L131-138` の literal line-number で指していた
- つまり「Same-file sync 経験則を強化する PR 自身が line-ref drift を持つ」 ironic な meta-self-undercut 構造
- Same-file sync 系経験則の累積適用 PR で繰り返し再発する pattern であり、`fix-induced-drift-in-cumulative-defense.md` (fractal drift) と本ページ (line-number 禁止) の交点

本事例は本ページ「禁止対象 6 種表記」table の `L[0-9]+(-[0-9]+)?` (#2 bracket short form) に該当する。PR description 内の literal line-number は changed-files の grep 対象外 (`hardcoded-line-number-check.sh` の scan 対象は `*.md` の本文系で PR body は対象外) のため、6 種表記の **scan scope** を「コード本文 / 設計メモ / 関連 PR description のクロス参照ブロック」へ拡張する余地が改めて確認された (REC: PR template に line-ref pre-flight self-check を組み込む)。

### Partial symbolic anchor 採用が新規追加で drift 再発（cycle 1→3 の実測）

partial 採用事例の cycle 1 fix で symbolic anchor 化を **partial** に適用したが、cycle 3 で peer 参照を新規追加する際に literal 行番号で記述した。結果として「既存 anchor は symbolic / 新規 anchor は hardcoded」の混在状態が成立し、cycle 3 で line drift が再発 (累積 N 回目の同型再発)。

教訓:

1. **partial adoption は中途半端な drift 防御**: 一部だけ symbolic anchor 化しても、新規追加サイトが line-number で書かれれば drift class は閉じない
2. **新規参照追加時こそ canonical 確認が必要**: 既存方針 (line-number 禁止) を **新規** anchor も遵守しているか、追加 commit 前に grep で機械検証する
3. **symbolic anchor 化 = 行番号 drift 経路の構造的閉塞**: cycle 3 fix で 6 ファイル全 line cite を symbolic name に置換することで「partial adoption の罠」を消去 → cycle 4 で 0 findings に収束

cycle 1 → 3 の 2 度同型再発は、本ページの **canonical scope 拡張版** が必要だった signal: 「**既存 anchor 群への新規追加** は既存方針との conformance を新規 anchor 自身が満たす必要がある」という partial adoption の罠を明示化すべき。

### reference 文書の NOTE 内 cross-file 行番号 citation の全件 stale 化（実測）

この事例では `references/wiki-patterns.md` L225 の「canonical 階層」NOTE が `ingest.md` を指す literal 行番号 citation (`L530` / `L559` / `L821` / `L557-567` / `L569`) を semantic anchor (section 見出し名 + placeholder 名) へ書き換えた。本ページが扱う code comment / DRIFT-CHECK ANCHOR / PR description に続く **第 4 の表記コンテキスト = reference 文書の散文 NOTE 内 cross-file citation** の実測事例。

本事例で確認された 2 つの新しい facet:

1. **全件 stale + target 消失の実測**: Doc-Heavy reviewer (tech-writer) が参照先 `ingest.md` を Read/Grep で照合した結果、旧 5 citation はすべて drift 済みだった (実体は 338 / 361 / 576 行、`L530` は空行、`L557-567` は別ブロック末尾、`L569` は `{title}` 表行、`L821` は EOF 超過)。特に `(L569 で dual-site 備考)` は **指している「dual-site 備考」記述そのものが ingest.md から消失** しており、citation を削除して dual-site 維持の事実を本文へ吸収する方が **誤情報の除去として net-positive** (情報欠落ではない)。「行番号は書いた時点から陳腐化が始まる」原理の cross-file 版。

2. **semantic anchor 採用後の残る drift 経路の明示**: section 見出し名 / placeholder 名による anchor は行番号 drift には耐えるが、**見出し名やラベルがリネームされると参照が切れる**新たな drift 経路を持つ。SoT (ingest.md) の見出し名と literal 一致させ、見出し名変更時に参照元 (wiki-patterns.md) も同期更新する契約を前提に運用する (行番号 citation より顕著に安定的なため採用自体は妥当という design_confirmation)。

scope 維持の判断: 同一ファイル `wiki-patterns.md` 内の sibling literal citation (L268 `trigger.sh L226-231` / L275 `L308-320` / L276 `lint.md L72-86`) は本 PR では touch せず follow-up Issue へ分離した。`asymmetric-fix-transcription` の「対称位置への伝播漏れ」を認識しつつ、scope creep を避けて別 Issue として切り出すのが clean (本ページ canonical の「禁止対象表記」を ファイル全体へ一括適用するのは別 PR の責務)。

### sibling literal citation の完遂と Doc-Heavy verification による独立検証（実測）

前項の PR が follow-up Issue へ分離した同一ファイル `wiki-patterns.md` 内の sibling literal citation 3 件を、後続 PR が完遂した。「対称位置への伝播漏れを別 Issue 化 → 後続 PR で消化する」運用（極小対称化 PR flow）の実例:

| 旧 citation | 新 semantic anchor |
|------------|-------------------|
| `trigger.sh L226-231 self-comment で「3 sites still re-implement inline」` | self-comment「Three sites still re-implement YAML parsing inline」(実コメント文言参照) |
| `(L308-320 case ... exit 2)` | `case "$wiki_enabled"` の `*) ... exit 2` 分岐 (case 構文参照) |
| `lint.md L72-86` | lint.md ステップ 1.1 (Wiki 設定の読み取りとブランチ戦略判定) の `branch_strategy` 検証 case (`*) ... exit 1`) (見出し名参照) |

本事例で確認された新 facet:

1. **引用文言の drift も伴っていた**: L268 の旧 citation は行番号だけでなく引用文言「3 sites still re-implement inline」自体が実コメント (`Three sites still re-implement YAML parsing inline`) と不一致だった。行番号 citation を semantic anchor 化する際は、anchor 文言を実体と verbatim 一致させる補正も同時に行う (引用 paraphrase の drift は行番号 drift と独立して発生する)。
2. **Doc-Heavy mode Implementation Coverage 検証が anchor の実在性・一意性の独立検証として機能**: review で tech-writer (Doc-Heavy mode) + code-quality の 2 reviewer が、新 anchor が参照する識別子 (self-comment 文言 / `case "$wiki_enabled"` の出現 1 回・`*) exit 2` 分岐 / lint.md ステップ 1.1 見出し + branch_strategy case) を全件 Grep/Read で照合し、実在かつ一意に解決可能であることを確認 (0 findings / 1 cycle mergeable)。semantic anchor 採用後の「見出しリネームで切れる残存 drift 経路」（前項の design_confirmation）に対する review-time の機械検証層として機能する。
3. **pre-existing boundary recommendation の revert test 分離**: 同一 doc 行 (`branch_strategy` 検証 bullet) の pre-existing 部分 (ingest.md fail-fast を「`*` arm」と記述) に reviewer が boundary recommendation を出したが、revert test で diff 変更箇所外と判定し別 Issue へ分離 (scope creep 回避)。citation 整備 PR でも本体スコープ (行番号 → anchor) に集中し、隣接 pre-existing 事項は別 Issue 化するのが clean。

### 相対パス hop 数コメントは基点 (file vs directory) で 1 ずれる — hop 数でなく基点+到達先を書く

`L[0-9]+` 行番号と同様、**相対パスの hop 数をコメントで「N 階層上」と数える**のも hand-maintained な数値であり drift 源になる。特に **ディレクトリ変数** (例: `SCRIPT_DIR`) を基点とする `../..` のような相対式は、「ファイル基点で N 階層」と「ディレクトリ基点で N hop」で数え方が 1 ずれ、comment/code 矛盾を生みやすい。

hop 数コメント事例では `SCRIPT_DIR` (= `hooks/scripts/` ディレクトリ) を基点とする `$SCRIPT_DIR/../..` (2 hop) のコードに対し、コメントが「三階層上」(ファイル基点の数え方) と記述していた。code は正しいが comment が 1 ずれており、cycle 2 reviewer は LOW/nit-noted、cycle 3 reviewer は「将来コメントを信じて `../../..` に誤修正 → PLUGIN_ROOT 破綻 (reconcile / self-ref path 両方)」とより強い current-pr 根拠で MEDIUM 昇格した (同一 comment-nit の severity/scope が reviewer 間で LOW/nit-noted ↔ MEDIUM/current-pr に非決定に振れた例)。

**fix (drift-free 表現)**: hop 数のカウントをやめ、「基点 (`SCRIPT_DIR`) + 到達先 (`plugins/rite`) + 相対式 (`../..`)」を名前で明示する (code は不変)。本ページ canonical の「行番号の代わりに到達先 code slice を書く」と同型で、hand-maintained な hop 数を到達先の固有名に置換することで drift 経路を閉じる。

### SoT ルールリストの再番号化で消費側の数値ルール引用が dangling 化する — 圧縮宣言は保持例外を明記する（cycle 1-2 の実測）

行番号 / hop 数だけでなく、**SoT 文書内の番号付きリスト項目（ルール N / 原則 N）への数値引用**も同型の drift 経路を持つことが実測された。coding-principles を rite 固有規約へ圧縮する PR で、Rules セクションを 5 項 → 3 項へ圧縮・再番号化した結果、消費側スキル（`open/SKILL.md`）が `reference_discovery` の「ルール 4」を数値で引用していた箇所が dangling 化した（cycle 1、MEDIUM）。cycle 2 fix で番号非依存の **semantic 参照**（ルール本文の要約引用）へ置換して解消し、cycle 2 で 0 findings に収束。

**教訓**: (1) SoT 側の番号付きリストを再構成（圧縮・並べ替え・統合）する PR では、消費側の「ルール N」「原則 N」のような数値引用は自動的に対象範囲外に落ちやすい — 伝播スキャンは `ルール [0-9]` / `原則 [0-9]` のような数値引用パターンの全 grep を必須にする（本ページ既存の `L[0-9]+` 系 grep と同型の scan 拡張）。数値引用は SoT 側の再構成に追従できないため、消費側は最初から semantic 参照（要約引用）を使うのが再発防止として有効。(2) SoT 表がアンカー参照する用例（本 PR では禁止句リスト表 → 原則 2 Failure Patterns）は圧縮の削除対象から意図的に除外する必要がある場合があり、圧縮 PR の前提宣言（「Summary + Rules のみを残す」等）と実態（例外的に一部節を保持する）が自己矛盾すると、将来の PR がその宣言だけを信じて literal に再圧縮した際 load-bearing な節を削ってしまう退行経路になる。圧縮 refactor では宣言文自体に保持例外を明記するのが安全（「圧縮宣言 vs 実態」の自己矛盾を防ぐパターンは [大規模圧縮 refactor の行数 AC は protected 区域 + scope 制約から逆算して決める](../heuristics/compression-refactor-ac-vs-structural-constraint.md) と同系統の圧縮 refactor 特有の losses）。

## 関連ページ

- [Peer pattern の drift 判定は canonical schema 不変条件で cross-check する](./canonical-schema-invariant-peer-cross-check.md)
- [LLM substitute placeholder は bash residue gate で fail-fast 化する](./placeholder-residue-gate-bash-fail-fast.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)
- [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](./drift-check-anchor-prose-code-sync.md)
- [Markdown code fence の balance は commit 前に awk で機械検証する](./markdown-fence-balance-precommit-check.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)

## ソース

- [PR #579 review results (cycle 1)](../../raw/reviews/20260418T122454Z-pr-579.md)
- [PR #579 fix results (cycle 1)](../../raw/fixes/20260418T122707Z-pr-579.md)
- [PR #586 cycle 5 review (大量行挿入時のコメント行番号 drift)](../../raw/reviews/20260419T034237Z-pr-586-cycle5.md)
- [PR #600 cycle 1 review (ハードコード行番号参照の self-referential drift 検出)](../../raw/reviews/20260419T122543Z-pr-600.md)
- [PR #600 fix results (semantic code slice 参照への置換による完全解消)](../../raw/fixes/20260419T122750Z-pr-600.md)
- [PR #600 cycle 2 review (code slice 参照の canonical 実証)](../../raw/reviews/20260419T123103Z-pr-600.md)
- [PR #605 review results (±3 行 drift brittleness 実証 + bidirectional backlink sub-pattern)](../../raw/reviews/20260419T134838Z-pr-605.md)
- [PR #617 review (ANCHOR 入れ子の crossing 構造 detection)](../../raw/reviews/20260420T042759Z-pr-617.md)
- [PR #617 fix (well-formed nesting canonical 適用)](../../raw/fixes/20260420T043015Z-pr-617-fix1.md)
- [PR #619 review (bidirectional backlink team guideline 5 ANCHOR 拡張 + allowed redundancy)](../../raw/reviews/20260420T052907Z-pr-619.md)
- [PR #624 cycle 2 review (直前 merge PR 規約への後続 PR 違反)](../../raw/reviews/20260420T145943Z-pr-624-cycle2.md)
- [PR #626 review (bidirectional backlink canonical format 統一 refactor の healthy landing)](../../raw/reviews/20260420T160140Z-pr-626.md)
- [PR #661 cycle 1 review (4-arg DRIFT-CHECK ANCHOR drift 3 件)](../../raw/reviews/20260425T133145Z-pr-661.md)
- [PR #661 cycle 1 fix (4-arg ANCHOR comment 統一)](../../raw/fixes/20260425T154517Z-pr-661-cycle-1.md)
- [PR #661 cycle 2 review (cleanup.md:1674 hardcoded line-number 違反)](../../raw/reviews/20260425T161137Z-pr-661.md)
- [PR #661 cycle 2 fix (structural reference 化)](../../raw/fixes/20260425T161635Z-pr-661.md)
- [PR #661 cycle 3 review (create-interview.md:605 散文形式 line-number reference cross-validation 検出)](../../raw/reviews/20260425T165246Z-pr-661.md)
- [PR #661 cycle 3 fix (5 種表記対応への scan 拡張提案)](../../raw/fixes/20260425T165546Z-pr-661.md)
- [PR #756 cycle 4 review (approximation 接尾辞 `~` 付き line-number reference HIGH 検出)](../../raw/reviews/20260501T024847Z-pr-756.md)
- [PR #756 cycle 5 fix (5 箇所削除 + 6 種目 approximation 接尾辞の lint 自動化提案)](../../raw/fixes/20260501T025722Z-pr-756.md)
- [PR #913 review — Same-file sync 経験則 PR 自身の line-ref drift meta-self-undercut](../../raw/reviews/20260509T053632Z-pr-913.md)
- [PR #1035 review (line anchor drift + sentinel format drift の 2 種同時検出)](../../raw/reviews/20260518T024436Z-pr-1035.md)
- [PR #1035 fix cycle 1 (line anchor を opener から capture 行に修正 + symbolic name 併記)](../../raw/fixes/20260518T024749Z-pr-1035.md)
- [PR #1035 fix cycle 3 (symbolic anchor 化で 6 ファイル全 line cite 撤廃 → 4-cycle 収束)](../../raw/fixes/20260518T032735Z-pr-1035.md)
- [PR #1035 review cycle 4 converged (symbolic anchor 化で line drift class 終結 + 0 findings)](../../raw/reviews/20260518T035931Z-pr-1035.md)
- [PR #1187 review — reference 文書 NOTE 内 cross-file 行番号 citation の全件 stale 化 + target 消失](../../raw/reviews/20260529T055839Z-pr-1187.md)
- [PR #1188 review — sibling citation 3 件完遂 + Doc-Heavy Implementation Coverage による anchor 独立検証 + 引用文言 drift 補正](../../raw/reviews/20260529T065341Z-pr-1188.md)
- [PR #1306 review cycle 3 (SCRIPT_DIR 基点の相対パス hop 数コメントが file/directory 基点で 1 ずれ)](../../raw/reviews/20260608T121819Z-pr-1306.md)
- [PR #1306 fix cycle 3 (hop 数を基点+到達先の固有名に置換して drift-free 化)](../../raw/fixes/20260608T122037Z-pr-1306.md)
- [PR #1887 review cycle 1 (SoT ルール圧縮・再番号化で消費側の数値ルール引用が dangling 化、MEDIUM 1件)](../../raw/reviews/20260717T062934Z-pr-1887.md)
- [PR #1887 review cycle 2 (semantic 参照への置換で収束、0 findings)](../../raw/reviews/20260717T064500Z-pr-1887.md)
- [PR #1887 fix results (番号非依存の semantic 参照への置換)](../../raw/fixes/20260717T063251Z-pr-1887.md)
