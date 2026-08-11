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
# 0 以下の値をここで別途弾く必要はない。xfade を実際に使う n>=2 では後段の
# 「クロスフェード > フレーム周期」検査がより具体的な診断つきで弾き、n==1 では xfade が
# 一度も使われないため。
case "$xfade" in
  ''|.*|*[!0-9.]*|*.*.*) echo "assemble: -t は正の数値で指定してください（先頭ドット表記は不可）: $xfade" >&2; exit 1 ;;
esac

scenes=("$@")
for scene in "${scenes[@]}"; do
  [ -f "$scene" ] || { echo "assemble: シーンが見つかりません: $scene" >&2; exit 1; }
done
if [ -n "$bgm" ] && [ ! -f "$bgm" ]; then
  echo "assemble: BGM が見つかりません: $bgm" >&2
  exit 1
fi

# 入力の尺はコンテナ尺で採る。単一ストリームの入力ではストリーム尺と一致し、複数ストリームを
# 持つ素材でも「素材全体の長さ」がここで欲しい値。ストリーム尺は容器によって `N/A` になる
# （Matroska 等）ため、正当な入力を弾いてしまう。
# ffprobe の戻り値は文字列で来る。`N/A` を awk の文字列比較が素通りさせるため、数値化して
# 正値であることを確かめる述語をひとつに集約する（判定を変えるときの直し漏れを防ぐ）。
is_positive() {
  awk -v v="$1" 'BEGIN{exit !((v + 0) > 0)}'
}

probe_duration() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
}

# BGM の音声ストリームの有無。無い入力を渡すと `[N:a]` のマッピングで ffmpeg が落ちるだけで、
# 原因が -b の指定であることが診断に出ない。
probe_audio_codec() {
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$1" \
    | awk 'NF { print; exit }'
}

# 映像のフレームレート（`num/den`）。同じストリームが複数回列挙される容器（mpegts 等）が
# あるため、最初の非空行だけを採る。
probe_frame_rate() {
  ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$1" \
    | awk 'NF { print; exit }'
}

# 出力のフレーム数。秒尺ではなくフレーム数で照合するのは render.mjs と同じ理由に加え、
# フレーム数は容器に依存しない（Matroska はストリーム尺を持たないが nb_read_packets は返す）。
probe_frame_count() {
  ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets \
    -of csv=p=0 "$1" | awk 'NF { print; exit }'
}

durations=()
frame_rate=""
frame_period=""
for scene in "${scenes[@]}"; do
  if ! d="$(probe_duration "$scene")"; then
    echo "assemble: ffprobe がシーンの解析に失敗しました: $scene" >&2
    exit 1
  fi
  # 数値であることを収集地点で確かめる。ここを空検査だけで通すと、ffprobe が `N/A` を返した
  # 素材が下のマージン判定まで運ばれ、「クロスフェード不足」という誤った原因で報告される。
  if ! is_positive "$d"; then
    echo "assemble: シーンの尺を数値で取得できません: $scene (ffprobe: ${d:-空})" >&2
    exit 1
  fi
  durations+=("$d")

  if ! r="$(probe_frame_rate "$scene")"; then
    echo "assemble: ffprobe がシーンのフレームレート取得に失敗しました: $scene" >&2
    exit 1
  fi
  p="$(awk -F/ -v r="$r" 'BEGIN{ split(r, f, "/"); if (f[1] + 0 > 0 && f[2] + 0 > 0) printf "%.9f", f[2] / f[1] }')"
  if ! is_positive "$p"; then
    echo "assemble: シーンのフレームレートを数値で取得できません: $scene (ffprobe: ${r:-空})" >&2
    exit 1
  fi
  # xfade は入力の frame rate が揃っていないとフィルタ構成に失敗する。ここで弾かないと
  # ffmpeg のフィルタ解析エラーだけが残り、どのシーンが原因かが診断から消える。
  if [ -z "$frame_rate" ]; then
    frame_rate="$r"
    frame_period="$p"
  elif [ "$r" != "$frame_rate" ]; then
    echo "assemble: シーンのフレームレートが一致しません（$frame_rate と $r）。xfade は同一 fps を要求します: $scene" >&2
    exit 1
  fi
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
  if ! awk -v x="$xfade" -v p="$frame_period" 'BEGIN{exit !((x + 0) > (p + 0))}'; then
    echo "assemble: クロスフェード ${xfade}s がシーンのフレーム周期 ${frame_period}s 以下です（1 フレーム分を超える値が必要）" >&2
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
  if ! bgm_duration="$(probe_duration "$bgm")"; then
    echo "assemble: ffprobe が BGM の解析に失敗しました: $bgm" >&2
    exit 1
  fi
  # シーン尺と同じ扱いにする。ffprobe が `N/A` を返す入力では awk が文字列比較へ落ち、
  # `"N/A" < "3.500"` が偽になって下の尺不足ガードが黙って通る。
  if ! is_positive "$bgm_duration"; then
    echo "assemble: BGM の尺を数値で取得できません: $bgm (ffprobe: ${bgm_duration:-空})" >&2
    exit 1
  fi
  # `-shortest` を発行していないため映像は BGM 長に切り詰められないが、BGM が総尺より短いと
  # 末尾が無音になる。無音の完成尺を黙って出さないためにここで落とす。
  if ! awk -v b="$bgm_duration" -v t="$total" 'BEGIN{exit !((b + 0) >= (t + 0))}'; then
    echo "assemble: BGM が総尺より短く末尾が無音になります（BGM ${bgm_duration}s < 総尺 ${total}s）" >&2
    exit 1
  fi
  if [ -z "$(probe_audio_codec "$bgm")" ]; then
    echo "assemble: BGM に音声ストリームがありません: $bgm" >&2
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

# 一時パスへ書いて、照合を通ったものだけを `$out` へ移す。失敗経路（ffmpeg の異常終了・中断・
# 照合不合格）で `$out` に触れないため、壊れた成果物が出力パスに残らず、既存の正常な成果物も
# 破壊されない。失敗ごとに削除を足していく形にすると、削除し忘れた経路が必ず残る。
# 拡張子は末尾に残す。ffmpeg は出力の muxer を拡張子から決めるため、`.part` で終わる名前に
# 書かせると容器を選べず失敗する。
out_ext=""
case "$out" in *.*) out_ext=".${out##*.}" ;; esac
tmp_out="$(mktemp "${out}.XXXXXX${out_ext}")"
# signal 側は明示的に exit する。exit を欠くと bash が signal を consume して以降の処理を
# 続行し、一時ファイルを消したうえで無関係な原因を報告する（canonical:
# plugins/rite/references/bash-trap-patterns.md）。
_assemble_cleanup() { rm -f "${tmp_out:-}"; }
trap 'rc=$?; _assemble_cleanup; exit $rc' EXIT
trap '_assemble_cleanup; exit 130' INT
trap '_assemble_cleanup; exit 143' TERM
trap '_assemble_cleanup; exit 129' HUP

# rc の捕捉は if/else 形式で行う（`if ! cmd; then rc=$?` は bash 仕様上 `$?` が常に 0 になる）。
if ffmpeg "${args[@]}" -filter_complex "$filter" "${maps[@]}" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -map_metadata -1 -t "$total" "$tmp_out"; then
  :
else
  rc=$?
  echo "assemble: ffmpeg が exit code ${rc} で終了しました" >&2
  exit "$rc"
fi

# 出力のフレーム数を実測して期待値と突き合わせる。ffmpeg はフィルタ側の入力が途中で尽きても
# exit 0 で短い成果物を残すため（xfade の offset 計算がずれた場合に silent な素材欠落として
# 現れる）、成果物そのものを測らないと検出できない。
# 秒尺ではなくフレーム数を使うのは render.mjs と同じ理由に加え、フレーム数が容器に依存しない
# ため（Matroska はストリーム尺を持たないが nb_read_packets は返す）。
# 判定は短い側のみ、許容差 1 枚。`-t "$total"` が出力尺の上限を固定するため実測が期待値を
# 超えるのは期待値の %d 丸め分（最大 1 枚）に限られ、長い側で失敗が起きる経路がない。
# 実測（24/25/30/60fps × 整数尺/端数尺 × 1〜3 シーン）でも差は 0 か +1 のみで、短い側へは
# 一度も振れなかった。素材が捨てられる欠落は数十枚単位で出るのでこの幅に隠れない。
expected_frames="$(awk -v t="$total" -v p="$frame_period" 'BEGIN{printf "%d", (t / p) + 0.5}')"
if ! actual_frames="$(probe_frame_count "$tmp_out")"; then
  echo "assemble: ffprobe が出力の解析に失敗しました" >&2
  exit 1
fi
if ! awk -v a="$actual_frames" -v e="$expected_frames" \
  'BEGIN{ exit !((a + 0) > 0 && (e + 0) - (a + 0) <= 1) }'; then
  echo "assemble: 出力のフレーム数が期待値より不足しています（期待 ${expected_frames} / 実測 ${actual_frames:-取得不能}、宣言尺 ${total}s）" >&2
  echo "  シーンが連結されずに捨てられた可能性があります。-t の値とシーン尺を確認してください。" >&2
  exit 1
fi

mv -f "$tmp_out" "$out"
tmp_out=""

echo "assembled ${#scenes[@]} scenes (${total}s, xfade ${xfade}s) -> $out"
