#!/usr/bin/env bash
# シーン mp4 を xfade で連結し、任意で BGM を合成する。
# 各シーンの尺は ffprobe で実測する（宣言尺を信じると xfade のオフセットが 1 本ずれるだけで
# 以降すべての繋ぎ目がずれる）。
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: assemble.sh [-P] -o <out.mp4> [-t <xfade_sec>] [-b <bgm.mp3>] <scene1.mp4> [scene2.mp4 ...]

  -o  出力 mp4（必須）
  -t  シーン間クロスフェード秒（既定: 0.5）
  -b  BGM 音声ファイル（任意。指定時は fade in/out を付けて合成する）
  -P  intro-video-v2 フルカットプリセット（M1〜M7 と既定 BGM を使用）
EOF
  exit 1
}

out=""
xfade="0.5"
bgm=""
preset=false
while getopts ":o:t:b:P" opt; do
  case "$opt" in
    o) out="$OPTARG" ;;
    t) xfade="$OPTARG" ;;
    b) bgm="$OPTARG" ;;
    P) preset=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

[ -n "$out" ] || usage
if [ "$preset" = true ]; then
  [ "$#" -eq 0 ] || { echo "assemble: -P とシーン引数は同時に指定できません" >&2; exit 1; }
  scenes=(
    "out/01-problem.mp4"
    "out/02-unknowns.mp4"
    "out/03-loop.mp4"
    "out/04-gates.mp4"
    "out/05-wiki.mp4"
    "out/06-second-lap.mp4"
    "out/07-closing.mp4"
  )
  [ -n "$bgm" ] || bgm="bombinsound-technology-tech-technology-90-second-499581.mp3"
else
  [ "$#" -ge 1 ] || usage
  scenes=("$@")
fi

# 「正の数値であること」を述語として要求する。文字クラスの否定（`*[!0-9.]*` 等）では `.` 単体や
# `0` が抜け、awk の比較が 0 に潰れたまま下流へ流れる。先頭ドット表記（`.5`）を除くのは ffmpeg の
# duration パーサが受理しないため（実測: `duration=.5` は exit 234）。ここで通すと、この検査が
# 防ぐはずの「ffmpeg のフィルタ解析エラーだけが残り、利用者が渡した -t の値が診断から消える」
# 状態を自分で作る。
if ! awk -v x="$xfade" 'BEGIN{ exit !(x ~ /^[0-9]+(\.[0-9]*)?$/ && (x + 0) > 0) }'; then
  echo "assemble: -t は正の数値で指定してください（先頭ドット表記は不可）: $xfade" >&2
  exit 1
fi

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

# 出力照合の許容差に使うフレーム周期。先頭シーンから採る（xfade は同一 fps を要求するので、
# 揃っていない入力は ffmpeg 側がフィルタ構成エラーで落とす — 実測: 30fps + 15fps は exit 234）。
frame_rate="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 \
  "${scenes[0]}" | awk 'NF { print; exit }')"
frame_period="$(awk -v r="$frame_rate" 'BEGIN{ split(r, f, "/"); if (f[1] + 0 > 0 && f[2] + 0 > 0) printf "%.9f", f[2] / f[1] }')"
if ! awk -v p="$frame_period" 'BEGIN{exit !((p + 0) > 0)}'; then
  echo "assemble: シーンのフレームレートを数値で取得できません: ${scenes[0]} (ffprobe: ${frame_rate:-空})" >&2
  exit 1
fi

# 連結後の総尺 = 全シーン尺の合計 − 重なり分（クロスフェード × 繋ぎ目の数）
total="$(awk -v n="${#durations[@]}" -v x="$xfade" 'BEGIN{s=0} {s+=$1} END{printf "%.6f", s - (n-1)*x}' \
  < <(printf '%s\n' "${durations[@]}"))"

# クロスフェードは繋ぎ目ごとにシーンを食う。端のシーンは 1 回（x）、中間のシーンは前後 2 回（2x）
# 食われるため、必要マージンは位置で変わる。総尺だけを見ると `d0 < x < d0+d1` の窓も中間シーンの
# 重なりも素通りし、負ないし重複した offset が xfade へ渡って ffmpeg が exit 0 のまま素材を捨てた
# mp4 を残す（実測: 2.0s×3 に -t 3.0 で総尺 0.000s・ストリーム 0 本の 262 バイト mp4 が成功終了）。
n_scenes="${#durations[@]}"
if [ "$n_scenes" -ge 2 ]; then
  # 下限側。1 フレーム周期未満のクロスフェードは xfade が遷移を発行できず、後続シーンを
  # まるごと落とす（実測: 30fps で -t 0.033 は先頭以外が消え、0.034 は正常に連結される）。
  # 出力照合でも捕まるが、そちらの診断は「-t の値とシーン尺を確認してください」までしか言えず、
  # 真の規則を名指しできない。入口検査が -t の値域を扱う以上、この条件もここで言う。
  if ! awk -v x="$xfade" -v p="$frame_period" 'BEGIN{exit !((x + 0) >= (p + 0))}'; then
    echo "assemble: クロスフェード ${xfade}s がシーンのフレーム周期 ${frame_period}s 未満です（xfade が遷移を発行できず後続シーンを落とします）" >&2
    exit 1
  fi

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
  # 桁は %.6f。%.3f だと丸めが offset を切り上げる場合があり、`offset + x` がシーン尺を超えて
  # xfade の遷移窓が入力の外へはみ出す（実測: 30fps・2.0s×2 に -t 0.0334 で offset が 1.9666 →
  # 1.967 に丸まり、第 2 シーンが丸ごと落ちて 2.066667s になった。%.6f では 3.966667s で正常）。
  acc="${durations[0]}"
  prev="[0:v]"
  for ((i = 1; i < ${#scenes[@]}; i++)); do
    offset="$(awk -v a="$acc" -v x="$xfade" 'BEGIN{printf "%.6f", a - x}')"
    label="[vx$i]"
    [ "$i" -eq $((${#scenes[@]} - 1)) ] && label="[v]"
    filter+="${prev}[${i}:v]xfade=transition=fade:duration=${xfade}:offset=${offset}${label};"
    prev="$label"
    acc="$(awk -v a="$acc" -v d="${durations[$i]}" -v x="$xfade" 'BEGIN{printf "%.6f", a + d - x}')"
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

# 完了行が名乗る尺は成果物から実測する。解析値 total をそのまま報告すると、素材が捨てられて
# 短い mp4 になっても成功メッセージ自体が誤情報になる。許容差は 1 フレーム周期 — ffmpeg は
# フレーム境界でしか切れないため、`-t "$total"` を渡しても実尺は最大 1 フレーム分ずれる
# （実測: 24〜60fps・1〜3 シーン・xfade 0.034〜1.2345 の掃引で差は常に 1 周期未満）。
if ! actual="$(probe_duration "$out")"; then
  echo "assemble: 出力の尺を取得できませんでした: $out" >&2
  exit 1
fi
if ! awk -v a="$actual" -v t="$total" -v p="$frame_period" \
  'BEGIN{ d = (a + 0) - (t + 0); if (d < 0) d = -d; exit !(d <= (p + 0)) }'; then
  echo "assemble: 出力の実尺が期待値と一致しません（期待 ${total}s / 実測 ${actual}s）: $out" >&2
  echo "  シーンが連結されずに捨てられた可能性があります。-t の値とシーン尺を確認してください。" >&2
  exit 1
fi

# BGM 指定時は完成物そのものを測る。入力音源の音量だけでは、fade / filter / encode 後の
# 可聴性を保証できない。音声ストリーム不在や volumedetect の解析不能も未検証成功にしない。
if [ -n "$bgm" ]; then
  if volume_report="$(ffmpeg -nostdin -hide_banner -i "$out" -map 0:a:0 \
    -af volumedetect -f null - 2>&1)"; then
    :
  else
    rc=$?
    unlink "$out" 2>/dev/null || true
    echo "assemble: 出力音声の可聴性を測定できませんでした（volumedetect exit ${rc}）: $out" >&2
    exit 1
  fi
  max_volume="$(printf '%s\n' "$volume_report" | sed -n 's/.*max_volume: \([-+0-9.]*\) dB.*/\1/p' | tail -1)"
  if ! awk -v v="$max_volume" 'BEGIN{exit !(v ~ /^-?[0-9]+(\.[0-9]+)?$/)}'; then
    unlink "$out" 2>/dev/null || true
    echo "assemble: 出力音声の max_volume を解析できませんでした（volumedetect: ${max_volume:-空}）: $out" >&2
    exit 1
  fi
  if ! awk -v v="$max_volume" 'BEGIN{exit !((v + 0) >= -20)}'; then
    unlink "$out" 2>/dev/null || true
    echo "assemble: BGM が実質無音です（実測 max_volume ${max_volume} dB < 閾値 -20 dB）" >&2
    exit 1
  fi
fi

echo "assembled ${#scenes[@]} scenes (${actual}s, xfade ${xfade}s) -> $out"
