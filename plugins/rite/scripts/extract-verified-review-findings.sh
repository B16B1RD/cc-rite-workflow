#!/bin/bash
# rite workflow - Extract Verified-Review Findings from Session Log(s)
# Extract individual /verified-review findings from one or more Claude Code
# session logs (jsonl) and emit them as JSONL records for downstream
# signal-rate auditing.
#
# Purpose: Issue #391 (Phase D 残タスク) で baseline_V signal rate 監査を行うため、
#          セッションログから個別指摘を構造化抽出する。PR コメントには集約結果
#          しか残っていないため、本スクリプトが必要。
#
# Note (#391 実測): Issue 当初想定では「session log 58685911-* 単独に 172 件」
#          と想定していたが、実測では verified-review の指摘は **複数 session
#          にまたがって散在** しており、単一 session では分母を構築できない。
#          そのため `--session-dir` オプションでディレクトリ走査をサポートする。
#
# Usage:
#   bash extract-verified-review-findings.sh --session <path-to-jsonl> [--out <jsonl>]
#   bash extract-verified-review-findings.sh --session-dir <dir> [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--min-size BYTES] [--out <jsonl>]
#   bash extract-verified-review-findings.sh --help
#
# Output (stdout, JSONL — 1 finding per line):
#   {
#     "cycle": 4,                              # cycle 番号 (1-8)
#     "severity": "CRITICAL",                  # CRITICAL | HIGH | MEDIUM | LOW
#     "file_line": "plugins/rite/commands/pr/fix.md:258-262",
#     "reviewer": "silent-failure-hunter (HIGH-1) / code-reviewer (M2)",
#     "description": "...",
#     "raw_row": "| CRITICAL | ... |",        # 元 markdown 行 (デバッグ用)
#     "source_session": "58685911-d795-...jsonl",
#     "source_offset": 12345                   # session log の jsonl 行番号 (debug)
#   }
#
# Exit codes (`measure-review-findings.sh` と階層を統一):
#   0  Success
#   1  Invalid arguments
#   2  File / directory access error (session 不在、out 書き出し失敗等)
#   3  Parse failure / extraction yielded zero findings
#
# 抽出ロジック:
#   1. session log の各 jsonl 行を読み、type=user の tool_result.content と
#      type=assistant の content[].text を全文走査
#   2. markdown 表 row `| {SEVERITY} | {file:line} | {reviewer} | {description} |`
#      を正規表現で抽出 (SEVERITY = CRITICAL|HIGH|MEDIUM|LOW)
#   3. 4 column variant のみサポート (3/5 column variant は v0 では未対応)
#   4. 同一 raw_row が複数回出現する場合 (ハンドオフで再掲) は dedupe
#   5. cycle 番号は session 内に出現する直近の「Cycle N」「サイクル N」表記から
#      ヒューリスティックで推定する (session を跨ぐと衝突する可能性あり)
#
# 除外:
#   - V{N} / X{N} prefix の行 (verified facts / cross-checked claims)
#   - documentation example (e.g. "docs/foo.md:12 ... WHAT問題") を heuristic で除外:
#       file_line に "docs/foo.md", "src/foo.ts", "src/auth.ts" を含むもの
#
# Limitations:
#   - cycle 番号推定はヒューリスティック。明示的な「Cycle N」見出しがない範囲では
#     0 (unknown) を出力する。session を跨ぐと cycle 番号は衝突する可能性あり
#     (集計時は (source_session, cycle) のタプルで識別すること)
#   - reviewer 列の判定は `silent-failure-hunter` / `code-reviewer` 等の reviewer
#     suffix を allow-list ベースで判定する heuristic。新しい reviewer 種別が
#     追加された場合は本ファイルの REVIEWER_NAMES set を更新すること
#   - dedup key は (severity, file_line[:120], col3[:100], cycle) のタプル。
#     再発 finding (異なる cycle で同一指摘が再出現) は cycle が key に含まれる
#     ため dedup されず保持される (Phase D 用途では再発も重要 signal)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash extract-verified-review-findings.sh --session <path-to-jsonl> [--out <jsonl>]
  bash extract-verified-review-findings.sh --session-dir <dir> [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--min-size BYTES] [--out <jsonl>]
  bash extract-verified-review-findings.sh --help

Options:
  --session <path>      単一 session log (jsonl) を指定
  --session-dir <dir>   ディレクトリ内の *.jsonl を走査
  --from YYYY-MM-DD     mtime 下限 (--session-dir 専用、ISO 8601 date 形式)
  --to   YYYY-MM-DD     mtime 上限 (exclusive、--session-dir 専用、ISO 8601 date 形式)
  --min-size BYTES      ファイルサイズ下限 (--session-dir 専用、デフォルト 500000 = 500KB)
                        500KB という値の根拠: #391 監査時の経験値。verified-review の
                        セッションは通常 2MB 以上で、500KB 未満の session は throwaway
                        セッション (test, scratch) であり verified-review の指摘を含まない
  --out <path>          出力先 jsonl (省略時は stdout、書き出し失敗時 exit 2)
  --help                このヘルプを表示

Exit codes:
  0  Success
  1  Invalid arguments
  2  File / directory access error
  3  Parse failure / zero findings
EOF
}

# require_arg: 引数値検証ヘルパー (measure-review-findings.sh のパターンを踏襲)
# `--session` を末尾に単独で渡したときの `set -u` unbound variable error を防ぎ、
# ユーザーに親切な error message を出す
require_arg() {
  if [ $# -lt 2 ]; then
    echo "ERROR: $1 requires an argument" >&2
    usage >&2
    exit 1
  fi
}

SESSION=""
SESSION_DIR=""
FROM_DATE=""
TO_DATE=""
MIN_SIZE="500000"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)     require_arg "$@"; SESSION="$2"; shift 2 ;;
    --session-dir) require_arg "$@"; SESSION_DIR="$2"; shift 2 ;;
    --from)        require_arg "$@"; FROM_DATE="$2"; shift 2 ;;
    --to)          require_arg "$@"; TO_DATE="$2"; shift 2 ;;
    --min-size)    require_arg "$@"; MIN_SIZE="$2"; shift 2 ;;
    --out)         require_arg "$@"; OUT="$2"; shift 2 ;;
    --help|-h)     usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# 排他チェック: --session と --session-dir は同時指定不可
if [ -n "$SESSION" ] && [ -n "$SESSION_DIR" ]; then
  echo "ERROR: --session and --session-dir are mutually exclusive" >&2
  usage >&2
  exit 1
fi
if [ -z "$SESSION" ] && [ -z "$SESSION_DIR" ]; then
  echo "ERROR: --session or --session-dir is required" >&2
  usage >&2
  exit 1
fi
if [ -n "$SESSION" ] && [ ! -f "$SESSION" ]; then
  echo "ERROR: session log not found: $SESSION" >&2
  exit 2
fi
if [ -n "$SESSION_DIR" ] && [ ! -d "$SESSION_DIR" ]; then
  echo "ERROR: session dir not found: $SESSION_DIR" >&2
  exit 2
fi

# --from / --to の format pre-validation (Python の raw traceback を回避)
if [ -n "$FROM_DATE" ] && ! [[ "$FROM_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: --from must be ISO 8601 date (YYYY-MM-DD): '$FROM_DATE'" >&2
  exit 1
fi
if [ -n "$TO_DATE" ] && ! [[ "$TO_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: --to must be ISO 8601 date (YYYY-MM-DD): '$TO_DATE'" >&2
  exit 1
fi

# Python 側に値を引き渡す。MIN_SIZE は bash 側を一元的なソース (DRY)
python3 - "$SESSION" "$SESSION_DIR" "$FROM_DATE" "$TO_DATE" "$MIN_SIZE" "$OUT" <<'PY'
import json
import math
import os
import re
import sys
import datetime
import glob
from collections import Counter

session_path = sys.argv[1] or None
session_dir  = sys.argv[2] or None
from_date    = sys.argv[3] or None
to_date      = sys.argv[4] or None
min_size     = int(sys.argv[5])  # bash 側で必ず set されている (二重デフォルト解消)
out_path     = sys.argv[6] or None

# Markdown 表 row pattern: | SEV | col2 | col3 | col4 | (4 columns)
ROW_RE = re.compile(
    r'^\|\s*(CRITICAL|HIGH|MEDIUM|LOW)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|',
    re.MULTILINE,
)
# Cycle 推定 (大文字小文字無視で "Cycle N" / "サイクル N")
CYCLE_RE = re.compile(r'(?:Cycle|サイクル|cycle)\s*(\d+)', re.IGNORECASE)
# Documentation example heuristic: tech-writer.md / internal-consistency.md 等で
# 教材として使われる generic file path を除外
DOC_EXAMPLE_PATHS = (
    'docs/foo.md',
    'src/foo.ts',
    'docs/example.md',
    'src/auth.ts',  # generic 例 (内部 doc で使われる頻度高)
    'src/components/Hero.tsx',
)
# Reviewer 名 allow-list (rite agents/ 配下の reviewer suffix と
# pr-review-toolkit / verified-review 等の外部 reviewer)
# 新しい reviewer を追加する場合は本セットを更新すること
REVIEWER_NAMES = {
    'silent-failure-hunter',
    'code-reviewer',
    'comment-analyzer',
    'security-reviewer',
    'performance-reviewer',
    'code-quality-reviewer',
    'api-reviewer',
    'database-reviewer',
    'devops-reviewer',
    'frontend-reviewer',
    'test-reviewer',
    'dependencies-reviewer',
    'prompt-engineer-reviewer',
    'tech-writer-reviewer',
    'error-handling-reviewer',
    'type-design-reviewer',
}
# 別名 (Title Case や略号)
REVIEWER_HINT_TOKENS = REVIEWER_NAMES | {
    'tech-writer',
    'code-quality',
    'silent-failure',
}

def collect_text(node):
    """Recursively collect all string fields from JSON node."""
    bag = []
    if isinstance(node, str):
        bag.append(node)
    elif isinstance(node, dict):
        for v in node.values():
            bag.extend(collect_text(v))
    elif isinstance(node, list):
        for v in node:
            bag.extend(collect_text(v))
    return bag

def is_reviewer_column(text):
    """col3 が reviewer 列か description 列かを allow-list で判定。
    `prompt-engineer` のような description 内の自然語による誤マッチを防ぐため、
    `engineer` 単独ではマッチさせず、必ず reviewer suffix (`-reviewer`) または
    既知の reviewer 略称 (`silent-failure-hunter` 等) を必須とする。"""
    text_lower = text.lower()
    for name in REVIEWER_HINT_TOKENS:
        # word-boundary 的な match: 前後が文字列境界か非単語文字
        idx = text_lower.find(name)
        if idx >= 0:
            before_ok = (idx == 0) or (not text_lower[idx - 1].isalnum())
            end = idx + len(name)
            after_ok = (end == len(text_lower)) or (not text_lower[end].isalnum())
            if before_ok and after_ok:
                return True
    return False

results = []
seen_keys = set()  # dedup key set
parse_errors = 0
parse_error_lines = []
skipped_files = []

# Build session path list
if session_path:
    session_paths = [session_path]
else:
    candidates = sorted(glob.glob(os.path.join(session_dir, "*.jsonl")), key=os.path.getmtime)
    session_paths = []
    try:
        start_ts = datetime.datetime.fromisoformat(from_date).timestamp() if from_date else 0
    except ValueError as e:
        # bash 側で format check 済みだが defense-in-depth
        print(f"ERROR: --from must be YYYY-MM-DD: {from_date} ({e})", file=sys.stderr)
        sys.exit(1)
    try:
        end_ts = datetime.datetime.fromisoformat(to_date).timestamp() if to_date else math.inf
    except ValueError as e:
        print(f"ERROR: --to must be YYYY-MM-DD: {to_date} ({e})", file=sys.stderr)
        sys.exit(1)
    for p in candidates:
        try:
            if os.path.getsize(p) < min_size:
                continue
            mt = os.path.getmtime(p)
        except OSError as e:
            print(f"WARNING: cannot stat {p}: {e}", file=sys.stderr)
            continue
        if mt < start_ts or mt >= end_ts:
            continue
        session_paths.append(p)
    print(f"# scanning {len(session_paths)} session logs in {session_dir}", file=sys.stderr)
    if not session_paths:
        print(
            "ERROR: no session logs matched the criteria. "
            f"dir={session_dir}, from={from_date}, to={to_date}, min_size={min_size}",
            file=sys.stderr,
        )
        sys.exit(2)

# --out 指定時の preflight: parent dir 存在確認 + write 試行
out_fp = None
if out_path:
    parent = os.path.dirname(out_path) or "."
    if not os.path.isdir(parent):
        print(f"ERROR: parent directory does not exist: {parent}", file=sys.stderr)
        sys.exit(2)
    try:
        out_fp = open(out_path, "w", encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot open output file {out_path}: {e}", file=sys.stderr)
        sys.exit(2)

def process_session(path):
    """Process a single session log file. Returns nothing; appends to global `results`."""
    current_cycle = 0  # session 内ローカル (global 不要、session 跨ぎリーク防止)
    session_basename = os.path.basename(path)
    try:
        f = open(path, encoding="utf-8")
    except OSError as e:
        print(f"WARNING: skipping {session_basename}: cannot open ({e})", file=sys.stderr)
        skipped_files.append(session_basename)
        return
    try:
        for lineno, line in enumerate(f, 1):
            try:
                o = json.loads(line)
            except json.JSONDecodeError as e:
                global parse_errors
                parse_errors += 1
                if len(parse_error_lines) < 10:
                    parse_error_lines.append(f"{session_basename}:{lineno}: {e}")
                continue
            if not isinstance(o, dict):
                continue
            if o.get("type") not in ("user", "assistant"):
                continue
            try:
                texts = collect_text(o)
            except (TypeError, ValueError) as e:
                # 構造異常 (まずないが defense-in-depth)
                print(f"WARNING: text collection failed at {session_basename}:{lineno}: {e}", file=sys.stderr)
                continue
            for text in texts:
                if not isinstance(text, str) or '|' not in text:
                    continue
                # cycle 推定
                cycle_matches = CYCLE_RE.findall(text)
                if cycle_matches:
                    try:
                        current_cycle = int(cycle_matches[-1])
                    except ValueError:
                        current_cycle = 0  # fail-safe: ヒューリスティック失敗時は unknown
                for m in ROW_RE.finditer(text):
                    severity = m.group(1)
                    file_line = m.group(2).strip()
                    col3 = m.group(3).strip()
                    col4 = m.group(4).strip()

                    # 除外: documentation example
                    if any(p in file_line for p in DOC_EXAMPLE_PATHS):
                        continue
                    # 除外: pure count rows like `| CRITICAL | 1 | desc |`
                    if re.match(r'^\d+$', file_line):
                        continue
                    # 除外: header `| CRITICAL | HIGH | MEDIUM | LOW |`
                    if file_line.upper() in ("CRITICAL", "HIGH", "MEDIUM", "LOW"):
                        continue
                    # 除外: file_line が reviewer 名を含む列ズレ row
                    if is_reviewer_column(file_line):
                        continue

                    raw_row = m.group(0)
                    # dedup key: severity + file_line + col3 + cycle (cycle で再発を保持)
                    dedupe_key = (severity, file_line[:120], col3[:100], current_cycle)
                    if dedupe_key in seen_keys:
                        continue
                    seen_keys.add(dedupe_key)

                    # reviewer / description 列の振り分け (allow-list ベース)
                    if is_reviewer_column(col3):
                        reviewer = col3
                        description = col4
                    else:
                        reviewer = ""
                        description = col3

                    results.append({
                        "cycle": current_cycle,
                        "severity": severity,
                        "file_line": file_line,
                        "reviewer": reviewer,
                        "description": description,
                        "raw_row": raw_row,
                        "source_session": session_basename,
                        "source_offset": lineno,
                    })
    finally:
        f.close()

for sp in session_paths:
    process_session(sp)

# 出力 (with-statement 相当の確実 close は try/finally で実現)
try:
    fp = out_fp if out_fp is not None else sys.stdout
    for r in results:
        fp.write(json.dumps(r, ensure_ascii=False) + "\n")
finally:
    if out_fp is not None:
        out_fp.close()

if out_path:
    print(f"# wrote {len(results)} findings to {out_path}", file=sys.stderr)
else:
    print(f"# total: {len(results)} findings", file=sys.stderr)

# Parse error summary
if parse_errors:
    print(f"# json parse errors: {parse_errors}", file=sys.stderr)
    for sample in parse_error_lines[:5]:
        print(f"#   {sample}", file=sys.stderr)
if skipped_files:
    print(f"# skipped files (open error): {len(skipped_files)}", file=sys.stderr)
    for s in skipped_files[:5]:
        print(f"#   {s}", file=sys.stderr)

# 集計サマリーを stderr に
sev_counts = Counter(r["severity"] for r in results)
cycle_counts = Counter(r["cycle"] for r in results)
print(f"# by severity: {dict(sev_counts)}", file=sys.stderr)
print(f"# by cycle: {dict(sorted(cycle_counts.items()))}", file=sys.stderr)

# Zero findings → exit 3 (parse failure)
if not results:
    print("# WARNING: 0 findings extracted", file=sys.stderr)
    sys.exit(3)
PY
