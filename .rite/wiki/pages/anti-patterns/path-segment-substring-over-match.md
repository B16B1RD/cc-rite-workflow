---
title: "path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する"
domain: "anti-patterns"
promote: rite-plugin
created: "2026-06-01T18:27:24+00:00"
updated: "2026-06-02T00:07:23Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260601T180203Z-pr-1236.md"
  - type: "reviews"
    ref: "raw/reviews/20260601T185616Z-pr-1238.md"
  - type: "reviews"
    ref: "raw/reviews/20260601T191319Z-pr-1238.md"
  - type: "fixes"
    ref: "raw/fixes/20260601T190814Z-pr-1238.md"
tags: []
confidence: high
---

# path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する

## 概要

path 内の固定セグメント名 (`rite` 等) を `rite.*?/hooks/` のような **substring 正規表現** でマッチすると、`favorite/hooks/`・`prerite/hooks/`・`rite-something/hooks/` のような **look-alike セグメント**を誤マッチし、本来保持すべき対象 (ユーザー定義 hook 等) を silent に over-remove する。`(?:^|/)rite/` のように **path セグメント境界に anchor** して排除すること。ただし anchor を厳格化する際は、cache 形の中間 version segment 等、実在する全 path 形状を列挙し false-negative を作らないこと。

## 詳細

### 検出された具体ケース

`settings.local.json` から rite hook エントリを除去する cleanup の正規表現が `rite.*?/hooks/` だった。`rite` を path segment 境界に固定していないため、`favorite/hooks/` 等のユーザー定義の非 rite hook を誤マッチし silent 除去しうる。これは **user-controlled security config の integrity リスク** (ユーザーが意図した hook が黙って消える)。

修正は `(?:^|/)rite/(?:[^/]+/)?hooks/`:

- `(?:^|/)rite/` で `rite` を完全 path segment (先頭が文字列頭か `/`) に固定 → `favorite`・`prerite`・`rite-something` を排除
- `(?:[^/]+/)?` で間の version segment を 0 個 or 1 個許容 → 実 hook command の 2 形状を両方カバー

| 形状 | 例 | 判定 |
|------|-----|------|
| cache install | `.../rite/0.2.0/hooks/...` = `rite/<version>/hooks/` | ✅ 除去 |
| dev / 相対 | `plugins/rite/hooks/...` = `rite/hooks/` | ✅ 除去 |
| look-alike | `favorite/hooks/`・`prerite/hooks/`・`rite-something/hooks/` | ❌ 保持 |

### 二重リスク: tightening で false-positive を false-negative にすり替えない

Issue が素朴に例示した anchor `(?:^|/)rite/hooks/` は cache 形の中間 version segment を考慮しておらず、本番インストール形 `rite/<version>/hooks/` を取りこぼして rite hook を**消し残す false-negative** を生む。

over-match (false-positive) を直すために pattern を厳格化するときは、**実在する全 path 形状を列挙してから** anchor を設計する。さもないと「look-alike を誤除去する」バグを「本物を除去し残す」バグに変えるだけで、どちらも silent regression として残る。anchor の妥当性は must-match 群 (cache/dev/相対) と must-not-match 群 (look-alike) の双方で verify する。

### 散文側への波及と完結

先行 PR が修正したのは regex 実装側 (`settings-local-rite-hook-cleanup.py:33` / `session-start.sh:201`) のみで、`commands/init.md` の**散文の検出基準**は plain substring `rite/hooks/` を記述として残していた。同一 defect class が同一 invariant の別表現 (実装 regex / 散文) に分散して存在し、片側のみ修正された [Asymmetric Fix Transcription](./asymmetric-fix-transcription.md) の典型。

後続 PR は init.md の散文 6 箇所を SoT 定義 (`RITE_HOOK_RE`) 参照へ統一して defect class を完結させた。Phase 4.5 内の全 `rite/hooks/` / `rite hook` 検出箇所 20 箇所を着手時 grep で網羅抽出し、旧 substring 基準の残存ゼロを確認 → 0 blocking findings / 2 cycle 収束。

検証では、散文が主張する「look-alike 非マッチ / cache version 形マッチ」を実 regex に 8 ケースかける **behavioral test** が両レビュアーで有効だった (詳細は [散文が引用する実装は文字一致・帰属・behavioral test の 3 点で裏取りする](../heuristics/prose-cited-implementation-behavioral-verification.md))。教訓: **substring over-match の修正は「実装 regex」と「散文の検出基準」の双方を着手時 grep の scope に含める** — 実装だけ直すと散文が古い over-match 基準を LLM への指示として残し、LEGACY 経路で同型の誤判定を再現しうる。

### security framing — over-match は fail-safe ではなく integrity 違反

substring over-match による「ユーザー hook の silent 除去」は user-controlled security config の黙示的 mutation であり、integrity 違反 (silent failure) に当たる。pattern を segment 境界へ厳格化する方向は **fail-safe 側**への是正である。なお本 regex は linear で nested quantifier を持たないため ReDoS リスクはない。

### root cause としての pattern class

このパターンは「**マッチ pattern が意図より広い入力を捕捉する over-capture class**」に属する。同型の事例:

- find glob の文字数/任意文字 wildcard が新規命名 token と偶発一致する collision ([find-glob-naming-collision](./find-glob-naming-collision-silent-removal.md))
- `case` の `*)` catch-all が未知の将来 prefix を吸収する ([catch-all-case-arm](./catch-all-case-arm-absorbs-future-prefix.md))

いずれも「区切り (segment / token / prefix) を明示せず広い pattern で済ませた」ことが root で、誤マッチ対象が削除・分岐吸収として silent に消費されるのが共通の failure mode。新しい pattern を導入・流用するときは、固定 token を **境界 anchor 付き**で書き、look-alike を negative test で固定する。

## 関連ページ

- [新規 file 命名と既存 find glob が collision して silent 削除を起こす](./find-glob-naming-collision-silent-removal.md)
- [prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する](./catch-all-case-arm-absorbs-future-prefix.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](../heuristics/prose-cited-implementation-behavioral-verification.md)

## ソース

- [PR #1236 review results](../../raw/reviews/20260601T180203Z-pr-1236.md)
- [PR #1238 review results (init.md 散文側の substring over-match 完結)](../../raw/reviews/20260601T185616Z-pr-1238.md)
- [PR #1238 review results (cycle 2 — behavioral test 8 ケースで散文-実装整合検証)](../../raw/reviews/20260601T191319Z-pr-1238.md)
- [PR #1238 fix results (SoT 散文の regex 共有元帰属修正)](../../raw/fixes/20260601T190814Z-pr-1238.md)
