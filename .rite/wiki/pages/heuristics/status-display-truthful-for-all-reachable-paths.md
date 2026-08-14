---
type: "heuristics"
title: "共有パスに置く進捗/status 表示は到達する全経路で真な文言にする（成功含意を避ける）"
domain: "heuristics"
promote: rite-plugin
description: "複数の実行経路が合流する共有コードパスに進捗カウンタや status 表示を置くときは、成功経路だけでなく到達する全経路で真である文言にする。常時出す完了文に空集合除外（「failed 扱いを除き」等）を置くのも同型で、空のときは条件付き専用行に任せ常時行から落とす。"
created: "2026-07-03T11:30:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260703T021717Z-pr-1733.md"
  - type: "fixes"
    resource: "raw/fixes/20260703T021912Z-pr-1733.md"
  - type: "reviews"
    resource: "raw/reviews/20260801T103500Z-pr-2081.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T104510Z-pr-2081.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T112516Z-pr-2081.md"
  - type: "reviews"
    resource: "raw/reviews/20260813T054655Z-pr-2300.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-13T05:55:07Z" }
---

# 共有パスに置く進捗/status 表示は到達する全経路で真な文言にする（成功含意を避ける）

## 概要

複数の実行経路が合流する共有コードパスに進捗カウンタや status 表示を置くときは、成功経路だけでなく到達する全経路で真である文言にする。「進めた件数（advanced / processed）」と「成功件数（succeeded）」を区別し、✅ /「完了」等の成功含意語を、非収束・失敗経路でも一律発火する表示に使わない。表示に使う marker が収束状況を持たないなら、その表示は「前進した事実」だけを語れる文言に限定する。常時出す完了文に空集合除外（「failed 扱いを除き」等）を置くのも同型で、空のときは条件付き専用行に任せ常時行から落とす。

## 詳細

**発生源**: `/rite:run` の着手前サマリ機能。バッチのキュー cursor を前進させる共有 bash（`RUN_ADVANCE` marker を emit する箇所）の直後に「各 Issue 完了時の進捗表示」として `✅ {new_cursor}/{total} 件完了` を追加した。

この cursor 前進 bash は複数の終了経路から合流する:
- 正常収束（`[review:mergeable]`）
- サーキットブレーカー発火（`[iterate:max-cycles-reached]`）で当該 Issue を `failed[]` 記録して前進する非収束経路
- `[fix:replied-only]` で未解決指摘を残したまま前進する非収束経路

`RUN_ADVANCE` marker は `cursor` / `total`（= キューを進めた件数）しか持たず、その Issue が成功したか非収束かの情報を持たない。にもかかわらず表示は ✅ /「完了」という成功含意語だったため、failed 記録された Issue や未解決指摘を残した Issue にも「正常完了した」と読める表示が出て、バッチ実行を見るユーザーを誤認させる UX finding（prompt-engineer が LOW-MEDIUM で検出）。

**修正**: 表示を `✅ {new_cursor}/{total} 件処理済み` に変更し、「この件数は『キューを進めた件数』であり成功件数ではない — 非収束経路も同じ前進 bash を通るため、成功／非収束の内訳は別途（完了通知）で報告する」旨を明示した。あわせて Placeholder Legend の `cursor` フィールド説明も「前進後のキューを進めた件数（成功件数ではない）」に整合させた（表示行と Legend の 2 site 同期。asymmetric-fix-transcription の系譜）。

**一般化した経験則**:
- status / 進捗表示を置く前に「このコードパスに合流する全経路」を列挙し、その表示文言が **全経路で真か** を verify する。happy path でしか真でない文言（✅ / 完了 / 成功 / done）を共有パスに置かない。
- 表示に使う marker / カウンタが「成否」の情報を持たないなら、表示は「前進した事実（advanced / processed / N/M reached）」だけを語れる中立語に限定する。成否の内訳は成否を知っている別レイヤー（終端の完了通知・failed 集計）に委ねる。
- 文言修正時は「表示を組み立てる本文」と「その placeholder を定義する Legend / スキーマ」の両方を同期する。
- 終端の完了通知でも同じ真実性を守る。失敗の内訳を条件付き専用行（空なら出さない）に分けているなら、常時行に「failed 扱いを除き」のような空集合除外を残さない。除外表現は failed が空の到達経路で偽になり、専用行の省略規則と矛盾する。常時行は全件完走の事実だけを述べ、除外は専用行側に閉じる。

**関連する path 対称性**: 「共有パスの表示は全経路で真であるべき」は、[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の「contract-implementation path 対称性（section 内の全 path が契約を満たすか verify する）」を、コード契約ではなく **ユーザー向けメッセージの真実性** の側面に適用したもの。

### 診断 WARNING は事実だけを述べ、帰結は marker に委ねる

同じ原則が診断メッセージにも効く。**WARNING に「〜しました」と帰結を書くと、判定の分岐が増えるたびに文面と実際の帰結がずれる**。判別を 2 値から 3 値へ広げた事例では、帰結を断定していた WARNING が古くなった。

- **冒頭は原因を断定しない**: 判定の母集団が選言へ広がった後も WARNING 冒頭が単一原因を断定していると、fail-open 経路で operator が受け取る唯一の診断が事実と異なる原因を名指しする。冒頭は原因非断定にし、**括弧内の列挙を真因の唯一の記述にする**。
- **原因列挙は分岐が動くたびに帰属を確認する**: 「この原因なら未判定」と書いた項目が実装では降格側に落ちる、という自己矛盾が同一 PR 内で発生した。原因列挙を持つ WARNING は、分岐を変えるたびに列挙の帰属を洗い直す。
- **帰結は機械可読 marker へ**: 検出した事実（何を検出したか）だけを WARNING が述べ、帰結は marker が持つ形にすると、分岐追加に構造的に耐える。

**pin があれば文言変更は必ずテスト失敗として現れる**: WARNING 文言をテストが literal で pin していれば、文言変更は失敗として可視化され、pin 側を機械的に追随させるだけでよい。逆に pin が無ければ文言と実装の乖離は無検出で進行する。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [機械的な述語を文書化するときは意図の語彙ではなく字句の語彙で書く](./mechanical-predicate-prose-lexical-vocabulary.md)
- [診断WARNINGの宛先（実行エージェント向けかユーザー向けか）を主語で明示する](./diagnostic-warning-message-audience-ambiguity.md)

## ソース

- [PR #1733 review results (cycle 2)](../../raw/reviews/20260703T021717Z-pr-1733.md)
- [PR #1733 fix results (cycle 2)](../../raw/fixes/20260703T021912Z-pr-1733.md)
- [PR #2081 review results](../../raw/reviews/20260801T103500Z-pr-2081.md)
- [PR #2081 fix results](../../raw/fixes/20260801T104510Z-pr-2081.md)
- [PR #2081 fix results (cycle 2)](../../raw/fixes/20260801T112516Z-pr-2081.md)
- [PR #2300 review results](../../raw/reviews/20260813T054655Z-pr-2300.md)
