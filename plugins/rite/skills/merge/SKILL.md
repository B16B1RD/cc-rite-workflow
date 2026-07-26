---
name: merge
description: |
  rite workflow の PR squash merge ステップ。指定 PR を `gh pr merge --squash` でマージする
  （cleanup は走らせない → 別途 /rite:cleanup）。/rite:iterate・/rite:ready・/rite:batch-run から
  programmatic に呼ばれる sub-step、または手動 /rite:merge <pr>。汎用の「PR をマージ」
  ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:merge <pr_number>
argument-hint: "<pr_number>"
---

# /rite:merge

## Contract

**Input**: PR number (required)
**Output**: `[merge:returned-to-caller]` / `[merge:not-ready]` / `[merge:error]`

`gh pr merge --squash` を叩いて PR をマージするだけ。**cleanup は走らせない**。マージ後の cleanup (ブランチ削除 / Projects 更新 / Wiki ingest 等) は `/rite:cleanup` を別途実行する。

## Arguments

| Argument | Description |
|----------|-------------|
| `$1` (= `{pr_number}`) | マージ対象の PR 番号 (required) |

> 本文中の `{pr_number}` placeholder は引数 `$1`（PR 番号）に展開する。

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{pr_number}` | 引数 `$1` |
| `{branch_name}` | ステップ 1 の `gh pr view --json headRefName` から取得 |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute |

---

## ステップ 1: mergeable 判定

Ready/merge 可否の権威判定はここ (`gh pr view`) に一本化する。flow-state は離散コマンド運用 (`/clear` 毎) では writer (`/rite:open`) と reader (本スキル) が別セッションになり常に空を読むため、前提チェックは設けず不在を正常系として扱う (設計ドキュメント `docs/designs/clear-per-command-flow-state-decoupling.md` §AC-4)。

```bash
gh pr view {pr_number} -R {owner_repo} --json mergeable,mergeStateStatus,isDraft,headRefName
```

`headRefName` の値は完了通知 (ステップ 3) の `{branch_name}` 展開に使うため retain する (flow-state 不在でもブランチ名が空にならない)。

| 状態 | アクション |
|------|-----------|
| `isDraft == true` | `[merge:not-ready]` emit + 「先に `/rite:ready {pr_number}` を実行してください」案内 + 終了 |
| `mergeable != "MERGEABLE"` | `[merge:not-ready]` emit + 原因 (`mergeStateStatus`) 表示 + AskUserQuestion で「再判定 (`mergeStateStatus` を再取得して ステップ 1 をもう一度実行、1 回のみ) / 中止」を提示 |
| `mergeable == "MERGEABLE"` | ステップ 2 へ |

> **「再判定」option の挙動**: 再判定は **1 回のみ**。再判定後も `MERGEABLE` でなければ `[merge:not-ready]` で確定終了する (ping-pong 防止)。`gh pr view` の mergeable 計算は数秒〜数十秒遅延するため、再判定前に短時間待機 (sleep / 手動 wait) するかはユーザー判断に委ねる。自動 sleep は提供しない (再判定を自動で繰り返さない最小主義と整合。iterate の review⇄fix ループとは別経路で、こちらは 1 回のみの再判定に留める)。

## ステップ 2: マージ実行

```bash
# canonical signal-specific trap pattern (../../references/bash-trap-patterns.md 参照、fix スキル ステップ 2.4 と対称)
gh_err=""
_rite_merge_cleanup() {
  rm -f "${gh_err:-}"
}
trap 'rc=$?; _rite_merge_cleanup; exit $rc' EXIT
trap '_rite_merge_cleanup; exit 130' INT
trap '_rite_merge_cleanup; exit 143' TERM
trap '_rite_merge_cleanup; exit 129' HUP

if gh_err=$(mktemp "${TMPDIR:-/tmp}/rite-merge-gh-err-XXXXXX" 2>/dev/null); then
  :
else
  mktemp_gh_err_rc=$?
  echo "WARNING: gh stderr 退避用 tempfile の mktemp に失敗しました (rc=$mktemp_gh_err_rc)。gh pr merge の stderr 詳細は失われます" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] MERGE_MKTEMP_DEGRADED=1; reason=mktemp_failure_gh_err; rc=$mktemp_gh_err_rc" >&2
  gh_err=""
fi

if gh pr merge {pr_number} -R {owner_repo} --squash --delete-branch=false 2>"${gh_err:-/dev/null}"; then
  echo "<!-- skill return signal: caller must continue next step -->"
  echo "<!-- [merge:returned-to-caller] -->"
  # 成功時のみ stderr の warning (deprecation / rate-limit) を surface する。
  # 失敗時に同 stderr を head -5 で再表示すると、下の else block の head -10 と二重出力に
  # なるため、warning surface は then-branch 内に閉じ込める。
  if [ -n "$gh_err" ] && [ -s "$gh_err" ]; then
    echo "  WARNING (gh stderr):" >&2
    head -5 "$gh_err" | sed 's/^/    /' >&2
  fi
  : # success path を exit 0 に固定。warning surface を if…fi で書いても &&チェーンに崩して転記しても、末尾の no-op により block が成功扱いで終わり trap の exit $rc が偽の 1 を返さない
  # 完了通知は ステップ 3 で表示
else
  merge_rc=$?
  echo "[merge:error]"
  echo "ERROR: gh pr merge failed (rc=$merge_rc)" >&2
  if [ -n "$gh_err" ] && [ -s "$gh_err" ]; then
    echo "  詳細 (stderr):" >&2
    head -10 "$gh_err" | sed 's/^/    /' >&2
  fi
  # AskUserQuestion を LLM 側で起動: 「再試行 / 中止」
fi
```

| 終了 status | アクション |
|------------|-----------|
| `[merge:returned-to-caller]` emit | ステップ 3 完了通知へ |
| `[merge:error]` emit | bash block が stderr に gh error 詳細を出力済み。LLM は AskUserQuestion で「再試行 / 中止」を提示 |

## ステップ 3: 完了通知

ステップ 1 の `gh pr view --json headRefName` で取得した値を `{branch_name}` placeholder に展開して以下を表示:

```
## /rite:merge 完了

- PR: #{pr_number}
- マージ方式: squash
- ブランチ: {branch_name} (`/rite:merge` はローカルブランチを削除していません。リモートは `delete_branch_on_merge: true` のリポジトリでは既に削除済みの場合があります)

次のステップ:
- クリーンアップ: /rite:cleanup {pr_number}
  (ブランチ削除 / Projects Status → Done / Issue close / Wiki ingest 等)

<!-- skill return signal: caller must continue next step -->
<!-- [merge:returned-to-caller] -->
```

---

## 設計判断

- **責務は merge のみ**: `gh pr merge` を叩く 1 アクションに専念。cleanup を呼び出さない (`pr.auto_cleanup_after_merge` 等の設定キーも追加しない)
- **`--delete-branch=false` 明示**: `gh` の default 挙動に任せてクライアント側から削除 API を呼ぶことを抑止し、ブランチ削除を `/rite:cleanup` の責務に寄せる。ただし**抑止できるのは gh クライアント側の削除だけ**で、リポジトリ設定 `delete_branch_on_merge: true` の環境では GitHub がマージ完了時にサーバサイドで head ブランチを削除する。このフラグはそれを止められないため、「マージ後もブランチが必ず残る」ことは保証されない（#2016）。`/rite:cleanup` のリモート削除ステップは、この既削除を正常系として扱う（`skills/cleanup/SKILL.md` ステップ 5 の `git ls-remote --exit-code` ガード）
- **flow-state は触らない**: マージ完了時点では `phase=ready` のまま。`completed` への遷移は `/rite:cleanup` 末尾で行う (既存仕様維持)
- **マージ戦略は squash ハードコード**: 設定キー (`pr.merge_strategy` 等) を追加すると将来対応スキャフォルディングになる。`merge` / `rebase` に変えたい場合は本ファイルを直接編集する
- **stderr 分離**: `gh pr merge` の stderr は `gh_err` tmpfile に退避し、成功時は warning (deprecation / rate-limit) のみ surface、失敗時は詳細を表示する。`2>&1` で stdout merge すると warning が混在し原因診断が困難になるため避ける
