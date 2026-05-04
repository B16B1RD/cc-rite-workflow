# rite workflow Simplification Charter

## 目的

rite workflow 自体および rite workflow が生成する成果物（commit message / Issue body / PR description / reference ファイル）が、自己生成的に肥大化することを防ぐ。**「シンプル化」のための作業が新たな複雑性を生む** 自己言及ループを止めるための判断基準を本 charter に集約する。

## 対象

本 charter は以下を編集・生成する LLM および人間メンテナに適用される:

- `plugins/rite/` 配下の全 .md / .yml / .sh ファイル（commands / skills / references / hooks / agents / templates / scripts）
- rite workflow が生成する commit message / Issue body / PR description
- review cycle で生成される指摘リスト

## 5 つの自問

ファイル新規作成・セクション追加・段落追加の前に順に自問する。**1 つでも YES に該当したら、その記述は削除候補**。

1. **これを削除して、`/rite:*` の動作は変わるか? → 変わらないなら削除**
   - runtime に効く: bash literal、MUST/MUST NOT 条文、decision tree、手順記述、設定スキーマ
   - runtime に効かない: 抽出経緯、対称化契約の散文、過去 incident の解説、cycle 番号付き review 記録

2. **これは git log / commit message / close 済み Issue で代替できるか? → できるなら削除**
   - 「なぜこの設計になったか」は commit message に書く
   - 「Issue #N で何が起きたか」は close 済み Issue を見れば良い

3. **これは『なぜこうなっているか』の説明か、『何をすべきか』か? → 説明だけなら削除**
   - LLM は「現在のコードがどう書かれているか」と「これから何をすべきか」だけ必要
   - 歴史的経緯はメンテナの好奇心を満たすだけで、LLM の挙動に影響しない

4. **既に承認された判断を再確認しているか? → 重複なら除去**
   - 親 skill が confirmation を取った直後に、子 skill で MANDATORY confirmation を再発火させない
   - 同一 phase に対する flow-state patch を複数 site で繰り返さない

5. **この記述を読むのは LLM か、人間か?**
   - LLM 向け: SoT として 1 箇所に集約
   - 人間向けの長文経緯: コードベース外（git log / GitHub の close 済み Issue / `docs/decisions/`）に置く

## 禁止パターン（コードベース内 .md / .yml / .sh に書かない）

- `Issue #[0-9]+` / `PR #[0-9]+` / `cycle [0-9]+` の本文引用（セクション見出しでも最小限）
- `Drift guard` / `DRIFT-CHECK ANCHOR` / `NFR-[0-9]+` 系の対称化契約の散文記述
  - 対称化が必要な場合は **テストで担保**（例: `hooks/tests/4-site-symmetry.test.sh`）し、散文重複は書かない
- 「抽出経緯」「移管経緯」「Regression context」セクション
- review cycle 番号付きの指摘記録（`cycle 3 F-NEW1` など）
- `🚨` の濫用（1 ファイル 5 occurrence 以下）

## 推奨パターン

- **commit message** で経緯を説明し、コードベースには現在の動作仕様だけを書く
- **README / docs/** で「設計判断」を書く（コードに散らさない）
- **対称化契約は test で担保**、散文 SoT は 1 箇所のみ
- **sub-skill 分離は最小限**、重複 confirmation や重複 flow-state patch を必要とするなら統合を検討

## レビュー指摘の扱い

- **当該 PR 内で全て解消する**。次 PR に「対応経緯」として持ち越さない
- 持ち越す場合は **新しい Issue を起票**し、対応経緯ではなく要件として書き直す
- レビューラウンド数を ID 付きで記録しない（cycle 1 / cycle 2 / cycle 3 などは git log で十分）

## 自己観察

本 charter 自体および本 charter に基づく simplification 作業も、自己言及性を持つ。**作業中に新しい reference / sub-skill / 契約レイヤーを追加したくなったら、まず charter の自問を適用する**。追加が本当に必要な場合のみ実施し、可能なら **既存 SoT を更新する** か **削除する**。

## 適用範囲外（runtime に効くため現状維持）

- `plugins/rite/scripts/` 配下の .sh（実装契約として必要）
- `plugins/rite/hooks/` の hook 自体（runtime に効く）
- decision tree 系の reference（`complexity-gate.md` / `slug-generation.md` / `pre-check-routing.md` 等）
- bash literal そのもの（`create-decompose.md` の bulk-create block 等）
