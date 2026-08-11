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

# 契約ガード + 決定論をまとめて検証（T-03 → T-02 の順。どちらか失敗で非ゼロ終了）
npm run check

# 個別に実行する場合
./check-contract.sh                                      # 契約違反シーンがエラー終了するか（AC-3）
./check-determinism.sh render/fixtures/valid-scene.html  # 2 回レンダして md5 比較（AC-2）

# シーンを連結（クロスフェード 0.5s、BGM は任意）
./assemble.sh -o out/final.mp4 -t 0.5 out/01.mp4 out/02.mp4
./assemble.sh -o out/final.mp4 -b bgm.mp3 out/01.mp4 out/02.mp4
```

`npm run check` は Chrome を起動するため **sandbox 外**で実行する（下記「環境前提」参照）。
リポジトリ root の `rite-config.yml` の `commands.test` には登録しない — 本リポジトリは
markdown 中心で、全 PR の lint 経路に Chrome 実行を持ち込むのは Issue #2240 の Non-goal
（CI での動画レンダリング）に反するため。

## 環境前提

依存の床は **playwright-core（npm）+ ローカル Chrome + ffmpeg / ffprobe** の 3 つだけ。
いずれも当該 API は枯れており、フレームワークの仕様変更へ追従する必要がない。

| 前提 | 内容 |
|------|------|
| Chrome | 既定は `/usr/bin/google-chrome`。別の場所にあるときは `CHROME_PATH` で上書きする（不在なら起動前にエラー終了） |
| GPU | `--disable-gpu` で software rasterizer に固定する。**WSL2 実測**: GPU 経路（SwiftShader）は描画が揺らぎ、決定論が崩れる |
| screenshot | **WSL2 実測**: SwiftShader の揺らぎで screenshot が散発的に失敗する（スパイク中に実際に 1 回発生）。150ms 間隔で最大 3 回試行し、3 回連続で失敗したらエラー終了する |
| sandbox | Chrome 起動は Claude Code sandbox の Unix socket 制約に当たる。レンダーは **sandbox 外**（通常の端末、または `dangerouslyDisableSandbox`）で実行する |
| CI | 動画レンダリングは CI に載せない。Chrome 実行と生成物サイズの割に得るものがなく、決定論チェックはローカル手動で足りる |

## エラー時の挙動（fail-loud）

検査は**契約違反と環境不足**に絞る（Issue #2240 §4.5 のエラー表）。下表は実際に検査を書いた
条件の一覧であり、「これ以外の異常が起きない」という主張ではない（未検査の経路は下記
「検査していないこと」を参照）。

### レンダー（`render/render.mjs`）

| 条件 | 挙動 |
|------|------|
| fps が正の数値でない | エラー終了（渡された値を表示） |
| シーン HTML が存在しない | エラー終了（Chrome はエラーページを load 完了扱いにするため、真っ白な mp4 が生成されるのを防ぐ） |
| Chrome が見つからない | エラー終了（探索パスを表示） |
| Chrome の起動に失敗 | エラー終了（sandbox 外で実行するよう案内。sandbox 内では Unix socket 制約で必ずここに落ちる） |
| `window.SCENE` 未宣言 | エラー終了。回帰は `check-contract.sh` が pin する |
| `duration_ms` が正の数値でない | エラー終了（実際の値を表示） |
| 宣言尺 × fps でフレームが 0 枚 | エラー終了（尺と fps を表示。弾かないと ffmpeg の入力ゼロ終了として現れ、真因が診断から消える） |
| screenshot が 3 回連続で失敗 | エラー終了（フレーム欠落のまま続行しない）。成功して終わった回もリトライ 1 件ごとに stderr へ記録する |
| ffmpeg の起動失敗 / 書き込み中断 / 非ゼロ終了 | エラー終了（exit code、signal 終了なら signal 名を表示） |
| シーン内で未捕捉の JavaScript 例外 | エラー終了（最初の 1 件を表示）。描画が途中で止まった絵を成功として出さない |

### 連結（`assemble.sh`）

| 条件 | 挙動 |
|------|------|
| `-t` が正の数値でない（`0` / 先頭ドット表記 `.5` / 非数値を含む） | エラー終了（渡された値を表示。ffmpeg のフィルタ解析エラーに原因が埋もれるのを防ぐ。先頭ドットを弾くのは ffmpeg の duration パーサが受理しないため — 実測 exit 234） |
| シーン / BGM のファイルが存在しない | エラー終了（パスを表示） |
| シーン / BGM の尺、シーンのフレームレートを数値で取得できない（ffprobe の非ゼロ終了・`N/A` を含む） | エラー終了（xfade のオフセット計算と出力照合に使う値なので、文字列のまま下流へ流さない） |
| シーン尺がクロスフェードに対して不足（端は `x` 超、中間は前後 2 回食われるため `2x` 超が必要） | エラー終了（該当シーンを表示）。負ないし重複した offset が xfade へ渡ると、ffmpeg は exit 0 のまま素材を捨てた mp4 を残す（実測: 2.0s×3 に `-t 3.0` で総尺 0.000s・ストリーム 0 本の 262 バイト mp4） |
| BGM が総尺より短い | エラー終了（`-t` で映像尺に切り詰めるため、末尾が無音の完成尺になる） |
| ffmpeg が非ゼロ終了 | エラー終了（exit code を表示） |
| 出力の実尺が期待値と一致しない（許容差 1 フレーム周期） | エラー終了（期待値と実測値を表示）。完了行が名乗る尺は解析値ではなく成果物の実測値 |

### 検査していないこと

パイプラインは**利用者が渡した入力を信用する**。下記は検査を書いていない経路で、いずれも
「異常が起きない」という主張ではない。実際に踏んだ実需が出たらその時点で Issue を切る
（CLAUDE.md `no_speculative_structure`）。

- **シーン契約表のうち renderer が検査しないもの**: `transition` 禁止 / `animation-fill-mode: both` 必須 / 非決定的な値（`Math.random()` 等）の不使用。いずれも著者側の遵守事項で、破っても診断ゼロで完走する。`Math.random()` を使ったシーンは 2 回レンダで md5 が割れるため、破れは `check-determinism.sh` でのみ検出できる
- レンダー出力 mp4 のフレーム数が宣言尺と一致するか。実測照合は Issue #2240 の T-01（手動テスト）が担う（連結側 `assemble.sh` は出力を実測照合する）
- シーン間でフレームレートが揃っているか。xfade は揃っていない入力に対し ffmpeg 側のフィルタ構成エラーで落ちる（実測: 30fps + 15fps は exit 234）
- BGM に音声ストリームが実在するか（拡張子だけ音声のファイル等）
- 失敗した実行は出力パスに書きかけの mp4 を残す。終了コードは非ゼロなので、成功と取り違える経路はない

## コミットしないもの

- `out/`（レンダー成果物の mp4）— リポジトリ root の `.gitignore` の `media/intro-video*/**/*.mp4` が拾う
- BGM の mp3 — 同じく root `.gitignore`。ライセンス上の理由は [PROVENANCE.md](./PROVENANCE.md) を参照
- `node_modules/` — 本ディレクトリの `.gitignore`
