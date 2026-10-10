---
title: "外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure"
domain: "anti-patterns"
description: "`gh pr view N` のような外部コマンドが失敗したとき、失敗種別 (origin) を区別せず無条件に「別の番号空間・別経路とみなす」分岐は silent failure である。"
promote: rite-plugin
created: "2026-06-02T03:50:58Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260602T033014Z-pr-1244.md"
  - type: "fixes"
    resource: "raw/fixes/20260602T033213Z-pr-1244.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T073356Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T073832Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T075618Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T075954Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T081603Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T081940Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T210423Z-pr-3446.md"
  - type: "fixes"
    resource: "raw/fixes/20261010T041537Z-pr-3747.md"
  - type: "reviews"
    resource: "raw/reviews/20261010T040833Z-pr-3747.md"
  - type: "reviews"
    resource: "raw/reviews/20261010T042231Z-pr-3747-cycle2.md"
tags: ["gh-cli", "error-handling", "silent-failure"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-10T04:36:45Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-10T04:36:45Z" }
---

# 外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure

## 概要

`gh pr view N` のような外部コマンドが失敗したとき、失敗種別 (origin) を区別せず無条件に「別の番号空間・別経路とみなす」分岐は silent failure である。404 (semantic な not-found = `Could not resolve to a PullRequest`) と一時障害 (network / auth / rate-limit) は意味が全く異なる。前者だけが再分類 (例: 「N を Issue とみなす」) を正当化し、後者は誤分類せず中断すべき。さらに silent な scope 縮退 (PR 解決失敗 → Issue のみで続行) はユーザー通知を必須にする。rite codebase はこの house rule を `pr/fix.md` の canonical 警告として持つ。

## 詳細

起点事例 (`/rite:learn` spec) の cycle 5 で error-handling reviewer が MEDIUM 検出した。`learn.md:54` が `gh pr view N` 失敗時に PR 404 と一時障害を区別せず無条件に「N を Issue とみなす」へ分岐していた。これは「gh 失敗 → 別番号空間へ再分類」を silent failure 禁止 anti-pattern として明示する repo の house rule (`pr/fix.md:236`) に反する。

### canonical 対策

- **失敗種別を exit code / stderr で区別する**: not-found (`Could not resolve to a PullRequest` 等の 404 シグナル) のみ別経路 (Issue 扱い) へ進む。一時障害 (network / auth / rate-limit) は誤分類せず中断する。
- **silent な scope 縮退にユーザー通知を添える**: 「PR 解決失敗 → Issue のみで続行」のように対象範囲を黙って狭める分岐は、必ずユーザーに通知する。
- 新規コマンドの prose 指示書 (LLM 実行手順) でも同 anti-pattern を踏襲しないよう、「失敗時に X とみなす」分岐を書くときは必ず失敗種別 (not-found vs transient) を区別する prose を添える。

### 観測された reviewer 非決定性

同 reviewer が cycle 4 ではこの論点を design_confirmation (任意) と判定し、cycle 5 で MEDIUM blocking に格上げした。reviewer の severity 判定は「read-only / 副作用なし」という緩和要因の重み付けで cycle 間に振動しうる。iterate ループは指摘ゼロまで継続する設計のため、振動する指摘も一度 blocking に出れば修正する (修正は codebase 規約との整合を高めるため正味プラス)。cycle 6 では「対応済み・severity 一貫性のため再指摘せず」と確認され収束した — reviewer prompt に「前 cycle で任意と判断した論点を理由なく blocking に格上げしない」severity 一貫性ガードを入れると収束が早まる。

### 分類軸は文言の固有化ではなく情報源の権威性に引き上げる

エラー文言を機械固有の literal へ狭めるだけでは、同じ表に並ぶ**別のコマンドの失敗**に同種欠陥が残る。実測で有効だったのは、分類軸を「文言」から**情報源の権威性**へ引き上げることだった。

| 情報源 | 権威性 | 不存在を断定できるか |
|---|---|---|
| `gh`（サーバ問い合わせ） | サーバ権威 | できる（`Could not resolve to an issue or pull request` は共通番号空間での不存在） |
| `git`（ローカルのみ） | ローカル | **できない** — 浅い clone / 未 fetch ブランチ / fork 上の commit では実在する SHA も同一の stderr になる |

この軸に揃えると誤分類が構造的に消える。`git` 側は stderr の文言（`unknown revision` / `bad object` / path 系）**で分岐せず、非ゼロ終了すべてを網羅で判定**する — 文言の列挙は SHA の位置により変化するため追随不能になる。サーバ権威で不存在を断定したいときだけ `gh api repos/{o}/{r}/commits/{sha}` を追加実行し、**HTTP 422（`No commit found for SHA`）のときに限り**強い判定へ昇格してよい（404 は SHA ではなくリポジトリ側の不在）。

「解決できない ≠ 存在しない」という意味論の分離は**表の全行に対称適用する**。`gh` 側の `Could not resolve to a PullRequest` も種別違いであって不存在ではない。エラー分類表の修正は「行の分離 / 文言の狭窄 / 意味論の分離」の 3 操作が別物であり、1 つを適用したら残り 2 つの適用漏れを同表の全行と参照元の表に対して監査する。

修正が SoT reference 1 箇所で完結したのは、consumer 3 箇所が表を参照するのみで条件を複製していなかったため — **SoT 委譲設計は fix コストを 1/3 にする**。

### 失敗を「対象外」と同じ値に丸めない

ディレクトリがチェックアウトに属するかを `git rev-parse` で判定する関数が、失敗を「リポジトリではない」と同じ `None` で返していた。その結果、git が worktree を読めないとき（信頼しない所有者など）でも「チェックアウトの外」と判定されていた。拒否理由が勧める `cd <worktree>` も同じ理由で拒否され、本当の原因（git のエラー）はどこにも出なかった。失敗しうる範囲をはっきり列挙し、その中での失敗はエラーとして出す。範囲の決め方は、`.git` が上位にあるかといったファイルの有無による推測にしない。`/tmp/.git` のような無関係な残骸があると、リポジトリの外のディレクトリまで「読めないリポジトリ」と誤判定する。git 自身が返す一覧（`git worktree list`）で範囲を決める。

### git の失敗を「不在」として記録しない — 失敗側と不在側を対で固定する

出典の照合で git が失敗したとき、ファイルを「存在しない」と記録すると、失敗が不在の判定へ化ける。失敗は error として記録し、git が成功して対象が無いときだけ従来どおり不在を返す。契約がこう二分されるときは、失敗側と不在側の両方のテストを対で置く。観測された事例では、片方の照合（path:line）だけに不在側のテストがあり、もう片方（節）は未固定だった。分岐を error に置き換える変異で、両方のテストが効くかを確かめる。

失敗の記録キーは、記録する単位（行・節・文書）と同じ粒度にする。行 ID と節だけをキーにすると、同じキーに複数の文書が当たったときに上書きされ、件数と WARNING が過少になる。キーに文書名を含める。キーの粒度を直した後も、同じ文書名が同じ行に複数回出るときの件数の食い違いは残る。error 自体は残って fail-loud は保たれるため、件数に依存する消費側ができるまで対応不要と判断された。

同種の修正では、隣接する経路も洗う。git の失敗を不在へ寄せる経路は他にも残りうる（例: コミット SHA の存在確認が、git の失敗と SHA の不在を区別せずに GitHub への照会へ進む）。

## 関連ページ

- [gh api graphql は HTTP 200 + .errors[] で partial failure を返す (exit code では検知できない)](./gh-api-graphql-http200-partial-errors.md)
- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](../patterns/silent-fallback-observability-via-debug-log.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)
- [検証手順を書くときは処方するコマンドの判別能力そのものを実測する](../heuristics/prescribed-command-discriminating-power-measured.md)

## ソース

- [レビュー結果](../../raw/reviews/20260602T033014Z-pr-1244.md)
- [fix 結果](../../raw/fixes/20260602T033213Z-pr-1244.md)

## ソース（追記分 4）

- [部分文字列マッチの過剰範囲](../../raw/reviews/20260730T073356Z-pr-2056.md)
- [実測 3 文言への分解](../../raw/fixes/20260730T073832Z-pr-2056.md)
- [片側修正の非対称残存](../../raw/reviews/20260730T075618Z-pr-2056.md)
- [権威性を分類軸に引き上げる](../../raw/fixes/20260730T075954Z-pr-2056.md)
- [行の分離 / 文言の狭窄 / 意味論の分離の 3 操作](../../raw/reviews/20260730T081603Z-pr-2056.md)
- [元 catch-all 行の全要件を新行へ明示転記](../../raw/fixes/20260730T081940Z-pr-2056.md)
- [失敗を範囲外と同じ値に丸めない](../../raw/fixes/20260929T210423Z-pr-3446.md)
- [失敗の記録キーの粒度と失敗側・不在側の対のテストを直した fix 結果](../../raw/fixes/20261010T041537Z-pr-3747.md)
- [git の失敗を不在として記録しない修正のレビュー結果](../../raw/reviews/20261010T040833Z-pr-3747.md)
- [失敗側と不在側の対の固定を変異で確かめた再レビュー結果](../../raw/reviews/20261010T042231Z-pr-3747-cycle2.md)
