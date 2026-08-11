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

外部楽曲は使わず、ffmpeg の音源フィルタだけで生成したオリジナルのアンビエント音を使用する。
第三者素材を含まないため、外部ライセンスや帰属表示はない。ローカル名は
`rite-synth-bgm.mp3` とし、再生成コマンドは次のとおり。

```bash
ffmpeg -y \
  -f lavfi -i 'sine=frequency=110:duration=45:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=164.81:duration=45:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=220:duration=45:sample_rate=48000' \
  -filter_complex '[0:a]volume=0.025[a0];[1:a]volume=0.018[a1];[2:a]volume=0.012[a2];[a0][a1][a2]amix=inputs=3,lowpass=f=900,aecho=0.8:0.75:60:0.12[out]' \
  -map '[out]' -c:a libmp3lame -b:a 192k rite-synth-bgm.mp3
```

生成した mp3 は再生成可能な中間素材としてコミットしない。クリーン checkout からは、依存を
インストールして次のコマンドで 5 シーンを規定名へレンダする。

```bash
npm ci
mkdir -p out
for scene in 01-problem 02-loop 03-terminal 04-gates 05-closing; do
  node render/render.mjs "scenes/${scene}.html" "out/${scene}.mp4" 30
done
```

BGM を上記コマンドで生成した後、次を実行する。

```bash
./assemble.sh -P -o out/rite-intro-v2.mp4
```

`-P` は `out/01-problem.mp4` から `out/05-closing.mp4` までを絵コンテ順に連結し、生成 BGM を
fade in/out 付きで合成する。完成動画は楽曲単体ではなく映像・タイポグラフィ・アニメーションを
組み合わせた新たな制作物として配布する。
