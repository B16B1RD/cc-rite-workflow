---
type: "heuristics"
title: "全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin"
domain: "heuristics"
description: "「本経路に来るのは別 live セッション在席時のみ」「3 gates all pass のときのみ reap」のような**全称主張（排他性・網羅性）を含む散文**は、新しい到達経路やゲート例外が追加されると、**その行自体は未変更のまま偽になる**（comment rot: 周辺コードの変更が未変更行を偽化する）。"
created: "2026-07-21T18:30:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260721T173620Z-pr-1959.md"
  - type: "fixes"
    resource: "raw/fixes/20260721T173955Z-pr-1959.md"
  - type: "reviews"
    resource: "raw/reviews/20260721T175725Z-pr-1959.md"
  - type: "reviews"
    resource: "raw/reviews/20260721T181434Z-pr-1959.md"
  - type: "reviews"
    resource: "raw/reviews/20260829T113539Z-pr-2461.md"
  - type: "reviews"
    resource: "raw/reviews/20260829T142006Z-pr-2464.md"
  - type: "fixes"
    resource: "raw/fixes/20260829T142223Z-pr-2464.md"
  - type: "reviews"
    resource: "raw/reviews/20260830T043014Z-pr-2475.md"
  - type: "reviews"
    resource: "raw/reviews/20260830T044223Z-pr-2475.md"
  - type: "reviews"
    resource: "raw/reviews/20260831T074623Z-pr-2494.md"
tags: ["comment-rot", "cause-neutral", "exclusivity-claim", "doc-sync", "not-grep-pin", "quantifier-strengthening", "birth-defect"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-31T14:09:34Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-08-29T11:40:00+09:00"
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-08-30T04:57:39Z"
  - by: "rite-wiki-ingest/claude-opus-5"
    at: "2026-08-31T14:09:34Z"
---

# 全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin

## 概要

「本経路に来るのは別 live セッション在席時のみ」「3 gates all pass のときのみ reap」のような**全称主張（排他性・網羅性）を含む散文**は、新しい到達経路やゲート例外が追加されると、**その行自体は未変更のまま偽になる**（comment rot: 周辺コードの変更が未変更行を偽化する）。起点事例では sandbox マスク skip という第 2 の deferral ルート追加により、emit 文面・checkbox ロジックを直した後も、説明散文・定義グロス・経路注記・overview 要約（SPEC.md）の計 5 箇所に旧排他帰属が 3 cycle にわたり残存した。

## 詳細

### 修正の全数洗い手順

1. **同じ marker / 概念を説明する箇所を旧文面 grep で全数列挙する**: emit 文面（WARNING / echo）だけでなく、(a) bash block 冒頭の説明コメント、(b) marker の定義グロス（「XXX=1（〜のケース）」）、(c) 経路注記（in_main 等の分岐説明）、(d) overview 文書の要約行（SPEC の absolute 主張）まで対象にする
2. **帰属が確定している箇所は触らない**: marker 由来で原因が確定する分岐（live-cwd 検知の「別セッション使用中」）は正しい帰属であり、中立化の対象外。確定帰属と原因不定を区別して直す
3. **原因中立文面に倒す**: 「まだ削除されていない作業ツリーで使用中のため」のように原因を断定しない文面は、将来の第 3 のルート追加にも耐える
4. **assert_not_grep pin で再発遮断**: 旧文面の識別トークンを not_grep pin にして、コピペ由来の復活を機械検出する

### 量化子を強める編集そのものも同じ失敗を起こす

偽化の契機は経路追加だけではない。**列挙を足す編集が量化子を変える**場合、その編集自体が同じ失敗を作る。`Everything else (A, B)` を `Every other reader (e.g. A, B, C, D)` へ変える修正は、表面上は「例を 2 つ足した」だけに見えるが、実際には「名指し 3 件への言明」から「全 reader への全称」への強化にあたる。この形では**追加した 2 例だけでなく、既存 3 例も新しい量化子の下で成立するか**を実測し直す必要がある。追加分だけを検証して通すと、強化された主張が既存メンバーで偽のまま残る。

同じ文書内で閉じた列挙と開いた例示を併置するときは、どちらであるかを表記で区別する。網羅性が主張の核（例:「legacy を書きうる経路は 2 つだけ」）なら閉じたまま書き、将来増えうる側（例:「legacy へ倒れない reader の例」）には `e.g.` を付ける。この書き分けがあると、読み手が列挙の性質を取り違えず、後続の編集者も「ここへ足してよいか」を判断できる。

### pin の needle を変えた同一 diff がその pin の説明コメントを偽化する

偽化は「後から経路が増える」形だけでなく、**needle を書き換えた当の diff がその真上の説明コメントを置き去りにする**形でも起きる。`assert_grep` の needle を「記法 1 を最優先する」から「明示宣言を表行より優先する」へ変えた際、2 行上の「needle は『全記法受理』と『**記法 1 優先**』を同じ 1 行の合成として pin する」というコメントが旧 semantics のまま残った。pin literal 自体は contract test が守るが、**pin の意図を説明する散文には守り手がいない**。

この位置のコメントは、次に当該箇所を触る作業者が最初に読む説明であり、そこが実態とずれていると pin の目的そのものが誤って伝わる。**assert の needle・marker 名・enum 値を変える編集では、その識別子を引用している散文を同じ diff の変更対象として最初から数える**（周辺行の grep ではなく、変更した識別子の旧文字列を grep する）。

この形は実測アンカー（repro / failing_test）を構造的に持てないため実測必須ゲートでは non-blocking に降格するが、`[review:mergeable]` 到達後の消化経路（NB digest sweep）で必ず処理する。**アンカーを持てないことは「直さない」理由にならない**。

### 括弧で列挙を添えた全称量化は、書いた瞬間から偽になりうる

偽化は「後から偽になる」形（comment rot）だけではない。**執筆時点で既に偽**という形もある。`Every failure along this path (fetch failure, transform failure, PATCH failure, unresolved owner/repo) also surfaces as a systemMessage` のように**全称量化に括弧で例示を添える**書き方は、括弧の 4 件を確認しただけで全称が裏取りできたつもりになる。実際には括弧外に通知を出さない失敗枝が存在し、`Every` の部分が最初から偽だった。

**列挙を括弧で添えるなら、量化子のスコープをその括弧に合わせる**（`Each of the four failures listed here — A, B, C, D — surfaces as X`）。全称のまま書くなら、括弧の中身ではなく**その述語を満たす全経路**を grep で数え上げてから書く。前者は数え上げの義務を消す方向の書き換えで、過剰主張が減るため surface area も増えない。

この形は cycle 1 のレビューで両 reviewer が推奨事項として挙げ、blocking fix と同じ文の中で同時に直した。cycle 2 の Over-fix Check は「新しい契約もガードも増えず net-flat、かつ過剰主張が減る方向」として over-fix ではないと判定した。

### 無条件主張を直した修正文が、別の無条件主張になる

もっとも見落としやすい形は、**限定を求められた修正そのものが新しい全称主張を持ち込む**ケースである。「両方の終端値に到達可能」という無条件性を直した文の末尾が「誰かが手で option を足すまで報告され続ける」という別の無条件主張になっていた。実際の走査は `--limit` 既定 100 の単一ページで、reconcile 失敗時は当該 Issue の `updatedAt` が進まないため、他の CLOSED Issue が 100 件更新された時点で窓から静かに外れて報告が止まる。**終了条件を人手操作だけに固定した時点で、有界窓の存在が反例になっていた**。

同じ PR の姉妹文（派生 rationale 側）は「次回の実行で再び報告される」と正しく弱く書かれており、SoT 側だけが過剰主張していた。**限定句を足す修正では、置き換え後の文にも同じ検査をかける**。cycle 1 で潰した欠陥クラスが cycle 2 の修正文で再生産されるのは、検査対象が「元の文」で止まっているためである。

### 件数を断定する列挙は、根拠が構造的なら必ず破れる

「N 個の経路が無条件に X を書く」と件数で閉じる列挙は、その**根拠が構造的**であるとき必ず破れる。起点事例では「Two documented paths が無条件 Done を書く」と数えたが、段落自身が挙げる根拠（委譲先 helper が現在値を読まない）は**helper の性質**であり、その helper を呼ぶ全 caller が継承する。実数は 6 だった。4 reviewer が独立に到達。

対処は列挙を長くすることではなく、**根拠の帰属先で書くこと**: 「`X.sh` は現在値を問い合わせないため、同 helper 経由で書く全経路がこの規則の外にある」と述べれば列挙自体が不要になり、caller が増えても文は真のまま残る。件数で閉じるのは、根拠が**その N 個に固有**であることを確認できたときだけにする（[「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](./exhaustiveness-claims-require-mechanical-inventory.md)）。

### 語彙を変えたら同じ語彙の全 hit を sweep する

SoT の定義から 1 語（`duplicate`）を外したが、同じ SoT の Consumers 表に載っている consumer script の user-facing WARNING に旧語彙が残り、**新旧 2 版を同時に配布する状態**になった。3 reviewer が独立到達。一般化を戻す方向も同型で、`A terminal transition` → `A Done transition` の差し戻しを派生 rationale だけに適用し、同文を持つ script header を取り残した。**1 箇所を直した時点で `git grep` を引き、同じ文・同じ列挙の全コピーを当たる**。

### 管轄が別 Issue の Non-Target ドキュメント

drift 先が Issue の Non-Target（別 Issue の管轄と明記）である場合は、本 PR で触らず**管轄 Issue へコメントで申し送りを配線**する。新規起票は重複になる。握り潰しにならないよう、完了報告にも明示する。

## 関連ページ

- [実装の分岐を散文へ落とす前に、フラグの状態数と観測ラベルの値域を機械的に数える](./count-implementation-states-before-writing-prose.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)
- [Documentation review は対応する実装側の grep verify を必須 step とする](../heuristics/docs-review-implementation-grep-verification.md)
- [新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される](../anti-patterns/upstream-silent-path-defeats-new-logged-guard.md)

## ソース

- [説明散文の排他性残存を検出](../../raw/reviews/20260721T173620Z-pr-1959.md)
- [中立化 + not_grep pin](../../raw/fixes/20260721T173955Z-pr-1959.md)
- [overview 要約 SPEC.md の absolute 主張 drift](../../raw/reviews/20260721T175725Z-pr-1959.md)
- [残存 0 確認 + Non-Target doc の管轄 Issue 配線](../../raw/reviews/20260721T181434Z-pr-1959.md)
- [量化子を強める編集が既存メンバーの再検証を要求する](../../raw/reviews/20260829T113539Z-pr-2461.md)
- [pin の needle を変えた同一 diff がその説明コメントを置き去りにする](../../raw/reviews/20260829T142006Z-pr-2464.md)
- [NB sweep — アンカーを持てない散文 drift の消化経路](../../raw/fixes/20260829T142223Z-pr-2464.md)
- [括弧で列挙を添えた全称量化が執筆時点から偽だった](../../raw/reviews/20260830T043014Z-pr-2475.md)
- [同一文への「ついでの限定」は over-fix ではないと判定](../../raw/reviews/20260830T044223Z-pr-2475.md)
- [無条件主張を直した修正文が別の無条件主張になる / 件数断定の列挙は構造的根拠で破れる](../../raw/reviews/20260831T074623Z-pr-2494.md)
