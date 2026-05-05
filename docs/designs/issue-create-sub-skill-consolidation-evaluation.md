# /rite:issue:create sub-skill 統合可能性評価

## 1. 背景

`/rite:issue:create` ゼロベース再設計 (Phase E) の段階的リファクタとして、`create.md` 本体と 3 sub-skill (`create-interview.md` / `create-decompose.md` / `create-register.md`) の統合可能性を評価する。

評価の判断基準は [Simplification Charter](../../plugins/rite/skills/rite-workflow/references/simplification-charter.md) の 5 自問および推奨パターン「sub-skill 分離は最小限、重複 confirmation や重複 flow-state patch を必要とするなら統合を検討」。

## 2. 現状サイズと責務

| ファイル | 行数 | 責務 |
|---------|------|------|
| `commands/issue/create.md` | 347 | orchestrator (Phase 0 / Phase 1 delegation / Phase 2 / Phase 3 delegation routing) |
| `commands/issue/create-interview.md` | 315 | Phase 1 + 1.1 (適応的インタビュー) |
| `commands/issue/create-decompose.md` | 508 | Phase 3 (Decompose path: Spec + Decompose + Bulk Create + Terminal Completion) |
| `commands/issue/create-register.md` | 623 | Phase 3 (Single Issue path: Classify + Confirm + Create + Terminal Completion) |
| **合計** | **1,793** | |

References (`commands/issue/references/`): 7 ファイル
- `bulk-create-pattern.md` / `complexity-gate.md` / `contract-section-mapping.md`
- `edge-cases-create.md` / `pre-check-routing.md` / `slug-generation.md`
- `sub-skill-handoff-contract.md`

## 3. 統合可能性評価

### 3.1 案 A: 完全統合 (4 → 1 ファイル)

**却下**。理由:

- 1 ファイル 1,800 行は AC-1「新規 contributor が 1〜2 ファイルで全体像把握」の精神に反する
- 巨大 monolith は scannability を悪化させ、Markdown 大規模 refactor 時の heading hierarchy skip リスクが増大 (Wiki 経験則: PR #808-#809)
- 関心の分離 (interview = adaptive Q&A / decompose = spec + bulk create / register = single issue classify) は機能的に正当で、責務境界が明確

### 3.2 案 B: 部分統合 (4 → 2-3 ファイル)

**却下**。理由:

- decompose と register は terminal sub-skill として並列の役割 (Phase 2 selection で分岐) であり、共通化メリットが薄い (両者の Phase 3 内容は構造が異なる)
- interview と decompose を統合すると、interview の早期 return (Bug Fix / Chore preset) と decompose の specification 生成の責務が混在する
- handoff 契約 (4-site 対称化) が複雑化し、新たな drift risk を生む

### 3.3 案 C: 採用方針 — handoff contract slim 化 + caller anchor 整理

**採用**。理由:

- charter 5 自問を `references/sub-skill-handoff-contract.md` (98 行) に適用すると、抽出経緯・historical site (4)・散文 DRIFT-CHECK ANCHOR・Wiki 経験則経緯記述・Issue/PR 番号本文引用が大量に削除候補となる
- 機能契約 (4 必須引数 / `--if-exists` 非対称 / path 非対称) は保持しつつ、散文 SoT を ≤ 60 行に削減
- caller (`create.md` / `create-interview.md`) の DRIFT-CHECK ANCHOR コメント・散文 blockquote も同基準で整理 (pair update で Asymmetric Fix Transcription 防止)
- 機械検証は `hooks/tests/4-site-symmetry.test.sh` が継続担保

これにより、新規 contributor が読むべき reference の認知負荷が下がり、AC-1 達成度が向上する。

## 4. charter 5 自問適用結果 (sub-skill-handoff-contract.md 98 行に対する)

| セクション | 自問 #1 (runtime?) | 自問 #2 (git log 代替?) | 自問 #5 (LLM が runtime で読むか?) | 判定 |
|-----------|------|------|------|------|
| 「抽出経緯」段落 | ❌ | ✅ | ❌ | 削除 |
| 「DRIFT-CHECK ANCHOR (semantic, 3-site + historical 4th)」blockquote | ❌ | ✅ | ❌ | 削除 |
| historical site (4) (表内 strikethrough 行) | ❌ | ✅ | ❌ | 削除 |
| Issue/PR 番号本文引用 (`#525 / #552 / #561 ...` 等) | ❌ | ✅ | ❌ | 削除 |
| 「関連 Wiki 経験則」セクション | ❌ | ✅ | ❌ | 削除 |
| 4 必須引数表 | ✅ | — | ✅ | **保持** |
| `--if-exists` 非対称表 | ✅ | — | ✅ | **保持** (occurrence 集計 を簡素化) |
| path 非対称表 | ✅ | — | ✅ | **保持** |
| DRIFT-CHECK ANCHOR pattern 4 ルール | △ | — | ✅ | **保持** (簡素化) |

## 5. AC 達成見込み

| AC | 達成見込み (本 PR) | 根拠 |
|----|------------------|------|
| AC-1 (1〜2 ファイル + 1〜2 reference で全体像把握) | 部分達成 — reference 1 本 (handoff contract) を slim 化、create.md 系 4 ファイルは構造維持 | 認知負荷を下げる方向で AC-1 に寄与 |
| AC-2 (Phase 番号体系整数化) | 維持 (PR-E2 達成) | 本 PR で新規 0.x.y 追加なし |
| AC-3 (AskUserQuestion 削減) | 本 PR scope 外 | PR-E3 で多くを処理済。コード経路に変更なし |
| AC-4 (機能契約保持: Bypass block / Terminal Completion / 機械検証 / sentinel emit) | 達成 | bash literal 不変、`4-site-symmetry.test.sh` で機械検証 |
| AC-5 (e2e test 3 経路 pass) | 部分達成 — `4-site-symmetry.test.sh` pass を本 PR で確認、e2e 3 経路 (Bug Fix preset / single Issue / XL decomposition) は別 PR で計測 | |

## 6. 採用方針の実装範囲

| Step | 内容 |
|------|------|
| S1 | 本評価レポート作成 |
| S2 | `references/sub-skill-handoff-contract.md` 散文 slim 化 (98 → ≤ 60 行) |
| S3 | `commands/issue/create.md` DRIFT-CHECK ANCHOR / 散文 blockquote 整理 |
| S4 | `commands/issue/create-interview.md` 同上 (S3 と pair update) |
| S5 | `hooks/tests/4-site-symmetry.test.sh` exit 0 を確認 |
| S6 | 本レポートに「実施した simplification」「残課題」追記 |
| S7 | charter 5 自問 self-check を PR description に記載 |

## 7. リスクと緩和

| リスク | 緩和策 |
|--------|--------|
| Asymmetric Fix Transcription (Wiki 累積23回目) | S3/S4 は本 PR で未実施 (Section 8.3 参照)。caller 側 (create.md / create-interview.md) に handoff contract slim 化への追従が不要だったため (grep で 0 件確認済)、片肺更新リスクは実体化せず |
| `--active true` / `--preserve-error-count` の silent omit (Wiki: AND 論理防御層チェーン無効化) | bash literal 不変、`4-site-symmetry.test.sh` で 4 引数の存在を機械検証 |
| Markdown heading hierarchy skip (Wiki: PR #808-#809) | slim 化後の `## / ###` 連続性を目視確認 |
| Protected 区域削除 (Wiki: 圧縮 AC は protected 区域から逆算) | 4 必須引数表 / `--if-exists` 非対称表 / path 非対称表は削除対象外 |

## 8. 実施した simplification

### 8.1 変更内容

| 対象 | 変更 | Before | After |
|------|------|--------|-------|
| `references/sub-skill-handoff-contract.md` | 散文 SoT slim 化 (抽出経緯 / historical site (4) / Issue・PR 番号本文引用 / 関連 Wiki 経験則経緯記述 削除) | 98 行 | 60 行 (-39%) |
| `commands/issue/create.md` | 追加整理 **不要** と確定 | 347 行 / 🚨 4 occurrence / Issue・PR 引用 0 | 同左 (PR-E1〜E3 で既に slim 化済) |
| `commands/issue/create-interview.md` | 追加整理 **不要** と確定 (handoff contract slim 化に追従が必要な箇所も 0 件) | 315 行 / 🚨 4 occurrence / Issue・PR 引用 0 | 同左 (PR-E1〜E3 で既に slim 化済) |

### 8.2 機能契約保持の検証

- `bash plugins/rite/hooks/tests/4-site-symmetry.test.sh` → exit 0 (PASS 8 / FAIL 0)
- 4 必須引数 (`--phase` / `--active` / `--next` / `--preserve-error-count`) が両 caller で grep -c >= 1 で機械検証
- `create.md`: `--phase`(8) `--active`(6) `--next`(8) `--preserve-error-count`(2)
- `create-interview.md`: `--phase`(5) `--active`(4) `--next`(5) `--preserve-error-count`(7)

### 8.3 計画逸脱

実装計画 S3 / S4 (create.md / create-interview.md の DRIFT-CHECK ANCHOR / 散文整理) は **追加実施せず**、handoff contract slim 化のみで本 PR-E4 の主成果物とした。

理由:
- 両ファイルは PR-E1〜E3 で既に charter 上限内 (🚨 ≤ 5 / Issue・PR 引用 ≤ 1) に整理済
- handoff contract で削除した「historical 4th site」記述に caller 側が依存していない (grep で 0 件)
- 残る rationale blockquote (Why patch mode only / Plain-text form rationale 等) は LLM の将来編集時に機能契約意図を理解するために必要 = charter 自問 #1 で「runtime に効く」と再評価

これにより本 PR の scope は「handoff contract 散文 slim 化 + 評価レポート」のみに収束。

### 8.4 charter 5 自問 self-check (本 PR への適用)

| # | 自問 | 本 PR での回答 |
|---|------|--------------|
| 1 | runtime に効くか? | handoff contract slim 化は機能契約 (4 必須引数 / `--if-exists` 非対称 / path 非対称) を保持しつつ散文記述のみ削減。`4-site-symmetry.test.sh` PASS で機能契約保持を機械検証 |
| 2 | git log / commit message / close 済み Issue で代替できるか? | 削除した「抽出経緯」「historical site (4) 経緯」「Wiki 経験則経緯」は git log + close 済み Issue + 本評価レポートで代替 |
| 3 | 「なぜこうなっているか」の説明か、「何をすべきか」か? | 削除対象は全て「なぜ」の説明 (経緯 / rationale / 歴史)。残した内容は全て「何をすべきか」(契約 / 表) |
| 4 | 既に承認された判断を再確認しているか? | DRIFT-CHECK ANCHOR の散文重複は本 PR で削減 (semantic anchor pattern セクションに集約) |
| 5 | LLM が runtime で読むものか? | 残した内容は全て LLM が `flow-state-update.sh patch` 編集時に参照する SoT。削除した経緯記述は人間メンテナの好奇心向け |

## 9. 残課題と次 PR 候補

- `commands/issue/create-decompose.md` (508 行) の charter 適用評価 (本 PR scope 外)
- `commands/issue/create-register.md` (623 行) の charter 適用評価 (本 PR scope 外)
- AskUserQuestion 削減 (AC-3) のさらなる強化と達成度計測 (Bug Fix preset 経路 0-1 回 / Refactor M 規模 2-3 回以下の達成度計測)
- e2e test 3 経路 (Bug Fix preset / single Issue / XL decomposition) の実機実行および pass 確認 (AC-5)
- handoff contract slim 化後に残る「Asymmetric Fix Transcription 経緯」「DRIFT-CHECK ANCHOR 設計理由」等の人間向け文脈は、本評価レポートおよび git log で代替されるため、コードベース内の散文記述は更に削減可能
