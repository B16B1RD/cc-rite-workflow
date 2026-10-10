---
title: "散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする"
domain: "heuristics"
description: "SoT 散文 / 設計ドキュメントが実装 (正規表現リテラル・helper file・挙動主張) を要約参照するとき、レビューは「散文を読む」だけでは整合を保証できない。"
created: "2026-06-02T00:07:23Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260911T123634Z-pr-2686.md"
  - type: "reviews"
    resource: "raw/reviews/20260601T185616Z-pr-1238.md"
  - type: "reviews"
    resource: "raw/reviews/20260601T191319Z-pr-1238.md"
  - type: "fixes"
    resource: "raw/fixes/20260601T190814Z-pr-1238.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T032116Z-pr-3202.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T152733Z-pr-3299.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T161451Z-pr-3305.md"
  - type: "reviews"
    resource: "raw/reviews/20260930T165732Z-pr-3561.md"
  - type: "retrospectives"
    resource: "raw/retrospectives/20261004T211619Z-issue-3665.md"
  - type: "fixes"
    resource: "raw/fixes/20261005T011713Z-pr-3681.md"
  - type: "fixes"
    resource: "raw/fixes/20261005T005745Z-pr-3681.md"
  - type: "reviews"
    resource: "raw/reviews/20261004T234257Z-pr-3681.md"
  - type: "reviews"
    resource: "raw/reviews/20261005T011354Z-pr-3681.md"
  - type: "reviews"
    resource: "raw/reviews/20261005T012658Z-pr-3681.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T143006Z-pr-3725.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T233431Z-pr-3735.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T234815Z-pr-3735.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T235534Z-pr-3735.md"
  - type: "reviews"
    resource: "raw/reviews/20261010T000858Z-pr-3735.md"
  - type: "reviews"
    resource: "raw/reviews/20261010T003759Z-pr-3735.md"
  - type: "fixes"
    resource: "raw/fixes/20261010T004622Z-pr-3735.md"
  - type: "reviews"
    resource: "raw/reviews/20261010T005053Z-pr-3735.md"
tags: ["verification-protocol", "prose-implementation-sync", "regex", "behavioral-test", "attribution"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-10T01:04:42Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:27:52Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T15:39:40Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T16:16:02Z" }
  - { by: "rite-wiki-ingest/grok-4.7", at: "2026-09-30T17:01:22Z" }
  - { by: "rite-wiki-ingest/gpt-6", at: "2026-10-05T01:39:35Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-09T19:10:23Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-10T01:04:42Z" }
---

# 散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする

## 概要

SoT 散文 / 設計ドキュメントが実装 (正規表現リテラル・helper file・挙動主張) を要約参照するとき、レビューは「散文を読む」だけでは整合を保証できない。3 点を機械的に裏取りする:

1. **文字一致**: 散文が引用する regex literal が実装ファイルの実体と byte 単位で一致するか (Cross-File Impact Check)
2. **帰属精度**: 散文が regex を帰属させたファイルが、実際にその regex を保持するファイルか (wrapper / 委譲先の取り違え)
3. **behavioral test**: 散文が主張する挙動 (match / non-match) を、実際にその regex を代表ケース群にかけて実測確認したか

prompt-engineer + code-quality の 2 cycle 収束・0 blocking findings の実測で、3 点すべてが review/fix 技法として有効に機能し、cycle 2 まで independent cross-validation された。

## 詳細

### 背景となった起点事例

`commands/init.md` の rite hook 検出基準を「散文の plain substring `rite/hooks/`」から「`rite` を完全 path segment とする SoT (`RITE_HOOK_RE` = `(?:^|/)rite/(?:[^/]+/)?hooks/`)」へ統一する doc PR。散文が helper 実装の regex を要約参照するため、散文と実装の整合検証が review の中心になった。

### 1. 文字一致 — 引用 literal の byte 単位 cross-check

散文が引用する正規表現リテラル `(?:^|/)rite/(?:[^/]+/)?hooks/` が、実体 (`settings-local-rite-hook-cleanup.py:33` / `session-start.sh:201`) と文字単位で一致するかを Cross-File Impact Check で検証する。散文の regex は「読者がコピペ origin にする」ため、1 文字の drift も誤誘導になる ([canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md) と同根)。

派生して観測された **pre-existing リスク (本 PR 由来ではない)**: 同一 regex が `.py:33` と `session-start.sh:201` の 2 箇所に独立コピーとして存在し、散文を含めると 3 系統になる。複数コピーは将来片方のみ更新する drift リスクを孕むため、regex 単一定義化 (共有 source 化) を follow-up Issue 候補として boundary 分類で切り出した (scope 規律: 本 PR では touch しない)。

### 2. 帰属精度 — wrapper / 委譲先の取り違えを避ける

新規 SoT 定義で regex 等の実体を要約参照する際、`.sh` wrapper が `.py` へ JSON 変換 (regex 適用) を委譲する**二層構造**を `.sh` 一語で要約すると、「regex 実体ファイル」の誤帰属を生む。読者が wrapper (`.sh`) を開いても regex が見つからない誘導ミスになる（F-01、code-quality LOW-MEDIUM → ユーザー承認で current-pr scope に昇格して fix）。

canonical: helper を散文参照するときは「regex 実体ファイル (`.py`)」と「python3 guard / atomic write の wrapper (`.sh`)」を区別するか、拡張子なし basename で両者を包含する表記にする。wrapper が regex を持たず別ファイルへ委譲する構造では、帰属先を grep で確認してから散文を書く ([Documentation review は対応する実装側の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md) の帰属軸への拡張)。

### 3. behavioral test — 挙動主張を実 regex で実測する

散文が主張する「look-alike 非マッチ / cache version 形マッチ / version segment 1 個許容」を、**代表ケース群に実際の regex をかけて実測確認**する。起点事例の cycle 2 では両レビュアーが独立に 8 ケースの behavioral test を実施した:

| ケース群 | 例 | 期待 |
|----------|-----|------|
| must-match | dev 形 `rite/hooks/` / cache 形 `rite/0.2.0/hooks/` | match |
| must-not-match (look-alike) | `favorite/hooks/` / `prerite/hooks/` / `rite-something/hooks/` | non-match |
| must-not-match (segment 過多) | version segment 2 個 `rite/a/b/hooks/` | non-match |

「散文の主張を読むだけ」でなく実際に regex を実行して claim を裏取りすると、散文の不正確さも検出できる (例: `(?:[^/]+/)?` は version に限らず任意単一セグメント許容のため、「version segment」という表現はやや不正確 — 実害なしの推奨事項として surface)。これは [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md) の regex/散文版。

同じ手法は regex 以外の**条件式**にも効く。散文が「どの指摘を修正対象にするか」のような複合条件（AND / OR の組み合わせ）を述べる場合、条件の各項を切り替えた fixture 群（全組み合わせ、例では 6 通り）を helper に与えて出力の分類を得て、散文の括弧構造と一致するかを照合する。散文の条件式は係り先が曖昧になりやすく、読むだけでは読み違いを潰しきれないが、実装を動かした結果と突き合わせれば確実に確定できる。

### 適用範囲

- SoT 散文 / 設計ドキュメントが regex・閾値・path 形状など実装の挙動を要約参照する PR
- helper が wrapper → 実体へ委譲する二層 (以上) 構造をもつ実装を散文が参照するケース
- substring → segment-anchored への正規表現厳格化 ([path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する](../anti-patterns/path-segment-substring-over-match.md) の検証手法として直結)
- CHANGELOG のエントリが機能の帰属先ファイルを名指しする場合。commit subject と PR 要約から書き起こすと、複数のファイルが同じ機能名を共有するときに帰属を取り違える（表の所在・版付き能力表・呼出し手順書がそれぞれ別ファイルで、配布物外の設計文書を配布物内として書いた例）。エントリが名指しするファイルの役割は Read で確認してから書く

条件付きの委譲（「このモードでは push を呼び出し側に委ねる」）を要約する散文は、helper の case 分岐の全組み合わせ（ブランチ戦略 × モード）を列挙して照合する。委譲先が no-op になる組み合わせでは「委ねる」と書けず、限定を省いた要約は一部の組み合わせで偽になる。同じ分岐の要約は手順書・仕様書・helper の docstring に分散しやすいので、1 箇所を直したら残りの写しを grep で探し、差分外なら別の修正に回す。

実装の挙動を一般化して述べる散文（「引用符なしのリダイレクトは数えない」）は、実装の例外（パイプ分割で数えられる形）より広く言い切っていないかを確かめる。共有パーサの戻り値に印を付けて特定の経路だけ挙動を変える方式は、消費側が等値比較や slice しか使わないことを確かめてから採る。

正規表現に並ぶ語を一つの種別名でまとめると、その種別に入らない語まで同じ種別に読まれる。予約語と builtin が同じ列挙にあるときは、種別名を使わず列挙のまま書く。報告条件を、今回直した分岐だけを見て「だけ」と書くと、差分に無い分岐が同じ条件で報告する場合まで否定する文になる。限定は、報告する分岐をすべて読んでから付ける。

### 保存された成果物と独立した期待結果による挙動主張の検証

手順書が「書き込み後の本文を比較する」「検査ログを保存した」と述べる場合、helper の終了コードだけでは根拠にならない。失敗を警告して正常終了する helper もあるため、比較に使うローカル commit を固定し、その commit から本文とログの全エントリを読み戻す。中断からの再開では、処理済み raw と未 commit のページ・index・log の対応を先に確かめ、書き込みと commit を完了してから比較する。必須入力を追加した変更は、実行手順だけでなく公開引数表と概要も同じ条件へ揃える。

「検査に成功した」と「問題を検出した」は別の観測である。入力欠落や比較未完了は停止、比較を完了して見つけた問題は件数として扱う。この違いは正常入力・明示的な空入力・欠落入力を実際の入口に与え、後続処理と保存記録まで観測して裏取りする。停止テストでは入口の Git 等の前提を準備し、停止前には遮断され、停止後には解除される対照を置く。

実装の規則をそのまま期待結果へ写すと、同じ見逃しをテストにも持ち込む。意味比較は対象・条件・結論を独立して読んだ期待結果と照合し、分類先の違いや低い確信度で候補を落とさず、条件付きの例外を方針逆転と取り違えないことを確かめる。静的な契約テストには、実際に注入される規則の全除去・個別除去を当てる。手作りの指摘を渡して緑になるだけでは、その規則が消えた際の退行を検出した証拠にはならない。

### 「同形」と書くコメントは、同じなのがどこまでかを限定する

Decision Log の採番式のコメントが「別ファイルの行の正規表現と同形」と書いていたが、同形なのは行頭の接頭部（日付と決定 ID）だけで、末尾の Reason / Impact は要求していなかった。同じ変更の追加テストは引用にコロンが無く、行頭アンカーと日付部分を外す変異が生き残った。「同形」「同じ」と書くときは一致する範囲を限定して書き、その範囲をテストの変異で確かめる。

### 理由として挙げる制御と、PR 本文の主張も同じ裏取りの対象にする

設計理由の文書に「シェル変数の形にすると、実行前の guard が argv を静的に確かめられなくなる」と、セキュリティ制御を理由に書いた例がある。guard の実装は `--` で始まるトークンを読み飛ばしており、変数形と literal 形で判定は変わらなかった。理由として挙げる制御は、その制御の実装を読み、両方の形を guard にかけて確かめてから書く。裏づけの無い理由は補強せず削除で直す。

理由の段落を削除するときは、その段落を理由として参照していた側（手順書の括弧書きの禁止と rationale ポインタ）も同じ変更で見直す。理由だけを消すと、参照側に根拠を辿れない制約が残り、次のレビューで指摘される。理由を書き足すより、根拠を失った制約を削って周囲の記法に揃える方が差分が小さい。

PR 本文の主張も同じである。採否ゲートの出口のように実装が条件で分岐する挙動を本文で要約するときは、判定関数を実際の入力で呼んで、要約が全分岐で成り立つかを確かめる（一部の分岐にしか当てはまらない言い切りは、別の分岐の読み手を誤らせる）。本文に書いたテスト件数などの数値は、修正でテストを足すたびに実測へ合わせる。本文の修正はコミットを伴わないので、差分の検査ではなく再レビューで照合させる。

本文と図の両方に同じ主張があるときは、本文だけを直すと両者が食い違う。図の該当ラベル、図の代替テキスト、本文を同じ変更で直す。

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md)
- [path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する](../anti-patterns/path-segment-substring-over-match.md)

## ソース

- [レビュー結果](../../raw/reviews/20260911T123634Z-pr-2686.md)
- [レビュー結果](../../raw/reviews/20260601T185616Z-pr-1238.md)
- [レビュー結果](../../raw/reviews/20260601T191319Z-pr-1238.md)
- [fix 結果](../../raw/fixes/20260601T190814Z-pr-1238.md)
- [条件式の説明を helper の実行結果で照合したレビュー](../../raw/reviews/20260927T032116Z-pr-3202.md)
- [委譲の要約を helper の分岐の全組み合わせと照合したレビュー結果](../../raw/reviews/20260927T152733Z-pr-3299.md)
- [一般化した散文と実装の例外の境界ずれを指摘したレビュー結果](../../raw/reviews/20260927T161451Z-pr-3305.md)
- [種別名と限定が列挙と分岐より広かったレビュー結果](../../raw/reviews/20260930T165732Z-pr-3561.md)

- [保存成果物と独立した挙動検証の記録](../../raw/retrospectives/20261004T211619Z-issue-3665.md)
- [保存成果物と独立した挙動検証の記録](../../raw/fixes/20261005T011713Z-pr-3681.md)
- [保存成果物と独立した挙動検証の記録](../../raw/fixes/20261005T005745Z-pr-3681.md)
- [保存成果物と独立した挙動検証の記録](../../raw/reviews/20261004T234257Z-pr-3681.md)
- [保存成果物と独立した挙動検証の記録](../../raw/reviews/20261005T011354Z-pr-3681.md)
- [保存成果物と独立した挙動検証の記録](../../raw/reviews/20261005T012658Z-pr-3681.md)
- [レビュー結果（「同形」と書くコメントの範囲）](../../raw/reviews/20261009T143006Z-pr-3725.md)
- [PR 本文の説明が判定の分岐より狭かったレビュー結果](../../raw/reviews/20261009T233431Z-pr-3735.md)
- [PR 本文のテスト件数が古くなったレビュー結果](../../raw/reviews/20261009T234815Z-pr-3735.md)
- [PR 本文の件数を直した fix 結果](../../raw/fixes/20261009T235534Z-pr-3735.md)
- [実装に無い制御を理由に挙げたレビュー結果](../../raw/reviews/20261010T000858Z-pr-3735.md)
- [理由の削除で参照側の根拠が消えたレビュー結果](../../raw/reviews/20261010T003759Z-pr-3735.md)
- [根拠を失った括弧書きを削った fix 結果](../../raw/fixes/20261010T004622Z-pr-3735.md)
- [括弧書きの削除を確かめたレビュー結果](../../raw/reviews/20261010T005053Z-pr-3735.md)
