---
title: "DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）"
domain: "patterns"
created: "2026-04-18T12:50:00+00:00"
updated: "2026-04-20T16:53:38+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T122454Z-pr-579.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T122707Z-pr-579.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T034237Z-pr-586-cycle5.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T122543Z-pr-600.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T122750Z-pr-600.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T123103Z-pr-600.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T134838Z-pr-605.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T042759Z-pr-617.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T043015Z-pr-617-fix1.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T052907Z-pr-619.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T145943Z-pr-624-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T160140Z-pr-626.md"
tags: []
confidence: high
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

### Canonical 形式 (PR #579 cycle 1 で統一)

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

### 大量行挿入時のコメント内行番号参照 drift (PR #586 cycle 5 での evidence)

PR #586 cycle 4 fix で Phase 1.3 ブロック (約 235 行) を init.md の Phase 1.2 と Phase 2 の間に挿入した結果、cycle 4 fix の F-02 修正コメント自身が「同一ファイル内 L555」を参照していたが、実際の対象行は L563 にずれた (8 行 drift)。cycle 5 review で F-02 として検出。

本原則は DRIFT-CHECK ANCHOR コメントだけでなく、**fix コメント / 設計メモ / 概要説明など**「同一ファイル内の他箇所を参照するあらゆる散文」に拡張される:

1. **参照は anchor / Phase 番号 / heading / function 名で書く**: drift 耐性が高い
2. **大量行挿入を伴う PR では最終 commit 後に行番号参照を grep で走査**: `grep -nE 'L[0-9]+' <file>` で全件取り出して目視再確認
3. **将来的に `/rite:lint` でコメント内行番号参照を検出する lint を追加する候補**: `L[0-9]+` を含むコメントは機械検証できないため、anchor / Phase 番号への置換を促す

### code slice 参照による semantic identifier の canonical 実証 (PR #600 での evidence)

PR #600 cycle 1 では `plugins/rite/commands/wiki/lint.md` のコメント内に `Phase 6.0 (line 698)` という「Phase 番号 + literal 行番号」の混成表現が残っていた。同 PR の +2 行差分で実体は L700 に shift し、コメントが即 stale 化した。cycle 2 fix で `(line 698)` を `LC_ALL=C cat .rite/wiki/log.md` という **対象コードの特徴的コード片による論理参照** に置換することで完全解消。両 reviewer (prompt-engineer / code-quality) が以下を独立して高く評価:

- **Grep で実体存在が機械検証可能**: 将来の読者が `grep 'LC_ALL=C cat .rite/wiki/log.md' lint.md` で target を確実に特定できる
- **PR の +N 行差分で stale 化しない**: 行番号 anchor のように shift しない
- **Phase 番号 + code slice の組み合わせ**: Phase 番号が「どの論理階層か」を示し、code slice が「その階層のどの具体行か」を指す 2 段階の semantic identifier として機能

canonical 記法の階層 (drift 耐性が高い順):

1. **Phase 番号 + 特徴的コード片** (最推奨、PR #600 実証): `Phase 6.0 の \`LC_ALL=C cat .rite/wiki/log.md\``
2. **Phase 番号 + heading / function 名**: `Phase 5.0.c canonical commit message`
3. **DRIFT-CHECK ANCHOR の semantic name**: `# >>> DRIFT-CHECK ANCHOR: ... <<<`
4. **literal 行番号** (禁止): `(line 698)` / `L1331-1332`

既存 convention (PR #564 F-06 で確立) を再導入時に違反する self-drift pattern として、commit 前 `grep -nE '\(line [0-9]+\)' <file>` で検出できる。

### line 番号 literal の brittleness 実証 + bidirectional backlink 拡張 (PR #605 での evidence)

PR #605 で init.md L253 / L320 のコメント内に残存していた `L270-277` / `L84-L113` / `L281 付近` を semantic anchor 参照に置換した際、次の 2 点が実証された:

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

### 入れ子追加時の outer/inner END 順序による well-formed nesting (PR #617 での evidence)

PR #617 で `.gitignore` 既存 `negation verification canonical` ANCHOR を inner として、それを包む outer ANCHOR `same_branch verification-first setup steps` を追加した際、HIGH finding として **「outer END を inner END より前に配置すると bracket matching が crossing 構造になる」** failure mode が検出された:

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

**Canonical 適用手順** (PR #617 fix で確立):

1. 既存 inner anchor の包含範囲 (どの節を含むか) を最初に確認する
2. outer END の位置は **inner END の直後** に配置することを最優先で決める
3. outer START の位置を inner START より前に配置する
4. commit 前に `awk` で depth tracking 検証: `awk '/START.*<<</{d++} /END.*<<</{d--; if(d<0){print "DEPTH_NEGATIVE at NR="NR; exit 1}}' file`

本原則は `# >>> DRIFT-CHECK ANCHOR <<<` だけでなく、HEREDOC marker (`<<EOF` / `EOF`) や Markdown code fence (` ``` `) のような **対称 delimiter を持つすべての構造** に適用される。

### bidirectional backlink の team guideline 拡張と allowed redundancy (PR #619 での evidence)

PR #605 で導入された bidirectional backlink sub-pattern (`# Downstream reference: <downstream-file>`) を、PR #619 で **既存 5 ANCHOR (ingest.md Phase 5.1/5.2 の 4 site + lint.md Phase 8.1 の 1 site) に team guideline として一律適用** した。これにより新規 ANCHOR と既存 ANCHOR の表記が統一され、canonical 側を編集する開発者が「downstream をどこから探せばよいか」を全 ANCHOR で grep 1 発で特定できる状態になった (片方向リンク残存による silent drift 経路を排除)。

両 reviewer (prompt-engineer / code-quality) が独立して以下の **allowed redundancy** 観察を確認:

- 既存 sibling sync 契約 prose (例: 「本 commit_msg 文字列と直下の placeholder-residue gate は Phase 5.0.c canonical と Phase 5.1 / Phase 5.2 の同一文字列と 3 箇所 explicit sync を契約。変更時は 3 箇所同時更新必須」) と、新規追加した backlink 行 (例: `Downstream reference: same file:Phase 5.2 — sibling sync 契約相手`) は、**同じ対称化相手を異なる文言で 2 度参照する**冗長表現になる
- これは **意図的に許容される redundancy** であり、撤去対象ではない:
  - prose は **意図と契約の説明** (なぜ 3 箇所同期が必要か / 変更時の手続き)
  - backlink 行は **機械検証可能な逆方向ポインタ** (grep 1 発で downstream を特定)
  - 役割が異なるため一方を削除すると他方の機能が劣化する (prose 削除 → 設計意図喪失、backlink 削除 → drift 検出機能喪失)

**Canonical 適用フロー** (PR #619 で確立):

1. 既存 ANCHOR に backlink を追加する PR では、既存の sibling sync 契約 prose を **撤去・統合せず** 並置する
2. backlink 行は END marker には付けない (PR #605 慣習: canonical reference は START のみに記載)
3. team guideline 適用 PR (本 PR のような「複数の既存 ANCHOR への一律拡張」) は scope を絞って 5-15 行程度に収め、Confidence 80+ の blocking 指摘 0 件で短時間 review 可能な極小対称化 PR として運用する

### bidirectional backlink の canonical format 統一 (PR #620 / Issue #620 での evidence)

PR #605 で bidirectional backlink sub-pattern を導入した時点と PR #619 で team guideline として 5 ANCHOR に一律適用した時点で、以下の 3 つの format dialect が並存していた:

1. **コロン記法 (Wiki canonical)**: `Downstream reference: plugins/rite/commands/wiki/init.md:Phase 1.3.4`
2. **スペース区切り (PR #605 実装 dialect)**: `Downstream reference: plugins/rite/commands/wiki/init.md Phase 1.3.4 verification`
3. **括弧記法 (PR #619 実装 dialect)**: `Downstream reference: same file Phase 5.2 (DRIFT-CHECK ANCHOR: Phase 5.0.c canonical commit message) — sibling sync 契約相手`

実害はないが grep ベースの drift 検出 lint を将来実装する際に 3 形式を parse する必要が生じ、機械検証の困難化を招く。PR #620 (Issue #620) で **コロン記法** を canonical format として team 合意・一律適用した。

**Canonical 形式 (PR #620 で統一)**:

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

- `Downstream reference: <file> Phase X.Y` (スペース区切り) — PR #605 旧 dialect
- `Downstream reference: <file> Phase X.Y (DRIFT-CHECK ANCHOR: ...)` (括弧記法) — PR #619 旧 dialect

**refactor 着地の cross-validation** (PR #626 review での evidence): PR #620 の canonical format 統一 refactor を develop に merge する PR #626 の multi-reviewer review (prompt-engineer / code-quality) で 0 findings / severity 全 0 の healthy landing を確認。extract された observation は以下の 4 点で、いずれも「format 統一 refactor を scope 外汚染なく着地させる」canonical application として機能した:

- **dialect unification の 9 site 1:1 対応**: 並存していた 3 format (コロン / スペース / 括弧) を全 9 site で canonical コロン記法に変換、unification 完遂
- **semantic 情報の保全**: 括弧注記 (`(DRIFT-CHECK ANCHOR: <name>)`) を削除しても `<file>:<Phase X.Y>` で anchor unique 特定が維持される (各 Phase 内に同名 anchor は高々数個という前提の再確認)
- **scope 境界の明確性**: bidirectional backlink sub-pattern 対象の 8 site のみ変更、一般 prose 内の参照 ( `plugins/rite/commands/...` 等) は意図的に scope 外として保持
- **wiki branch 別 commit 分離**: Wiki canonical page 更新を develop branch PR から分離、dev ブランチ diff に Wiki 変更が混入しない worktree ベース運用を維持

本 cross-validation は「canonical format を team guideline として確立する PR (PR #619)」→「canonical format を一律適用する refactor PR (PR #620 / PR #626)」の 2 段階着地が、極小対称化 PR (PR #592) の運用 heuristic に乗る形で短時間 review 可能であることの追加実証にもなっている (findings 0 件 + merge 可の decisive 判定)。

### 直前 merge PR 規約への後続 PR 違反 (PR #624 cycle 2 での evidence)

PR #624 (Issue #618) cycle 2 で、PR #617 merge 直後に作成された本 PR が PR #617 で確立した「line 番号 literal 禁止 / semantic anchor 化」規約を設計メモ記述で破る G4 HIGH が検出された:

- PR #617 merge timestamp: 2026-04-20T04:30 頃
- PR #624 初回 commit timestamp: 2026-04-20T14:33 頃 (約 10 時間後)
- 違反箇所: PR #624 Phase 9.1 設計メモの非レンダリング注釈内で Step 番号 ↔ Output ordering の対応を literal 行番号参照で記述

直前 merge PR で確立した規約は、当該 repository の contributors 全員が把握しているとは限らない。特に複数の PR を並行で手掛けている場合、merge 済み PR の PR body から抽出すべき規約の認知に gap が発生し、同規約の violation が 1 日以内に発生する。

**canonical 対策 (PR #624 cycle 2 fix で確立)**:

1. **後続 PR の review 時に直近 merged PR 一覧を参照**: `git log --oneline --merges -10` で直近 10 件の merged PR 一覧を取得し、各 PR の主要規約を PR body の "確立規約" セクション (あれば) から抽出する
2. **commit 時系列を意識した review**: 「この PR が作成された時点で既に merge 済みの規約 PR」を reviewer が明示的に確認する。review プロンプトに「直近 1 週間の merged PR で確立された規約を list して遵守確認」を含める
3. **PR body の "確立規約" セクション記述**: 規約を確立する PR では PR body に `## 確立規約` セクションを設け、grep-matchable な形で後続 PR reviewer が検出できるようにする (例: `semantic anchor 規約: DRIFT-CHECK ANCHOR に line 番号 literal を書かない`)
4. **pre-PR self-check**: PR 作成者自身が commit 前に `grep -nE 'L[0-9]+|\(line [0-9]+\)' <changed_files>` を実行して line 番号 literal 残存を検出する

本原則は semantic anchor 規約に限らず、**最近の PR で確立された任意の規約** (コメント規約、naming convention、test pattern 等) に一般化される。team velocity の高い repository ほど規約 velocity も高く、直前 PR の規約違反が 24 時間以内に発生する risk が上昇する。

## 関連ページ

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
