#!/usr/bin/env bash
set -u

# review-spawn-spread-check.sh
#
# skills/pr-review/SKILL.md ステップ 4.6 の spawn spread チェック。全 reviewer の起動時刻
# (`started_at`) の拡がりを測り、閾値を超えた cycle を「並列起動の直列化」として表面化する。
#
# Why this exists:
#   並列起動は SKILL.md が MUST で多重に宣言しているが、宣言だけでは長時間セッションで守られず、
#   実測で 4 reviewer が逐次完走してレビュー壁時計が数倍化した run がある。その違反はどこにも
#   記録されず、事後に検出する計器が存在しなかった。本 helper が観測層を担う。
#   **強制はしない** — Task 発行は LLM の応答構造そのもので hook から強制できないため、可能な
#   のは事後検出と表面化までである (references/wiki-promotions/anti-patterns/
#   declarative-enforcement-cannot-prevent-llm-end-turn.md の適用)。
#
# Non-blocking 契約:
#   判定結果はレビューの採否・merge ゲートに一切影響しない。直列化は効率違反であって
#   品質低下ではないため、検出しても rc=0 で返す。非ゼロ (rc=2) は caller 契約違反と環境不備のみ。
#
# Usage:
#   review-spawn-spread-check.sh --input <timings.json> [--threshold <seconds>]
#
# Input JSON (caller = ステップ 4.6 が Write する):
#   {"reviewer_timings": [{"reviewer": "security-reviewer", "started_at": "2026-08-10T12:00:00Z"},
#                         {"reviewer": "test-reviewer",     "started_at": null}]}
#   `started_at` は ISO 8601 UTC の正規形 (`YYYY-MM-DDThh:mm:ssZ`) のみを受理する。取得できな
#   かった reviewer は `null` を書く (省略・捏造は禁止 — 欠落は「計測不能」として表面化させる)。
#
# Output (in-place、判定できた場合のみ追記。入力の他キーは保持する):
#   .reviewer_spawn_serialized      bool  spread > threshold か
#   .reviewer_spawn_spread_seconds  int   実測した spread (秒)
#   判定できなかった (計測不能) 場合は**両キーとも書かない** — キー欠落が「未判定」を表す
#   (review-result-schema.md の `verification.measured` と同じ 3 値モデル)。
#
# 出力姿勢 (E2E Output Minimization):
#   全員分の起動時刻が揃い spread が閾値内なら **stdout / stderr とも完全に無言**で返る。
#   それ以外は stderr に行動可能な WARNING を出し、その**後ろ**に `[CONTEXT]` marker を 1 本置く。
#   WARNING は条件ごとに 1 行で、直列化と計測不能は独立に判定されるため**同時に 2 行**出うる
#   (直列化かつ一部欠落の cycle で、何名を測り落としたかと spread が実測分だけの値であることが
#   消えないようにするため。排他にしてはならない)。
#
# `[CONTEXT] SPAWN_SPREAD=` marker (stderr、1 run につき最大 1 本):
#   serialized    spread > threshold
#   parallel      spread <= threshold。**一部の起動時刻が欠落していたときのみ** emit する
#                 (全員分揃った正常系は無言のため marker も出ない)
#   undetermined  判定不能。reason= に理由が入る:
#                   timestamp_unparseable         正規形でない started_at がある
#                   no_parseable_timing           parse できた起動時刻が 0 件
#                   insufficient_parseable_timing 複数 reviewer だが parse できたのが 1 件のみ
#
# Exit codes:
#   0  判定を実施した / 計測不能を報告した (いずれも非ブロッキング)
#   2  引数不正・jq 不在・入力不正・書き出し失敗 (caller 契約違反 or 環境不備)

DEFAULT_THRESHOLD_SECONDS=120

input=""
threshold="$DEFAULT_THRESHOLD_SECONDS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input|--threshold)
      option="$1"
      if [ "$#" -lt 2 ]; then
        echo "ERROR: $option requires a value" >&2
        exit 2
      fi
      if [ "$option" = "--input" ]; then input="$2"; else threshold="$2"; fi
      shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$input" ]; then
  echo "ERROR: --input is required" >&2
  exit 2
fi
case "$threshold" in
  ''|*[!0-9]*) echo "ERROR: --threshold must be a non-negative integer (got: $threshold)" >&2; exit 2 ;;
esac
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq が見つかりません (PATH を確認してください)" >&2
  exit 2
fi
if [ ! -r "$input" ]; then
  echo "ERROR: spawn spread チェックの入力 JSON を読み取れません: $input" >&2
  exit 2
fi
if ! jq empty "$input" >/dev/null 2>&1; then
  echo "ERROR: spawn spread チェックの入力 JSON が parse できません: $input" >&2
  exit 2
fi
if [ "$(jq -r '.reviewer_timings | type' "$input" 2>/dev/null)" != "array" ]; then
  echo "ERROR: .reviewer_timings が配列ではありません: $input" >&2
  exit 2
fi

out_tmp=""
_cleanup() {
  [ -n "${out_tmp:-}" ] && rm -f "$out_tmp"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT

# jq の出力は awk へ直接パイプせず、いったん変数へ受けて rc を検査する。直接繋ぐと jq の
# element 単位 parse 失敗 (配列に非 object が混じる等) が rc ごと捨てられ、awk は切り詰め
# られた stream をそのまま数えて `total` まで一緒に縮むため、件数ガードも素通りして
# 「直列化なし」を無音で書き込む。rc を検査してから awk へ渡せば、その経路が構造的に存在
# しなくなる (pipefail と件数の再取得を足すより単純)。awk への供給に here-string を使わない
# のは、空文字列にも改行 1 個を付けてしまい空配列で `total=1` になるため。
if ! timings_tsv=$(jq -r '.reviewer_timings[] | [(.reviewer // ""), (.started_at // "")] | @tsv' "$input" 2>/dev/null); then
  echo "ERROR: .reviewer_timings の要素を読み出せません (要素が object でない / 値が配列やオブジェクト): $input" >&2
  exit 2
fi

# 起動時刻の parse は `date -d` に頼らない。GNU/BSD で構文が割れるうえ、緩い parser は
# 非正規形 (ローカル時刻・オフセット付き) を黙って受理して spread を歪める。正規形だけを
# 通す strict な自前 parse にすることで、形式崩れは「計測不能」として必ず表面化する。
stats=$(printf '%s' "$timings_tsv" | awk -F'\t' '
  function days_from_civil(y, m, d,   era, yoe, doy, doe) {
    if (m <= 2) y--
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  BEGIN { total=0; missing=0; unparseable=0; parsed=0; min=0; max=0; missing_names="" }
  {
    total++
    reviewer = ($1 == "" ? "?" : $1)
    ts = $2
    if (ts == "" || ts == "null") {
      missing++
      missing_names = (missing_names == "" ? reviewer : missing_names " " reviewer)
      next
    }
    if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) { unparseable++; next }
    y = substr(ts, 1, 4) + 0; mo = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
    h = substr(ts, 12, 2) + 0; mi = substr(ts, 15, 2) + 0; s = substr(ts, 18, 2) + 0
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 60) { unparseable++; next }
    epoch = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
    if (parsed == 0 || epoch < min) min = epoch
    if (parsed == 0 || epoch > max) max = epoch
    parsed++
  }
  END { printf "%d\t%d\t%d\t%d\t%d\t%s\n", total, missing, unparseable, parsed, (parsed > 0 ? max - min : 0), missing_names }
')
if [ -z "$stats" ]; then
  echo "ERROR: spawn spread の集計に失敗しました: $input" >&2
  exit 2
fi
IFS=$'\t' read -r total missing unparseable parsed spread missing_names <<EOF
$stats
EOF

_undetermined() {
  echo "WARNING: reviewer の spawn spread を判定できません (reason=$1)。reviewer prompt の「起動時刻の記録」指示が全 reviewer に届いているか確認してください" >&2
  echo "[CONTEXT] SPAWN_SPREAD=undetermined; reason=$1; reviewers=$total; measured=$parsed" >&2
  exit 0
}

# 判定不能の 3 経路。いずれも silent skip せず理由付きで表面化する (欠落を「直列化なし」と
# 読ませないため)。正規形でない started_at が 1 件でもあれば cycle 全体を計測不能へ倒す —
# 残りだけで測った spread は「どの reviewer を測り落としたか」が判定値に現れず誤読を招く。
if [ "$unparseable" -gt 0 ]; then _undetermined timestamp_unparseable; fi
if [ "$parsed" -eq 0 ]; then _undetermined no_parseable_timing; fi
if [ "$parsed" -eq 1 ] && [ "$total" -gt 1 ]; then _undetermined insufficient_parseable_timing; fi

if [ "$spread" -gt "$threshold" ]; then serialized=true; else serialized=false; fi

if ! out_tmp=$(mktemp "${input}.spread.XXXXXX" 2>/dev/null); then
  echo "ERROR: spawn spread 判定結果の tempfile を作成できません (dir: $(dirname "$input"))" >&2
  exit 2
fi
if ! jq --argjson serialized "$serialized" --argjson spread "$spread" \
     '.reviewer_spawn_serialized = $serialized | .reviewer_spawn_spread_seconds = $spread' \
     "$input" > "$out_tmp" 2>/dev/null; then
  echo "ERROR: spawn spread 判定結果の書き出しに失敗しました: $out_tmp" >&2
  exit 2
fi
if ! mv "$out_tmp" "$input" 2>/dev/null; then
  echo "ERROR: spawn spread 判定結果の atomic mv に失敗しました: $out_tmp -> $input" >&2
  exit 2
fi
out_tmp=""

# 直列化と欠落は独立に判定する (排他にすると「直列化かつ一部欠落」の cycle で何名を測り
# 落としたかが消え、spread が実測できた分だけの値であることも読めなくなる)。marker は
# 判定を変数へ畳んで最後に 1 本だけ出す — WARNING より先に出る経路が構造的に無くなり、
# ほぼ同一の emit 行を 2 つ持たずに済む。
verdict=""
if [ "$serialized" = "true" ]; then
  echo "WARNING: reviewer の並列起動が直列化しています (spawn spread ${spread}s > 閾値 ${threshold}s)。全 reviewer の Task 呼び出しを 1 メッセージ内にまとめて発行してください (1 件ずつ別メッセージで発行すると逐次実行になります)" >&2
  verdict=serialized
elif [ "$missing" -gt 0 ]; then
  verdict=parallel
fi
if [ "$missing" -gt 0 ]; then
  echo "WARNING: ${missing} 名の reviewer の起動時刻を取得できず、spawn spread は残り ${parsed} 名のみで判定しました (計測不能: ${missing_names})" >&2
fi
if [ -n "$verdict" ]; then
  echo "[CONTEXT] SPAWN_SPREAD=${verdict}; spread=${spread}s; threshold=${threshold}s; reviewers=$total; measured=$parsed" >&2
fi
