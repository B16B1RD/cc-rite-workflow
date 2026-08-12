# intro-video-v2 — 来歴と取り扱い

外部動画フレームワークに依存しない内製 frame-step レンダリングパイプライン。
シーン契約と使い方は [DESIGN.md](./DESIGN.md) を参照。

## 来歴

- 2026-08-11 のスパイクで frame-step 方式（仮想時計 seek → screenshot → ffmpeg pipe）の
  決定論を実証した。2 シーン計 360 フレーム（1280x720 / 30fps）を 2 回独立にレンダし、
  mp4 の md5 が完全一致することを確認している。
- Issue #2240 でスパイク版を本パイプラインとして整備した。スパイク版からの差分は次の 3 系統:
  - **fail-loud 化**: シーン契約違反（`window.SCENE` の未宣言・`duration_ms` 非数値）、
    契約適合でも成果物が壊れる組み合わせ（宣言尺 × fps でフレーム 0 枚、シーン内の未捕捉例外）、
    環境不足（Chrome / シーンの不在、ffmpeg の異常終了）、および Chrome パスの解決。
    失敗時は出力パスに成果物を残さない
  - **連結側の新規設計**: `-t` の入力検証、クロスフェードのフレーム周期下限、シーン尺のマージン
    検査、BGM 尺不足の検査、BGM fade の総尺追従、出力実尺の照合。スパイク版に対応物はなく、
    本 Issue のレビュー中に設計した
  - **契約の自動 pin**: `check-contract.sh`（AC-3 / T-03）。fixture を置くだけでは契約ガードを
    消しても決定論チェックが green のまま通ることを変異実験で確認したため追加した。
    レンダー側の各 fail-loud ガードに 1 ケースずつ対応させている
- レンダー出力のフレーム数照合は実行時ガードに置かず、Issue の手動テスト（T-01）が担う。
- Issue #2258 で絵コンテを「回るたび、賢くなる」（複利の物語）へ作り直し、シーンを 7 本に
  組み替えた。同じシーン mp4 群からフルカットと SNS カットの 2 本を作る構成になっている。

## 既存 HyperFrames 版との関係

`media/intro-video/`（日本語字幕版）と `media/intro-video-en/`（英語版）は HyperFrames で
制作した既存の紹介動画で、**本ディレクトリとは併存**する。v2 の整備で既存版を変更・削除しない。

採用の分かれ目は「仕様変更への追従を誰の Issue で回すか」にある。HyperFrames 版は上流の
リリースノートを追う必要があるが、内製版の仕様変更は自リポジトリの Issue として
rite workflow 自身で回せる。

## ビルド / プレビュー

```bash
cd media/intro-video-v2
npm install
node render/render.mjs <scene.html> out/<name>.mp4 30
npm run check                       # 契約ガード (AC-3) + 決定論 (AC-2)
./assemble.sh -o out/final.mp4 out/01.mp4 out/02.mp4
```

レンダリングには playwright-core + ローカル Chrome + ffmpeg / ffprobe が必要。
シーンのプレビューはブラウザで HTML を直接開けばよい（別途プレビューサーバは不要）。

## コミットしないもの（`.gitignore` 済み）

| 対象 | 理由 |
|------|------|
| `out/*.mp4`（レンダー成果物） | 再生成可能なビルド成果物。リポジトリ root の `.gitignore` の `media/intro-video*/**/*.mp4` が拾う |
| `*.mp3`（BGM） | 後述のライセンス制約のため。同じく root `.gitignore` |
| `node_modules/` | ローカル依存。本ディレクトリの `.gitignore` |

## BGM について

BGM は本リポジトリに含めない。`assemble.sh -b <file>` で合成する場合、素材の入手と
ライセンス確認は利用者側の責任で行う。

既存の HyperFrames 版で使用している Pixabay の楽曲を流用する場合の制約は
[../intro-video/PROVENANCE.md](../intro-video/PROVENANCE.md) に記載がある — 要点は
「生の mp3 を公開リポジトリに置かない（standalone 配布に該当しうる）」「映像に合成した
動画そのものの配布は問題ない」の 2 点。

### ショート動画 v2 で使用する BGM

**本カットの 2 本（フル / SNS）には、下記レシピで生成した `rite-synth-bgm-58s.mp3`
（実測 58.104 秒）を合成している。** 外部楽曲は使わず ffmpeg の音源フィルタだけで作るため、
第三者素材を含まず外部ライセンスや帰属表示は発生しない。生成物は `*.mp3` の gitignore 対象で
コミットしないが、下記コマンドがそのまま再現手段になる（`{duration}` を変えるだけで任意の尺を
作れる）:

```bash
# {duration} を秒数へ置換する。本カットには 58、尺不足ガードの検証には 45 を使う。
ffmpeg -y \
  -f lavfi -i 'sine=frequency=110:duration={duration}:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=164.81:duration={duration}:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=220:duration={duration}:sample_rate=48000' \
  -filter_complex '[0:a]volume=0.25[a0];[1:a]volume=0.18[a1];[2:a]volume=0.12[a2];[a0][a1][a2]amix=inputs=3,lowpass=f=900,aecho=0.8:0.75:60:0.12,volume=15[out]' \
  -map '[out]' -c:a libmp3lame -b:a 192k rite-synth-bgm-58s.mp3
```

A2・E3・A3 の正弦波を弱く重ね、`lowpass` と `aecho` で角を落としたアンビエント音になる。
末尾の `volume=15` は `assemble.sh` の可聴性ガードを通すために必要で、これを外すと
生成物は max_volume −58 dB 前後になり、合成後の完成物が閾値 −20 dB を下回って assemble が
失敗する（実測: `volume` 無し −58.1 dB / `volume=15` −14.5 dB）。

`assemble.sh` は **BGM が総尺より短いとエラー終了する**（末尾が無音の完成尺を黙って出さない
ため）。フルカットの完成尺は 55.0 秒なので、`duration=58` の生成物がそのまま足りる。
`duration=45` の生成物（実測 45.096 秒）はこのガードが発火することの確認に使う。

既存 HyperFrames 版と同じ **BombinSound — Technology**（Pixabay, track ID `499581`、90 秒）も
代替候補として使える。その場合は Pixabay から
`bombinsound-technology-tech-technology-90-second-499581.mp3` を取得してこのディレクトリ直下に
置く。入手元・Pixabay Content License・生 mp3 をコミットしない理由は
[../intro-video/PROVENANCE.md](../intro-video/PROVENANCE.md) の記録を正本とする。90 秒あるため
フルカットにはそのまま足りるが、**本カットの音声は上記の合成音であり、Pixabay 曲へ差し替えると
音は一致しない**。

## レンダーと連結の手順

クリーン checkout からは、依存をインストールして次のコマンドで 7 シーンを規定名へレンダする。

```bash
npm ci
mkdir -p out
for scene in 01-problem 02-unknowns 03-loop 04-gates 05-wiki 06-second-lap 07-closing; do
  node render/render.mjs "scenes/${scene}.html" "out/${scene}.mp4" 30
done
```

BGM を用意した後、2 本のカットを連結する（配布物と同じ音声にするには `duration=58` の生成物を使う）。

```bash
# フルカット（M1〜M7、約 55.0 秒）
./assemble.sh -o out/rite-intro-v2-full.mp4 -t 0.5 -b rite-synth-bgm-58s.mp3 \
  out/01-problem.mp4 out/02-unknowns.mp4 out/03-loop.mp4 out/04-gates.mp4 \
  out/05-wiki.mp4 out/06-second-lap.mp4 out/07-closing.mp4

# SNS カット（M1 + M3 + M5 + M7、約 31.5 秒）
./assemble.sh -o out/rite-intro-v2-sns.mp4 -t 0.5 -b rite-synth-bgm-58s.mp3 \
  out/01-problem.mp4 out/03-loop.mp4 out/05-wiki.mp4 out/07-closing.mp4
```

完成動画は楽曲単体ではなく映像・タイポグラフィ・アニメーションを組み合わせた新たな制作物として
配布する。

> `assemble.sh` の `-P`（プリセット）は Issue #2240 当時の 5 シーン構成（`01-problem` /
> `02-loop` / `03-terminal` / `04-gates` / `05-closing`）と Pixabay 曲名を既定値に持ったままで、
> 現構成では使えない（実測: `assemble: シーンが見つかりません: out/02-loop.mp4` で終了する）。
> 同スクリプトの usage 文言も「レンダ済み 5 シーンと既定 BGM」と旧構成のままである。
> `assemble.sh` は Issue #2258 の変更対象外だったため据え置いており、上記のシーン明示形を正とする。
> `-P` の新構成対応（または撤去）は Issue #2259 で扱う。
