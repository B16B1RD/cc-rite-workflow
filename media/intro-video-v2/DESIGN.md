# DESIGN.md — 内製 frame-step レンダリングパイプライン

`media/intro-video-v2/` は、外部動画フレームワークに依存せず HTML → mp4 を**決定論的に**生成する
最小パイプラインである。シーンの実体（絵コンテ・実際の動画）はこのディレクトリの管轄外で、
本ドキュメントは**パイプラインの契約**だけを定める。

HyperFrames 版（`media/intro-video/` / `media/intro-video-en/`）は変更せず併存させる。

## ショート動画 v2 絵コンテ

### ねらい

「Issue を渡すと自律で回り、**止まるべき所で止まり、回るたびプロジェクトが賢くなる**」ことを、
同じシーン群から作る 2 本のカットで伝える。自律ループ自体はもはや珍しくないため前提として扱い、
rite 固有の差別化 — `/rite:unknowns`（実装前に未知を潰す）・実測必須ゲート・Wiki に残る経験則の
複利 — を主役に据える。M1「何周しても、1周目。」と M7「回るたび、賢くなる。」が対句を成す。

1280x720 / 30fps、シーン間は 0.5 秒のクロスフェードを使う。

### 訴求する 3 点

1. **実装前の探索（`/rite:unknowns`）** — 実装より安い段階で unknowns の 4 象限を埋める。
   手戻りが最も高くつくのは「考慮すらしていないこと」に実装後で気付いたときのため。
2. **実測必須ゲート** — レビュアーの推測をそのまま blocking にせず、実測のない指摘を
   non-blocking に分離する。根拠のある指摘だけで修正ループを駆動するため。
3. **経験則の複利** — cleanup が学びを経験則カードとして Wiki に残し、次のループの実装前に
   自動注入する。一度の自動化ではなく、周回するほどプロジェクト固有の判断材料が増えることを示せるため。

発散検出と circuit breaker は M4 の安全ゲートとして画面に出すが、訴求の主役には置かない。
XS/S 軽量レーンや個別の Projects 操作も同様に、主メッセージをぼかさないため画面から外す。

### シーン構成

| # | ファイル | 宣言尺 | 画面のメッセージ | 役割 | SNS |
|---|---|---:|---|---|:-:|
| M1 | `scenes/01-problem.html` | 6秒 | 何周しても、1周目。 | 問題提起。AI は速いがプロジェクトを学ばない | ● |
| M2 | `scenes/02-unknowns.html` | 9秒 | 実装より安い段階で、未知を潰す。 | `/rite:unknowns` の 4 象限が埋まる。人間の出番 1/2 | |
| M3 | `scenes/03-loop.html` | 10秒 | 自律で回り、draft で待つ。 | `/rite:batch-run <N>` の既定挙動。`[review:mergeable]` 到達後も draft のまま停止する | ● |
| M4 | `scenes/04-gates.html` | 8秒 | 止める条件まで、設計する。 | 実測なし → non-blocking / 発散 → breaker / breaker 後 → full review | |
| M5 | `scenes/05-wiki.html` | 9秒 | 学びが、Wiki に残る。 | 承認（人間の出番 2/2）→ merge → cleanup → 経験則カードを Wiki へ格納 | ● |
| M6 | `scenes/06-second-lap.html` | 8秒 | 2 周目は、学んだ状態で始まる。 | 次の Issue の open で同じカードが実装前に自動注入される | |
| M7 | `scenes/07-closing.html` | 8秒 | 回るたび、賢くなる。 | rite ロゴ、インストール手順で閉じる | ● |

### 2 つのカット

同じシーン mp4 群から、連結する部分集合を変えて 2 本を作る（シーンを作り分けない）。

| カット | 構成 | 宣言尺合計 | クロスフェード | 完成尺 |
|---|---|---:|---|---:|
| フル | M1〜M7 | 58秒 | 6 × 0.5秒 | 約 55.0秒 |
| SNS | M1 + M3 + M5 + M7 | 33秒 | 3 × 0.5秒 | 約 31.5秒 |

SNS カットは「学ばない → draft で待つ自律ループ → 学びが残る → 回るたび賢くなる」で単体でも
物語が閉じる。連結コマンドは [PROVENANCE.md](./PROVENANCE.md) を参照する。

### 日本語版と英語版

シーンは日本語（`scenes/`）と英語（`scenes-en/`）の 2 組を持つ。ファイル名・宣言尺・`@keyframes`・
`animation` 宣言は対応する 2 本で**同一**とし、差分は画面のテキスト、`<html lang>`、および英語の
文字幅差を吸収する局所的な寸法調整に限る。ファイル名を縛るのは `assemble.sh -P` が `-d` の指す
ディレクトリ配下に同じ 7 つの basename を決め打ちで要求するためであり、宣言尺を縛るのは上表の
カット構成とクロスフェードのオフセット計算の前提だからであり、`@keyframes` と `animation` 宣言を
縛るのは対応する 2 本を同じ動きで進めるためである。寸法調整を例外にするのは、英語は
同じ意味でも字幅が変わり、1280x720 に収めるには局所的な調整が要るためである（現に M7 の
`.loop-label` は英語ラベルが長く、`inset` の左右マージンだけ JA と異なる）。

英語シーンを別ディレクトリ（`intro-video-v2-en/`）ではなく本ディレクトリ配下に置くのは、
`render.mjs` / `assemble.sh` / 契約ガードを 1 組に保つためである。分けるのはレンダー成果物だけで、
日本語は `out/`、英語は `out/en/` へ出す。連結時は `assemble.sh -P -d <dir>` でプリセットの
シーン探索先を切り替える。

### 表記の実在根拠

- コマンドの既定挙動: `skills/batch-run/SKILL.md` — 引数なしの `/rite:batch-run <N>` は
  **open → iterate まで進めて draft PR で停止する**（merge しない）。`ready → merge → cleanup`
  まで走らせるのは `--merge` を明示したときだけであり、M3 は既定の挙動を描く
- 4 象限: `skills/unknowns/SKILL.md` の unknowns マトリクス（既知/未知 × 既知の/未知の）
- sentinel: `skills/iterate/SKILL.md` の `[review:mergeable]`
- 実測必須ゲート: `skills/pr-review/SKILL.md` と `references/severity-levels.md`
- 発散検出・breaker 後 full review: `skills/iterate/SKILL.md`
- 知見統合: `skills/cleanup/SKILL.md` の Wiki ingest
- 経験則カードの 4 要素（見出し / ドメイン / 確信度 / サマリー）:
  `hooks/wiki-query-inject.sh` の出力形式。M5 と M6 は同一カードを表示する

性能値や短縮率は画面に出さない。数値として表示するのは、このリポジトリ内で宣言・実測できる
シーン尺、解像度、fps と、製品バージョンだけとする。

製品バージョンだけを例外にするのは、それが訴求の材料ではなく「この動画がどの版の rite を
写しているか」を読み手が確かめるための identifier だからである。表示位置は M1 のヘッダー
バッジと M7 のフッターの 2 箇所（日英とも）。リリースで版が上がったら両シーンの文字列を
更新する — 画面の版と README の配布物がずれた動画は、注記で逃げるしかなくなる。

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
./check-contract.sh                                      # 各 fail-loud ガードの発火（AC-3）
./check-determinism.sh render/fixtures/valid-scene.html  # 2 回レンダして md5 比較（AC-2）

# シーンを連結（クロスフェード 0.5s、BGM は任意）
./assemble.sh -o out/final.mp4 -t 0.5 out/01.mp4 out/02.mp4
./assemble.sh -o out/final.mp4 -b bgm.mp3 out/01.mp4 out/02.mp4

# フルカットのプリセット（-d でシーン探索先を切り替える。既定は out）
./assemble.sh -P -o out/rite-intro-v2-full.mp4
./assemble.sh -P -d out/en -o out/rite-intro-v2-full-en.mp4
```

`npm run check` は契約チェックで Chrome を 4 回、決定論スイープで fixture 1 本と日英 14 シーンを
各 2 回レンダして 30 回、合わせて 34 回起動する。**sandbox 外**で実行する（`./check-contract.sh`
単体も Chrome を要する。下記「環境前提」参照）。
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

レンダー側の各ガードは `check-contract.sh` が「非ゼロ終了 + 期待メッセージ + 成果物が残らないこと」
の 3 点で pin する。`render.mjs` にガードを足したら同スクリプトにもケースを 1 行足し、上の「使い方」節が
名乗る Chrome 起動回数も併せて直すこと（回数は同スクリプトのケース数に直結する） —
fixture を置くだけではガードを消しても決定論チェックが green のまま通る（実測済み）。同スクリプトの
ケース同定は `render.mjs` と `assemble.sh` のメッセージ文言に依存するため、文言を変えると
「契約チェック不能」として検出される（silent には落ちない）。

### レンダー（`render/render.mjs`）

| 条件 | 挙動 |
|------|------|
| fps が正の数値でない | エラー終了（渡された値を表示） |
| シーン HTML が存在しない | エラー終了（Chrome はエラーページを load 完了扱いにするため、真っ白な mp4 が生成されるのを防ぐ） |
| Chrome が見つからない | エラー終了（探索パスを表示） |
| Chrome の起動に失敗 | エラー終了（sandbox 外で実行するよう案内。sandbox 内では Unix socket 制約で必ずここに落ちる） |
| `window.SCENE` 未宣言 | エラー終了 |
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
| シーン / BGM の尺、シーンのフレームレート、**出力の尺**を数値で取得できない（ffprobe の非ゼロ終了・`N/A` を含む） | エラー終了（xfade のオフセット計算と出力照合に使う値なので、文字列のまま下流へ流さない。出力側は照合の入力なので、取得失敗を照合成功に丸めない） |
| クロスフェードがシーンのフレーム周期未満（`n>=2` のとき） | エラー終了（`-t` の値と周期を表示）。ffmpeg の xfade は遷移を発行できず後続シーンを丸ごと落とす（実測: 30fps で `-t 0.033` は第 2 シーンが消えて 62 フレームになる。`0.0334` 以上は正常） |
| シーン尺がクロスフェードに対して不足（端は `x` 超、中間は前後 2 回食われるため `2x` 超が必要） | エラー終了（該当シーンを表示）。負ないし重複した offset が xfade へ渡ると、ffmpeg は exit 0 のまま素材を捨てた mp4 を残す（実測: 2.0s×3 に `-t 3.0` で総尺 0.000s・ストリーム 0 本の 262 バイト mp4） |
| BGM が総尺より短い | エラー終了（`-t` で映像尺に切り詰めるため、末尾が無音の完成尺になる） |
| BGM 合成後の出力音声を volumedetect で解析できない / `max_volume < -20dB` | エラー終了（解析不能を未検証成功にせず、実測値がある場合は閾値とともに表示する） |
| ffmpeg が非ゼロ終了 | エラー終了（exit code を表示） |
| 出力の実尺が期待値と一致しない（許容差 1 フレーム周期） | エラー終了（期待値と実測値を表示）。完了行が名乗る尺は解析値ではなく成果物の実測値 |
| `-d` の指定が不正（`-P` なしで指定 / 空文字） | エラー終了（併用要求または空指定の拒否を表示）。`-d` は `-P` のシーン探索先を切り替える指定なので、黙って無視すると日本語素材から組んだ mp4 が `-en` の名前で正常終了する |

### 検査していないこと

パイプラインは**利用者が渡した入力を信用する**。下記は検査を書いていない経路で、いずれも
「異常が起きない」という主張ではない。実際に踏んだ実需が出たらその時点で Issue を切る
（CLAUDE.md `no_speculative_structure`）。

- **シーン契約表のうち renderer が検査しないもの**: `transition` 禁止 / `animation-fill-mode: both` 必須 / 非決定的な値（`Math.random()` 等）の不使用。いずれも著者側の遵守事項で、破っても診断ゼロで完走する。`Math.random()` を使ったシーンは 2 回レンダで md5 が割れるため、破れは `check-determinism.sh` でのみ検出できる
- レンダー出力 mp4 のフレーム数が宣言尺と一致するか。実測照合は Issue #2240 の T-01（手動テスト）が担う（連結側 `assemble.sh` は出力を実測照合する）
- シーン間でフレームレートが揃っているか。xfade は揃っていない入力に対し ffmpeg 側のフィルタ構成エラーで落ちる（実測: 30fps + 15fps は exit 234）

**レンダーの失敗は出力パスに成果物を残さない**（`render.mjs` は catch で出力を削除する）。シーン内例外の検出は ffmpeg の完了後になるため、削除しないと「exit 1 なのに宣言尺どおり完結した mp4」が残り、正常レンダーの成果物と区別できないまま `assemble.sh` へ入る。`check-contract.sh` はこの不変条件を全ケースで assert する。

## コミットしないもの

- `out/`（レンダー成果物の mp4）— リポジトリ root の `.gitignore` の `media/intro-video*/**/*.mp4` が拾う
- BGM の mp3 — 同じく root `.gitignore`。ライセンス上の理由は [PROVENANCE.md](./PROVENANCE.md) を参照
- `node_modules/` — 本ディレクトリの `.gitignore`
