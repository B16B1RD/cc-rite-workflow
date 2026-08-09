#!/usr/bin/env bash
# comment-journal-check.sh
#
# Detect high-confidence "journal" narration patterns and descriptive
# Issue/PR number references in plugins/rite/**/*.{sh,md}, repo-root docs/**/*.md,
# and .rite/wiki/**/*.md (ドキュメント散文・Wiki ページまでスコープ拡張). These are
# mechanical comment violations that accumulate when authors paste review-cycle /
# fix-history wording, or "詳細は #N 参照" 系の説明的番号参照, into persistent
# artifacts (code / docs prose / Wiki) instead of into commit messages or PR
# descriptions (= 番号の正しい受け皿). 廃止判定ルール (comment-best-practices.md)
# に従い、説明的参照のみを検出し、TODO/FIXME 追跡番号 (前方ポインタ=維持) と
# ファイル名アンカー (xxx.test.sh 等、番号ではない) は検出から除外する。
#
# `.rite/wiki/**` に届く条件 (wiki.branch_strategy 依存):
#   same_branch     Wiki の実体が dev ブランチのワークツリーにあるため、pages / index.md /
#                   log.md / raw のすべてに到達する。
#   separate_branch Wiki ページ (pages/ / index.md) の実体は wiki ブランチにあり到達しない。
#                   ただし dev checkout の `.rite/wiki/raw/` には ingest 待ちの Raw Source が
#                   一時的に実在する (wiki-ingest-trigger が書き、wiki-ingest-commit が wiki
#                   ブランチへ移すまでの窓) ため、その間は raw 由来の検出が出うる。
#                   ページ分の走査は `/rite:wiki-lint` ステップ 7.5
#                   (`wiki-lint-descriptive-refs.sh`) が担う — そちらは `git show` で
#                   wiki ブランチを直接読むため実体に届く。ただし 7.5 は log.md / raw/ /
#                   SCHEMA.md を意図的に除外するため、両検出器の対象集合は一致しない。
#   ここでは wiki ブランチを読みに行かない。本スクリプトはワークツリー上のファイルを
#   走査する CI 向けの高速レイヤであり、ブランチ解決を持ち込むと wiki-lint と検出責務が
#   二重化する。separate_branch で Wiki ページ分の指摘が 0 件でも「Wiki が clean」ではなく
#   「本スクリプトの走査範囲外」である点に注意する。
#
# Layered defense:
#   This script is the fast-fail layer below the LLM reviewers. The reviewers
#   focus on WHY > WHAT semantic judgments; mechanical 100%-confidence patterns
#   are killed here before they reach the reviewer queue. Operationally invoked
#   from /rite:lint (manual). PR review integration is intentionally out of
#   scope (採択方針: CI のみ運用).
#
# Detected patterns (4 regexes scanned in a single while-match awk loop, so
# multiple triggers on the same line are all reported — same multi-match
# discipline as bang-backtick-check.sh):
#
#   P1: verified-review cycle N
#       regex: verified-review cycle [0-9]+
#       semantics: leftover narration referring to a verified-review iteration.
#                  The iteration number drifts as soon as cycles add up; the
#                  reference becomes wrong-but-confident over time.
#
#   P2: 旧実装(は|では) - "the old implementation (was|did)"
#       regex: 旧実装(は|では)
#       semantics: comments that explain what the previous version did. The
#                  WHAT of removed code belongs in commit/PR history, not in
#                  the tree where it ages out of sync with the current code.
#
#   P3: PR #N cycle N fix
#       regex: PR #[0-9]+ cycle [0-9]+ fix
#       semantics: comments tagging a fix to a specific PR review cycle. PR
#                  numbers carry no meaning at read time; the cycle number
#                  is tied to a workflow run that no longer exists.
#
#   P4: cycle N F-N で(導入|確立|集約) - "introduced/established/consolidated in cycle N F-N"
#       regex: cycle [0-9]+ F-[0-9]+ で(導入|確立|集約)
#       semantics: comments referencing review-finding identifiers (F-NN).
#                  Finding IDs are scoped to one review run; the reference
#                  decays the moment that review is closed.
#
#   rationale (検出設計の根拠・除外の実測値):
#     skills/wiki-lint/references/descriptive-refs-rationale.md
#
#   P5: descriptive Issue/PR reference (keyword + number, SoT 禁止句リスト由来)
#       regex: (^|[^A-Za-z])([Ii]ssues?|[Pp][Rr]s?|[Rr]efs?|[Ss]ee|…) *#[0-9]+([^0-9]|$)
#       語彙は大小文字を対称に受ける (`issue #12` / `pr #3` も説明的参照)。左側の
#       `(^|[^A-Za-z])` は `prefs #12` / `hrefs #3` の語尾が `refs` に一致するのを防ぐ。
#       semantics: "See #N" / "Closes #N" / "(refs #N)" / 裸の "PR #N は…" 等、Why の
#                  代替として貼られた説明的参照。番号を辿っても背景は得られないため、
#                  Why を散文で残すべき。
#                  キーワード列は「語彙」であって表層形の列挙ではない: 括弧付き
#                  "(refs #N)"・"see PR #N"・裸の "PR #N" はすべて「キーワード、任意の
#                  空白、番号」に畳まれるため 1 規則で足りる。新しい形に対応するときは
#                  語彙に 1 語足すのであって、分岐を増やさない。
#                  裸の `#N` (キーワードなし単独形) は意図的に検出しない — 正当な文脈が
#                  多すぎて機械的に切り分けられず、対応するには除外を過大に広げる必要が
#                  生じるため。
#
#   P6: descriptive Issue/PR reference (keyword-less Japanese, SoT 禁止句リスト由来)
#       regex: #[0-9]+ ?で(別途)?対応|詳細は ?#[0-9]+([^0-9]|$)
#       semantics: 「#N で対応」「#N で別途対応」「詳細は #N」。参照キーワードを持たない
#                  ため P5 へは畳めない 2 構文を 1 つの alternation にまとめる。
#       走査順: P6 を P5 より先に実行する。「PR #N で別途対応」は両規則に当たるため、
#       P6 で報告した接尾構文を P5 の走査行からマスクして同一位置の二重報告を断つ。
#
# Word boundary:
#   番号一致は `([^0-9]|$)` で終える (`#204` が `#2047` の途中で止まらない)。貪欲な
#   `[0-9]+` が既に数字列の末尾まで到達するため実効は同じだが、明示することで将来
#   番号パターンを狭めたときに prefix 衝突が無言で再発するのを防ぐ契約にする。
#   NOTE: ここは文字クラスであって `\b` にしてはならない — gawk は `\b` をバックスペース
#   として読むため `/#[0-9]+\b/` は永久に一致せず、検出器が無言で沈黙する。
#
# Whitelist (line-level skip):
#
#   Lines containing any of the following markers are skipped entirely:
#     - <!-- example: ...    (markdown HTML-comment example marker)
#     - # example: ...        (shell / Python comment example marker)
#     - // example: ...       (TypeScript / JavaScript comment example marker)
#     - TODO / FIXME          (追跡番号は前方ポインタ=維持。廃止判定ルールで検出除外)
#
#   ファイル名アンカー (xxx.test.sh 等) は #N を含まないため P5/P6 に該当せず自然に除外される。
#
# Descriptive-reference exclusions (P5 / P6 のみに適用。P1-P4 の挙動は不変):
#
#   X1 code fence      — ``` で囲まれた範囲。コマンドや regex を逐語引用する場所であり、
#                        そこにある番号は主張ではなく literal。
#   X2 inline code span— `` `refs #204` `` 等。X1 と同じ理由。span は削除ではなく `_` へ
#                        置換する: 削除するとキーワードと後続番号が隣接して偽の一致を
#                        作り出すため。
#   X3 `## ソース` 節   — `.rite/wiki/` 配下の Wiki ページに限定。provenance リンクラベル
#                        (`- [PR #N review results](...)`)
#                        は出所の監査証跡として維持対象。走査すると当該節を持つ全ページが
#                        誤検出になる。`docs/` / `plugins/rite/` の同名見出しは除外を開始せず、
#                        以降の参照を検出し続ける。Wiki 内の除外は**節スコープ**
#                        (見出しから次の `##` 見出しの手前まで)
#                        で、ファイル末尾までではない。判定はフェンス状態の更新後に行うため、
#                        コードフェンス内に引用された `## ソース` では発火しない。見出しは
#                        `## ソース（追記分）` 等の接尾辞を許容する (wiki-ingest の生成形)。
#
#   いずれの除外もその範囲内では既知アンチパターンの再発が見えなくなる。P1-P4 に広げないのは
#   その盲点を説明的参照の検出に限定するため (既存 31 件の検出結果を変えない)。
#
#   Self-exclusion: this script's own regex literals would otherwise match.
#   When --all is requested the find walk skips (1) this script's own path,
#   (2) the SoT 本体 comment-best-practices.md, (3) parity test
#   comment-best-practices-parity.test.sh, and (4) 検出器自身の test 2 本
#   (comment-journal-check.test.sh / wiki-lint-descriptive-refs.test.sh) —
#   (2)-(4) は禁止句を「定義・例示」する性質上、走査すると Bad 例の語句 (test では
#   fixture 文字列) が本物の違反として誤検出されるため除外する。
#
# Future extension: rite-config.yml workflow.lint.comment_journal.whitelist
# can list extra prefix tokens. Not implemented in this revision; the prefix
# markers above already cover SoT bad-example sections when the author wraps
# the example with one of the three markers.
#
# Usage:
#   comment-journal-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = pattern detected, 2 = invocation error.

set -euo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: comment-journal-check.sh [options]

Options:
  --all              Scan plugins/rite/**/*.sh and plugins/rite/**/*.md
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
  -h, --help         Show this help

Detected patterns:
  P1  verified-review cycle N
  P2  旧実装(は|では)
  P3  PR #N cycle N fix
  P4  cycle N F-N で(導入|確立|集約)
  P5  descriptive Issue/PR ref (Issue/PR/Refs/See/Related to/Closes/Fixes/Resolves #N)
  P6  descriptive Issue/PR ref ja (#N で(別途)対応 / 詳細は #N)

Whitelist markers (line-level skip):
  <!-- example:    /    # example:    /    // example:    /    TODO / FIXME

Descriptive-ref exclusions (P5/P6 only): code fence, inline code span, "## ソース" section

Scan scope (--all):
  plugins/rite/**/*.{sh,md}, docs/**/*.md, .rite/wiki/**/*.md
  (self-exclude: this script, comment-best-practices.md SoT, parity test,
   検出器自身の test 2 本: comment-journal-check.test.sh / wiki-lint-descriptive-refs.test.sh)
  .rite/wiki/ の Wiki ページ (pages/ / index.md) に到達するのは same_branch 構成のみ。
  separate_branch では wiki ブランチにあるため走査しないが、ingest 待ちの Raw Source が
  .rite/wiki/raw/ に一時的に実在する窓では raw 由来の検出が出うる
  (ページ分の走査は /rite:wiki-lint ステップ 7.5 が担当。ただし 7.5 は raw/ を除外する)。

Exit codes:
  0  No journal narration detected
  1  Pattern detected
  2  Invocation error
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  base="plugins/rite"
  if [ ! -d "$base" ]; then
    echo "ERROR: --all requested but $base does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  # 説明的番号参照は永続成果物全般 (in-source コメント + ドキュメント散文 + Wiki ページ) が対象であり、
  # plugins/rite に加えて repo-root の docs/ と .rite/wiki/ も走査する。後二者は存在するときのみ加える
  # (marketplace install や Wiki 無効プロジェクトでは plugins/rite のみで走査が成立する)。
  # `.rite/wiki/` に Wiki ページの実体があるのは wiki.branch_strategy: same_branch のときだけ。
  # separate_branch では不在なら scan_root に加わらず、空ディレクトリなら加わるが対象は 0 件になる。
  # ただし ingest 待ちの Raw Source が `.rite/wiki/raw/` に一時的に置かれる窓ではそれが走査対象に入る。
  # これは未実装の残債ではなく責務分割で、その構成の Wiki 走査は wiki-lint ステップ 7.5 が担う (冒頭コメント参照)。
  scan_roots=("$base")
  [ -d "docs" ] && scan_roots+=("docs")
  [ -d ".rite/wiki" ] && scan_roots+=(".rite/wiki")
  self_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  self_rel=""
  case "$self_abs" in
    "$REPO_ROOT"/*) self_rel="${self_abs#"$REPO_ROOT"/}" ;;
  esac
  while IFS= read -r f; do
    # 定義ファイルの self-exclusion: スクリプト自身に加え、禁止句を「例示として保持する」SoT 本体と
    # parity test を除外する。これらは禁止句リストを定義する性質上、走査すると definitional な例
    # (Bad 例の語句) が本物の違反として誤検出される。
    case "$f" in
      "$self_rel") continue ;;
      plugins/rite/skills/rite-workflow/references/comment-best-practices.md) continue ;;
      plugins/rite/hooks/tests/comment-best-practices-parity.test.sh) continue ;;
      plugins/rite/hooks/tests/comment-journal-check.test.sh) continue ;;
      plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh) continue ;;
    esac
    TARGETS+=("$f")
  done < <(find "${scan_roots[@]}" -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE=""
_rite_journal_cleanup() {
  rm -f "${FINDINGS_FILE:-}"
}
trap 'rc=$?; _rite_journal_cleanup; exit $rc' EXIT
trap '_rite_journal_cleanup; exit 130' INT
trap '_rite_journal_cleanup; exit 143' TERM
trap '_rite_journal_cleanup; exit 129' HUP

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }

# Single awk pass per file. Whitelist check happens up-front; the six pattern
# scans share the same while-match loop idiom so multi-match per line is
# preserved (parity with bang-backtick-check.sh).
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  awk -v F="$file" '
    FNR == 1 { infence = 0; insources = 0; wiki_file = (F ~ /^\.rite\/wiki\//) }
    {
      line = $0
      # コードフェンスと `## ソース` 節の状態は、どの `next` よりも先に更新する。
      # TODO を含む行や whitelist 行で先に抜けると infence が desync し、以降の
      # フェンス内外の判定が丸ごとずれる (P5/P6 の除外 X1 / X3 が壊れる)。
      if (line ~ /^[[:space:]]*```/) { infence = !infence; fence_marker = 1 } else fence_marker = 0
      # `## ソース` は節スコープ (見出しから次の `##` 見出しの手前まで)。ファイル末尾まで
      # 打ち切ると、当該見出しの後ろに続く本文節が丸ごと盲点になる。
      # 判定はフェンス状態の更新後に置く — フェンス内に引用された `## ソース` で誤発火しない。
      # 見出しは接尾辞を許容する (`## ソース（追記分）` 等)。厳密一致だと揺れた見出しが
      # 節の開始として認識されないまま次の見出しとしては認識され、直前の節の除外を打ち切る。
      if (wiki_file && !infence && line ~ /^##[[:space:]]+ソース([[:space:]]*$|[（(])/) insources = 1
      else if (wiki_file && !infence && insources && line ~ /^##[[:space:]]/) insources = 0

      # Whitelist: any line carrying an "example:" marker is skipped wholesale.
      if (line ~ /(<!--[[:space:]]*example:|#[[:space:]]+example:|\/\/[[:space:]]+example:)/) next
      # 廃止判定ルール (comment-best-practices.md): TODO/FIXME に添えた追跡番号は
      # 「前方追跡ポインタ (維持)」であり説明的参照ではないため、TODO/FIXME 行は走査からスキップする。
      # これにより `# TODO(#123): ...` / `<!-- FIXME #99 -->` 等を誤検出しない。
      if (line ~ /(TODO|FIXME)/) next

      # P5/P6 専用の走査対象行: インラインコードスパンを `_` へマスクした line。
      # `_` は空文字ではない — 空にするとキーワードと後続番号が隣接して偽の一致を作る。
      ref_line = line
      gsub(/`[^`]*`/, "_", ref_line)
      # 除外 X1 (フェンス内 / フェンス記号行そのもの) と X3 (`## ソース` 節以降) を適用する。
      ref_scan = (!infence && !fence_marker && !insources)

      # P1: verified-review cycle N
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /verified-review cycle [0-9]+/)) break
        print "[comment-journal][P1] " F ":" NR ": verified-review cycle reference: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P2: 旧実装(は|では)
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /旧実装(は|では)/)) break
        print "[comment-journal][P2] " F ":" NR ": legacy-impl narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P3: PR #N cycle N fix
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /PR #[0-9]+ cycle [0-9]+ fix/)) break
        print "[comment-journal][P3] " F ":" NR ": PR cycle fix narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P4: cycle N F-N で(導入|確立|集約)
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /cycle [0-9]+ F-[0-9]+ で(導入|確立|集約)/)) break
        print "[comment-journal][P4] " F ":" NR ": review-finding narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      if (!ref_scan) next

      # P6: 参照キーワードを持たない日本語 2 構文 (#N で(別途)対応 / 詳細は #N)。
      # P5 より先に走らせる — 「PR #N で別途対応」は両方の規則に当たるため、先に P6 で報告し
      # 当該範囲を P5 の走査対象から外して同一位置の二重報告を防ぐ。
      pos = 1
      while (pos <= length(ref_line)) {
        rest = substr(ref_line, pos)
        if (!match(rest, /#[0-9]+ ?で(別途)?対応|詳細は ?#[0-9]+([^0-9]|$)/)) break
        hit = substr(rest, RSTART, RLENGTH)
        # 数字の直後に境界文字を 1 つ消費した場合だけ落とす。無条件に末尾 1 文字を削ると
        # 「#N で別途対応」のような数字で終わらない一致まで壊れる。
        if (hit ~ /[0-9][^0-9]$/) hit = substr(hit, 1, length(hit) - 1)
        print "[comment-journal][P6] " F ":" NR ": descriptive issue/PR reference (ja): " hit
        pos = pos + RSTART + RLENGTH - 1
      }

      # P5 走査用に、P6 が報告済みの ja 接尾構文をマスクした行を作る。位置計算を持ち回らずに
      # 二重報告を断てる (「詳細は #N」は P5 の語彙に当たらないためマスク不要)。
      p5_line = ref_line
      gsub(/#[0-9]+ ?で(別途)?対応/, "_", p5_line)

      # P5: 参照キーワード + 番号 (裸の `PR #N` / `Issue #N` を含む)。
      #     ファイル名アンカー (xxx.test.sh 等) は #N を含まないため本パターンに該当せず、自然に除外される。
      #     語彙は大小文字を対称に受け、左側にも文字クラス境界を置く (`prefs #12` の語尾一致を防ぐ)。
      #     報告文字列からは語境界のために消費した前後 1 文字を落とす (行頭 / 行末一致時は消費なし)。
      pos = 1
      while (pos <= length(p5_line)) {
        rest = substr(p5_line, pos)
        if (!match(rest, /(^|[^A-Za-z])([Ii]ssues?|[Pp][Rr]s?|[Rr]efs?|[Ss]ee|[Rr]elated to|[Cc]loses|[Ff]ixes|[Rr]esolves) *#[0-9]+([^0-9]|$)/)) break
        hit = substr(rest, RSTART, RLENGTH)
        if (hit ~ /[0-9][^0-9]$/) hit = substr(hit, 1, length(hit) - 1)
        # 左境界で消費した 1 文字を落とす (行頭一致では消費していないので先頭は英字のまま)
        if (hit ~ /^[^A-Za-z]/) hit = substr(hit, 2)
        print "[comment-journal][P5] " F ":" NR ": descriptive issue/PR reference: " hit
        pos = pos + RSTART + RLENGTH - 1
      }
    }
  ' "$file" >> "$FINDINGS_FILE"
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE")
else
  total=0
fi
log "==> Total comment-journal findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
