#!/usr/bin/env bash
# シーン mp4 を xfade で連結し、任意で BGM を合成する。
# 各シーンの尺は ffprobe で実測する（宣言尺を信じると xfade のオフセットが 1 本ずれるだけで
# 以降すべての繋ぎ目がずれる）。
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: assemble.sh -o <out.mp4> [-t <xfade_sec>] [-b <bgm.mp3>] <scene1.mp4> [scene2.mp4 ...]

  -o  出力 mp4（必須）
  -t  シーン間クロスフェード秒（既定: 0.5）
  -b  BGM 音声ファイル（任意。指定時は fade in/out を付けて合成する）
EOF
  exit 1
}

out=""
xfade="0.5"
bgm=""
while getopts ":o:t:b:" opt; do
  case "$opt" in
    o) out="$OPTARG" ;;
    t) xfade="$OPTARG" ;;
    b) bgm="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

[ -n "$out" ] || usage
[ "$#" -ge 1 ] || usage

# 非数値を通すと awk の比較が 0 に潰れ、ffmpeg のフィルタ解析エラーだけが残って原因
# （利用者が渡した -t の値）が診断から消える。
case "$xfade" in
  ''|*[!0-9.]*|*.*.*) echo "assemble: -t は数値で指定してください: $xfade" >&2; exit 1 ;;
esac

scenes=("$@")
for scene in "${scenes[@]}"; do
  [ -f "$scene" ] || { echo "assemble: シーンが見つかりません: $scene" >&2; exit 1; }
done
if [ -n "$bgm" ] && [ ! -f "$bgm" ]; then
  echo "assemble: BGM が見つかりません: $bgm" >&2
  exit 1
fi

# 尺はコンテナ尺で採る（ストリーム尺は容器によって `N/A` になり、正当な入力を弾いてしまう）。
# オフセット計算に使う値なので、数値でない結果はここで落とす — `N/A` を文字列のまま下流へ
# 流すと awk の比較が素通りし、原因の違う診断で報告される。
probe_duration() {
  local d
  d="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")" \
    || { echo "assemble: ffprobe が解析に失敗しました: $1" >&2; return 1; }
  awk -v v="$d" 'BEGIN{ if ((v + 0) > 0) print v; else exit 1 }' \
    || { echo "assemble: 尺を数値で取得できません: $1 (ffprobe: ${d:-空})" >&2; return 1; }
}

durations=()
for scene in "${scenes[@]}"; do
  d="$(probe_duration "$scene")" || exit 1
  durations+=("$d")
done

# 連結後の総尺 = 全シーン尺の合計 − 重なり分（クロスフェード × 繋ぎ目の数）
total="$(awk -v n="${#durations[@]}" -v x="$xfade" 'BEGIN{s=0} {s+=$1} END{printf "%.3f", s - (n-1)*x}' \
  < <(printf '%s\n' "${durations[@]}"))"

inputs=()
for scene in "${scenes[@]}"; do inputs+=(-i "$scene"); done

filter=""
if [ "${#scenes[@]}" -eq 1 ]; then
  filter="[0:v]null[v]"
else
  # 累積出力尺 L_k = Σd(0..k) − k*x。k+1 本目を重ねるオフセットは L_k − x。
  acc="${durations[0]}"
  prev="[0:v]"
  for ((i = 1; i < ${#scenes[@]}; i++)); do
    offset="$(awk -v a="$acc" -v x="$xfade" 'BEGIN{printf "%.3f", a - x}')"
    label="[vx$i]"
    [ "$i" -eq $((${#scenes[@]} - 1)) ] && label="[v]"
    filter+="${prev}[${i}:v]xfade=transition=fade:duration=${xfade}:offset=${offset}${label};"
    prev="$label"
    acc="$(awk -v a="$acc" -v d="${durations[$i]}" -v x="$xfade" 'BEGIN{printf "%.3f", a + d - x}')"
  done
  filter="${filter%;}"
fi

args=(-y "${inputs[@]}")
maps=(-map "[v]")

if [ -n "$bgm" ]; then
  bgm_duration="$(probe_duration "$bgm")" || exit 1
  # 出力は `-t "$total"` で映像尺に切り詰めるため、BGM が総尺より短いと末尾が無音になる。
  # 無音の完成尺を黙って出さない。
  if ! awk -v b="$bgm_duration" -v t="$total" 'BEGIN{exit !((b + 0) >= (t + 0))}'; then
    echo "assemble: BGM が総尺より短く末尾が無音になります（BGM ${bgm_duration}s < 総尺 ${total}s）" >&2
    exit 1
  fi
  # fade は総尺に収まる長さへ縮める。既定の in 1s / out 2s を固定にすると総尺 3s 未満で区間が
  # 重なり、BGM 全体が減衰した mp4 が exit 0 で残る（同梱 fixture は 2s なので既定手順で到達する）。
  fade_in="$(awk -v t="$total" 'BEGIN{printf "%.3f", (t / 4 < 1) ? t / 4 : 1}')"
  fade_out="$(awk -v t="$total" 'BEGIN{printf "%.3f", (t / 2 < 2) ? t / 2 : 2}')"
  fade_out_start="$(awk -v t="$total" -v o="$fade_out" 'BEGIN{printf "%.3f", t - o}')"
  args+=(-i "$bgm")
  filter+=";[${#scenes[@]}:a]afade=t=in:st=0:d=${fade_in},afade=t=out:st=${fade_out_start}:d=${fade_out}[a]"
  maps+=(-map "[a]" -c:a aac -b:a 192k)
fi

# rc の捕捉は if/else 形式で行う（`if ! cmd; then rc=$?` は bash 仕様上 `$?` が常に 0 になる）。
if ffmpeg "${args[@]}" -filter_complex "$filter" "${maps[@]}" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -map_metadata -1 -t "$total" "$out"; then
  :
else
  rc=$?
  echo "assemble: ffmpeg が exit code ${rc} で終了しました" >&2
  exit "$rc"
fi

echo "assembled ${#scenes[@]} scenes (${total}s, xfade ${xfade}s) -> $out"
