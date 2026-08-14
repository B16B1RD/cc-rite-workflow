---
title: "「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる"
domain: "heuristics"
promote: rite-plugin
created: "2026-06-10T12:50:00+09:00"
description: "ドキュメントやテストの保守ガイダンスで「contract の全 consumer」のような網羅性を主張する列挙を書くとき、reviewer の指摘任せに 1 件ずつ追加していくと cycle ごとに新たな漏れが見つかり review-fix loop が発散する。"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260804T120832Z-pr-2108.md"
  - type: "reviews"
    resource: "raw/reviews/20260725T041328Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T193804Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T202517Z-pr-2013.md"
  - type: "reviews"
    resource: "raw/reviews/20260609T233431Z-pr-1334.md"
  - type: "fixes"
    resource: "raw/fixes/20260609T230419Z-pr-1332.md"
  - type: "fixes"
    resource: "raw/fixes/20260609T230945Z-pr-1332-c2.md"
  - type: "fixes"
    resource: "raw/fixes/20260609T231510Z-pr-1332-c3.md"
  - type: "fixes"
    resource: "raw/fixes/20260609T232051Z-pr-1332-c4.md"
  - type: "reviews"
    resource: "raw/reviews/20260609T232442Z-pr-1332-c5.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-04T21:15:00+09:00" }
---

# 「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる

## 概要

ドキュメントやテストの保守ガイダンスで「contract の全 consumer」のような網羅性を主張する列挙を書くとき、reviewer の指摘任せに 1 件ずつ追加していくと cycle ごとに新たな漏れが見つかり review-fix loop が発散する。grep による機械的全数棚卸し → 包含基準での分類 → 全数列挙 + scope note (含む/除く基準と棚卸し方法) の明記、で 1 cycle で収束させる。

## 詳細

doc cross-ref drift を解消した PR で、link-sub-issue.sh の「contract 変更時に更新すべき consumer」列挙が 5 cycle にわたり発散した実測:

- cycle 1: 復旧手順 literal (create.md) の pointer 欠落 → 追加
- cycle 2: runtime consumer (backfill-sub-issues.sh) の漏れ → 追加 + usage 例 (graphql-helpers.md) も追加
- cycle 3: sibling test (create-md-invocation-symmetry.test.sh TC-5b) の漏れ → 追加 + scope note 導入
- cycle 4: scope note の自己定義基準に合致する integration test stub (decompose-issues.test.sh) の漏れ → **grep 全数棚卸しで残余ゼロを確認してから**追加し、棚卸し方法 (`grep link-sub-issue で棚卸し済`) を scope note に明記
- cycle 5: 3 reviewer が独立に全数列挙を再検証し過不足ゼロで 0 findings 収束

教訓:

1. **「網羅完了」の主張は機械的棚卸しの裏付けが必須**: reviewer の知識ベースの指摘で 1 件ずつ追加する方式は、毎 cycle 新しい盲点 (runtime consumer / sibling test / mock stub / usage 例) が surface して収束しない。`grep -rln <token>` の全 hit を包含基準 (literal 保持の有無) で分類し、残余ゼロを確認してから「全数」と書く。
2. **scope note には基準と棚卸し方法の両方を書く**: 「literal を持つ consumer のみ (設計ドキュメント除く)」という基準だけだと、基準に合致する未列挙ファイルの存在が次 cycle の指摘になる。「grep X で棚卸し済」と方法まで書けば、将来の更新者も同じ手順で再検証できる。
3. **二次 drift に注意**: cross-ref drift の修正 PR 自体が、参照先の置換で「旧参照先が担っていた別役割 (復旧手順等) への pointer」を消す二次 drift を起こしやすい。置換前に旧参照先の全役割を棚卸しする。

## 変種: 規約の適用対象は「構文」でなく「概念」で grep する

規約を新設した PR が **自分でその規約に適用漏れを起こす** 事例が 4 cycle で 3 回反復した。核心は棚卸しの検索語の選び方にある。

| cycle | 何を grep したか | 何を取りこぼしたか |
|---|---|---|
| 2 | 1 箇所に床を入れて終わり | 同じ形の probe が他に 2 つ |
| 3 | `command -v` という **構文** | `mktemp` の成否で判定している TC-036a の probe |
| 4 | — | （概念で探して収束） |

cycle 3 で「capability probe には blocking gate の floor を付けよ」と CONTRIBUTING に明文化した同じ PR が、触った 3 つの `command -v jq` gate に floor を付けていなかった。cycle 4 で最後に残った 1 件は、`command -v` 形だけを grep したために `mktemp` ベースの probe を取りこぼしたものだった。

> **規約が定義するのは「capability probe」という概念であって `command -v` という構文ではない。** 構文で探すと、同じ性質を持つが別の書き方をしている箇所が構造的に漏れる。

同型の指摘は「否定アサーション」「予約グリフ」でも起きた。いずれも規約の言葉（概念）で探せば見つかり、実装形（構文）で探すと漏れる。

**あわせて「対象外」の判断も根拠付きで記録する**: cycle 3 の修正では、他 7 ファイルの jq probe は `ERROR + exit 1` の hard fail で silent skip しないため対象外、と grep で全数確認してから修正範囲を決めた。「探して、無かった」と「探していない」を読み手が区別できる形にする。

### 部分適用が新しい盲点を作る

原則を部分適用すると、**残りの箇所は「対処済みのクラス」に見えて逆に発見されにくくなる**。「非 ASCII 隣接の未ブレース変数を禁じる」規則も、宣言文は全体規則として書きながら走査は 1 ファイルに限っていた。レビューで原則を立てたら、**その場で grep して全適用箇所を列挙する**。

### 補足: フィルタしたストリームへの `grep -n` は行番号を壊す

棚卸しの実行時、`grep -v '^#' file | grep -n pattern` は「コメント除去後の何行目か」を返す。単一ファイルなら気づくが、走査対象を数百ファイルに広げると数百行ずれた無関係な位置を指し、診断が誤誘導になる。元ファイルに採番する単一 awk パスにすれば構造的に起きない:

```bash
awk '!/^#/ && /pattern/ { print FILENAME ":" NR ": " $0 }' file...
```

## 変種: 「1 件の記載漏れ」の報告は、その形式を採る全サイトの走査要求として読む

Issue が具体的な 1 件だけを挙げていても、それは「この 1 行を直せ」ではなく「同じ形式を採る全サイトを走査せよ」という要求として読む。ドキュメントの列挙 1 行の漏れを報告した Issue で、実装時に同形式の行を全数確認したところ**別の行にも同種の漏れ**が見つかり、修正対象が 1 件から 2 件になった。報告された 1 件だけを直すと、同じ Issue が形を変えて繰り返し起票される。

**走査範囲を広げるのと、修正範囲を広げるのは別の判断**。同じ cycle でレビュアーが走査面を隣接ディレクトリへ広げた結果、同クラス（仕様書と実体の乖離）の pre-existing な問題が 4 件見つかったが、これらは本 diff が導入したものではない（revert test fail）ため指摘事項ではなく follow-up Issue に切り出した。走査は広く、修正は本 diff スコープに閉じる — 引き込むと 2 行の diff が 6 箇所へ膨らみ、レビューの焦点も失われる。

### 根拠の検証と結論の検証は別軸で行う

実装者が「触らない」判断の理由として挙げた根拠が実体と食い違っていても、判断そのものは正しいことがある。上記の cycle では実装者が「列挙を持たない 4 スキルは対象が多いため意図的に集約形式にしている」と説明したが、実体を照合すると 1 つは列挙形式のスキルと同数で、**件数による使い分けという説明は成立しなかった**。それでも「本 PR で触らない」という結論自体は正しい（それらの行はそもそも列挙形式を採っておらず、Issue が言う「列挙の記載漏れ」に該当しない）。根拠が崩れたことを結論の否定に直結させず、結論は独立に検証する。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [形状検証 gate の allowlist 化は複数行 bypass・上流 degraded 値・コメント同期をセットで棚卸しする](./allowlist-gate-hardening-checklist.md)
- [reviewer の regression 主張は revert test (git show / git diff) で PR 由来か pre-existing かを独立検証する](./reviewer-regression-claim-revert-test-attribution.md)

## ソース

- [PR #1332 fix cycle 1 (復旧手順 pointer 追加)](../../raw/fixes/20260609T230419Z-pr-1332.md)
- [PR #1332 fix cycle 2 (runtime consumer 追加)](../../raw/fixes/20260609T230945Z-pr-1332-c2.md)
- [PR #1332 fix cycle 3 (sibling test 追加 + scope note 導入)](../../raw/fixes/20260609T231510Z-pr-1332-c3.md)
- [PR #1332 fix cycle 4 (grep 全数棚卸しで収束)](../../raw/fixes/20260609T232051Z-pr-1332-c4.md)
- [PR #1332 review cycle 5 mergeable (3 reviewer 独立検証で過不足ゼロ)](../../raw/reviews/20260609T232442Z-pr-1332-c5.md)
- [PR #1334 review mergeable (派生事例: doc 追記の Issue 番号帰属を git log で裏取りし、番号を付ける対象を裏付けの取れた側のみに限定して誤帰属を回避 — reviewer の独立検証と一致して 1 cycle 0 findings 収束)](../../raw/reviews/20260609T233431Z-pr-1334.md)
- [PR #2013 review cycle 4 — 規約の適用漏れは「構文」でなく「概念」で grep する](../../raw/reviews/20260725T041328Z-pr-2013.md)
- [PR #2013 fix results (cycle 3) — 原則は立てた箇所でなく当てはまる全箇所に適用する](../../raw/fixes/20260724T193804Z-pr-2013.md)
- [PR #2013 fix results (cycle 4) — フィルタ済みストリームへの grep -n が行番号を壊す](../../raw/fixes/20260724T202517Z-pr-2013.md)
- [PR #2108 review results — 「1 件の記載漏れ」の報告を全サイト走査要求として読む / 走査範囲と修正範囲の分離](../../raw/reviews/20260804T120832Z-pr-2108.md)
