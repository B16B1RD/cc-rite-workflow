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

scenes=("$@")
for scene in "${scenes[@]}"; do
  [ -f "$scene" ] || { echo "assemble: シーンが見つかりません: $scene" >&2; exit 1; }
done
if [ -n "$bgm" ] && [ ! -f "$bgm" ]; then
  echo "assemble: BGM が見つかりません: $bgm" >&2
  exit 1
fi

probe_duration() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
}

durations=()
for scene in "${scenes[@]}"; do
  d="$(probe_duration "$scene")"
  [ -n "$d" ] || { echo "assemble: 尺を取得できません: $scene" >&2; exit 1; }
  durations+=("$d")
done

# 連結後の総尺 = 全シーン尺の合計 − 重なり分（クロスフェード × 繋ぎ目の数）
total="$(awk -v n="${#durations[@]}" -v x="$xfade" 'BEGIN{s=0} {s+=$1} END{printf "%.3f", s - (n-1)*x}' \
  < <(printf '%s\n' "${durations[@]}"))"

# クロスフェードは繋ぎ目ごとに両側のシーンを食うため、判定は総尺ではなく最短シーン尺で行う。
# 総尺だけを見ると `d0 < x < d0+d1` の窓を素通りし、xfade へ負の offset が渡って
# ffmpeg が exit 0 のまま素材の大半を捨てた mp4 を残す。
# （`x < min(d)` は `total > 0` を含意するので、総尺ガードはこれに包含される）
if [ "${#durations[@]}" -ge 2 ]; then
  min_d="$(printf '%s\n' "${durations[@]}" | sort -g | head -1)"
  if awk -v x="$xfade" -v m="$min_d" 'BEGIN{exit !(x >= m)}'; then
    echo "assemble: クロスフェード ${xfade}s が最短シーン尺 ${min_d}s 以上です（総尺 ${total}s）" >&2
    exit 1
  fi
fi

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
  bgm_duration="$(probe_duration "$bgm")"
  # 出力尺は下の `-t "$total"` で固定するため映像は削られないが、BGM が総尺より短いと
  # 末尾が無音になる。無音の完成尺を黙って出さないためにここで落とす。
  if awk -v b="$bgm_duration" -v t="$total" 'BEGIN{exit !(b < t)}'; then
    echo "assemble: BGM が総尺より短いため映像が切り詰められます（BGM ${bgm_duration}s < 総尺 ${total}s）" >&2
    exit 1
  fi
  fade_out_start="$(awk -v t="$total" 'BEGIN{printf "%.3f", (t - 2 > 0) ? t - 2 : 0}')"
  args+=(-i "$bgm")
  filter+=";[${#scenes[@]}:a]afade=t=in:st=0:d=1,afade=t=out:st=${fade_out_start}:d=2[a]"
  maps+=(-map "[a]" -c:a aac -b:a 192k)
fi

ffmpeg "${args[@]}" -filter_complex "$filter" "${maps[@]}" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -map_metadata -1 -t "$total" "$out"

echo "assembled ${#scenes[@]} scenes (${total}s, xfade ${xfade}s) -> $out"
