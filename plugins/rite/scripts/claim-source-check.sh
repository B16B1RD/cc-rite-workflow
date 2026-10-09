#!/usr/bin/env bash
# rite workflow - 主張と出典の照合 (claim-source) の機械検査
#
# Responsibility: PR 自身が書いた「主張 + 出典」の組を全件、決定論的に扱う。
#   extract — 文書ファイルの追加行と PR 本文から、出典トークンを含む行を CLAIM-N として全件抜き出す
#   facts   — 抜き出した各出典の確定事実を集める (Issue を閉じた PR の変更ファイル、PR の変更ファイル、
#             path:line の HEAD 上の実在と行内容、コミットの変更ファイル、文書の節本文)
#   table   — 検証 agent の `### 主張と出典の照合` 表を、extract の行集合と 1 対 1 で照合する。
#             判定は 支持 (観点は実在・内容・含意の 3 つすべて) / 不支持 (根拠に Verification: アンカー) /
#             判定不能 (根拠に Measurement-Blocked: アンカー) / 主張なし (例文・fixture など PR の主張でない行。観点は -)
# 含意の判定 (出典が主張を裏づけるか) は検証 agent が行う。本 helper は抽出の網羅と表の全件性を
# 機械で保証し、抜き取りの確認を「照合した」と報告できなくする強制層である。入力は書き換えない。
#
# Called from:
#   - skills/pr-review/SKILL.md の「主張と出典の照合」節 (extract / facts / table)
#   - skills/issue-implement/SKILL.md の commit 前照合 (extract / facts / table。PR 本文なし)
#
# Usage:
#   claim-source-check.sh extract --base REF --out PATH [--pr NUMBER --repo OWNER/REPO]
#   claim-source-check.sh facts --rows PATH --repo OWNER/REPO --out PATH
#   claim-source-check.sh table --rows PATH --input PATH
#
# 抽出の規則 (extract):
#   - 対象は merge-base(REF, HEAD) から作業ツリーまでの追加行 (未 commit・未追跡を含む) のうち
#     文書ファイル (*.md *.mdx *.txt *.rst *.adoc) と、--pr 指定時の PR 本文の各行
#   - 出典トークン: Issue/PR 参照 (`#N` / `owner/repo#N` / `Issue#N` / `PR#N`)、`path:line`、
#     コミット SHA (7-40 桁の 16 進で数字と英字を両方含む)、節 (`§S` / `N 節` / `第 N 節` /
#     `「見出し」節` / `Section N`)。`x.md#anchor` 形式のリンクは道案内であり出典トークンにしない
#   - PR 本文の行は、出典トークンが無くても「全件照合した」「確認済み」などの検証主張を含めば行にする
#   - Issue/PR 参照の文法は hooks/scripts/number-reference-check.sh と別に持つ。あちらは rite 自身の
#     永続成果物で 3-4 桁の番号を禁じる検査、こちらは利用先の文書の全桁の参照を拾う抽出で、目的と範囲が違う
#
# stdout contract:
#   extract — [CONTEXT] CLAIM_SOURCE_ROWS=N; ids=CLAIM-1..CLAIM-N (N=0 なら ids=none)
#   facts   — [CONTEXT] CLAIM_SOURCE_FACTS=ok; refs=K; errors=E
#   table   — [CONTEXT] CLAIM_SOURCE_TABLE=ok; total=N; judged=M; supported=a; unsupported=b;
#             undetermined=c; no_claim=d; existence=x; content=y; implication=z
#             CLAIM_SOURCE_ROWS_JSON=[{id, origin, text, verdict, evidence}] (不支持と判定不能の行)
#   失敗時   — [CONTEXT] CLAIM_SOURCE_CHECK_FAILED=1; mode={mode}; reason={reason}; detail={detail}
#
# Reason SoT:
#   extract: base_unresolved / git_failed / pr_body_fetch_failed
#   facts:   rows_invalid
#   table:   rows_invalid / input_missing / table_missing / table_malformed / id_set_mismatch /
#            verdict_invalid / perspective_invalid / evidence_missing / anchor_missing
#
# facts の gh / git 失敗は止めずに、その出典の事実へ error を記録する (errors=E に数える)。
# error の出典を含む行は、検証 agent が判定不能 (Measurement-Blocked:) として表に出す。
#
# Exit codes: 0 = 成功, 1 = 検査失敗 (CLAIM_SOURCE_CHECK_FAILED emit 済み), 2 = invocation error
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo 'ERROR: claim-source-check: python3 is required' >&2
  exit 2
fi

exec python3 - "$@" <<'PY'
import json
import os
import re
import subprocess
import sys

DOC_PATHSPECS = ["*.md", "*.mdx", "*.txt", "*.rst", "*.adoc"]
MAX_SECTION_LINES = 200

ISSUE_RE = re.compile(
    r"(?:(?<![0-9A-Za-z_&/#.\-])|(?<=[Ii]ssue)|(?<=PR))"
    r"((?:[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)?#\d+)(?![\w\-])",
    re.ASCII,
)
FILE_LINE_RE = re.compile(
    r"(?<![\w./\-])((?:[\w.\-]+/)*[\w.\-]+\.[A-Za-z0-9]+:\d+(?:-\d+)?)(?![\w/])",
    re.ASCII,
)
SHA_RE = re.compile(r"(?<![\w#.\-])([0-9a-f]{7,40})(?![\w\-]|\.\w)", re.ASCII)
SECTION_RE = re.compile(
    r"(§\s*[\w.\-]+|第\s*\d+(?:\.\d+)*\s*節|\d+(?:\.\d+)*\s*節|「[^」\n]+」\s*(?:の)?節|[Ss]ection\s+\d+(?:\.\d+)*)",
    re.ASCII,
)
VERIFICATION_CLAIM_RE = re.compile(
    r"((全件|すべて|全て|全部).{0,20}(照合|確認|検証|チェック)|(照合|確認|検証)済み|"
    r"\b(verified|checked|cross-checked)\s+all\b)",
    re.IGNORECASE,
)
DOC_PATH_RE = re.compile(r"(?<![\w./\-])((?:[\w.\-]+/)*[\w.\-]+\.(?:md|mdx|rst|adoc|txt))(?![\w/:#])", re.ASCII)
VERDICTS = ("支持", "不支持", "判定不能", "主張なし")
PERSPECTIVES = ("実在", "内容", "含意")
VERIFICATION_ANCHOR_RE = re.compile(r"Verification:\s*repro\s+[^=]+?=>\s*\S")
BLOCKED_ANCHOR_RE = re.compile(r"Measurement-Blocked:\s*\S[^=]*?=>\s*\S")


def fail(mode, reason, detail=""):
    detail = detail.replace("\n", " ")[:300]
    print(f"[CONTEXT] CLAIM_SOURCE_CHECK_FAILED=1; mode={mode}; reason={reason}; detail={detail}")
    sys.exit(1)


def usage_error(message):
    print(f"ERROR: claim-source-check: {message}", file=sys.stderr)
    print(
        "Usage: claim-source-check.sh extract --base REF --out PATH [--pr NUMBER --repo OWNER/REPO]\n"
        "       claim-source-check.sh facts --rows PATH --repo OWNER/REPO --out PATH\n"
        "       claim-source-check.sh table --rows PATH --input PATH",
        file=sys.stderr,
    )
    sys.exit(2)


def parse_args(argv, allowed):
    opts = {}
    i = 0
    while i < len(argv):
        key = argv[i]
        if key not in allowed or i + 1 >= len(argv) or argv[i + 1] == "":
            usage_error(f"unknown or empty argument: {key}")
        opts[key[2:]] = argv[i + 1]
        i += 2
    return opts


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr.strip()


def tokens_of(text):
    refs = []
    seen = set()

    def add(kind, token):
        token = token.strip()
        if (kind, token) not in seen:
            seen.add((kind, token))
            refs.append({"kind": kind, "token": token})

    for m in ISSUE_RE.finditer(text):
        add("issue", m.group(1))
    for m in FILE_LINE_RE.finditer(text):
        add("file_line", m.group(1))
    for m in SHA_RE.finditer(text):
        value = m.group(1)
        if re.search(r"\d", value) and re.search(r"[a-f]", value):
            add("sha", value)
    for m in SECTION_RE.finditer(text):
        add("section", m.group(1))
    return refs


def added_doc_lines(merge_base):
    rc, out, err = run(
        ["git", "diff", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color",
         "--unified=0", merge_base, "--", *DOC_PATHSPECS]
    )
    if rc != 0:
        fail("extract", "git_failed", err)
    lines = []
    path = None
    lineno = 0
    for raw in out.split("\n"):
        if raw.startswith("+++ "):
            target = raw[4:]
            path = target[2:] if target.startswith("b/") else None
            continue
        if raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
            lineno = int(m.group(1)) if m else 0
            continue
        if path and raw.startswith("+") and not raw.startswith("+++"):
            lines.append((f"{path}:{lineno}", raw[1:]))
            lineno += 1
    rc, out, err = run(["git", "ls-files", "--others", "--exclude-standard", "--", *DOC_PATHSPECS])
    if rc != 0:
        fail("extract", "git_failed", err)
    for untracked in sorted(p for p in out.split("\n") if p):
        try:
            with open(untracked, encoding="utf-8", errors="replace") as fh:
                for n, text in enumerate(fh.read().split("\n"), start=1):
                    lines.append((f"{untracked}:{n}", text))
        except OSError as exc:
            fail("extract", "git_failed", f"{untracked}: {exc}")
    return lines


def cmd_extract(argv):
    opts = parse_args(argv, ("--base", "--out", "--pr", "--repo"))
    if "base" not in opts or "out" not in opts:
        usage_error("extract requires --base and --out")
    if ("pr" in opts) != ("repo" in opts):
        usage_error("--pr and --repo go together")
    rc, _, err = run(["git", "rev-parse", "--verify", "--quiet", opts["base"] + "^{commit}"])
    if rc != 0:
        fail("extract", "base_unresolved", opts["base"])
    rc, merge_base, err = run(["git", "merge-base", opts["base"], "HEAD"])
    if rc != 0:
        fail("extract", "git_failed", err)
    merge_base = merge_base.strip()

    rows = []
    for origin, text in added_doc_lines(merge_base):
        refs = tokens_of(text)
        if refs:
            rows.append({"origin": origin, "source": "diff", "text": text.strip(), "refs": refs})
    if "pr" in opts:
        rc, body, err = run(["gh", "pr", "view", opts["pr"], "-R", opts["repo"], "--json", "body", "--jq", ".body"])
        if rc != 0:
            fail("extract", "pr_body_fetch_failed", err)
        for n, text in enumerate(body.split("\n"), start=1):
            refs = tokens_of(text)
            claim = bool(VERIFICATION_CLAIM_RE.search(text))
            if refs or claim:
                row = {"origin": f"PR本文:{n}", "source": "pr_body", "text": text.strip(), "refs": refs}
                if claim:
                    row["verification_claim"] = True
                rows.append(row)
    for i, row in enumerate(rows, start=1):
        row["id"] = f"CLAIM-{i}"
    with open(opts["out"], "w", encoding="utf-8") as fh:
        json.dump({"merge_base": merge_base, "rows": rows}, fh, ensure_ascii=False, indent=1)
    ids = ",".join(r["id"] for r in rows) if rows else "none"
    print(f"[CONTEXT] CLAIM_SOURCE_ROWS={len(rows)}; ids={ids}")


def load_rows(mode, path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        rows = data["rows"]
        ids = [r["id"] for r in rows]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        fail(mode, "rows_invalid", f"{path}: {exc}")
    if len(set(ids)) != len(ids):
        fail(mode, "rows_invalid", "duplicate row id")
    return rows


def repo_root():
    rc, out, _ = run(["git", "rev-parse", "--show-toplevel"])
    return out.strip() if rc == 0 else os.getcwd()


def resolve_path(root, path):
    if os.path.isfile(os.path.join(root, path)):
        return [path]
    rc, out, _ = run(["git", "-C", root, "ls-files"])
    if rc != 0:
        return []
    suffix = "/" + path.lstrip("./")
    return [p for p in out.split("\n") if p and p.endswith(suffix)]


def read_lines(root, path):
    with open(os.path.join(root, path), encoding="utf-8", errors="replace") as fh:
        return fh.read().split("\n")


def fact_issue(token, default_repo):
    repo, _, number = token.partition("#")
    repo = repo or default_repo
    owner, _, name = repo.partition("/")
    query = (
        "query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issueOrPullRequest(number:$n){"
        "__typename ... on Issue{state title closedByPullRequestsReferences(first:20,includeClosedPrs:true)"
        "{nodes{number state title files(first:100){nodes{path}}}}}"
        " ... on PullRequest{state title merged files(first:100){nodes{path}}}}}}"
    )
    cmd = ["gh", "api", "graphql", "-f", f"query={query}", "-f", f"o={owner}", "-f", f"r={name}", "-F", f"n={number}"]
    rc, out, err = run(cmd)
    if rc != 0:
        return {"error": err or f"gh exited {rc}", "command": "gh api graphql issueOrPullRequest"}
    try:
        node = json.loads(out)["data"]["repository"]["issueOrPullRequest"]
    except (ValueError, KeyError, TypeError) as exc:
        return {"error": f"unexpected gh output: {exc}", "command": "gh api graphql issueOrPullRequest"}
    if node is None:
        return {"exists": False, "repo": repo, "number": int(number)}
    fact = {"exists": True, "repo": repo, "number": int(number), "state": node.get("state"), "title": node.get("title")}
    if node.get("__typename") == "PullRequest":
        fact["type"] = "pull_request"
        fact["merged"] = node.get("merged")
        fact["files"] = [f["path"] for f in node["files"]["nodes"]]
    else:
        fact["type"] = "issue"
        fact["closing_prs"] = [
            {"number": p["number"], "state": p["state"], "title": p["title"],
             "files": [f["path"] for f in p["files"]["nodes"]]}
            for p in node["closedByPullRequestsReferences"]["nodes"]
        ]
    return fact


def fact_file_line(root, token):
    path, _, span = token.rpartition(":")
    start, _, end = span.partition("-")
    start = int(start)
    end = int(end) if end else start
    candidates = resolve_path(root, path)
    if not candidates:
        return {"exists": False, "path": path}
    found = []
    for cand in candidates:
        lines = read_lines(root, cand)
        total = len(lines) - (1 if lines and lines[-1] == "" else 0)
        entry = {"path": cand, "line_count": total, "in_range": start <= total and end <= total}
        if entry["in_range"]:
            entry["lines"] = lines[start - 1:min(end, start + 19)]
        found.append(entry)
    return {"exists": True, "candidates": found}


def fact_sha(token, default_repo):
    rc, _, _ = run(["git", "cat-file", "-e", token + "^{commit}"])
    if rc == 0:
        rc, subject, err = run(["git", "show", "-s", "--format=%H%x09%s", token])
        rc2, files, err2 = run(["git", "show", "--name-only", "--format=", token])
        if rc != 0 or rc2 != 0:
            return {"error": err or err2, "command": f"git show {token}"}
        full, _, title = subject.strip().partition("\t")
        return {"exists": True, "where": "local", "sha": full, "subject": title,
                "files": [f for f in files.split("\n") if f]}
    rc, out, err = run(["gh", "api", f"repos/{default_repo}/commits/{token}"])
    if rc != 0:
        if "No commit found" in err or "HTTP 422" in err or "HTTP 404" in err:
            return {"exists": False, "sha": token}
        return {"error": err or f"gh exited {rc}", "command": f"gh api repos/{default_repo}/commits/{token}"}
    try:
        data = json.loads(out)
        return {"exists": True, "where": "github", "sha": data["sha"],
                "subject": data["commit"]["message"].split("\n")[0],
                "files": [f["filename"] for f in data.get("files", [])]}
    except (ValueError, KeyError, TypeError) as exc:
        return {"error": f"unexpected gh output: {exc}", "command": f"gh api repos/{default_repo}/commits/{token}"}


def section_key(token):
    m = re.search(r"「([^」]+)」", token)
    if m:
        return m.group(1)
    m = re.search(r"\d+(?:\.\d+)*", token)
    if m:
        return m.group(0)
    return re.sub(r"^§\s*", "", token)


def fact_sections(root, row):
    sections = [r["token"] for r in row["refs"] if r["kind"] == "section"]
    if not sections:
        return None
    docs = [m.group(1) for m in DOC_PATH_RE.finditer(row["text"])]
    if not docs:
        return [{"section": s, "doc": None} for s in sections]
    result = []
    for s in sections:
        key = section_key(s)
        for doc in docs:
            candidates = resolve_path(root, doc)
            if not candidates:
                result.append({"section": s, "doc": doc, "doc_exists": False})
                continue
            for cand in candidates:
                lines = read_lines(root, cand)
                body = None
                for i, line in enumerate(lines):
                    m = re.match(r"^(#{1,6})\s+(.*)$", line)
                    if m and key in m.group(2):
                        level = len(m.group(1))
                        body = [line]
                        for nxt in lines[i + 1:]:
                            h = re.match(r"^(#{1,6})\s", nxt)
                            if h and len(h.group(1)) <= level:
                                break
                            body.append(nxt)
                        break
                entry = {"section": s, "doc": cand, "doc_exists": True, "found": body is not None}
                if body is not None:
                    entry["truncated"] = len(body) > MAX_SECTION_LINES
                    entry["body"] = body[:MAX_SECTION_LINES]
                result.append(entry)
    return result


def cmd_facts(argv):
    opts = parse_args(argv, ("--rows", "--repo", "--out"))
    if not all(k in opts for k in ("rows", "repo", "out")):
        usage_error("facts requires --rows, --repo and --out")
    rows = load_rows("facts", opts["rows"])
    root = repo_root()
    refs = {}
    sections = {}
    for row in rows:
        for ref in row["refs"]:
            key = f'{ref["kind"]}:{ref["token"]}'
            if key in refs or ref["kind"] == "section":
                continue
            if ref["kind"] == "issue":
                refs[key] = fact_issue(ref["token"], opts["repo"])
            elif ref["kind"] == "file_line":
                refs[key] = fact_file_line(root, ref["token"])
            elif ref["kind"] == "sha":
                refs[key] = fact_sha(ref["token"], opts["repo"])
        found = fact_sections(root, row)
        if found is not None:
            sections[row["id"]] = found
    errors = [k for k, v in refs.items() if "error" in v]
    for key in errors:
        print(f"WARNING: claim-source facts: {key}: {refs[key]['error']}", file=sys.stderr)
    with open(opts["out"], "w", encoding="utf-8") as fh:
        json.dump({"refs": refs, "sections": sections}, fh, ensure_ascii=False, indent=1)
    print(f"[CONTEXT] CLAIM_SOURCE_FACTS=ok; refs={len(refs)}; errors={len(errors)}")


def split_cells(line):
    body = line.strip()
    if not (body.startswith("|") and body.endswith("|")):
        return None
    return [c.strip().strip("　").strip() for c in body[1:-1].split("|")]


def cmd_table(argv):
    opts = parse_args(argv, ("--rows", "--input"))
    if not all(k in opts for k in ("rows", "input")):
        usage_error("table requires --rows and --input")
    rows = load_rows("table", opts["rows"])
    try:
        with open(opts["input"], encoding="utf-8") as fh:
            lines = fh.read().replace("\r\n", "\n").split("\n")
    except OSError as exc:
        fail("table", "input_missing", str(exc))
    start = next((i for i, l in enumerate(lines) if re.match(r"^###\s*主張と出典の照合\s*$", l)), None)
    if start is None:
        fail("table", "table_missing", "### 主張と出典の照合")
    block = []
    for line in lines[start + 1:]:
        if line.startswith("#"):
            break
        if line.strip():
            block.append(line)
    if len(block) < 2 or split_cells(block[0]) != ["ID", "判定", "観点", "根拠"] \
            or not re.match(r"^\|(\s*:?-+:?\s*\|){4}\s*$", block[1].strip()):
        fail("table", "table_malformed", "header must be | ID | 判定 | 観点 | 根拠 |")
    judged = []
    for line in block[2:]:
        cells = split_cells(line)
        if cells is None or len(cells) != 4:
            fail("table", "table_malformed", line)
        judged.append(cells)
    expected = [r["id"] for r in rows]
    got = [c[0] for c in judged]
    missing = [i for i in expected if i not in got]
    extra = [i for i in got if i not in expected]
    dup = sorted({i for i in got if got.count(i) > 1})
    if missing or extra or dup:
        fail("table", "id_set_mismatch", f"missing={','.join(missing) or '-'} extra={','.join(extra) or '-'} duplicate={','.join(dup) or '-'}")
    counts = {v: 0 for v in VERDICTS}
    seen = {p: 0 for p in PERSPECTIVES}
    by_id = {r["id"]: r for r in rows}
    reported = []
    for cid, verdict, perspective, evidence in judged:
        if verdict not in VERDICTS:
            fail("table", "verdict_invalid", f"{cid}: {verdict}")
        parts = [p.strip() for p in re.split(r"[・/、,]", perspective) if p.strip()]
        if verdict == "主張なし":
            if perspective != "-":
                fail("table", "perspective_invalid", f"{cid}: 主張なし takes - as 観点")
            parts = []
        elif not parts or any(p not in PERSPECTIVES for p in parts) or len(set(parts)) != len(parts):
            fail("table", "perspective_invalid", f"{cid}: {perspective}")
        if verdict == "支持" and set(parts) != set(PERSPECTIVES):
            fail("table", "perspective_invalid", f"{cid}: 支持 requires 実在・内容・含意")
        if not evidence:
            fail("table", "evidence_missing", cid)
        if verdict == "不支持" and not VERIFICATION_ANCHOR_RE.search(evidence):
            fail("table", "anchor_missing", f"{cid}: 不支持 needs Verification: repro <cmd> => <observed>")
        if verdict == "判定不能" and not BLOCKED_ANCHOR_RE.search(evidence):
            fail("table", "anchor_missing", f"{cid}: 判定不能 needs Measurement-Blocked: <cmd> => <observed>")
        counts[verdict] += 1
        for p in parts:
            seen[p] += 1
        if verdict in ("不支持", "判定不能"):
            row = by_id[cid]
            reported.append({"id": cid, "origin": row["origin"], "text": row["text"],
                             "verdict": verdict, "evidence": evidence})
    total = len(rows)
    print(
        f"[CONTEXT] CLAIM_SOURCE_TABLE=ok; total={total}; judged={counts['支持'] + counts['不支持'] + counts['主張なし']}; "
        f"supported={counts['支持']}; unsupported={counts['不支持']}; undetermined={counts['判定不能']}; no_claim={counts['主張なし']}; "
        f"existence={seen['実在']}; content={seen['内容']}; implication={seen['含意']}"
    )
    print("CLAIM_SOURCE_ROWS_JSON=" + json.dumps(reported, ensure_ascii=False))


def main():
    if len(sys.argv) < 2:
        usage_error("missing subcommand")
    mode, rest = sys.argv[1], sys.argv[2:]
    handlers = {"extract": cmd_extract, "facts": cmd_facts, "table": cmd_table}
    if mode not in handlers:
        usage_error(f"unknown subcommand: {mode}")
    handlers[mode](rest)


main()
PY
