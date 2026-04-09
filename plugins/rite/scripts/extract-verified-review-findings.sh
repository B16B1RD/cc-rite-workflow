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
#   bash extract-verified-review-findings.sh --session-dir <dir> [--from <YYYY-MM-DD>] [--to <YYYY-MM-DD>] [--out <jsonl>]
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
#     "source_offset": 12345                   # session log の jsonl 行番号 (debug)
#   }
#
# 抽出ロジック:
#   1. session log の各 jsonl 行を読み、type=user の tool_result.content と
#      type=assistant の content[].text を全文走査
#   2. markdown 表 row `| {SEVERITY} | {file:line} | {reviewer} | {description} |`
#      を正規表現で抽出 (SEVERITY = CRITICAL|HIGH|MEDIUM|LOW)
#   3. 列数が異なる variant (3列 / 5列) も best-effort で対応
#   4. 同一 raw_row が複数回出現する場合 (ハンドオフで再掲) は dedupe
#   5. cycle 番号は直前に出現した「Cycle N」「サイクル N」「### Cycle N」表記から推定
#
# 除外:
#   - V{N} / X{N} prefix の行 (verified facts / cross-checked claims タブ)
#   - documentation example (e.g. "docs/foo.md:12 ... WHAT問題") を heuristic で除外:
#       file_line に "docs/foo.md" or "src/foo.ts" を含むもの
#   - severity word が表 header 行 (`| Severity |`) であるもの
#
# Limitations:
#   - cycle 番号推定はヒューリスティック。明示的な「Cycle N 結果」見出しがない
#     範囲では 0 (unknown) を出力する
#   - reviewer 列は free text のため、正規化は行わない (downstream で集計)

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
  --from YYYY-MM-DD     mtime 下限 (--session-dir 専用)
  --to   YYYY-MM-DD     mtime 上限 (exclusive、--session-dir 専用)
  --min-size BYTES      ファイルサイズ下限 (--session-dir 専用、デフォルト 500000)
  --out <path>          出力先 jsonl (省略時は stdout)
  --help                このヘルプを表示
EOF
}

SESSION=""
SESSION_DIR=""
FROM_DATE=""
TO_DATE=""
MIN_SIZE="500000"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)     SESSION="$2"; shift 2 ;;
    --session-dir) SESSION_DIR="$2"; shift 2 ;;
    --from)        FROM_DATE="$2"; shift 2 ;;
    --to)          TO_DATE="$2"; shift 2 ;;
    --min-size)    MIN_SIZE="$2"; shift 2 ;;
    --out)         OUT="$2"; shift 2 ;;
    --help|-h)     usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$SESSION" ] && [ -z "$SESSION_DIR" ]; then
  echo "ERROR: --session or --session-dir is required" >&2
  usage >&2
  exit 1
fi
if [ -n "$SESSION" ] && [ ! -f "$SESSION" ]; then
  echo "ERROR: session log not found: $SESSION" >&2
  exit 1
fi
if [ -n "$SESSION_DIR" ] && [ ! -d "$SESSION_DIR" ]; then
  echo "ERROR: session dir not found: $SESSION_DIR" >&2
  exit 1
fi

python3 - "$SESSION" "$SESSION_DIR" "$FROM_DATE" "$TO_DATE" "$MIN_SIZE" "$OUT" <<'PY'
import json, re, sys, os, glob, datetime

session_path = sys.argv[1] or None
session_dir  = sys.argv[2] or None
from_date    = sys.argv[3] or None
to_date      = sys.argv[4] or None
min_size     = int(sys.argv[5] or 500000)
out_path     = sys.argv[6] or None

# Markdown 表 row pattern
#   | CRITICAL | <file_line> | <col3> | <col4?> | ...
ROW_RE = re.compile(
    r'^\|\s*(CRITICAL|HIGH|MEDIUM|LOW)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|',
    re.MULTILINE,
)
# Cycle 推定
CYCLE_RE = re.compile(r'(?:Cycle|サイクル|cycle)\s*(\d+)', re.IGNORECASE)
# Documentation example heuristic
DOC_EXAMPLE_PATHS = ('docs/foo.md', 'src/foo.ts', 'docs/example.md')

# severity word が table header row の場合は除外
HEADER_EXCLUDE_RE = re.compile(r'^\|\s*(Severity|severity|重大度|レビュアー|reviewer)', re.MULTILINE)

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

results = []
seen_raw = set()

# Build session path list
if session_path:
    session_paths = [session_path]
else:
    candidates = sorted(glob.glob(os.path.join(session_dir, "*.jsonl")), key=os.path.getmtime)
    session_paths = []
    start_ts = datetime.datetime.fromisoformat(from_date).timestamp() if from_date else 0
    end_ts = datetime.datetime.fromisoformat(to_date).timestamp() if to_date else 1e12
    for p in candidates:
        if os.path.getsize(p) < min_size:
            continue
        mt = os.path.getmtime(p)
        if mt < start_ts or mt >= end_ts:
            continue
        session_paths.append(p)
    print(f"# scanning {len(session_paths)} session logs in {session_dir}", file=sys.stderr)

current_cycle = 0

def process_session(path):
    global current_cycle
    current_cycle = 0
    session_basename = os.path.basename(path)
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            if o.get("type") not in ("user", "assistant"):
                continue
            texts = collect_text(o)
            for text in texts:
                if not isinstance(text, str) or '|' not in text:
                    continue
                # cycle 推定
                cycle_matches = CYCLE_RE.findall(text)
                if cycle_matches:
                    try:
                        current_cycle = int(cycle_matches[-1])
                    except ValueError:
                        pass
                for m in ROW_RE.finditer(text):
                    severity = m.group(1)
                    file_line = m.group(2).strip()
                    col3 = m.group(3).strip()
                    col4 = m.group(4).strip()

                    if any(p in file_line for p in DOC_EXAMPLE_PATHS):
                        continue
                    if severity.lower() in ("severity",):
                        continue
                    # exclude pure count rows like `| CRITICAL | 1 | desc |`
                    if re.match(r'^\d+$', file_line):
                        continue
                    # exclude header `| CRITICAL | HIGH | MEDIUM | LOW |`
                    if file_line.upper() in ("CRITICAL", "HIGH", "MEDIUM", "LOW"):
                        continue

                    raw_row = m.group(0)
                    dedupe_key = (severity, file_line[:120], col3[:100])
                    if dedupe_key in seen_raw:
                        continue
                    seen_raw.add(dedupe_key)

                    reviewer = ""
                    description = ""
                    if re.search(r'(reviewer|hunter|analyzer|critic|engineer|writer|quality)',
                                 col3, re.IGNORECASE):
                        reviewer = col3
                        description = col4
                    else:
                        description = col3
                        reviewer = ""

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

for sp in session_paths:
    process_session(sp)

# 出力
out_fp = open(out_path, "w", encoding="utf-8") if out_path else sys.stdout
for r in results:
    out_fp.write(json.dumps(r, ensure_ascii=False) + "\n")
if out_path:
    out_fp.close()
    print(f"wrote {len(results)} findings to {out_path}", file=sys.stderr)
else:
    print(f"# total: {len(results)} findings", file=sys.stderr)

# 集計サマリーを stderr に
from collections import Counter
sev_counts = Counter(r["severity"] for r in results)
cycle_counts = Counter(r["cycle"] for r in results)
print(f"# by severity: {dict(sev_counts)}", file=sys.stderr)
print(f"# by cycle: {dict(sorted(cycle_counts.items()))}", file=sys.stderr)
PY
