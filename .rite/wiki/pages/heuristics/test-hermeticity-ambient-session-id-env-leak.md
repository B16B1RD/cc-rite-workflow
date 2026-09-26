---
type: "heuristics"
title: "hook のテストスイートは ambient な session-id 環境変数 (CLAUDE_CODE_SESSION_ID 等) に依存させない (non-hermetic test)"
domain: "heuristics"
promote: rite-plugin
description: "`flow-state.sh` の session_id 解決優先順位（CLI `--session` > env `CLAUDE_CODE_SESSION_ID` > env `CLAUDE_SESSION_ID` > `.rite-session-id` ファイルの優先順）は、hook を単体で叩く分にはファイルベース fixture を安全に isolate できる設計だが、テストスイート自体が **稼働中の Claude Code セッション内**（`bash \"$HOOK\"` を素の子プロセスとして呼ぶ形）で実行されると、そのセッション自身の環境変数がテストの各 `bash \"$HOOK\"` 呼び出しへ暗黙に継承され、優先順位の上位で fixture を握り潰す。"
created: "2026-07-20T09:47:41Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260720T094042Z-pr-1928.md"
  - type: "reviews"
    resource: "raw/reviews/20260720T142626Z-pr-1932.md"
  - type: "reviews"
    resource: "raw/reviews/20260915T132416Z-pr-2871.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T090314Z-pr-3129.md"
tags: ["test", "hermeticity", "env-var-leak", "session-id", "flow-state", "sandbox"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T09:08:27Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-15T13:31:28Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T09:08:27Z" }
---

# hook のテストスイートは ambient な session-id 環境変数 (CLAUDE_CODE_SESSION_ID 等) に依存させない (non-hermetic test)

## 概要

`flow-state.sh` の session_id 解決優先順位（CLI `--session` > env `CLAUDE_CODE_SESSION_ID` > env `CLAUDE_SESSION_ID` > `.rite-session-id` ファイルの優先順）は、hook を単体で叩く分にはファイルベース fixture を安全に isolate できる設計だが、テストスイート自体が **稼働中の Claude Code セッション内**（`bash "$HOOK"` を素の子プロセスとして呼ぶ形）で実行されると、そのセッション自身の環境変数がテストの各 `bash "$HOOK"` 呼び出しへ暗黙に継承され、優先順位の上位で fixture を握り潰す。

## 詳細

### 症状

`post-compact.test.sh` は、Issue 本文では「`gh`/network 依存が未 mock 化なのが原因」と推定されていたが、実際に `bash -x` でトレースした結果、原因は全く別だった: テストが `write_per_session_state()` で `.rite-session-id` ファイルに特定の session_id を書き込んだ fixture を用意していても、テストランナー自身（この対話セッション）の `CLAUDE_CODE_SESSION_ID` 環境変数が各 `bash "$HOOK"` 呼び出しに ambient に漏れ込み、優先順位に従ってファイル fixture より先に解決されてしまう。結果、hook は存在しない（または意図と異なる）flow-state ファイルを解決し、出力が silent に空になる。

```bash
# 反面教材 — テストランナー自身の環境変数が子プロセスに暗黙継承される
write_per_session_state "$fixture_session_id" ...   # .rite-session-id ファイルに書く
bash "$HOOK" ...   # だが CLAUDE_CODE_SESSION_ID が親から継承され、ファイルより優先されてしまう
```

修正は `unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID` をテストスイート冒頭に 1 行追加するだけで、`post-compact.test.sh` は 34/34 pass に到達した（修正前は 15-17 件が silent に fail）。

### なぜ問題か

- **CLI から直接叩くと再現しない**: 独立した非対話シェル（新しいターミナル等）から同じテストを実行すると `CLAUDE_CODE_SESSION_ID` は設定されておらず問題は顕在化しない。稼働中の Claude Code セッション内でテストスイートを実行するときのみ発現するため、開発者の実行文脈によって pass/fail が変わる non-hermetic なテストになる。
- **Issue の推定原因が的外れになりうる**: 本件では Issue 本文が「gh/network 未 mock 化」を原因と推定していたが、これは誤りだった。ambient env var 漏洩は症状（empty output / 意図しない flow-state 参照）だけからは推測しにくく、実際に `bash -x` で「どの session_id がどこから来たか」をトレースしないと特定できない。
- **横展開の射程が広い**: `flow-state.sh` を呼ぶ hook テストは共通してこの優先順位ロジックに依存するため、1 ファイルで顕在化した場合、同種の `bash "$HOOK"` 呼び出しパターンを持つ他のテストファイルにも同一バグが潜んでいる可能性が高い（横断調査で `hooks/tests/*.test.sh` 6+ ファイルに同一パターンを確認し、follow-up Issue として追跡）。

### 対策

1. **テストスイート冒頭で明示的に unset する**: `.rite-session-id` ファイル fixture に依存するテストスイートでは、`set -euo pipefail` の直後など早い段階で `unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID` を実行し、session_id 解決を常にファイルベース fixture へ強制する。
2. **優先順位ロジックに依存する全テストを横断監査する**: 1 ファイルで発見したら、同じ `bash "$HOOK"` 呼び出しパターンを持つ他のテストファイルも横断的に確認する（横展開の射程がドメイン単位で広いため、issue_accountability に基づき個別 Issue へ切り出す）。
3. **Issue 本文の推定原因を鵜呑みにしない**: 「〜が原因と思われる」という記述は仮説であり、実際に失敗を再現・トレースして検証してから修正範囲を確定する。

### 悉皆監査の結果

先行 PR で予告された `hooks/tests/*.test.sh` 全95ファイルの横断監査を実施し、以下を実測で確定した:

- **静的解析 + 実機検証（ambient env 設定状態 vs unset 状態の挙動比較）の 2 段構えが有効**: 「`bash "$HOOK"` を呼んでいるか」の grep だけでは fixture 上書きの有無まで判定できない。両方を組み合わせることで false negative（実は安全なのに疑わしいと誤判定）と false positive（実は危険なのに見逃す）の両方を防げた。
- **「部分ガードで未検証」という Issue 起票時点の推測が実機検証で覆るケースがある**: `issue-claim.test.sh` / `wiki-ingest-lock.test.sh` は起票時「部分的にしか env -u を持たない」と推測されていたが、実際には `--session` を省略する全呼出に inline `env -u` ガードが漏れなく掛かっており修正不要だった。推測ベースの Issue 記述は実装確認のスタート地点であり、そのまま信じて修正範囲を決めてはいけない。
- **`set -euo pipefail` 環境下では漏洩が「一部テスト失敗」で済まず「テストスイート自体のクラッシュ」に発展しうる**: `pre-compact.test.sh` は ambient env 下で `set -euo pipefail` が jq parse 失敗を伝播させ、`Results:` 行に到達する前にスイート全体が exit code 5 でクラッシュしていた（unset 後は 32/0 で完走）。この失敗モードは通常の FAIL カウント比較では見えず、実行ログの exit code まで確認する必要がある。

### 漏れる変数は session-id だけではない

session-id の 2 変数を unset しても、同じテストが稼働中のセッション内で失敗し続けることがある。host 選択の `RITE_HOST` が残ると、解決側は「そのホストのセッション ID が必要」と判断し、ID が無いため ERROR で終わる。呼び出し側がその ERROR を `2>/dev/null` で捨てて「claim なし」と扱うと、作ったばかりの fixture は age guard で黙って skip され、reap 前提の assert が数十件まとめて落ちる。テストランナー経由では `run-tests.sh` が先に一覧をまとめて unset するので起きず、単体実行のときだけ現れる。

- **漏れ方は変数ごとに違う**: `CODEX_THREAD_ID` / `GROK_SESSION_ID` は値があれば別セッションの sid に解決され、空で設定されていれば `RITE_HOST` と同じ ERROR 経路に入る。`RITE_STATE_ROOT` はセッション解決ではなく state の置き場所を差し替える。コメントで「同じように漏れる」とまとめると、この違いが読み取れなくなる。
- **対策は runner の一覧に合わせる**: 冒頭の unset は、session 解決と state root に効く変数（`CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST RITE_STATE_ROOT`）まで含める。一覧を各テストへ手でコピーするとずれていくため、共通の読み込み元でまとめて unset する方法も候補になる。
- **CI では検出できない**: CI はランナー経由でしか走らないので、テスト側の unset から変数を外しても green のままになる。効き目を確かめるには、該当変数を設定したまま単体実行する。

### レビュー中のセッションで検証コマンドを走らせると commit 拒否側に倒れる

fix-scope の検証コマンドは実行中のセッションから `bash -c` で起動されるため、session-id の環境変数をそのまま継承する。レビュー cycle が進行中のセッションでは、その環境変数からレビュー状態が解決され、commit / merge を検査する hook のテストが「計画・検証が揃っていない commit」として拒否側の結果を返す。`pre-tool-bash-guard.test.sh` はこの経路で 6 件落ち、同じテストをセッション変数を外して実行すると全件 pass した。テスト冒頭で unset しているのは subagent 種別の変数だけで、session 解決の変数は外していない。

- **検証コマンドは CI と同じ条件で書く**: 計画の検証コマンドに `env -u CLAUDE_CODE_SESSION_ID -u RITE_HOST -u RITE_PLUGIN_ROOT` を前置し、ランナー経由と同じ環境で走らせる。失敗を見たら、取り込んだ変更を疑う前にセッション変数を外した単体実行で再現するか確かめる。
- **reviewer に渡すテスト実行手順にも同じ前置を付ける**: 付けないと reviewer がこの偽の失敗を指摘として報告する。

## 関連ページ

- [owner/repo 解決テストは ambient な git remote 状態に依存させない (non-hermetic test)](./test-hermeticity-ambient-git-remote-dependency.md)

## ソース

- [post-compact.test.sh の ambient session-id 環境変数漏洩を遮断](../../raw/reviews/20260720T094042Z-pr-1928.md)
- [hooks/tests 全体の悉皆監査で7ファイルを修正](../../raw/reviews/20260720T142626Z-pr-1932.md)
- [reap テストの単体実行でホスト選択の環境変数を除去するレビュー結果](../../raw/reviews/20260915T132416Z-pr-2871.md)
- [base 取り込み後の検証でレビュー中のセッション状態がテストへ漏れたレビュー結果](../../raw/reviews/20260926T090314Z-pr-3129.md)
