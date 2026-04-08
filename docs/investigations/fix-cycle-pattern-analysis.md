# PR #350 Fix-Cycle 症例研究 — 分散伝播漏れ 5 パターン

> **位置づけ**: Issue #356 (Phase 0) 作業項目 6 の成果物。Issue #361 (Phase C2) 「分散伝播漏れ検出 lint」の **要件仕様** として参照される。

## 1. 背景

PR #350 (`feat/issue-349-doc-heavy-review-mode`) では `/verified-review` を含む 16+ 回の review-fix サイクルを経て累計 250+ 件の指摘に対応した。その過程で、**「同一の修正パターンが複数箇所に分散しているとき、LLM が一部にしか修正を伝播できない」** 現象が **5 パターン** にわたり繰り返し観測された。

これらは LLM 由来の系統的失敗であり、agent-based review (Issue #355 Phase A/B/C で改善) の品質向上では完全には防げない。**静的 lint による補完が必要** という認識が Issue #361 (Phase C2) として新設された経緯。

本ドキュメントは 5 パターン全てについて以下を記録する:
- **定義**: 何が起きているかの正確な記述
- **検出条件**: Phase C2 の lint が実装可能な静的検出ロジック
- **PR #350 内の再発回数**: 実例の出現箇所と修正までのサイクル数

## 2. 対象パターン

### Pattern-1: 同一構造の修正が一部 Phase にしか伝播しない

#### 定義

ある修正パターン (例: HEREDOC を `cat <<'EOF' > tmpfile` 形式に統一する) が、複数の Phase / 関数 / コードブロックに同じ形で存在しているにもかかわらず、修正コミットが **その一部にしか適用されない** 現象。

LLM は「3 箇所のうち 2 箇所を修正したから完了」と判断し、3 箇所目を見落とす。再 review で第三者から指摘されて初めて気づく。

#### 静的 lint 検出条件

「同一ファイル内に **構造的に類似した N 個のコードブロック** が存在し、N-1 個のみが特定のパターンに準拠している」状態を検出する:

1. **対象スコープ**: 1 つの Markdown ファイル内 (例: `commands/*.md`)
2. **構造的類似性の判定**: 同じ heredoc (`<<'EOF'`)、同じ関数呼び出しパターン (`bash {plugin_root}/...`)、同じテーブル列パターン
3. **準拠/非準拠の判定**: 修正パターン (例: `mktemp` の trap 設定) が N-1 ブロックに存在し、1 ブロックに欠落
4. **アラート閾値**: ファイル内の類似ブロックが 3 個以上で、同一パターンの遵守率が 50% 〜 99% (= 全準拠でも全非準拠でもない、混在状態)

**実装ヒント**: AST 不要。Markdown コードブロック単位で text-based diff を取り、majority pattern からの逸脱を検出する。

#### PR #350 内の再発回数

| サイクル | コミット | 該当 finding | 該当箇所 |
|---------|---------|------------|---------|
| Cycle 8 | `d8525cd` | L-5 (HEREDOC tmpfile pattern) | `commands/issue/create.md` Phase 2.4 のみ修正、Phase 4.2 と 4.3.4 を取りこぼし |
| Cycle 11 | `d36f80f` | L-7 (mktemp trap setup) | 同上、Phase 4.3.4 のみ修正、Phase 2.4 を取りこぼし (本セッション C3 で実証) |
| Cycle 11 | `d36f80f` | L-8 (Bash variable scope) | 同上、3 箇所中 2 箇所のみ修正 |

**再発回数**: 3 件 (PR #350 サイクル 8-11 範囲内)、いずれも `commands/issue/create.md` のような複数 Phase を持つ大型ファイルで発生。

---

### Pattern-2: 成功経路にのみ retained flag を emit、失敗経路で漏れる

#### 定義

「副作用を持つ操作 (例: `mktemp` でファイル作成、`gh project item-add` で Project 登録) が成功した場合に retained flag を emit してログに残す」というルールを追加した際、**成功経路 (try ブロック) にのみ flag emit を適用し、失敗経路 (catch / 失敗フォールバック) に emit が漏れる** 現象。

副作用が発生した可能性があるのにログに残らないため、後続の cleanup や retry ロジックが副作用を検出できなくなる (silent failure)。

#### 静的 lint 検出条件

1. **対象パターン**: `if [ ... ]; then ... emit_flag ... else ... fi` または `command1 && emit_flag || (echo error)` 形式
2. **emit_flag の検出**: 関数呼び出し / 変数 export / printf による特定マーカー出力
3. **アラート条件**: emit_flag が成功側にあり、失敗側にない、かつ失敗側が **副作用 (file creation, network call, state mutation) を実行している**
4. **副作用の判定**: `mktemp`, `mv`, `gh `, `git `, `curl`, `cp` 等のコマンドを失敗側で発見

**実装ヒント**: bash AST 解析は不要。`then ... else ... fi` ブロックを正規表現で抽出し、両側でパターン照合。

#### PR #350 内の再発回数

| サイクル | コミット | 該当 finding | 該当箇所 |
|---------|---------|------------|---------|
| Cycle 9 | `5da7b01` | H-1 (mktemp 失敗時の retained flag) | `commands/issue/create.md` Phase 2.4: success path で `WM_RETAINED=true` を export、mktemp 失敗パスで未設定 |
| Cycle 10 | `e825232` | H-2 (Phase 4.2 同パターン) | 同ファイル Phase 4.2 で同じ漏れ、再指摘 |
| Cycle 11 | `d36f80f` | H-3 (Phase 4.3.4 同パターン) | 同ファイル Phase 4.3.4 で同じ漏れ、本セッション再検証で確認 |
| Cycle 11 | `d36f80f` | H-4 (Phase 2.6 cleanup path) | `commands/issue/start.md` の cleanup ロジックで成功側 only |

**再発回数**: 4 件、すべて同一ファイル内の異なる Phase (Pattern-1 と複合)。

---

### Pattern-3: Reason table と実 emit ロジックの drift

#### 定義

`commands/pr/fix.md` Phase 8.1 のように、「呼び出し元に返す結果 reason の一覧表」をドキュメント内に持つ場合、**実コードで emit される reason 文字列が表に登録されていない** 現象。

Phase A 以降の実装で `[fix:pushed-wm-stale]` のような新パターンを追加しても、reason 表に追記し忘れる。reason 表を読んだ呼び出し元は新パターンを未知扱いし、エラー処理が壊れる。

#### 静的 lint 検出条件

1. **対象**: Markdown ファイル内の「reason 表」(列挙形式の table) と、同ファイル内の `printf 'pattern'` / `echo 'pattern'` / 結果出力ステートメント
2. **抽出**: 表の reason 列から登録 pattern セット A を抽出、コードブロック内の `[xxx:yyy]` 形式の出力 pattern セット B を抽出
3. **アラート条件**: B - A ≠ ∅ (実 emit されているが表にない pattern が存在) **または** A - B ≠ ∅ (表にあるが実 emit がない dead pattern)

**実装ヒント**: Markdown table parser + grep の組み合わせ。pattern syntax は `[a-z\-]+:[a-z\-]+(?::[a-z0-9-]+)?` のような統一フォーマットを前提とする。

#### PR #350 内の再発回数

| サイクル | コミット | 該当 finding | 該当箇所 |
|---------|---------|------------|---------|
| 本セッション (再検証) | (未修正) | C2 (reason table 12 件 vs 実 emit 28 件) | `commands/pr/fix.md` Phase 8.1 reason table と Phase 4-7 の実 emit |

**再発回数**: 1 件確定 (本セッション C2 で発見)。Phase A の修正範囲に組み込まれ、Issue #357 で対応予定。

---

### Pattern-4: Markdown 内部 anchor の drift

#### 定義

ドキュメント内の `[name](#anchor)` 形式の内部リンクで、**リンク先 heading が rename されたが anchor 参照側が更新されない** 現象。Markdown では存在しない anchor へのリンクはエラーにならず silent に壊れる。

#### 静的 lint 検出条件

1. **対象**: Markdown ファイル内の `[text](#anchor)` 形式
2. **生成**: `## ` `### ` heading から GFM anchor 生成ルール (lowercase, spaces→hyphens, 特殊文字削除) を適用して有効 anchor セットを構築
3. **アラート条件**: リンク内 anchor が有効 anchor セットに含まれない

**実装ヒント**: 既存の Markdown link checker (markdownlint MD051 ルール、remark-validate-links など) で実装可能。

#### PR #350 内の再発回数

| サイクル | コミット | 該当 finding | 該当箇所 |
|---------|---------|------------|---------|
| 本セッション (再検証) | (未修正) | H6 (`#cross-reference` → `#drift-detection-invariants` rename) | `docs/designs/review-quality-gap-closure.md` 内部リンク |

**再発回数**: 1 件確定。本セッションの再検証で発見。

---

### Pattern-5: 評価順テーブル row の reason 列挙 drift

#### 定義

「評価順テーブル」(例: `| 1 | reason X | ... |`, `| 2 | reason Y, Z, W | ... |` のように、行内に **括弧で列挙された理由文字列** を持つ table) において、**列挙された reason の集合と実コードの reason 集合が drift する** 現象。Pattern-3 の variant だが、table の単一セル内に列挙されるため検出が難しい。

#### 静的 lint 検出条件

1. **対象**: Markdown table の単一セル内に括弧 `(...)` または カンマ列挙 `a, b, c` 形式で reason がリストされているもの
2. **抽出**: セル内の列挙要素を分解 (split by `,` または `|` 内の reason pattern)
3. **比較**: 同ファイル内の実 emit pattern セットと比較
4. **アラート条件**: Pattern-3 と同じ (差分が ∅ ではない)

**実装ヒント**: Pattern-3 の検出ロジックを table セル parser で拡張。

#### PR #350 内の再発回数

| サイクル | コミット | 該当 finding | 該当箇所 |
|---------|---------|------------|---------|
| 本セッション (再検証) | (未修正) | C2 副次発見 | `commands/pr/fix.md` Phase 8.1 評価順テーブル row 2 (7 件の固定列挙 vs 実 28 件 emit) |

**再発回数**: 1 件確定。Pattern-3 と同コミットで発見、別パターンとして区別。

---

## 3. パターン別 検出優先度

| パターン | 検出難易度 | 修正コスト | 再発リスク | C2 lint 優先度 |
|---------|-----------|----------|----------|--------------|
| Pattern-1 (構造的類似ブロック) | 中 | 低 | **高** (大型 Markdown ファイルで頻発) | **HIGH** |
| Pattern-2 (失敗経路 emit 漏れ) | 中 | 低 | **高** (silent failure 直結) | **HIGH** |
| Pattern-3 (reason table drift) | 低 | 低 | 中 | MEDIUM |
| Pattern-4 (anchor drift) | **低** (既存ツールで実装可) | 低 | 中 | LOW (既存ツール導入で代替可) |
| Pattern-5 (table セル列挙 drift) | 高 (parser 必要) | 中 | 低 | LOW |

## 4. Phase C2 (#361) への引き継ぎ事項

1. **lint 実装範囲**: HIGH 優先度 (Pattern-1, Pattern-2) を最初に実装。Pattern-3 を MEDIUM で追加。Pattern-4 は markdownlint MD051 で代替可能、自前実装は不要。Pattern-5 は ROI 低のため deferral 候補。
2. **誤検出許容範囲**: false positive rate 10% 以下を目標 (LLM レビューと異なり静的解析は決定論なため)
3. **PR #350 commit `cec0140` での検証**: 5 パターン全てを検出できることを確認。`d36f80f` 以降の HEAD では 0 件になることを確認 (Phase A の修正後 = Pattern-3 解消後)
4. **既存 reviewer との分担**: Pattern-1, 2 は agent-based review でも検出可能だが LLM 揺らぎが大きい。lint で確実な safety net を張る役割
5. **CI 統合**: lint は PR 作成時に自動実行。指摘がある場合は PR ステータスを fail にせず warning として表示 (Phase 5.4 review-fix loop に委ねる)

## 5. 関連リソース

- **親 Issue**: #355 (refactor: /rite:pr:review 品質ギャップ解消)
- **本症例研究を必要とする Issue**: #361 (Phase C2 - 分散伝播漏れ検出 lint)
- **PR #350**: `feat/issue-349-doc-heavy-review-mode` (本症例研究の対象)
- **設計書**: `docs/designs/review-quality-gap-closure.md` (Phase A-D の全体設計)
- **事前検証 Issue**: #356 (Phase 0 - 本ドキュメントの作成元)
