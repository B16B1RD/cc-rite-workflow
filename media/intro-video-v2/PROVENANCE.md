# intro-video-v2 — 来歴と取り扱い

外部動画フレームワークに依存しない内製 frame-step レンダリングパイプライン。
シーン契約と使い方は [DESIGN.md](./DESIGN.md) を参照。

## 来歴

- 2026-08-11 のスパイクで frame-step 方式（仮想時計 seek → screenshot → ffmpeg pipe）の
  決定論を実証した。2 シーン計 360 フレーム（1280x720 / 30fps）を 2 回独立にレンダし、
  mp4 の md5 が完全一致することを確認している。
- Issue #2240 でスパイク版を本パイプラインとして整備した。スパイク版からの差分は、
  契約違反（`window.SCENE`）・環境不足（Chrome / シーンの不在、ffmpeg の異常終了）の
  fail-loud 化と Chrome パスの解決に限る。出力そのものの検証は実行時ガードではなく
  `check-determinism.sh` と Issue の手動テスト（T-01 / T-02 / T-03）が担う。

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
./check-determinism.sh <scene.html>
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
