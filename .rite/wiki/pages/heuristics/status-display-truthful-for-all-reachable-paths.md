---
type: "heuristics"
title: "共有パスに置く進捗/status 表示は到達する全経路で真な文言にする（成功含意を避ける）"
domain: "heuristics"
description: "複数の実行経路が合流する共有コードパスに進捗カウンタや status 表示を置くときは、成功経路だけでなく到達する全経路で真である文言にする。「進めた件数（advanced）」と「成功件数（succeeded）」を区別し、✅ /「完了」等の成功含意語を非収束・失敗経路でも一律発火する表示に使わない。"
created: "2026-07-03T11:30:00+09:00"
updated: "2026-07-03T11:30:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260703T021717Z-pr-1733.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T021912Z-pr-1733.md"
tags: []
confidence: medium
---

# 共有パスに置く進捗/status 表示は到達する全経路で真な文言にする（成功含意を避ける）

## 概要

複数の実行経路が合流する共有コードパスに進捗カウンタや status 表示を置くときは、成功経路だけでなく到達する全経路で真である文言にする。「進めた件数（advanced / processed）」と「成功件数（succeeded）」を区別し、✅ /「完了」等の成功含意語を、非収束・失敗経路でも一律発火する表示に使わない。表示に使う marker が収束状況を持たないなら、その表示は「前進した事実」だけを語れる文言に限定する。

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

**関連する path 対称性**: 「共有パスの表示は全経路で真であるべき」は、[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の「contract-implementation path 対称性（section 内の全 path が契約を満たすか verify する）」を、コード契約ではなく **ユーザー向けメッセージの真実性** の側面に適用したもの。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1733 review results (cycle 2)](../../raw/reviews/20260703T021717Z-pr-1733.md)
- [PR #1733 fix results (cycle 2)](../../raw/fixes/20260703T021912Z-pr-1733.md)
