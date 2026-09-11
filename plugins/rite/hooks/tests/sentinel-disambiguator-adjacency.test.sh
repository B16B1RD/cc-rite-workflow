#!/bin/bash
# sentinel-disambiguator-adjacency.test.sh
#
# Cross-producer parity verification for sentinel + disambiguator marker pairs.
#
# 背景:
#   sub-skill return sentinel を `:returned-to-caller` 形式に rename し、
#   各 sentinel の直前に `<!-- skill return signal: caller must continue next step -->`
#   disambiguator marker を併記する契約を導入した。`create-md-invocation-symmetry.test.sh`
#   の TC-7a/7b は create.md 専用の adjacency 検証として既に機能している。
#
#   一方で他 5 producer (cleanup.md / merge.md / ready.md / wiki/lint.md / wiki/ingest.md)
#   には同等の自動検査が存在せず、wiki/lint.md ステップ 1.1/1.3 早期 return path で echo 順序が
#   sentinel → disambiguator に swap されても既存 test 群は通過する非対称 gap があった。
#   本 meta-test は全 producer 横断で 2 つの検査を機械化する:
#     (a) count parity (disambiguator count >= sentinel count) — silent marker strip
#         (rename 漏れ等で disambiguator のみ落ちた状態) を構造的に予防する (TC-{name})
#     (b) order-swap detection — marker pair の順序逆転 (sentinel が disambiguator より前に
#         emit される状態) を予防する (TC-{name}-order)。3 emit format それぞれに format 固有の
#         anchor で判定する (下記「検出する drift」参照)
#   これにより wiki/lint.md 早期 return path 等の echo 順序 swap を構造的に検出する。
#
# 検出する drift:
#   - count parity (TC-{name}): 各 producer で sentinel 数 > disambiguator 数 になっていれば
#     silent strip suspected
#   - order-swap (TC-{name}-order): 各 producer で marker pair の順序逆転 (sentinel が
#     disambiguator より前) を検出。正しい順序は「disambiguator → sentinel」。format 別判定:
#       * inline (format 3): 行末が disambiguator marker (` <!-- skill return signal... -->$`)
#         かつ同一行に sentinel marker を含む → sentinel が先 = swap
#       * multi-line / echo (format 1,2): sentinel emit 行 (whole-line / echo) の直後行が
#         disambiguator emit 行 → sentinel が先 = swap
#     create.md は create-md-invocation-symmetry.test.sh の TC-7b (line-head anchor 方式) で
#     covered のため本 test の対象外。
#
# 検出しない drift (本 test の scope 外):
#   - sentinel literal の rename 漏れ → CHANGELOG / grep / 他 test で別途検出
#   - marker pair が非隣接 (sentinel と disambiguator の間に無関係行が挟まる) ケース →
#     emit site は隣接前提 (同一行 inline / 連続行 multi-line・echo) のため order-swap 判定は
#     隣接時のみ発火する。非隣接な状態は count parity か rename 漏れの別 drift として他 check が
#     検出する
#
# 対応する 3 emit format:
#   (1) Multi-line markdown (ready.md / merge.md ステップ 3 / lint.md ステップ 9.2 / ingest.md):
#         <!-- skill return signal: caller must continue next step -->
#         <!-- [skill:returned-to-caller] -->
#   (2) Bash echo (lint.md ステップ 1.1/1.3 / merge.md ステップ 2):
#         echo "<!-- skill return signal: caller must continue next step -->"
#         echo "<!-- [skill:returned-to-caller] -->"
#   (3) Inline single-line (cleanup.md の ordered list item):
#         2. <list item text> <!-- skill return signal: ... --> <!-- [cleanup:returned-to-caller] -->
#
# When this test fails:
#   該当 producer の sentinel emit site と disambiguator marker の対称性が崩れている。
#   sentinel rename / disambiguator 追加時に片方を更新し忘れた可能性が高い。
#   失敗 producer の emit site と disambiguator site を再走査して同期させる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

# Producers under test (create.md は create-md-invocation-symmetry.test.sh の TC-7a/7b で
# 別途 covered のため除外。本 test は残り 5 producer の cross-producer 非対称 gap を埋める)
# Format: "skill_name:relative_path"
PRODUCERS=(
  "cleanup:skills/cleanup/SKILL.md"
  "merge:skills/merge/SKILL.md"
  "ready:skills/ready/SKILL.md"
  "lint:skills/wiki-lint/SKILL.md"
  "ingest:skills/wiki-ingest/SKILL.md"
)

# ──────────────────────────────────────────────────────────────────────
# Per-producer count parity test (TC-{name})
# ──────────────────────────────────────────────────────────────────────
# 各 producer について以下を assert する:
#   1. sentinel emit site が 1 件以上存在する (file の構造が壊れていないこと)
#   2. disambiguator marker emit site count >= sentinel emit site count
#
# emit site の判定:
#   - 行頭 `<!-- [name:returned-to-caller...] -->` (multi-line markdown format)
#   - 行頭 (任意 indent あり) `echo "<!-- [name:returned-to-caller...] -->"` (bash echo format)
#   - 行末 ` <!-- [name:returned-to-caller...] -->` (inline format、leading space 必須で
#     backtick 内 prose mention を除外)
#
# prose 内の literal mention (例: "...sentinel ``<!-- [name:returned-to-caller] -->``..." や
# `<!-- [name:returned-to-caller] -->` HTML コメント sentinel という説明テキスト) は上記
# パターンのいずれにもマッチせず除外される。
for entry in "${PRODUCERS[@]}"; do
  name="${entry%%:*}"
  rel_path="${entry##*:}"
  abs_path="$PLUGIN_ROOT/$rel_path"

  if [ ! -f "$abs_path" ]; then
    fail "TC-${name}: Producer file not found: $rel_path"
    continue
  fi

  # sentinel emit site count
  # 3 format をまとめて捕捉する OR pattern。
  # 各 alternative はそれぞれ 1 つの format に対応する:
  #   alt1: `^<!-- [name:returned-to-caller...] -->$`                       multi-line markdown
  #   alt2: `^[[:space:]]*echo "<!-- [name:returned-to-caller...] -->"$`    bash echo
  #   alt3: ` <!-- [name:returned-to-caller...] -->$`                       inline (leading space)
  sentinel_pattern="(^<!-- \[${name}:returned-to-caller[^]]*\] -->$)|(^[[:space:]]*echo \"<!-- \[${name}:returned-to-caller[^]]*\] -->\"$)|( <!-- \[${name}:returned-to-caller[^]]*\] -->$)"
  sentinel_count=$(grep -cE "$sentinel_pattern" "$abs_path" 2>/dev/null || true)
  # POSIX wc -l 互換: grep -c は match なしで rc=1 を返すため `|| true` で吸収する
  case "$sentinel_count" in ''|*[!0-9]*) sentinel_count=0 ;; esac

  # disambiguator emit site count (3 format 同様に capture)
  # 規約 — prose mention は backtick wrap 必須: 第 3 alternative ` <!-- skill return signal: ... -->`
  # (leading space anchor) は inline emit site を捕捉するため、prose 文中で marker literal を
  # backtick なしで言及すると count が inflate し real strip を mask しうる。本 test 群を含む
  # ドキュメント/prose で disambiguator marker literal を言及する際は必ず backtick で囲むこと
  # (現行 producer の prose mention は全て backtick 内で正しく除外される)。
  disambig_pattern='(^<!-- skill return signal: caller must continue next step -->$)|(^[[:space:]]*echo "<!-- skill return signal: caller must continue next step -->"$)|( <!-- skill return signal: caller must continue next step -->)'
  disambig_count=$(grep -cE "$disambig_pattern" "$abs_path" 2>/dev/null || true)
  case "$disambig_count" in ''|*[!0-9]*) disambig_count=0 ;; esac

  if [ "$sentinel_count" -eq 0 ]; then
    fail "TC-${name}: sentinel emit site が ${rel_path} に存在しません (期待: >= 1)。ファイル構造が壊れているか、sentinel rename で literal が変わった可能性"
    continue
  fi

  if [ "$disambig_count" -ge "$sentinel_count" ]; then
    pass "TC-${name}: ${rel_path} disambiguator emit site (${disambig_count}) >= sentinel emit site (${sentinel_count})"
  else
    # 診断出力は grep を pipe で直接流さず変数に捕捉する。disambig_count == 0 (本 test の主検出
    # シナリオ = disambiguator 完全 strip) のとき grep は rc=1 を返し、`set -euo pipefail` 配下では
    # `grep ... | sed >&2` の pipeline rc=1 が set -e を発火させ fail() 到達前に loop を中断する
    # (診断・summary が render されず後続 producer も skip される)。`|| true` で grep の no-match を
    # 吸収してから printf | sed で出力し、fail() を確実に到達させる (姉妹 test
    # create-md-invocation-symmetry.test.sh の pipefail-safe パターンと同形)。
    sentinel_sites=$(grep -nE "$sentinel_pattern" "$abs_path" 2>/dev/null || true)
    disambig_sites=$(grep -nE "$disambig_pattern" "$abs_path" 2>/dev/null || true)
    echo "  sentinel emit sites:"
    printf '%s\n' "$sentinel_sites" | sed 's/^/    /'
    echo "  disambiguator emit sites:"
    printf '%s\n' "$disambig_sites" | sed 's/^/    /'
    fail "TC-${name}: ${rel_path} disambiguator (${disambig_count}) < sentinel (${sentinel_count}) — silent marker strip suspected (rename 漏れで marker のみ落ちた状態の可能性)"
  fi
done

# ──────────────────────────────────────────────────────────────────────
# Per-producer order-swap test (TC-{name}-order)
# ──────────────────────────────────────────────────────────────────────
# marker pair の順序逆転 (sentinel が disambiguator より前に emit される) を検出する。
# 正しい順序は「disambiguator → sentinel」。3 emit format それぞれに format 固有の anchor で
# swap を判定する (prose mention は backtick wrap 規約により bare ` -->$` で行を終えないため除外):
#   - inline (format 3): 行末が disambiguator marker (` <!-- skill return signal... -->$`) かつ
#     同一行に sentinel marker を含む → sentinel が先 = swap
#   - multi-line / echo (format 1,2): sentinel emit 行 (whole-line / echo) の直後行が
#     disambiguator emit 行 → sentinel が先 = swap
#
# awk regex 注記: BEGIN で動的に組み立てる sentinel pattern は producer 名 (`name`) を埋め込む。
# awk 文字列リテラル内の `\\[` / `\\]` は実 regex の `\[` / `\]` (literal bracket) に解決され、
# count parity loop の grep -E pattern と同じ emit-site anchor を再現する。
for entry in "${PRODUCERS[@]}"; do
  name="${entry%%:*}"
  rel_path="${entry##*:}"
  abs_path="$PLUGIN_ROOT/$rel_path"

  if [ ! -f "$abs_path" ]; then
    fail "TC-${name}-order: Producer file not found: $rel_path"
    continue
  fi

  order_swap_out=$(awk -v name="$name" '
    BEGIN {
      sent_re_line = "^<!-- \\[" name ":returned-to-caller[^]]*\\] -->$"
      sent_re_echo = "^[[:space:]]*echo \"<!-- \\[" name ":returned-to-caller[^]]*\\] -->\"$"
      sent_re_any  = "<!-- \\[" name ":returned-to-caller[^]]*\\] -->"
      disg_re_line = "^<!-- skill return signal: caller must continue next step -->$"
      disg_re_echo = "^[[:space:]]*echo \"<!-- skill return signal: caller must continue next step -->\"$"
      disg_re_endinline = " <!-- skill return signal: caller must continue next step -->$"
      swaps = 0
    }
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        ln = lines[i]
        # inline same-line swap: 行末が disambiguator かつ同一行に sentinel marker を含む
        if (ln ~ disg_re_endinline && ln ~ sent_re_any) {
          swaps++
          print "  SWAP(inline) line " i ": sentinel marker が disambiguator より前 (disambiguator が行末)"
          continue
        }
        # multi-line / echo consecutive swap: sentinel emit 行の直後行が disambiguator emit 行
        if ((ln ~ sent_re_line || ln ~ sent_re_echo) && i < NR) {
          nxt = lines[i+1]
          if (nxt ~ disg_re_line || nxt ~ disg_re_echo) {
            swaps++
            print "  SWAP(multiline) lines " i "-" (i+1) ": sentinel emit が disambiguator emit より前"
          }
        }
      }
      print "SWAPCOUNT=" swaps
    }
  ' "$abs_path")

  swap_count=$(printf '%s\n' "$order_swap_out" | sed -n 's/^SWAPCOUNT=//p')
  case "$swap_count" in ''|*[!0-9]*) swap_count=0 ;; esac

  if [ "$swap_count" -eq 0 ]; then
    pass "TC-${name}-order: ${rel_path} marker pair の順序 swap なし (disambiguator -> sentinel)"
  else
    # 診断行 (`  SWAP...`) を stdout に出力。grep no-match (rc=1) は `|| true` で吸収して
    # set -euo pipefail 下で fail() 到達前に中断しないようにする (count parity loop と同形)。
    printf '%s\n' "$order_swap_out" | grep -E '^  SWAP' || true
    fail "TC-${name}-order: ${rel_path} で marker pair の順序逆転 ${swap_count} 件検出 — sentinel が disambiguator より前に emit されています (正しい順序: disambiguator -> sentinel)"
  fi
done

if ! print_summary "sentinel-disambiguator-adjacency.test.sh" "drift hint: count parity 失敗は sentinel と disambiguator の数を合わせてください (silent strip は rename 中に echo 行の片方だけ更新したケースで発生)。order-swap 失敗は marker pair の順序を disambiguator -> sentinel に修正してください"; then
  exit 1
fi
