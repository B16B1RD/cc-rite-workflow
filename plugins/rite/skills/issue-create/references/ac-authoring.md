# 受入条件（AC）の書き方と検証

> **SoT scope**: Issue 本文の受入条件を書くときの規則。consumer は `skills/issue-create/SKILL.md` の本文生成と `agents/_reviewer-base.md` の Documentation Fidelity Gate（AC を根拠にした finding の検証）。構造検査（AC 件数・T-xx 対応）は `templates/issue/default.md` の Output Validation Checklist が担い、本 reference は AC の**中身が検証可能か**だけを見る。

## 書くとき

- **検出条件は検出経路と 1 対 1 にする**: AC が失敗例を列挙するなら、1 件ずつ検出経路（テスト・grep・手動観測）を対応付ける。変異で「そのケースだけが落ちる」ことを求める AC は変異点を特定して書く。
- **grep 1 行を AC の判定にしない**: 複数行継続の patch site ではfalse positive になりうる。ブロックを意識した走査（block-aware scan）で書く。rename の AC は、キーワード + 数字の組み合わせでなく word boundary で全件を triage する。
- **実測記録型の AC は対象全件を実測する**: 形の検査や類推で代えない。実測は最後の修正 commit 後の HEAD で取り直し、HEAD とプラットフォーム（例: Linux 上の PASS）を記録に明記する。
- **択一で示された選択肢は両方実装しない**。MUST 同士が衝突するときは、実装を revert せず契約側の変更として扱う（手順は [review-reconciliation](../../../references/review-reconciliation.md) の `change_contract`）。契約自体が事実誤認の上にあるときは、契約どおりに実行し、訂正を Decision Log に残し、未決は WARNING + 後続 Issue にする。
- **未了の deferred は書いた場所で起票する**（番号の置き場所は `templates/issue/default.md` の Output Validation Checklist に従う）。恒久記録簿に未了工程を完了形で先書きしない（範囲宣言で書き、完了形は観測後）。
- **制約は閉じる Issue でなく、その時点で open な側・手順が読む場所に置く**。Sub-Issue 系列で AC を緩める判断が確定したら、親 Issue・設計文書・後続 Sub-Issue にも同じ緩和を反映する。

## 起票前

- 前提（「違反あり」「位置・件数・最終要素」）は現 HEAD で grep し、既に解消済みなら Issue を起票しない。ドキュメント修正 Issue は、記述箇所の網羅も grep で測ってから範囲を書く。

## 判定・進展・改訂

満たしたかの判定は `agents/acceptance-reviewer.md`、進展の判定と AC 改訂の記録は [review-stagnation](../../../references/review-stagnation.md) に従う（本 reference では扱わない）。
