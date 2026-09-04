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
tags: ["test", "hermeticity", "env-var-leak", "session-id", "flow-state", "sandbox"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-20T14:26:26Z" }
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

## 関連ページ

- [owner/repo 解決テストは ambient な git remote 状態に依存させない (non-hermetic test)](./test-hermeticity-ambient-git-remote-dependency.md)

## ソース

- [post-compact.test.sh の ambient session-id 環境変数漏洩を遮断](../../raw/reviews/20260720T094042Z-pr-1928.md)
- [hooks/tests 全体の悉皆監査で7ファイルを修正](../../raw/reviews/20260720T142626Z-pr-1932.md)
