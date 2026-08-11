# DESIGN.md — 内製 frame-step レンダリングパイプライン

`media/intro-video-v2/` は、外部動画フレームワークに依存せず HTML → mp4 を**決定論的に**生成する
最小パイプラインである。シーンの実体（絵コンテ・実際の動画）はこのディレクトリの管轄外で、
本ドキュメントは**パイプラインの契約**だけを定める。

HyperFrames 版（`media/intro-video/` / `media/intro-video-en/`）は変更せず併存させる。

## なぜ frame-step なのか

全アニメーションを `pause()` し、`currentTime` を 1/fps ずつ進めながら screenshot を撮る。
実時間録画（screencast 系 API）はフレーム到達時刻が実行環境の負荷に依存するため、
**同一シーンを 2 回レンダしても mp4 が一致しない**。frame-step は仮想時計だけで駆動するので
一致する — 2026-08-11 のスパイクで 2 シーン計 360 フレームの md5 完全一致を実測済み。

一致するということは、シーン HTML を編集したときの mp4 の差分が**編集意図だけを反映する**
ということでもある。`check-determinism.sh` はこの性質が壊れていないことを確かめる退路。

## シーン契約

1 シーン = 1 HTML ファイル。renderer はこの契約だけを前提にする。

| 契約 | 内容 |
|------|------|
| 尺の宣言 | `window.SCENE = { duration_ms: <正の数値> }` を必ず宣言する。未宣言・非数値・0 以下は**エラー終了**（既定値で続行しない） |
| 動きの表現 | CSS `@keyframes` または WAAPI（`Element.animate()`）のみ。`transition` は**使用禁止** |
| fill-mode | すべてのアニメーションに `animation-fill-mode: both`（WAAPI なら `fill: 'both'`）を付ける |
| 非決定的な値 | `Math.random()` / `Date.now()` / `new Date()` を描画に使わない（フレームごとに絵が変わり決定論が壊れる） |
| 画面サイズ | 1280x720 固定（`render.mjs` の `WIDTH` / `HEIGHT`）。`deviceScaleFactor` は 1 |

**`transition` を禁じる理由**: `transition` は Web Animations API の `getAnimations()` で
取得できるが、開始トリガが実時間のイベント（クラス付与・レイアウト確定）に紐づくため、
`currentTime` の seek だけでは所定の位置に戻せない。`@keyframes` は宣言時点で時間軸が
確定しているので seek で完全に再現できる。

**`fill-mode: both` を必須にする理由**: 指定が無いと seek 位置がアニメーション区間の外に
出た瞬間に要素が初期値へ戻る。尺の先頭・末尾フレームが意図しない絵になる。

シーンはブラウザで HTML を直接開けばそのままプレビューできる（renderer は seek するだけで
DOM を書き換えないため、実時間再生の見えとレンダ結果が一致する）。

契約の最小例は `render/fixtures/valid-scene.html` を参照。

## 使い方

```bash
cd media/intro-video-v2
npm install                                              # playwright-core のみ

# 1 シーンを mp4 化
node render/render.mjs render/fixtures/valid-scene.html out/01.mp4 30

# 決定論チェック（2 回レンダして md5 比較。不一致なら非ゼロ終了）
./check-determinism.sh render/fixtures/valid-scene.html

# シーンを連結（クロスフェード 0.5s、BGM は任意）
./assemble.sh -o out/final.mp4 -t 0.5 out/01.mp4 out/02.mp4
./assemble.sh -o out/final.mp4 -b bgm.mp3 out/01.mp4 out/02.mp4
```

## 環境前提

依存の床は **playwright-core（npm）+ ローカル Chrome + ffmpeg / ffprobe** の 3 つだけ。
いずれも当該 API は枯れており、フレームワークの仕様変更へ追従する必要がない。

| 前提 | 内容 |
|------|------|
| Chrome | 既定は `/usr/bin/google-chrome`。別の場所にあるときは `CHROME_PATH` で上書きする（不在なら起動前にエラー終了） |
| GPU | `--disable-gpu` で software rasterizer に固定する。**WSL2 実測**: GPU 経路（SwiftShader）は描画が揺らぎ、決定論が崩れる |
| screenshot | **WSL2 実測**: SwiftShader の揺らぎで screenshot が散発的に失敗する（スパイク中に実際に 1 回発生）。150ms 間隔で 3 回リトライし、それでも失敗したらエラー終了する |
| sandbox | Chrome 起動は Claude Code sandbox の Unix socket 制約に当たる。レンダーは **sandbox 外**（通常の端末、または `dangerouslyDisableSandbox`）で実行する |
| CI | 動画レンダリングは CI に載せない。Chrome 実行と生成物サイズの割に得るものがなく、決定論チェックはローカル手動で足りる |

## エラー時の挙動（fail-loud）

黙って劣化した mp4 を残す経路を作らない。同じ帰結（不正な mp4 が正常終了で残る）に至る
出口はすべて塞いである。

| 条件 | 挙動 |
|------|------|
| シーン HTML が存在しない | エラー終了（Chrome はエラーページを load 完了扱いにするため、真っ白な mp4 が生成されるのを防ぐ） |
| Chrome が見つからない | エラー終了（探索パスを表示） |
| `window.SCENE` 未宣言 | エラー終了 |
| `duration_ms` が正の数値でない | エラー終了（実際の値を表示） |
| 宣言尺 × fps でフレームが 0 枚 | エラー終了 |
| screenshot が 3 回連続で失敗 | エラー終了（フレーム欠落のまま続行しない） |
| ffmpeg の起動失敗 / 途中終了 / 非ゼロ終了 | エラー終了（exit code を表示） |
| 出力フレーム数が宣言尺と不一致 | エラー終了（ffprobe で実測して照合。ffmpeg は入力が尽きても exit 0 で短い mp4 を残せるため） |
| 連結時に BGM が総尺より短い | エラー終了（`-shortest` で映像が黙って切り詰められるのを防ぐ） |
| 連結時にクロスフェードがシーン尺より長い | エラー終了 |

## コミットしないもの

- `out/`（レンダー成果物の mp4）— リポジトリ root の `.gitignore` の `media/intro-video*/**/*.mp4` が拾う
- BGM の mp3 — 同じく root `.gitignore`。ライセンス上の理由は [PROVENANCE.md](./PROVENANCE.md) を参照
- `node_modules/` — 本ディレクトリの `.gitignore`
