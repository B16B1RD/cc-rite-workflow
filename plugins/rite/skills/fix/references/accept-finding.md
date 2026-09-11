### 2.1.A accept (認知のみ)

accept = 本 PR では直さない決着を `acknowledged` にし、fingerprint で次 cycle を suppression。別 Issue 化はしない。

**accept 選択時の処理 (4 つを同期実行)**:

1. **accept reason 分類 (必須、AskUserQuestion)**: accept の根拠を `scope-creep` / `out-of-scope` / `minor` / `user-override` の構造化 enum から必ず選択し、追加説明だけを `accept_reason_detail` の free-text として任意入力する。空値・enum 外・同義の自由記述だけで次へ進んではならない。trailer の `reason` 欄は `{accept_reason_class}: {accept_reason_detail}`（detail 空なら class のみ）とする。
   `accept_reason_rendered` を `{accept_reason_class}: {accept_reason_detail}`（detail 空なら class のみ）として一度生成し、reply と commit trailer の両方でこの同じ値を使う。class を含まない durable output は禁止する。
1.5. **Rejection Evidence Gate (state mutation 前)**: 4 分類すべてについて、別 reviewer の cross-validation と reject 対象 scenario の empirical counterfactual/revert test を [promotion-audit-review-fix-loop.md](../../pr-review/references/promotion-audit-review-fix-loop.md#rejection-evidence-gate) に従って実行し、両方の artifact を Decision Log に記録する。どちらかが欠ける場合はステップ 2 の `status = acknowledged` override・reply・fingerprint block・commit trailer の**いずれにも到達せず**、finding を修正対象へ戻すか AskUserQuestion で accept を取り消す。`user-override` も evidence gate の例外ではない。
2. **finding state の override**:
   - `status = "acknowledged"` を設定
   - `scope` を `nit-noted` に override (元 scope は `original_scope` として retain — reply 文言で参照)
3. **reply 投稿**: ステップ 2.4 の reply 機構を再利用（人間由来ゲート適用。rite 由来なら skip、fingerprint は続行）:
   ```
   accepted, will not be fixed in this PR. (reviewer scope: {original_scope}; user decision: accept{reason_suffix})
   ```
   `{reason_suffix}` は常に `; reason: {accept_reason_rendered}`。必須 class があるため空 suffix 経路は存在しない
4. **accept fingerprint 永続化**: `.rite/state/accepted-fingerprints-{pr_number}.txt` に当該 finding の fingerprint を append (詳細は下記 bash block)

**fingerprint 計算式 (ステップ 2.1.A 独自仕様 — accept 抑止専用。cycle 間比較は `pr-review/references/finding-cycling.md` の semantic 判断であり、本 hash はそれとは独立の機械契約)**:

```
fingerprint = sha1(normalize(file_path) + ":" + category + ":" + normalize(message))
```

- `normalize(file_path)`: `./` prefix のみ collapse (case-sensitive filesystem 保護のため lowercase 化・空白除去はしない)
- `category`: review-result-schema.md の `findings[].category` フィールド値 (例: `code_quality`)
- `normalize(message)`: trim + whitespace collapse (lowercase + 行番号除去等は行わない)


**Placeholder data flow** (`{file}` / `{line}` / `{category}` / `{description}` の取得元):

| Placeholder | 取得元 | ステップ 1.2.0 構築有無 |
|-------------|--------|---------------------|
| `{file}` | `findings[].file` (schema 1.1.0) | ステップ 1.2.2 の reload 済み JSON を finding ID で参照し、直接置換 |
| `{line}` | `findings[].line` (`integer \| null`、null は anchor sentinel) | 同上 |
| `{category}` | `findings[].category` (schema 1.1.0、例: `code_quality`) | ステップ 1.2.0 では `category_map` 未構築 — Claude は会話コンテキストの finding object から直接置換する責務を持つ |
| `{description}` | `findings[].description` | 同上 |
| `{pr_number}` | ステップ 1.0 正規化値 | bash block 冒頭で literal substitute |

**`{line}` が null の場合**: `Acknowledged-finding:` commit trailer / `[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED` retained flag emit / fingerprint normalize すべてで `null` literal を避け、`anchor` sentinel (ステップ 1.3 の thread lookup 規約と統一) に正規化する。

**accept 永続化 bash block** (per accepted finding、単一 Bash tool invocation 内で実行 — `{file}` / `{line}` / `{category}` / `{description}` / `{pr_number}` は Claude が事前 substitute):

```bash
# ステップ 2.1.A accept fingerprint 永続化
# canonical trap pattern は ../../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: パス先行宣言 → trap 先行設定 → mktemp の順序、signal 別 exit code、関数契約)

# Step 1: placeholder の literal substitution + numeric/empty gate
pr_number="{pr_number}"
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: ステップ 2.1.A の pr_number が literal substitute されていません (値: '$pr_number')" >&2
    echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 1  # placeholder gate と対称化 (blocking 統一)
    ;;
esac
file_path="{file}"
line_no="{line}"
category="{category}"
description="{description}"
# line=null → anchor sentinel に正規化 (ステップ 1.3 の thread lookup 規約と統一)
case "$line_no" in
  ''|null|0) line_no="anchor" ;;
esac

# Step 2: パス先行宣言 → cleanup 関数定義 → 4 行 trap 設置 → mktemp の順 (canonical pattern)
tmpfile=""
# state ファイルはリポジトリ共通の state ルート基準 (state-path-resolve.sh)。セッション worktree /
# main checkout のどちらから実行しても同一パスに解決される (pr-review.md ステップ 5.1.2.A の
# 読取側と同一解決。解決失敗時は cwd fallback)
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
state_dir="$_state_root/.rite/state"
state_file="${state_dir}/accepted-fingerprints-${pr_number}.txt"
_rite_fix_phase21A_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_fix_phase21A_cleanup; exit $rc' EXIT
trap '_rite_fix_phase21A_cleanup; exit 130' INT
trap '_rite_fix_phase21A_cleanup; exit 143' TERM
trap '_rite_fix_phase21A_cleanup; exit 129' HUP

# Step 3: fingerprint 計算 (ステップ 2.1.A 独自 simplified normalize — accept 抑止専用)
# normalize(file_path): `./` prefix のみ collapse、case-sensitive path 保護のため lowercase 化しない
# normalize(message): trim + whitespace collapse、identifier mask しない (audit log の human readability 重視)
norm_file=$(printf '%s' "$file_path" | sed 's@^\./@@')
norm_cat="$category"
norm_msg=$(printf '%s' "$description" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')

# portable SHA-1 helper (BSD shasum / GNU sha1sum 両対応)
if command -v sha1sum >/dev/null 2>&1; then
  fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | sha1sum | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | shasum -a 1 | awk '{print $1}')
else
  echo "WARNING: sha1sum / shasum が見つかりません — fingerprint 永続化を skip します" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=sha1_helper_missing" >&2
  exit 0  # non-blocking: accept reply 投稿は完了済、suppression は諦めるだけ
fi

# Step 4: state directory + tempfile
if ! mkdir -p "$state_dir" 2>/dev/null; then
  echo "WARNING: .rite/state/ ディレクトリ作成に失敗しました — fingerprint 永続化を skip します" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mkdir_failed" >&2
  exit 0
fi

if ! tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-fix-accept-fp-${pr_number}-XXXXXX" 2>/dev/null); then
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mktemp_failed" >&2
  exit 0
fi

# Step 5: idempotent append (sort -u で重複排除) + atomic mv
{ [ -f "$state_file" ] && cat "$state_file"; printf '%s\n' "$fingerprint"; } | sort -u > "$tmpfile"
if ! mv "$tmpfile" "$state_file" 2>/dev/null; then
  echo "WARNING: accepted-fingerprints state file の atomic mv に失敗しました ($state_file)" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mv_failed" >&2
  exit 0
fi
tmpfile=""  # mv 成功後は trap cleanup 対象から外す (二重 rm 回避)

# Step 6: 成功時 retained flag (bash 変数経由で placeholder 残留を防ぐ)
echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED=1; fingerprint=$fingerprint; pr=$pr_number; file=$file_path; line=$line_no" >&2

# Step 7: accept ≥5 件警告 (AC-4)
# wc -l 出力に platform 依存の空白が含まれるため tr -d で剥がす (BSD wc は 先頭に空白を付ける)
accept_count=$(wc -l < "$state_file" 2>/dev/null | tr -d '[:space:]')
case "$accept_count" in ''|*[!0-9]*) accept_count=0 ;; esac
if [ "$accept_count" -ge 5 ]; then
  echo "⚠️ WARNING: 本 PR で accept (認知のみ) 累計件数が 5 件以上 (${accept_count} 件) に達しました。reviewer の精度を疑うべき水準です。" >&2
  echo "  対処: reviewer agent の prompt / scope assignment / pattern check ロジックを見直すか、本 PR を別 Issue に分割することを検討してください。" >&2
  echo "[CONTEXT] ACCEPT_LIMIT_EXCEEDED=1; pr=$pr_number; accept_count=$accept_count" >&2
fi
```

accept は **revocable** (state file の行削除)。`acknowledged` は ステップ 3 の commit 対象外。trailer は 3.2。

**`acknowledged` retained flag namespace** (ステップ 2.1.A 独立、ステップ 1.2.0 reason 表とは別 namespace):

| Flag | reason | Description |
|------|--------|-------------|
| `ACCEPT_FINGERPRINT_PERSISTED` | (success marker) | fingerprint state file への append が成功。`fingerprint=<sha1>; pr=<num>; file=<path>; line=<num\|anchor>` を含む (`line` は null/0/空のとき `anchor` sentinel に正規化される。ステップ 2.1.A bash block の line_no 正規化と統一) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `pr_number_placeholder_residue` | `pr_number` placeholder が literal substitute されていない (空文字 / placeholder 残留 / 非数値) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `sha1_helper_missing` | sha1sum / shasum のいずれも環境に存在しない (極稀、CI 環境異常) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mkdir_failed` | `.rite/state/` directory 作成失敗 (permission denied / read-only filesystem) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mktemp_failed` | tmpfile 作成失敗 (disk full / inode 枯渇) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mv_failed` | tmpfile から state file への atomic mv 失敗 |
| `ACCEPT_LIMIT_EXCEEDED` | (warning marker) | 同一 PR 内 accept 件数が 5 件以上に達した警告 (AC-4) |

永続化失敗は WARNING + flag で続行 (reply は済、suppression だけ諦める)。
