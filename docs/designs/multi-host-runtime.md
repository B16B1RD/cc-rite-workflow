# Multi-host runtime

Claude Code・Codex・Grok Build で同じ rite workflow を実行するための能力調査。実行規則の SoT は配布物の [Host Runtime Contract](../../plugins/rite/references/host-runtime-contract.md)。本書は版別の根拠と確認手順を記録する。ホスト別スキル複製とグローバル設定変更は行わない。同梱 runtime helper による明示実行の範囲は下記に記録する。

## 確認範囲

確認日: 2026-09-08、Linux / Bash。公式 Web 資料は同日閲覧した現行版であり、以下のインストール版に固定された仕様とは限らない。

| 観測ID | 対象版 | 実機で確認した範囲 |
|---|---|---|
| C | Claude Code `2.1.263` | `claude --version`。ツールや hook のホスト実行は今回未検証。既存 rite の shell 回帰テストとは区別 |
| X | Codex CLI `0.153.4` | `codex --version` / `--help` / `features list`、本セッションの公開ツールと実行結果。CLI 全実行面への一般化はしない |
| G | Grok Build `1.0.21 (3aedf38d5cfb) [alpha]` | `grok --version` / `--help` / `inspect --json`。モデル起動・質問・hook 発火は未実行 |

`native` は直接機能の存在、`検証済み代替` は契約を満たす別手段の実測、`未対応` は意味の不一致を確認したもの、`未検証` は証拠不足。native（資料のみ）と実機成功を混同しない。各行の C/X/G は確認版も表し、P は後述の再確認手順を指す。

## 能力表

| 領域 | Claude Code（C） | Codex（X） | Grok Build（G） |
|---|---|---|---|
| ツール | native（資料）: Bash / Read / Edit / Write / Grep [C-tools]。実行未検証 P1 | native（観測）: exec_command、apply_patch、検索の shell 実行。公開 schema の workdir / 終了コードを確認 P1 | native（資料）: Bash / Read / Edit 等の互換名が permission filter に存在 [G-permissions]。実ツール schema / 実行は未検証 P1 |
| 作業先指定 | native（資料）: EnterWorktree(path) は既存 worktree に入場 [C-tools]。実行未検証 P2 | 検証済み代替: 専用 git worktree + exec_command(workdir) の toplevel 照合。編集は絶対パス。EnterWorktree は本実行面で未公開。子への伝播・復旧は個別検証 P2 | native（CLI受付）: --cwd / --worktree / --worktree-ref [G-cli]。既存 worktree 入場と編集先伝播は未検証 P2 |
| スキル読込 | native（資料）: Skill [C-tools]。rite の子スキル実行は未検証 P3 | native（観測）: skill catalog。検証済み代替: 解決した SKILL.md と references を読取。読取のみで子工程を完了にしない [X-skills]、P3 | native（検出）: inspect が project rite を enabled、skills=32 と報告。子スキル実行は未検証。user-invocable:false の扱いに差 [G-skills]、P3 |
| 委譲 | native（資料）: Agent、旧 Task 呼称 [C-tools]。reviewer 起動/回収は未検証 P4 | native（観測）: collaboration.spawn_agent / completion notification で計画レビュー結果を回収 [X-agents]。必要な reviewer 制約は別途 P4 | native（資料）: 独立子と親への要約 [G-agents]、CLI --agents / --no-subagents。named reviewer 読込・回収は未検証 P4 |
| 質問 | native（資料）: AskUserQuestion [C-tools]。未回答時の動作は対象版で未検証 P5 | native（公開 schema）: request_user_input は Plan 限定、async は公開あり。今回の Default で前者は利用不可。会話による回答待ちの代替は未検証 P5 | 未検証: plan preview の承認 UI は資料にあるが一般の質問ツールとの同値性は未確認 [G-plan]、P5 |
| hook | native（資料）: SessionStart / PreToolUse / Stop / compact 等と JSON 契約 [C-hooks]。今回の対象版で発火未検証 P6 | native（検出・資料）: features list の hooks=stable,true、公式 hook 定義あり [X-hooks]。rite 登録・matcher・Stop/compact 継続は未検証 P6 | native（資料）: lifecycle hook [G-hooks]。未対応: Claude の payload/Stop 出力を無変換で同値とする経路。rite adapter 経由は未検証 P6 |
| セッションID | native（資料）: hook payload の session_id [C-hooks]。対象版の shell への env 提供は未検証 P7 | native（観測）: CODEX_THREAD_ID が本セッションで存在。検証済み代替（限定）: プロセス限定 CLAUDE_CODE_SESSION_ID 入力で flow-state と claim が同じIDを受理。全 hook consumer / restart は未検証 P7 | native（CLI・資料）: --session-id は新規 UUID、--resume は再開 [G-cli]、hook の sessionId / GROK_SESSION_ID [G-hooks]。通常 shell / rite consumer への受渡しは未検証 P7 |
| 承認機構 | native（資料）: tool permission、auto 分類器 [C-tools]。拒否試験は未検証 P8 | native（観測）: workspace-write と require_escalated の正式審査で gh / git 操作を実行。拒否後の不変性は未検証 [X-approval]、P8 | native（CLI・資料）: --permission-mode / --allow / --deny と別の --sandbox [G-permissions]。承認/拒否の実行試験は未検証 P8 |

## 互換性の境界

- Claude の現行公式名は `Agent`。共通スキルの `Task` 表記を文字列置換しただけでは、reviewer 定義や回収契約を満たしたことにならない。
- Grok の公式資料は `user-invocable: false` がユーザーとモデルの両方から隠れ、`allowed-tools` が権限を制限せず、skill の `model` / `effort` を適用しないとする。rite の非公開子スキルや reviewer 制約は配布本文の明示読込と実際のツール制約を別々に検証する。[G-skills]
- Grok hooks は `sessionId` / `hookEventName` / `toolName` を渡し、passive event の stdout を無視する。PreToolUse の異常は fail-open とされる。Claude 向け Stop の差し戻しや追加コンテキストが自動的に働くとはみなせない。[G-hooks]
- Codex の hook 機能が有効でも、rite skills を発見しただけでは hooks.json の登録証跡にならない。[X-hooks] 現行 launcher は skill の接続を行うため、hook 配線は別に確認する。
- `session-identity.sh` は CODEX_THREAD_ID / GROK_SESSION_ID を直接受け取り、flow-state・claim・work memory・wiki lock へ同じ実 ID を渡す。選択先の欠落・不正・未選択複数 host env は拒否し、共有 marker を借りない。下記の配布統合テストと、ホストでの自動発火・再開の実機検証は区別する。

## 実装した明示経路

配布内の `hooks/host-runtime.sh` は `init` / `checkpoint` / `before-bash` / `before-edit` / `after-edit` / `next` を固定 helper に接続する。`auto` は native に委ね、`explicit` は caller が操作前の拒否と工程後の保存を確認する。開発 launcher やグローバル設定の変更は不要。新規の自動 hook 登録や、Grok camelCase payload の透過互換を意味しない。

`references/host-workflow-operations.md` が本文実行による nested Skill の caller 復帰、セッション別 task 台帳、公開 native 子への reviewer 本文の絶対パスと読取義務の明示、未回答・承認拒否の停止を定義する。`reviewer-completion-check.sh` は選定全員の実 ID・完了出力を照合し、未回収者がいれば統合前に停止する。

| 検証面 | 証跡と範囲 |
|---|---|
| 配布 shell | `runtime-session-identity.test.sh` が同時3ホストの state / claim / queue / WM / lock と欠落・不正・競合時の不変性を実行検証する |
| 明示 lifecycle | `host-runtime.test.sh` が配布コピーでの初期化・checkpoint・guard・二重更新・失敗を検証する。ホスト自動 hook の発火証跡ではない |
| レビュー回収 | `reviewer-completion-check.test.sh` が実 pr-review ゲートと不完全 manifest の停止を検証する。manifest の実ツール由来は caller が確認する |
| 自律継続 | `host-workflow-operations.test.sh` が実 batch のキュー初期化・停止・再開・前進・終了と foreign queue 保護を検証する |
| Codex 実機 | この実行面で独立した計画/実装子の起動・完了回収、明示 workdir、実 thread ID を観測。自動 Stop / compact / SessionEnd と Grok の全工程実機 E2E は未検証 |

## ワークフロー全工程の実機検証

[3ホスト共通の実行ガイド](../../tests/runtime-e2e/README.md) に、検証用リポジトリの準備、ホスト別の起動、コピーして渡せる指示、結果記録・集計を定義する。既存の shell suite は上表の内部契約を維持し、`tests/rite-dev.test.sh` はホストの非ゼロ終了・stderr伝播・既存設定保持を検査する。`tests/runtime-e2e.test.sh` は準備と記録道具の契約を検査する。これらを実機成功件数へ含めない。

| ホスト | 開発 launcher での全工程 | 配布物直接利用での全工程 | 理由 |
|---|---|---|---|
| Claude Code | 未検証 | 未検証 | 専用repoでのdraft・merge・recoverの一連の証跡が未採取 |
| Codex | 未検証 | 未検証 | 個別操作の観測はあるが、共通シナリオ全体の証跡が未採取 |
| Grok Build | 未検証 | 未検証 | CLI受付・plugin検出以降の共通シナリオを未実行 |

集計は同一rite commit・導入経路・実行面で3ホストの必須項目を照合する。認証不足、実機不在、未実行は理由付きの未検証とし、失敗や未検証を含む間は統合検証を完了にしない。実測後は証跡を参照して本表を更新する。

## 再確認手順

使い捨て repository と専用 worktree で実施し、現在のユーザー設定・他セッションのファイルは変更しない。各 probe でホスト版、実行面、モード、入力、stdout/stderr/終了コード、期待値との比較を残す。認証情報・全文の設定ダンプは証跡へ載せない。CLI help / inspect だけなら「受付/検出」のまま、実測して下記期待結果が揃った範囲だけ native 実行確認または検証済み代替へ更新する。意味の不一致は未対応、未実行・観測不能は未検証のままにする。

| Probe | 操作と期待する観測結果 |
|---|---|
| P1 | 公開 schema を記録し、一時ファイルの読取→1箇所編集→検索→差分確認を行う。コマンドの exit 7 と stderr も回収し、非ゼロを成功にしない |
| P2 | 別々の worktree A/B へ明示指定してマーカーを読取・編集する。続く別の tool call と子でも toplevel/branch が指定先と一致し、main/B のファイル不変を確認。再開でも同じ検査を実施 |
| P3 | 配布 plugin だけを使い、読取専用の親/子スキルと相対 reference を読ませる。user-invocable:false の子も解決し、実際の完了出力を親が回収。子の欠落/失敗では親が次工程へ進まない |
| P4 | 配布 reviewer 本文の絶対パスを指定し読取完了申告を回収、独立した子2件を起動、識別子・開始/完了時刻・結果を全件回収。読取専用・指定cwdを確認。1件失敗/不正形式では統合を成功としない |
| P5 | 要件確認を1問出し、未回答では依存処理停止、回答時のみ再開を確認。Default/Plan/headless と UI 有無を別記。batch 自動承認と権限承認を混同しない |
| P6 | 無害な記録用 handler で SessionStart、PreToolUse、PostToolUse、Stop、PreCompact/PostCompact、SessionEnd を発火。payload、plugin root、matcher、追加context、阻止/差し戻しを比較。起動検出、実行、効果を分け、意図的な exit 2 / 不正JSONも試す |
| P7 | 2セッションのIDを採取し、flow-state / claim / queue / work memory の所有者を比較。停止→同一セッション再開で一貫、別セッションは分離することを確認。欠落/不正IDで共有 marker を流用しない。IDの有無以外の環境値は記録しない |
| P8 | 専用 fixture の許可操作と拒否操作をホストの正式機構で実行。拒否後は対象不変、承認後だけ変更可能、通常質問で昇格を代用しないことを確認。権限変更で sandbox を恒久無効化しない |

### 契約の検証例

| 入力条件 | 期待する選択/結果 |
|---|---|
| native と検証済み代替の両方が必要条件を満たす | native のみを選ぶ |
| native 不在、P2 を通過した workdir 経路あり | 明示 workdir と絶対編集パスを選び、各呼出しと復旧後の invariant を維持 |
| native 不在、代替は help 表示しか確認していない | 未検証として操作前で停止し、該当 P の実施と recover を案内 |
| native 操作が権限拒否された | 別ツールへ逃がさず停止。branch / worktree / state と queue cursor を保持 |
| hook 検出成功、Stop 出力が無視される | Stop 継続を必要とする経路は未対応。成功 sentinel を生成しない |
| 開発用 launcher と開発プロファイルが存在しない | 配布内の共通契約・参照だけで解決。能力根拠が無ければ不足能力を明示 |

Claude Code の非回帰確認には既存の `plugins/rite/hooks/tests/flow-state.test.sh`、`concurrent-sessions.test.sh`、`worktree-foreign-cwd.test.sh`、`open-plan-self-review-contract.test.sh` を使う。これらは state の成功/失敗、セッション分離、他 worktree の保護、既存 open のレビュー契約を検査する。shell テストの成功を3ホストの実機 E2E 成功と呼ばない。実行結果は作業メモリ/PRに記録する。

## 根拠

公式資料（すべて 2026-09-08 閲覧）:

- [C-tools] — Claude Code Tools reference
- [C-hooks] — Claude Code Hooks reference
- [X-skills] — Build skills
- [X-agents] — Subagents
- [X-hooks] — Hooks / [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [X-approval] — Agent approvals & security
- [G-cli] — Grok CLI Reference
- [G-skills] — Grok Skills, Plugins & Marketplaces
- [G-agents] — Grok Subagents
- [G-plan] — Grok Plan Mode
- [G-hooks] — Grok Hooks
- [G-permissions] — Grok Permissions

実装側の照合先: [launcher](../../scripts/rite-dev)、[flow-state](../../plugins/rite/hooks/flow-state.sh)、[claim](../../plugins/rite/hooks/issue-claim.sh)、[Claude hook 登録](../../plugins/rite/hooks/hooks.json)、[worktree 設計](multi-session-worktree.md)。G の inspect は rite plugin の検出までを示す。すべての hook が発火した証拠ではない。

[C-tools]: https://code.claude.com/docs/en/tools-reference
[C-hooks]: https://code.claude.com/docs/en/hooks
[X-skills]: https://learn.chatgpt.com/docs/build-skills
[X-agents]: https://learn.chatgpt.com/docs/agent-configuration/subagents
[X-hooks]: https://learn.chatgpt.com/docs/hooks
[X-approval]: https://learn.chatgpt.com/docs/agent-approvals-security
[G-cli]: https://docs.x.ai/build/cli/reference
[G-skills]: https://docs.x.ai/build/features/skills-plugins-marketplaces
[G-agents]: https://docs.x.ai/build/features/subagents
[G-plan]: https://docs.x.ai/build/features/plan-mode
[G-hooks]: https://docs.x.ai/build/features/hooks
[G-permissions]: https://docs.x.ai/build/features/permissions
