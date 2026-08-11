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

# 尺の比較を数値で行う以上、xfade も数値であることを入口で確かめる。非数値のまま通すと
# 比較が 0 に潰れてシーン尺ガードが無条件通過し、ffmpeg のフィルタ解析エラーだけが残って
# 原因（利用者が渡した -t の値）が診断から消える。
# 先頭ドット（`.5`）を弾くのは ffmpeg の duration パーサが受理しないため。ここで通すと
# まさに上記の「ffmpeg のエラーだけが残る」状態を自分で作る。
case "$xfade" in
  ''|.*|*[!0-9.]*|*.*.*) echo "assemble: -t は正の数値で指定してください（先頭ドット表記は不可）: $xfade" >&2; exit 1 ;;
esac
# 0 は xfade を発行しない指定だが、ffmpeg の xfade は duration が 1 フレーム周期未満だと
# 遷移点で出力を打ち切るため、2 本目以降のシーンが丸ごと消えた mp4 を exit 0 で残す。
# 「クロスフェードなしで繋ぐ」用途は本スクリプトの対象外。
if awk -v x="$xfade" 'BEGIN{exit !(x + 0 <= 0)}'; then
  echo "assemble: -t に 0 は指定できません（クロスフェードなしの連結は対象外）: $xfade" >&2
  exit 1
fi

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

# クロスフェードは繋ぎ目ごとにシーンを食う。端のシーンは 1 回（x）、中間のシーンは前後
# 2 回（2x）食われるため、必要マージンは位置で変わる。総尺 `Σd −(n−1)x` だけを見ると
# `d0 < x < d0+d1` の窓も中間シーンの重なりも素通りし、負ないし重複した offset が xfade へ
# 渡って ffmpeg が exit 0 のまま素材を捨てた mp4 を残す。
# n==1（xfade を使わない）では必要マージンが 0 になり `d > 0` の検査へ自然に縮退するので、
# 総尺ガードは本ループに含まれる。
# `d+0` で数値化するのは、ffprobe が `N/A` を返した尺を awk の文字列比較が素通りさせるため。
n_scenes="${#durations[@]}"
for i in "${!durations[@]}"; do
  if [ "$n_scenes" -eq 1 ]; then
    need=0
    # 単一シーンは xfade を発行しないため、クロスフェードを理由に挙げると因果が繋がらない。
    reason="尺が正の数値である必要があります（ffprobe が尺を返さない素材の可能性）"
  elif [ "$i" -eq 0 ] || [ "$i" -eq $((n_scenes - 1)) ]; then
    need="$xfade"
    reason="クロスフェード ${xfade}s に対し ${need}s 超が必要"
  else
    need="$(awk -v x="$xfade" 'BEGIN{printf "%.6f", 2 * x}')"
    reason="中間シーンは前後 2 回食われるためクロスフェード ${xfade}s に対し ${need}s 超が必要"
  fi
  if ! awk -v d="${durations[$i]}" -v need="$need" 'BEGIN{exit !((d + 0) > (need + 0))}'; then
    echo "assemble: シーン $((i + 1)) の尺 ${durations[$i]}s が不足しています（${reason}）: ${scenes[$i]}" >&2
    exit 1
  fi
done

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
  # シーン尺と同じ扱いにする。ffprobe が `N/A` を返す入力（live-mux 由来の webm 等）では
  # awk が文字列比較へ落ち、`"N/A" < "3.500"` が偽になって下の尺不足ガードが黙って通る。
  if ! awk -v b="$bgm_duration" 'BEGIN{exit !((b + 0) > 0)}'; then
    echo "assemble: BGM の尺を数値で取得できません: $bgm (ffprobe: ${bgm_duration:-空})" >&2
    exit 1
  fi
  # `-shortest` を発行していないため映像は BGM 長に切り詰められないが、BGM が総尺より短いと
  # 末尾が無音になる。無音の完成尺を黙って出さないためにここで落とす。
  if awk -v b="$bgm_duration" -v t="$total" 'BEGIN{exit !((b + 0) < (t + 0))}'; then
    echo "assemble: BGM が総尺より短く末尾が無音になります（BGM ${bgm_duration}s < 総尺 ${total}s）" >&2
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

# 出力尺を実測して宣言値と突き合わせる。render.mjs がフレーム数で同じことをしているのと同じ
# 理由 — ffmpeg はフィルタ側の入力が途中で尽きても exit 0 で短い mp4 を残す（xfade の offset
# 計算がずれた場合に silent な素材欠落として現れる）。許容差は出力自身のフレーム周期 2 枚分で、
# 定数ではなく生成物から採る（muxer の丸めは両端で最大 1 枚ずつ出る）。
# 短い側だけを見るのは、この帰結が常に「素材が捨てられて短くなる」向きに出るため。
actual_duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")"
out_frame_rate="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$out")"
if ! awk -v a="$actual_duration" -v t="$total" -v r="$out_frame_rate" '
  BEGIN {
    split(r, fr, "/")
    period = (fr[1] + 0 > 0 && fr[2] + 0 > 0) ? fr[2] / fr[1] : 0
    exit !((a + 0) >= (t + 0) - 2 * period)
  }'; then
  echo "assemble: 出力尺が宣言と一致しません（宣言 ${total}s / 実測 ${actual_duration:-取得不能}s、fps ${out_frame_rate:-不明}）: $out" >&2
  echo "  シーンが連結されずに捨てられた可能性があります。-t の値とシーン尺を確認してください。" >&2
  exit 1
fi

echo "assembled ${#scenes[@]} scenes (${total}s, xfade ${xfade}s) -> $out"
