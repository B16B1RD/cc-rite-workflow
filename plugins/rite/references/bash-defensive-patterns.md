# Bash Defensive Patterns Reference

A collection of defensive Bash patterns to prevent recurring syntax errors in rite workflow command templates.

> **CRITICAL: All Bash code in command templates MUST use the defensive patterns defined in this document.**
>
> These patterns prevent the 5 most common runtime errors observed in rite workflow execution.
>
> **Applies to**: All command templates under `commands/` that contain Bash code blocks

---

## Table of Contents

- [Summary: Error Pattern → Defensive Pattern Mapping](#summary-error-pattern--defensive-pattern-mapping)
- [Pattern 1: Integer Comparison](#pattern-1-integer-comparison)
- [Pattern 2: grep Variable Expansion](#pattern-2-grep-variable-expansion)
- [Pattern 3: Python Inline Scripts with Japanese](#pattern-3-python-inline-scripts-with-japanese)
- [Pattern 4: Directory Pre-creation](#pattern-4-directory-pre-creation)
- [Pattern 5: SIGPIPE Prevention in Pipelines](#pattern-5-sigpipe-prevention-in-pipelines)
- [Other Bash Pitfalls](#other-bash-pitfalls)
- [Pitfalls by Theme](#pitfalls-by-theme)
- [Quick Checklist for Template Authors](#quick-checklist-for-template-authors)

---

## Summary: Error Pattern → Defensive Pattern Mapping

| # | Error Message | Root Cause | Defensive Pattern |
|---|---------------|-----------|-------------------|
| 1 | `整数の式が予期されます` | Unquoted variable or missing default in `[ ]` integer comparison | `[[ "${var:-0}" -gt 0 ]]` |
| 2 | `grep: 無効なオプション -- ' '` | Unquoted variable passed to grep | `grep -- "$pattern"` + `|| true` |
| 3 | `SyntaxError: unterminated string literal` | Japanese strings in inline Python script (`python3 -c`) | File-based argument passing |
| 4 | `そのようなファイルやディレクトリはありません` | Missing directory before file write | `mkdir -p` before write |
| 5 | SIGPIPE / exit code 141 | `echo`/`printf` pipe to early-terminating `head`/`grep -m`/`grep -q`, or buffered writer to early-exit `awk`, under `pipefail` | Here-string `<<<` instead of pipe; drain input in `awk` |

---

## Pattern 1: Integer Comparison

### Vulnerable Pattern

```bash
count=$(echo "$result" | grep -c "pattern")
if [ $count -gt 0 ]; then
  echo "found"
fi
```

**Failure mode**: When `grep -c` finds 0 matches, it exits with code 1. Under `set -e`, this aborts the script before the assignment completes, leaving `$count` empty or unset. The `[` command then receives insufficient arguments and fails with `整数の式が予期されます`.

### Defensive Pattern

```bash
count=$(echo "$result" | grep -c "pattern" || true)
if [[ "${count:-0}" -gt 0 ]]; then
  echo "found"
fi
```

**Key changes**:
1. `|| true` — prevents `set -e` from aborting when grep finds 0 matches (exit code 1)
2. `[[ ]]` — handles empty/whitespace variables without word splitting
3. `${count:-0}` — provides default value `0` when variable is empty or unset

### Additional Examples

```bash
# Before (vulnerable)
if [ "$updated_length" -lt $((original_length / 2)) ]; then
  echo "WARNING: body too short" >&2
  exit 1
fi

# After (defensive)
if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
  echo "WARNING: body too short" >&2
  exit 1
fi
```

```bash
# Before (vulnerable)
if [ "$patch_status" -ne 0 ]; then
  echo "ERROR: PATCH failed" >&2
  exit 1
fi

# After (defensive)
if [[ "${patch_status:-1}" -ne 0 ]]; then
  echo "ERROR: PATCH failed" >&2
  exit 1
fi
```

---

## Pattern 2: grep Variable Expansion

### Vulnerable Pattern

```bash
echo "$body" | grep $pattern
echo "$body" | grep -c $pattern
```

**Failure mode**: When `$pattern` contains spaces or starts with `-`, grep interprets parts as options, producing `無効なオプション` errors.

### Defensive Pattern

```bash
echo "$body" | grep -- "$pattern" || true
echo "$body" | grep -c -- "$pattern" || true
```

**Key changes**:
1. `"$pattern"` — double quotes prevent word splitting
2. `--` — end-of-options separator prevents pattern from being interpreted as flags
3. `|| true` — prevents non-zero exit code when no matches found

### grep -c Specific Pattern

When using `grep -c` to count matches and storing the result:

```bash
# Defensive: capture count safely
match_count=$(echo "$body" | grep -c -- "$pattern" || true)
if [[ "${match_count:-0}" -gt 0 ]]; then
  echo "Found ${match_count} matches"
fi
```

**Never `|| echo 0` inside the substitution.** `grep -c` already prints `0` and exits 1 on zero matches, so `$(grep -c ... || echo 0)` captures `"0\n0"` and the next integer test fails. Keep the fallback outside the substitution: `cnt=$(... | grep -c .) || cnt=0` (a failure of an upstream or later pipe stage is absorbed into `|| cnt=0` as well), or use `|| true` with `${cnt:-0}`. **Both forms are for stdin pipes only**: they also swallow exit 2 (I/O error), so with a file argument capture `rc` (`rc=0; cnt=$(grep -c -- "$pat" "$file") || rc=$?`, which survives `set -e`) and stop when `rc >= 2`. Regression: `hooks/tests/grep-c-echo-fallback.test.sh`.

---

## Pattern 3: Python Inline Scripts with Japanese

### Vulnerable Pattern

```bash
python3 -c "
import re
body = '''$body_content'''
updated = re.sub(r'現在のループ回数: \d+', '現在のループ回数: $new_count', body)
print(updated)
"
```

**Failure mode**: Shell variable expansion (`$body_content`) inside double-quoted `python3 -c` strings can produce unterminated string literals when the content contains quotes, triple-quotes, or backslashes. This pattern is especially common in this project because command templates frequently process Japanese text content via shell variable expansion.

### Defensive Pattern

```bash
# Write body to file first, pass file paths as arguments
printf '%s' "$body_content" > "$body_tmp"

python3 -c '
import sys, re

body_path, out_path, new_count = sys.argv[1], sys.argv[2], sys.argv[3]
with open(body_path, "r") as f:
    body = f.read()
updated = re.sub(
    r"^(- \*\*現在のループ回数\*\*[:：] ?)\d+",
    lambda m: m.group(1) + new_count,
    body, count=1, flags=re.MULTILINE
)
with open(out_path, "w") as f:
    f.write(updated)
' "$body_tmp" "$updated_tmp" "$new_loop_count"
```

**Key changes**:
1. Body content is written to a temp file, not embedded in the script
2. Python script is wrapped in single quotes — no shell expansion inside
3. File paths and simple values are passed as `sys.argv` arguments
4. Japanese regex patterns are safe inside Python string literals (not shell-expanded)

---

## Pattern 4: Directory Pre-creation

### Vulnerable Pattern

```bash
echo "$content" > .rite/work-memory/issue-123.md
printf '%s' "$backup" > "${TMPDIR:-/tmp}/rite-backups/wm-backup.md"
```

**Failure mode**: Parent directory does not exist, producing `そのようなファイルやディレクトリはありません`.

### Defensive Pattern

```bash
mkdir -p .rite/work-memory
echo "$content" > .rite/work-memory/issue-123.md

mkdir -p "${TMPDIR:-/tmp}/rite-backups"
printf '%s' "$backup" > "${TMPDIR:-/tmp}/rite-backups/wm-backup.md"
```

**Key changes**:
1. `mkdir -p` — creates directory and all parent directories if they don't exist
2. `-p` flag — no error if directory already exists (idempotent)
3. Place `mkdir -p` immediately before the first write to that directory

### Common Directories to Pre-create

| Directory | Purpose |
|-----------|---------|
| `.rite/work-memory/` | Local work memory files |
| `${TMPDIR:-/tmp}/rite-backups/` | Work memory backup files |
| `docs/designs/` | Design documents |

---

## Pattern 5: SIGPIPE Prevention in Pipelines

### Vulnerable Pattern

```bash
# echo/printf が upstream (writer)、grep/head が downstream (reader) の pipeline
incomplete_tasks=$(echo "$comment_body" | sed -n '/### 進捗/,/### /p' | grep -E '^\s*- \[ \]' | head -10)
parent_number=$(echo "$issue_body" | grep -A2 '^## 親 Issue' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
ISSUE_NUMBER=$(printf '%s\n' "$ISSUE_URL" | grep -oE '[0-9]+$' || true)
```

**Failure mode**: `pipefail` 有効時、`head -N` / `grep -m 1` / `grep -q` が早期終了すると downstream の reader が閉じる。upstream の `echo` / `printf` がまだ書き込み中の場合（変数の内容が pipe buffer 64KB を超えるときに限らず、数行の `echo "$output" | grep -q` でも CI で観測されている）、SIGPIPE (rc=141) が upstream に届き、pipeline 全体の exit code が 141 になる。`|| true` で吸収しても SIGPIPE と「マッチなし」が区別できない。

### Defensive Pattern

```bash
# here-string `<<<` で echo/printf subprocess を排除
# bash 5.0 以前は一時ファイル、5.1 以降は pipe buffer 未満なら pipe（大きい入力は一時ファイル）で渡す
# here-string は上流の書き手プロセスを作らないため、grep の早期終了で書き手が SIGPIPE を受ける経路がない
progress_section=$(sed -n '/### 進捗/,/### /p' <<< "$comment_body")
incomplete_tasks=$(grep -E '^\s*- \[ \]' <<< "$progress_section" | head -10)

parent_number=$(grep -A2 '^## 親 Issue' <<< "$issue_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

ISSUE_NUMBER=$(grep -oE '[0-9]+$' <<< "$ISSUE_URL" || true)
```

**Key changes**:
1. `echo "$var" | cmd` → `cmd <<< "$var"` — echo subprocess を排除し SIGPIPE 経路を断つ
2. 複合 pipeline (`sed | grep | head`) は段階分割: まず `sed <<< "$var"` で範囲抽出、次に `grep <<< "$section"` でフィルタ
3. `grep -q` / `grep -m 1` のような早期終了 flag と組み合わせる場合は特に重要
4. 前段が `jq` / `git` / `sed` などのコマンドで、pipeline の終了コードで producer の失敗も判定していた場合は、`out=$(cmd) && grep -q x <<< "$out"` のように結果を変数に受けてから渡し、producer の失敗を偽として残す。「一致なし」を確かめる否定形では、producer の成功を先に確認する。代入と検索をまとめて否定すると、producer の失敗も「一致なし」の側へ入る。出力を変数に受けず stream のまま読むときは、後述の「Buffered Writer + Early-Exit `awk`」節に従い、`grep -q` の代わりに入力を読み切る `cmd | awk '/x/ { found=1 } END { exit !found }'` を使う

```bash
if ! out=$(cmd); then
  echo "ERROR: producer failed" >&2
  exit 1
elif grep -q x <<< "$out"; then
  echo "一致あり"
else
  echo "一致なし"
fi
```

### When NOT to Convert

以下のパターンは SIGPIPE リスクがないため変換不要:

| パターン | 理由 |
|---------|------|
| `echo "$var" \| grep -c` | `grep -c` は全入力を消費（早期終了しない） |
| `echo "$var" \| sort -u \| grep -v` | `sort` が全入力をバッファリング |
| `echo "$var" \| grep`（`-q` / `-m` なし） | `grep` は全入力を消費（早期終了しない） |

`grep -q` / `grep -m` と組み合わせる場合は、変数の中身が小さく見えても、テストコードでも here-string に変換する。`printf '%s' "$var"` も `echo "$var"` と同じ builtin の書き込みで、変数の大きさに上限がないため対象に含む。lint（`pipefail-grep-q-check.sh`）は、producer 段（前置きの代入やリダイレクトを含む）に `$`・バッククォート・glob（`*` `?` `[`）・ブレース展開（`{`）の文字を含まない `echo` / `printf` を、出力の上限が呼び出し箇所で決まる bounded proxy として免除する。これは SIGPIPE が起きないことの証明ではない。書式に数値の幅や精度（`%300000s` / `%.5000f`）を持つ `printf` は、リテラルの長さを超えて出力を膨らませるため免除しない。lint はほかに brace group・`docker ps`・`enable -p` も免除する。

### Buffered Writer + Early-Exit `awk`

変数に受けず stream のまま読む upstream（関数・`awk` / `sed` などコマンドの出力）でも同じ SIGPIPE が起きる。出力を変数に受けられるなら Key changes 4 の here-string へ、stream のまま読むなら本節の awk へ寄せる。バッファ付きの writer は出力を数 KB ずつ複数回 write するため、合計が 64KB 未満でも、downstream の `awk '... { exit }'` が、writer の write がまだ残っているうちに終端行で終了すると、残りの write が SIGPIPE を受ける（終端行が何番目の chunk にあっても起きる）。発生はタイミング依存で、並列負荷下ほど再現しやすい。

```bash
# Vulnerable: section は複数 chunk で書かれ、awk は終端行で exit する
extract_section "$file" | awk '/^BEGIN$/ { a=1; next } a && /^END$/ { exit } a { print }'

# Defensive: 終端でフラグを立て、以降は next で入力を読み切る（done を先頭ルールに置き抽出の再開を防ぐ）
extract_section "$file" | awk 'done { next } /^BEGIN$/ { a=1; next } a && /^END$/ { done=1; next } a { print }'
```

upstream がファイルを直接読む `awk ... "$file"` の `exit` は pipe を持たないため変換不要。

### Reference

- 初回修正: `pr-review.md` の `printf | grep -m 1` → `<<<`
- 横断調査による残存パターンの一括修正

---

## Other Bash Pitfalls

| Situation | Defensive form |
|-----------|----------------|
| `n=$(grep -oE ... \| wc -l)` under `set -euo pipefail` aborts the script on zero matches when assigned | `{ grep -oE ... \|\| true; } \| wc -l` (stdin pipe only; with a file argument capture `rc=0; ... \|\| rc=$?` and stop on `rc >= 2`) |
| `awk -v var=...` processes escape sequences like a string literal; an unknown escape such as `\[` is undefined by POSIX (gawk yields `[`, mawk keeps `\[`) | Pass via the environment: `VAR="$x" awk '... ENVIRON["VAR"] ...'` |
| awk `==` on non-ASCII strings (e.g. Japanese headings) matched wrongly on some awks (observed with macOS awk; current POSIX requires identity comparison for `==`) | Resolve the line with `grep -nxF`, require exactly one hit |
| `d=$(cd "$(mktemp -d)" && pwd -P)`: a failed `mktemp` makes the command `cd ""`, which is a no-op in bash, so the result is the cwd and a later `rm -rf` trap deletes the working tree | Never nest `mktemp` inside `cd`. New code: `rite_tempdir_new d \|\| exit 1` (declares empty, installs the cleanup handler, then creates the directory), then `cd "$d"` |
| `tmp=$(mktemp) \|\| tmp=""` then `${tmp:-/dev/null}` when the captured stderr is **used for a judgment** (marker grep, diagnosis): a failed `mktemp` silently turns the judgment into "nothing happened". The non-blocking stderr-capture slot (`x=$(mktemp 2>/dev/null) \|\| x=""`, stderr only displayed) is a sanctioned idiom and out of scope | Fail loudly (`tmp=$(mktemp) \|\| { echo "ERROR: mktemp failed" >&2; exit 1; }`), or fold stderr with `$(cmd 2>&1)` when stdout is not interpreted. New helpers take temp files from `hooks/scripts/lib/tempfile.sh` instead of raw `mktemp` |
| LLM-generated JSON placed inside `--argjson '...'` single quotes | Write to a file (`mktemp` + heredoc) and pass with `--rawfile v f` and apply `$v \| fromjson` (a malformed file fails loudly). `--slurpfile v f` reads as `$v[0]` and silently ignores a second JSON value |

---

## Pitfalls by Theme

Each row is a condition and the form that avoids it. Forms marked **lint** are detected by `hooks/scripts/bash-pitfall-check.sh` (`/rite:lint`); the rest need a reviewer's judgment. Rows cover the bash, awk, sed, grep and jq forms the plugin uses.

### Exit status, `set -e`, `pipefail`

| Situation | Defensive form |
|-----------|----------------|
| `out=$(cmd); rc=$?` aborts at the assignment under `set -e`, so the `rc` branch is dead code (also in test code) | `rc=0; out=$(cmd) \|\| rc=$?`, or bracket the call with `set +e` / `set -e` |
| `if ! cmd; then rc=$?` — `$?` is the negated status, always 0 (**lint**: `if-bang-rc`) | `rc=0; cmd \|\| rc=$?`, or read `$?` in the `else` of a positive `if cmd` |
| `git diff --quiet`, `grep`, `diff` return 0 / 1 / ≥2; folding them with a negated `if` turns a real error (≥2) into the "differs / no match" branch | Capture `rc` and branch on 0, 1 and ≥2 separately |
| `$(grep -c ... \|\| echo 0)` captures "0" twice on no match (**lint**: `grep-c-echo-fallback`; see Pattern 2) | Keep the fallback outside the substitution |
| `grep -v ... > f \|\| true` and `grep ... \|\| true` treat no-match (1) and I/O error (≥2) alike; a destructive branch chosen on "no match" runs on an error | Capture `rc`; stop at `rc >= 2` before any destructive step. Do not wrap a `grep` whose no-match is itself the bug |
| `local v=$(cmd)` masks the failure while top-level `v=$(cmd)` aborts; a guard written after the top-level form is dead code. "A simple assignment is exempt from `set -e`" is false for a command substitution | `local v; v=$(cmd) \|\| v=""` (symmetric), then validate `v` |
| `v=$(cmd) \|\| v=""` overwrites a diagnostic the command already wrote to stdout (for example a parser's JSON error) | No fallback on the capture: `if v=$(cmd); then ...; else` show `v` as the reason |
| `exit` inside a helper called as `$(helper)` stops the substitution, not the caller | After the assignment check `rc`, then emptiness, then `${v:?}`. A substitution embedded in a condition (`[ "$(cmd)" = x ]`) discards its status: assign first |
| `[ "$x" -eq 0 ]` on a non-numeric `$x` returns 2, so a fail-closed intent falls into the `else` | Validate numeric (`[[ "$x" =~ ^[0-9]+$ ]]`) before comparing |
| `v=$(a \| b); ... ${PIPESTATUS[0]}` — after the assignment the array holds the substitution's own status (one element), not the stages' (**lint**: `pipestatus-subst`) | `v=$(a) \|\| fallback` with parameter expansion, or capture the status inside the substitution |
| `v=$(fn \| tr ...)` without `pipefail` loses `fn`'s `return 1`; the script continues on the opt-out default | Declare `pipefail`, or capture `fn` first and filter the variable |
| `set -euo pipefail` with `v=$(a \| grep x \| head)` aborts on no-match; `v=$(cmd \| jq ... 2>/dev/null)` aborts on invalid JSON and makes the later FAIL branch dead | `mapfile -t arr < <(grep x f \|\| true)` for lists; `if ! v=$(cmd \| jq ...); then <named reason>` for judged values |
| `( subshell )` returning non-zero under `set -e` stops the script before the status is read | `rc=0; ( ... ) \|\| rc=$?` |
| `cat > f <<EOF` writes a newline even when every expansion is empty, so `[ ! -s f ]` is never true | Guard the exit status of the command that produced the content. Delete a guard that no input can trigger instead of keeping it |
| `gen > target` truncates `target` before `gen` fails; a success marker whose value comes from the substitution then claims success with empty content | Generate to a temp file, move on success; derive the marker only after the generator's status is checked |
| `cmd1 \| cmd2 \| cmd3` where later stages may never start | Initialise per-stage status variables with a non-numeric sentinel (`n/a`), not `0` |
| A `case` arm list whose initial value lies outside the allowed values falls through silently; `*) continue` hides enum drift in LLM-generated values | Initial value inside the allowed set, or `*) fail-loud`. A value carried in a marker that may be empty collapses to "unset": substitute a sentinel (`unresolved`) and reject it at the consumer |
| Signal and `EXIT` traps both call the same cleanup, so output-bearing checks run twice | Clear the "needs cleanup" flag before running the check |
| A signal test passes only when the sender (self / external) and receiver state (running / waiting on a child) match production | Use a background victim plus a marker file, and measure |
| A script with its own exit-code contract is tested with "non-zero" | Assert the exact code (`2`), so a crash (1, 127, 141) is not read as the contract |
| An exit-code branch described in prose as "other" absorbs the named codes | Write the branches as a table: `0` / `1` / `2` / other → fail loud. Enumerate every path that can produce each code, with broken inputs |
| A new exit code is added | Carry its meaning to every surface that prints it (hook stdout, branch tables); guarantee only what the new code means |

### Extracting or delegating a bash block

| Situation | Defensive form |
|-----------|----------------|
| Moving inline bash into a helper adds argument validation; an input that used to be supported (an empty value) now fails with no marker | Decide the consumer's handling of the new usage error before adding the validation |
| A non-blocking helper returns `rc=0` and reports partial failure by marker only; the caller tests `rc` and treats leftovers as done | The caller reads the marker. Do not add `\|\| return 2` inside a function whose contract is "failure is a marker": the dispatcher drops `rc` and recreates the trap |
| Appending `echo marker` as the last line of a moved block turns the last command's failure into a successful empty value | Keep the status-bearing command last, or capture its status before the `echo` |
| After delegating to a helper, "helper could not be resolved" (`rc=127`) dominates failures | List it first among the diagnosed causes; keep the meaning of the failure-time default unchanged |
| A new path or value placeholder in a skill body is shell-expanded in one place and consumed literally (by `Write`) in another | Ask once per new placeholder which of the two applies; quote path placeholders and check option-name pairing |
| A new placeholder collides with an existing shell variable (`$owner_repo` vs `{owner_repo}`) | Grep the whole tree before introducing it. `VAR={placeholder}` literal substitutions must be quoted. Replace placeholders with `sed` only in the `{var}` form |
| A command is copied from another call site | Copy the sibling's diagnostic handling too; do not copy its `\|\| true`. New code fails loudly where the sibling swallows |

### Reporting a failure

| Situation | Defensive form |
|-----------|----------------|
| One diagnosis covers failures with different causes (not-found vs transient, content missing vs re-read failed) | Classify by cause; give each cause its own recovery hint. Do not reuse the hint of another path |
| Within one exit code, the reason is read from structured stdout | Match the reason exactly; unknown, missing or repeated markers fail fast |
| `2>/dev/null` on a command whose stderr is the root cause (for example `gh`) | Capture to a temp file, show a selected line in the reason. One stderr file per step in a multi-step git flow |
| `$(cmd 2>&1)` where the helper writes a token on stdout and diagnostics on stderr: the token no longer matches any `case` arm and the sentinel is silently never emitted | Capture stdout and stderr separately and document the helper's output contract |
| A recovery hint printed after a long diagnostic is cut by the caller's `head -5` | Put the one line a person must act on first |
| A refactor adds `2>/dev/null` | Look for it in the diff and justify each one |
| A redirection written before `2>/dev/null` that fails still prints its error (`cmd >/bad/x 2>/dev/null`); one written after is hidden; `{ cmd; } 2>/dev/null` hides both | Use the brace group only when every diagnostic, redirection errors included, is disposable; otherwise capture (previous row) |
| A fallback hides a failure that looks like success (`git rev-parse HEAD \|\| echo unknown`) | Print a WARNING in the fallback branch |
| A best-effort loop continues past failures | Count each failure so that "summary total == items processed" holds; pass the delegate's stderr through |

### awk, sed, grep and regular expressions

| Situation | Defensive form |
|-----------|----------------|
| awk `exit` still runs the `END` rule; a body `print` plus an `END` fallback prints twice | Put the single `print` in `END` |
| awk `> file` mixed with `close(file)` re-truncates on the next write | Do not `close()` a file written with `>` mid-run |
| CRLF input: awk's default `FS` leaves the `\r`, so `NF == 0` fails on empty lines | Strip `\r` once where the input is captured |
| `{m,n}` interval in an awk regex is not supported by older mawk (before the 2020 interval support), so the match differs silently | Alternation: `(##\|###\|####)` where such an awk must work |
| `[^#].*X` (negated class, greedy, literal) misses `X` at the line start | Filter comments first (`!/^[[:space:]]*#/`), match `X` separately; POSIX ERE has no lookahead |
| awk `-v` and a regex: `\.` becomes any character, `\[` needs `\\[` | Pass through `ENVIRON`, or use `[.]` / `[[]` |
| `out = out c` one byte at a time is quadratic on mawk | Decide and `printf` in place |
| ERE `?` on a multibyte character applies to its last byte under `LC_ALL=C` | Group the character: `(値)?`. Wrap variables followed by a multibyte character in `${VAR}` (a non-UTF-8 locale otherwise reads the bytes into the name and trips `set -u`) |
| `sed -i` with or without an empty-string argument (**lint**: `sed-inplace-gnu`; GNU and BSD disagree on the argument form); `sed '20i\text'` one-liner; BRE `\?` / `\+` | `-i.bak` or temp file + `mv`; `awk 'NR==20 {...}'`; `sed -E` with `?` / `+` |
| `paste -sd ' '` without an operand on BSD | `paste -sd ' ' -` |
| `grep -oE '(^\|[^A-Za-z])D-[0-9]+'` returns the boundary character with the match | Add a stage that extracts only the token |
| `git log --grep=12` matches `123`; a short number hides behind a longer one | Express the word boundary with several `--grep` options (OR) and re-test in the consumer |
| `grep -E` with a literal `\|` in the pattern reads it as alternation, so the assertion is trivially true | `grep -F` for fixed strings |
| `grep -n` after a filter breaks line numbers | Number lines in one awk |
| A regex anchored at the line start misses `if cmd`, `x \|\| cmd`, `v=$(cmd)` | Use a command boundary: `(^\|[;&\|[:space:]])cmd`; restrict static checks to fenced bash blocks so prose quoting a recovery command is not matched |
| Extracting headings or blocks from Markdown | Drop fenced lines first; update the fence state before evaluating the terminator; close a fence only with the same character and at least the same length; wrap a document that contains triple-backtick fences in four backticks; check the fence count is even before committing |
| A block checked with a fixed "+N lines" window | Track the block end with an awk state machine; flush on state change so several blocks are not concatenated |
| An awk range (`/start/,/end/`) whose body can contain a heading of the same form | Make the end condition the section-heading form and advance past the start line with `next` |
| A table row selected with `NF == N` when the last column may contain `\|` | `NF >= N` |
| Japanese text compared or trimmed in awk under `LC_ALL=C`, where `[[:space:]]` matches ASCII only | Trim full-width spaces explicitly, repeating until the length stops changing; pin `LC_ALL=C` on the line that declares the comparison |
| A detector regex tested only on the form that motivated it | Keep a known-bad and a known-good fixture; probe in the reader's context (trailing newline, flags, multi-line shape) |
| Several spellings of one rule (`cycle N`, `cycle-N`) | Enumerate them with several greps before editing; give detectors an alternation for all of them |
| A detector exit code covers regeneration-fixable violations and malformed input | Return different codes (1 vs 2) and branch the caller |

### Temp files, `trap`, test fixtures

| Situation | Defensive form |
|-----------|----------------|
| `cd "$(mktemp -d)"` (**lint**: `nested-mktemp-cd`) | Create, check, then `cd` as separate steps; register the `trap` after the assignment |
| A temp file is created before the `trap` that removes it | Register the `trap` first; where that is impossible use a scoped mini-trap and remember that `trap - EXIT` resets the handler to the default instead of restoring an outer one |
| A temp file handed to a downstream step and the variable emptied | Add the hand-off variable to the cleanup |
| `mkdir -p` creates a directory in a flow | Pair it with `rmdir <dir> 2>/dev/null \|\| true` in cleanup |
| A fixture helper called as `$(helper)` pushes onto a cleanup array | The push happens in the subshell; register in the parent shell. A function that restores `trap` via `eval` inside `$()` fires the `EXIT` trap when the subshell ends and removes the parent's fixture directory |
| A temp file created inside `$()` | `EXIT` does not cover it; delete it on every failure path and test that none remain |
| A leak test counts files in the shared temp directory | Compare the path set before and after (`comm -13`); the count delta is wrong under parallel runs |
| `mktemp` templates | Reuse the template shape of neighbouring code; avoid `mktemp -p` (not portable) |
| A library function documents that errexit or a trap belongs to the caller | Save and restore with `$-`, `trap -p` and `eval`, and pin it with a test |
| Cleanup assertions in tests | Match against the last `EXIT` registration, and register a fixture directory right after creating it |
| `sha1sum`, `readlink -f`, `date -I` differ between GNU and BSD | `command -v` chain with a fallback |
| A script sources siblings relative to its own path | Resolve `_SCRIPT_DIR` with `cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd` before any `cd` |

### jq and JSON

| Situation | Defensive form |
|-----------|----------------|
| `has("k")` is true when the value is `null` | Classify the three shapes (missing, null, value) by `type` and do not write `null` |
| `.[]?` swallows a type error, so malformed input yields "0 violations" | Test the exit code: `if ! v=$(jq ...)`, and pin the branch with a `jq` shim |
| A `select(...)` assignment that matches nothing succeeds silently | Count matches (`[.[] \| select(...)] \| length`) and fail on 0 when a match is required |
| `@tsv` read with `IFS=$'\t' read` shifts fields left over an empty middle field (tab is IFS whitespace) | Use `\x1f` as the separator |
| A judgment mechanism is replaced (`jq` for `grep`, for example) | Enumerate the old mechanism's implicit failure conditions (empty input, status) and compare measured exit codes before switching |
| A new consumer reads a persisted array | Take the meaning of the collection from the writer's definition, not the field name |
| The `gh api graphql` variable is an opaque string (ID, cursor) | `-f`, not `-F` (which converts the type); every `gh` command in a skill body carries `-R {owner_repo}` |

---

## Quick Checklist for Template Authors

Before adding Bash code to a command template, verify:

- [ ] All integer comparisons use `[[ ]]` with `${var:-default}`
- [ ] All `grep` invocations quote variables and use `--` separator
- [ ] All `grep -c` results are captured with `|| true`, or with `cnt=$(grep -c ...) || cnt=0` (fallback outside the substitution; stdin pipes only — for a file argument capture `rc=0; ... || rc=$?` and stop on `rc >= 2`) — never `$(grep -c ... || echo 0)`
- [ ] Python inline scripts use file-based argument passing (no shell variable embedding)
- [ ] All file writes are preceded by `mkdir -p` for the target directory
- [ ] All variables in `[ ]` or `[[ ]]` are double-quoted
- [ ] Pipelines with early-termination (`head`, `grep -m`, `grep -q`) use here-string `<<<` instead of `echo`/`printf` pipe
- [ ] A command producer (`jq` / `git` / `sed` …) feeding `grep -q` is captured first (`out=$(cmd) && grep -q x <<< "$out"`), so its failure still makes the condition false
- [ ] `awk` readers fed by a pipe drain their input instead of `exit` at the end marker
- [ ] Exit status is read through `cmd || rc=$?` (with `rc=0` before), never `$?` inside a negated `if` condition and never `out=$(cmd); rc=$?` under `set -e`
- [ ] Failure causes are told apart (no-match vs error, not-found vs transient); the diagnostic is not discarded by `2>/dev/null` or a `|| x=""` fallback
- [ ] `mktemp` / `trap` / fixture cleanup follow "Pitfalls by Theme"; `/rite:lint` reports no `bash-pitfall` finding
