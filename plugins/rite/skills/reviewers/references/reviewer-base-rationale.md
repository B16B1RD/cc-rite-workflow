# Reviewer Base — Design Rationale

`agents/_reviewer-base.md` の実行ルールの設計背景。本文は実行時に注入されないため、ルールの「なぜ」はここに集約する(rationale 退避規約: CLAUDE.md スキル行数原則)。

## read-only-is-a-state-level-guarantee

The `[READ-ONLY RULE]` is not just a tool-level (`Edit`/`Write`) restriction — it is a **state-level** guarantee. A reviewer that runs `git checkout develop -- path/to/file` silently pollutes the parent session's index, which later surfaces as a "ghost diff" the parent session cannot attribute. Always compare blobs via `git show <ref>:<file>` or `git diff <ref> -- <file>` instead. 同様に、`git stash` は「undo すれば戻る」ように見えるが、stash entry の作成自体が parent session の working tree をクリアし、並列レビュアー間で race を起こす。`git add` / `git reset` も index を汚染し、後続の `/rite:fix` が diff を誤認する根本原因になる。`git fetch --prune` は remote-tracking branch を削除するため、後続の `git diff origin/<branch>` が「unknown revision」で壊れる silent regression を引き起こす。

## why-wrappers-are-blocked-wholesale

`hooks/pre-tool-bash-guard.sh` が shell-command wrapper (`eval`, `bash -c` 等) を中身に関係なく一律 block するのは意図的な設計である。「中身が read-only な挙動プローブなら許可してほしい」という直感に反するように見えるが:

- **理由**: guard は Bash 組み込みの word-boundary マッチで .git 書き込み (sub-block (H)) を検出するが、quote の中身 (`bash -c '...'` の `...`) はこのマッチから opaque で、`bash -c 'echo pwned > .git/hooks/pre-commit'` のような .git 書き込みを隠して bypass できてしまう。quote 内を信頼できる形で解析するのは fragile で新たな bypass 面を生むため、wrapper 自体を一律 block する方が安全側に倒せる。
- **read-only プローブの代替**: wrapper を外す。コマンドを直接実行する / 複数コマンドは subshell `( cmd1; cmd2 )` でまとめる / スクリプト化して `bash <script.sh>` で実行する (`_reviewer-base.md` の "Allowed Bash/Git commands" の `bash <test>` と同じ経路)。これらは block されない。

> 補足: read-only な挙動プローブのために `bash -c` を使うと block されるが、`( ... )` / 直接実行 / `bash <script.sh>` で検証強度を落とさず代替できる。block 時の deny メッセージにもこの代替が表示される。

## mutation-worktree-rationale-and-incident-history

**Rationale**: 過去に reviewer subagent が「mutation 検証」のために新規 named branch を作成し、`git checkout <test-branch>` → file 変更 → `git checkout develop` という遷移を行った結果、parent session の working tree が `develop` のクリーン状態に置き換わり、後続の `/rite:fix` が PR ブランチを見失う事故が起きた。さらに rite 0.8.2 の実運用では、reviewer が実装ファイルを `Edit`/`Write` ツールで **parent working tree 上で直接変更**してテストを走らせ手動復元する事故も観測された 。prose レベルの「禁止」だけでは LLM agent は mutation 検証の必要性を過大評価して bypass する傾向があるため、**正規経路を明示**し、structural enforcement と組み合わせて多層防御する。structural 層の構成 (この仕様の導入後): `hooks/pre-tool-edit-guard.sh` (Edit/Write/MultiEdit/NotebookEdit が parent working tree 配下を書き換えるのを block。隔離 worktree = `rite-review-mutation-*` / `rite-revert-test-*` 配下は許可)、`hooks/pre-tool-bash-guard.sh` (機械遮断は .git 書き込み経路のみ — 不可視・不可逆で RCE に至るため)、`hooks/scripts/post-review-state-verify.sh` (Layer 3 — Bash 経由の working-tree / branch / stash mutate をレビュー後に検出する post-condition gate。verb 単位の事前 block は #1879 で撤去され、Bash 経由 mutate の検出保証はこの Layer 3 が正)。

**禁止パターンと代替の対応表** (すべて worktree-only pattern に置換する):

| 禁止経路 | 代替 (worktree-only pattern) |
|---------|-----------------------------|
| `git checkout -b pr-N-test` → file 変更 → `git checkout <orig>` | `git worktree add --detach $(mktemp -d -t rite-review-mutation-XXXXXX) HEAD` |
| `git stash` → file 変更 → test → `git stash pop` | 同上 (stash は禁止) |
| `cp file file.bak` → file 変更 → test → `mv file.bak file` (parent working tree 内) | 同上 (parent working tree の file 変更自体が禁止 — `Edit`/`Write` tool レベル違反でもある) |
| `git checkout HEAD~1 -- file` → test → `git checkout HEAD -- file` | `git show HEAD~1:file` で blob を取得し、worktree 内で適用 |

**Invariant の enforcement 経路**: exit-time invariant (branch / stash count / branch list / worktree hash の 4 軸) は orchestrator 側 (`skills/pr-review/SKILL.md` ステップ 5.0.A post-review state verification) で `post-review-state-verify.sh` により post-condition check される。worktree 軸 (`git status --porcelain` hash) は この仕様により enforce に昇格 — Edit/Write in-place mutation や state-changing git が残す差分を検出する。drift 検出時は WARNING を stderr に出力 + (branch drift のみ) automatic recovery (`git checkout <original_branch>`) を行う。stash/branch_list/worktree drift は内容を失うリスク回避のため auto-recover せず manual action を案内する。

## why-fail-fast-is-the-default

Fallbacks hide failures. A `catch (e) { return null }` recommendation that the reviewer treats as a "safety improvement" is, in fact, the same silent-failure pattern that error-handling reviewers flag as CRITICAL. Adding a fallback without justification turns the reviewer into a co-conspirator in silent failure.

## why-low-signal-findings-are-filtered

Finding Quality Guardrail は review-fix loop の四つの quality signal のうち Signal 4 を実装する (`skills/pr-review/references/finding-cycling.md` の Quality Signal 1-4 の位置付けを参照)。low-signal な指摘は非収束 review-fix loop の支配的な根本原因である: low-signal 指摘 1 件が防御的 fix を誘発し、その防御コードがさらなる low-signal 指摘を呼ぶ。

各 filter category は、reviewer が敵対的質問に対して**自信を持って防御できない**指摘を表す。「これが実際に失敗することをどう検証したか?」と問われて証拠を出せない指摘を blocking として提示すると、fix cycle N が症状に対処し、fix cycle N+1 が追加コードへの新たな bikeshedding を生み、loop は 0 findings に収束できない。
