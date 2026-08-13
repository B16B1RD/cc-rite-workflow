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
- Issue #2297 で英語シーン（`scenes-en/`）と画面上のバージョン表記（M1 / M7）を追加し、
  両 README の Demo を本ディレクトリのフルカットへ差し替えた。README 掲載までを 1 本の
  Issue に含めたのは、Issue #2258 が README 埋め込みを Non-goal にしたまま後続 Issue が
  作られず、Demo が旧版のまま取り残されたためである。

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

本カットの 2 本（フル / SNS）には、既存 HyperFrames 版と同じ
**BombinSound — Technology**（Pixabay, track ID `499581`、実測 89.78 秒）を使用する。
Pixabay から
`bombinsound-technology-tech-technology-90-second-499581.mp3` を取得してこのディレクトリ直下に
置く。入手元・Pixabay Content License・生 mp3 をコミットしない理由は
[../intro-video/PROVENANCE.md](../intro-video/PROVENANCE.md) の記録を正本とする。

以前の生成方式は、可聴性ガードを通る音量を持たないため棄却済みである。音量係数を足して
ガードを通す形でも再導入しない。`assemble.sh` は BGM が総尺より短いとエラー終了するが、
本曲はフルカットの完成尺 55.0 秒に足りる。

## レンダーと連結の手順

クリーン checkout からは、依存をインストールして次のコマンドで 7 シーンを規定名へレンダする。

```bash
npm ci
mkdir -p out out/en
for scene in 01-problem 02-unknowns 03-loop 04-gates 05-wiki 06-second-lap 07-closing; do
  node render/render.mjs "scenes/${scene}.html" "out/${scene}.mp4" 30
  node render/render.mjs "scenes-en/${scene}.html" "out/en/${scene}.mp4" 30
done
```

BGM を用意した後、2 本のカットを連結する。

```bash
# フルカット（M1〜M7、約 55.0 秒）
./assemble.sh -P -o out/rite-intro-v2-full.mp4
./assemble.sh -P -d out/en -o out/rite-intro-v2-full-en.mp4

# SNS カット（M1 + M3 + M5 + M7、約 31.5 秒）
./assemble.sh -o out/rite-intro-v2-sns.mp4 -t 0.5 -b bombinsound-technology-tech-technology-90-second-499581.mp3 \
  out/01-problem.mp4 out/03-loop.mp4 out/05-wiki.mp4 out/07-closing.mp4
./assemble.sh -o out/rite-intro-v2-sns-en.mp4 -t 0.5 -b bombinsound-technology-tech-technology-90-second-499581.mp3 \
  out/en/01-problem.mp4 out/en/03-loop.mp4 out/en/05-wiki.mp4 out/en/07-closing.mp4
```

完成動画は楽曲単体ではなく映像・タイポグラフィ・アニメーションを組み合わせた新たな制作物として
配布する。

`-P` は現行のフルカット（M1〜M7）と上記の既定 BGM を選ぶ。`-d` はそのシーン探索先で、
既定 `out`（日本語）に対し英語は `out/en` を指す。SNS カットはフルカットとシーン構成が
異なるため、意図が見える上記のシーン明示形を正とする。

## README への公開手順

README の Demo に映る動画の正本は git ではなく **GitHub の user-attachments URL** である。
`out/*.mp4` は `.gitignore` 済みの再生成物であり、シーン HTML を更新しても README の Demo は
変わらない。差し替えは次の順で行う。

1. 上記の手順で日英フルカットをレンダ・連結する
2. `ffprobe` で 1280x720 / 30fps / 約 55.0 秒、`stat` で 10,485,760 bytes 以下を確認する
   （GitHub のコメント添付上限。超えたらアップロードせず圧縮または絵を見直す）
3. 2 本を GitHub の Issue / PR コメントへドラッグしてアップロードし、生成された
   `https://github.com/user-attachments/assets/<uuid>` を控える（Web UI が要るため人手の工程）
4. `README.md` に英語カットの URL、`README.ja.md` に日本語カットの URL を書く
5. URL が両 README に入るまで PR を Ready にしない

5 を運用として明記するのは、URL 差し替えを follow-up に回した PR（Issue #2258 / PR #2029）が
そのまま忘れられ、Demo が旧版のまま公開され続けた実績があるためである。
