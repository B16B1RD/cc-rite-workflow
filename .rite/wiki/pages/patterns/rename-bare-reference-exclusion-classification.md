---
type: "patterns"
title: "識別子リネーム後の裸参照置換で除外すべき参照の分類"
domain: "patterns"
promote: rite-plugin
description: "スキル/コマンドのリネーム（例: `/rite:resume` → `/rite:recover`）後、旧名への「裸のスキル名参照」（bare-word reference、例: 「resume の AskUserQuestion」のような文中の裸表記）をリポジトリ横断で修正するとき、旧名と同じ文字列を含むが**修正してはいけない**箇所を誤って置換しないよう分類する必要がある。"
created: "2026-07-08T02:20:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260707T171543Z-pr-1793.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-08T02:20:00+00:00" }
---

# 識別子リネーム後の裸参照置換で除外すべき参照の分類

## 概要

スキル/コマンドのリネーム（例: `/rite:resume` → `/rite:recover`）後、旧名への「裸のスキル名参照」（bare-word reference、例: 「resume の AskUserQuestion」のような文中の裸表記）をリポジトリ横断で修正するとき、旧名と同じ文字列を含むが**修正してはいけない**箇所を誤って置換しないよう分類する必要がある。

## 詳細

`resume` → `recover` の裸スキル名参照を横断修正した際、以下の6種類の「置換すべきでない」出現形態が確認された:

1. **enum/marker値・変数名**: `RESUME_DISPATCH`、`RUN_QUEUE=resume_match`、`resume_phase`（シェル変数）など。これらは識別子として `resume` という文字列を含むだけで、スキル名そのものへの言及ではない。
2. **ファイル名・スクリプト名**: `resume-active-flag-restore.sh` のような、リネーム後もそのままの名前で存在し続けるファイル。歴史的な変更ログ（design-rationale 系ドキュメント）内でこれらのファイル名を参照する記述は、当時の実装を正確に記録しているため書き換えてはならない。
3. **principle ID**: `clear_resume_is_canonical` のような内部識別子。これも文字列としての `resume` を含むが、リネーム対象の bare-word 参照ではない。
4. **一般語としての「再開」**: 「resume / context 圧縮」のように、英語の一般動詞として「再開する」を意味する用法。`fresh` と対比される状態名（`cb_mode_init=resume`）としての使用も同様。
5. **意図的な歴史的記述・仮想例示**: `coding-principles.md` 内の「実装で /rite:issue-resume コマンドを /rite:recover にリネームした」という worked example のように、過去の実際のリネームイベントを説明する目的で書かれた記述。正確な歴史的記録であり書き換えると意味が変わる。
6. **裸ファイル名参照との混同**: 「裸スキル名参照」（本パターンの対象）と「裸ファイル名参照」（例: `resume.md` → `recover.md` を扱った別 Issue のスコープ）は異なるパターン。同じ `resume` という文字列でも、指しているものが「スキルの振る舞い」なのか「ファイルの実体」なのかで、対応すべき Issue のスコープが異なる。混同して同一 PR に含めると scope creep になる。

**判別の実務的な進め方**:
- `grep -rn "resume"` で横断検索した結果を1件ずつ文脈込みで読み、上記6分類のいずれかに該当するかを確認する。
- 該当する場合は「対象外」として明示的に除外理由を記録し（PR本文やコミットメッセージに残す）、機械的な一括置換をしない。
- どの分類にも該当せず、かつ「[旧スキル名] の [動作]」のように第三者的にスキルの振る舞いを指している場合のみ、真の bare-word スキル参照として置換対象にする。

## 関連ページ

- [先行 Issue の明示的 Non-Target 指定は、reviewer 推奨だけで覆さずユーザー確認する](../heuristics/respect-prior-non-target-designation.md)
- [識別子リネームは3階層（コマンド文字列・ファイル名shorthand・裸トークン）で置換対象を洗い出す](../heuristics/identifier-rename-three-tier-pattern-enumeration.md)

## ソース

- [PR #1793 review results](../../raw/reviews/20260707T171543Z-pr-1793.md)
