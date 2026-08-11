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
if ! awk -v x="$xfade" 'BEGIN{exit !((x + 0) > 0)}'; then
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

# コンテナ尺（format=duration）ではなくストリーム尺を採る。コンテナ尺は全ストリームの最大値
# なので、BGM を載せた出力では音声が映像の切り捨てを覆い隠す。
probe_duration() {
  ffprobe -v error -select_streams "$1" -show_entries stream=duration -of csv=p=0 "$2"
}

# 各シーンのフレーム周期。クロスフェードが 1 フレーム周期未満だと ffmpeg の xfade は遷移点で
# 出力を打ち切る（あるいは遷移自体を発行しない）ため、尺の下限として使う。
probe_frame_period() {
  ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$1" \
    | awk -F/ '{ if ($1 + 0 > 0 && $2 + 0 > 0) printf "%.9f", $2 / $1; else print "" }'
}

durations=()
max_frame_period=0
for scene in "${scenes[@]}"; do
  d="$(probe_duration v:0 "$scene")"
  # 数値であることを収集地点で確かめる。ここを空検査だけで通すと、ffprobe が `N/A` を返した
  # 素材が下のマージン判定まで運ばれ、「クロスフェード不足」という誤った原因で報告される。
  if ! awk -v d="$d" 'BEGIN{exit !((d + 0) > 0)}'; then
    echo "assemble: シーンの尺を数値で取得できません: $scene (ffprobe: ${d:-空})" >&2
    exit 1
  fi
  durations+=("$d")

  p="$(probe_frame_period "$scene")"
  if ! awk -v p="$p" 'BEGIN{exit !((p + 0) > 0)}'; then
    echo "assemble: シーンのフレームレートを取得できません: $scene" >&2
    exit 1
  fi
  max_frame_period="$(awk -v a="$max_frame_period" -v b="$p" 'BEGIN{printf "%.9f", (b + 0 > a + 0) ? b : a}')"
done

# 連結後の総尺 = 全シーン尺の合計 − 重なり分（クロスフェード × 繋ぎ目の数）
total="$(awk -v n="${#durations[@]}" -v x="$xfade" 'BEGIN{s=0} {s+=$1} END{printf "%.3f", s - (n-1)*x}' \
  < <(printf '%s\n' "${durations[@]}"))"

# 以下は xfade を発行する n>=2 の検査。単一シーンは繋ぎ目を持たないため対象外（尺の正当性は
# 収集地点で検査済み）。
n_scenes="${#durations[@]}"
if [ "$n_scenes" -ge 2 ]; then
  # クロスフェードがフレーム周期未満だと ffmpeg の xfade は遷移点で出力を打ち切る（低 fps では
  # 遷移自体を発行せずハードカットになる）。この帰結は出力尺の実測照合では捕まえられない —
  # 許容差がフレーム周期でスケールする以上、フレーム規模の欠落は常に許容差に隠れるため。
  if ! awk -v x="$xfade" -v p="$max_frame_period" 'BEGIN{exit !((x + 0) > (p + 0))}'; then
    echo "assemble: クロスフェード ${xfade}s がシーンのフレーム周期 ${max_frame_period}s 以下です（1 フレーム分を超える値が必要）" >&2
    exit 1
  fi

  # クロスフェードは繋ぎ目ごとにシーンを食う。端のシーンは 1 回（x）、中間のシーンは前後
  # 2 回（2x）食われるため、必要マージンは位置で変わる。総尺 `Σd −(n−1)x` だけを見ると
  # `d0 < x < d0+d1` の窓も中間シーンの重なりも素通りし、負ないし重複した offset が xfade へ
  # 渡って ffmpeg が exit 0 のまま素材を捨てた mp4 を残す。
  for i in "${!durations[@]}"; do
    if [ "$i" -eq 0 ] || [ "$i" -eq $((n_scenes - 1)) ]; then
      need="$xfade"
      reason="クロスフェード ${xfade}s 分の重なりを超える尺が必要"
    else
      need="$(awk -v x="$xfade" 'BEGIN{printf "%.6f", 2 * x}')"
      reason="中間シーンは前後 2 回食われるため ${need}s 超が必要"
    fi
    if ! awk -v d="${durations[$i]}" -v need="$need" 'BEGIN{exit !((d + 0) > (need + 0))}'; then
      echo "assemble: シーン $((i + 1)) の尺 ${durations[$i]}s が不足しています（${reason}）: ${scenes[$i]}" >&2
      exit 1
    fi
  done
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
  bgm_duration="$(probe_duration a:0 "$bgm")"
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

# 出力の映像尺を実測して宣言値と突き合わせる。render.mjs がフレーム数で同じことをしているのと
# 同じ理由 — ffmpeg はフィルタ側の入力が途中で尽きても exit 0 で短い mp4 を残す（xfade の
# offset 計算がずれた場合に silent な素材欠落として現れる）。
# コンテナ尺ではなく映像ストリーム尺を採るのは、BGM を載せた出力ではコンテナ尺が音声側の長さに
# なり、映像の切り捨てを覆い隠すため。
# 許容差は出力自身のフレーム周期 2 枚分で、定数ではなく生成物から採る（muxer の丸めは両端で
# 最大 1 枚ずつ出る）。フレーム規模の欠落はこの許容差に隠れるため、そちらは上の
# 「クロスフェード > フレーム周期」の入口検査が受け持つ。
actual_duration="$(probe_duration v:0 "$out")"
out_frame_period="$(probe_frame_period "$out")"
if ! awk -v a="$actual_duration" -v t="$total" -v p="$out_frame_period" '
  BEGIN { exit !((a + 0) > 0 && (a + 0) >= (t + 0) - 2 * (p + 0)) }'; then
  echo "assemble: 出力の映像尺が宣言と一致しません（宣言 ${total}s / 実測 ${actual_duration:-取得不能}s）: $out" >&2
  echo "  シーンが連結されずに捨てられた可能性があります。-t の値とシーン尺を確認してください。" >&2
  # 検証に落ちた成果物を出力パスに残さない（再生できてしまうため、存在だけを見る運用が拾う）。
  rm -f "$out"
  exit 1
fi

echo "assembled ${#scenes[@]} scenes (${total}s, xfade ${xfade}s) -> $out"
