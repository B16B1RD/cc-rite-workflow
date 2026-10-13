---
type: "heuristics"
title: "テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する"
domain: "heuristics"
description: "複数の不変量（集合差分 I1/I2 + 行内整合 I3 等）を持つ検証スクリプトのテストでは、fixture 変異の設計を誤ると「テストは green だが特定の不変量・guard を削除しても green のまま」という vacuous coverage が生まれる。"
created: "2026-07-03T18:30:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20261001T015350Z-pr-3576.md"
  - type: "reviews"
    resource: "raw/reviews/20260703T164934Z-pr-1743.md"
  - type: "fixes"
    resource: "raw/fixes/20260703T165654Z-pr-1743.md"
  - type: "reviews"
    resource: "raw/reviews/20260703T180609Z-pr-1743.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T033632Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T040711Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T043752Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T050456Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T182103Z-pr-2751.md"
  - type: "fixes"
    resource: "raw/fixes/20260912T182702Z-pr-2751.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T183826Z-pr-2751.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T225833Z-pr-2753.md"
  - type: "reviews"
    resource: "raw/reviews/20260913T005700Z-pr-2757.md"
  - type: "reviews"
    resource: "raw/reviews/20260913T020014Z-pr-2760.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T025734Z-pr-2798.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T091626Z-pr-2813.md"
  - type: "reviews"
    resource: "raw/reviews/20260917T132504Z-pr-2936.md"
  - type: "reviews"
    resource: "raw/reviews/20260925T005035Z-pr-3063.md"
  - type: "fixes"
    resource: "raw/fixes/20260925T005815Z-pr-3063.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T060817Z-pr-3060.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T085328Z-pr-3130.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T141701Z-pr-3147.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T141827Z-pr-3170.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T031018Z-pr-3199.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T080916Z-pr-3245.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T112645Z-pr-3275.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T113227Z-pr-3274.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T144951Z-pr-3289.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T162928Z-pr-3309.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T171357Z-pr-3318.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T005008Z-pr-3365.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T091647Z-pr-3391.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T092706Z-pr-3391.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T094130Z-pr-3391.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T054229Z-pr-3434.md"
  - type: "reviews"
    resource: "raw/reviews/20260930T092118Z-pr-3525.md"
  - type: "fixes"
    resource: "raw/fixes/20260930T093720Z-pr-3525.md"
tags: ["test", "fixture", "mutation", "invariant", "coverage"]
confidence: high
generated: { by: "rite-wiki-ingest/gpt-6", at: "2026-10-01T02:00:46Z" }
verified:
  - { by: "rite-wiki-ingest/gpt-6", at: "2026-10-01T02:00:46Z" }
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T18:43:00+00:00" }
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T23:20:00+00:00" }
  - { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-13T01:10:00+00:00" }
  - { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-13T02:07:58+00:00" }
  - { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-14T03:36:26Z" }
  - { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-14T09:23:49Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-25T03:58:00Z" }
  - { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T06:12:43Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T08:57:51Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T14:30:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:16:22Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T08:15:44Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T11:35:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T11:33:48Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T14:56:46Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T16:35:29Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T17:19:25Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T01:02:34Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T09:47:59Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T05:45:52Z" }
  - { by: "rite-wiki-ingest/grok-4.7", at: "2026-09-30T09:44:17Z" }
  - { by: "rite-wiki-ingest/grok-4.7", at: "2026-09-30T09:44:17Z" }
---

# テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する

## 概要

複数の不変量（集合差分 I1/I2 + 行内整合 I3 等）を持つ検証スクリプトのテストでは、fixture 変異の設計を誤ると「テストは green だが特定の不変量・guard を削除しても green のまま」という vacuous coverage が生まれる。変異がどの不変量を発火させるかは推測せず実行で確認し、各不変量・guard を**単独で** kill する配置（均衡入替 / reverse 方向の明示 pin / guard 射程内への decoy 配置）を採る。

## 詳細

起点事例（reviewer-registry-drift-check.test.sh、TC-1〜TC-11）の設計・レビューで実測した 3 つの配置原則。

### 1. 行内整合の分離検証には均衡入替（双方向 swap）を使う

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 均衡入替で I3 のみ発火・集合差分の混入なしを負 assert・TC-6）

### 2. 双方向チェックの reverse 方向は明示 TC で pin する

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: reverse 方向は orphan 行 fixture + 方向ラベル assert の明示 TC で pin・TC-9）

### 3. guard を exercise する decoy は guard の射程内に置く

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: decoy は guard だけが除外を担う射程内に置く）

### 4. 連言述語 `A ∧ B` の fixture は項の数だけ用意する

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 連言は項の数だけ fixture・位置固定述語は位置違いも足す）

### 5. 観測経路が片方しか通っていないと、もう片方の mutation が生存する

同一の形状定義を read 側（抽出）と write 側（除去）で共有している場合、read 側の TC だけでは write 側を狭める mutation が落ちない。write 側が別経路（fallback 等）を通らないと発火しないためである。**形状定義を共有しているなら、pin も両方の経路で張る。**

定義が共有ではなく**複製**されている場合はさらに弱い。手順書の fenced bash で、同じ境界の条件式を「番号を数える範囲を切り出す awk」と「追記位置を決める awk」の 2 か所に書いた例では、「数える範囲と書き込む範囲が一致する」という不変条件をコメントと設計理由の文でしか支えていなかった。テストの境界ループは追記側の awk しか通しておらず、新しい fixture にもその境界の種類が無かったため、切り出し側から境界を 1 つ消す変異を当ててもスイートは緑のままだった。

- 複製した条件式は、文書から両方を抜き出して**件数と内容の一致を assert する**か、**両方の awk を同じ境界 fixture で回す**
- 境界 fixture は、条件式が列挙する境界の種類をすべて 1 つずつ含める（1 種類でも欠けると、その境界を消す変異が生き残る）

条件式の**文字列一致**を assert する形にしても、まだ穴が残る。比べているのが「条件式を持つ 1 行の括弧内」だけだと、括弧内は触らずに**別の行のルールとして片側だけに境界を足す**変異（`in_section && /^### / { ... }` を 1 行追加する形）は、両側から同じ文字列が取り出されて素通りする。境界 fixture も既知の境界しか流さないので、足された境界はどの層でも試されない。

- 文字列一致に加えて、**境界を持つルール行の本数**も両側で固定する（本数が変われば落ちる）
- 書き方に依存させないなら、境界候補（見出しの別レベル・HTML コメント・空行など）を混ぜた本文に対して、2 つのプログラムの**出力位置が一致する**ことを突き合わせる差分テストにする
- 変異を当てたら「どの assert が落ちたか」をラベル単位で見る。既存テストがたまたま守っている境界と、新しい assert だけが守る境界が分かれ、テストのコメントが主張する保証範囲を実態に合わせられる

出力位置の差分テストにも固有の穴がある。追記側の出力から「差し込みマーカーより前の行」を切り出して比べる形では、**マーカーが 1 回も出ない変異**（境界で区間を閉じるが新しい行を差し込まないルールを足す）で切り出し側が EOF まで読み進め、未変異の番号付け側の出力と一致してしまう。比較そのものは成功するが、何も検査していない。

- 差分比較の前に、比較範囲を決める区切り（差し込みマーカー）が**ちょうど 1 回**出ることを assert する。0 回は「区切りが消えた」、2 回以上は「複数箇所に差し込まれた」で、どちらも一致比較では見えない
- 候補リストを流す差分テストは、書き方に依存しない代わりに**候補の行の中身に依存する**。ルール本数の比較は逆に書き方に依存し中身に依存しない。組み合わせても「本数に数えられない書き方」かつ「候補にない行」を片側に足す変異だけは両方をすり抜けるので、テストのコメントには守れる範囲をその 2 条件で書く

### 6. negative control は「到達したうえで発火しない」ことを確認する

（→ prose-pin-requires-positive-control に統合: negative control は分岐に到達したうえで発火しないことを確認）

### 7. 同じコマンドを複数回呼ぶ手順の失敗注入は、呼び出し回数ごとに分ける

1 つの手順が同じコマンドを 2 回呼び、それぞれの終了コードを別々に捕捉していることがある（例: 挿入位置を awk で決め、本文を awk で組み立てる）。このとき失敗注入の mock が**そのコマンドの全呼び出しを失敗させる**と、1 回目で必ず失敗が立つ。そのため 2 回目の捕捉を消してもテストは緑のままになり、2 回目だけが途中で落ちる実害（本文の切り詰めと成功 marker）を検出できない。

- mock に呼び出し回数を数えさせ、**指定回目だけ失敗させ、それ以外は実コマンドへ exec する**。ケースは「何回目を・どの形（異常終了 / 空出力）で落とすか」の組で並べる
- 単独固定できたかは、捕捉を 1 つずつ外す変異で**各変異がちょうど 1 ケースだけを落とす**ことで判定する。修正前のテストに同じ変異を当てて素通りすることも示すと、欠陥が実在したことまで裏付けられる
- この形の mock の正しさは 3 点で決まる。回数ログを実行ごとに空にしていること、実コマンドのパスを mock が PATH に入る**前**に解決していること（mock が自分を exec する再帰を防ぐ）、関数呼び出しの前に置いた一時代入が子プロセスまで届くこと

### 8. 除外側の対照は、判定式の条件を 1 つだけ外す形になっているかを確かめる

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 除外側の対照は判定式の条件を 1 つだけ外す・lstat で実測）

### 9. テスト入力の値が変異の落ち方を変え、assert の単独の検出力を奪うことがある

未知ラベルを受けて既定ラベルに倒す分岐のテストで、入力ラベルに `/` を含む値を選んだ例がある。フォールバックを消す変異を当てると、ラベルが sed の置換式にそのまま入って sed 自体が失敗し、詳細行が 1 行も出なくなる。このため「未知ラベルを接頭辞に使わない」ことを見る否定の assert は、変異の下でも満たされたまま通る。変異を落としていたのは、既定ラベルの詳細行を完全一致で探す別の assert だけだった。

- 変異は 1 つずつ当て、**assert ごとに**落ちたかを見る。「スイートが落ちた」だけでは、ある assert が単独で何も検出していないことが隠れる
- 入力値が「実装を壊したときの壊れ方」を変えていないかを確かめる。壊れ方が変われば、否定の assert は探す行そのものが出ないことで通ってしまう
- 単独の検出力が要るなら、壊れ方を変えない値（`/` を含まないラベル）に替える。壊れ方を実演できる値を残すなら、その否定の assert は補助だと分かる名前にし、保証を担う assert を別に置く

### 10. 正規表現の一部（行末 anchor 等）を固定する入力は、その部分の有無だけで判定が分かれる値を選ぶ

reader の正規表現にある行末 anchor `$` を固定するテストで、当初の案は改行を含む値を helper に渡すものだった。helper は制御文字を中和して 1 行にするため、その出力は anchor より手前の部分（`pr=[0-9]*;` のような数字だけを許す箇所）で先に不一致になる。anchor を外す変異を当てても結果は変わらず、テストは anchor を何も固定しない。改行を含まず、手前の部分はすべて一致し、行末だけが違う値に替えて初めて、anchor の有無で判定が分かれた。

- 正規表現の特定の部分を固定したいときは、**その部分を外した正規表現なら一致する**入力を選ぶ。手前で先に落ちる入力は、変異を当てる前から識別力がない
- 「anchor を外した正規表現はこの行に一致する」という前提の assert を同じテストに置く。helper の出力形式が後で変わって入力が的外れになったとき、素通りの green ではなく前提側の失敗で気付ける（6 の「到達したうえで発火しない」と同じ考え方を入力の選択に当てたもの）
- 同じ正規表現を複数の reader が持つなら、reader ごとに変異を 1 つずつ当て、それぞれが独立に落ちることを確かめる

### 11. 拒否判定を固定するときは、同じ操作で結果が変わらない許可対照も併記する

参照が動いたことを拒否する検査で、拒否側の fixture だけを固定すると「拒否条件を緩めて許可へ寄せる」変異が生き残ることがある。同じ操作カテゴリで結果が変わらない（HEAD を動かさない等）許可対照を fixture に併記し、拒否と許可の両方を assert すると、拒否側へ寄せすぎる変異（許可されるべき操作まで拒否してしまう）も同時に検出できる。原則は 8 の「除外側の対照は判定式の条件を 1 つだけ外す」と同型で、二値判定（許可 / 拒否）一般に適用できる。

### 12. 集合の各要素は、他の要素を含まない形で 1 つずつ固定する

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 集合の各要素は最小入力形で 1 つずつ固定）

### 13. 位置を固定する照合の前方一致は、固定点の後ろへの追記を素通りさせる

ある文の直後に来るべき文字列（tail）を固定する検査が、tail の前方一致で照合していると、tail の**後ろ**に反転文を足す変異は通る。とくに tail が閉じ括弧のような短い文字列だと、固定しているのは実質その 1 文字だけになる。同じ検査が別の箇所では優先句のような長い tail を持っていて変異を落とせるため、全箇所で守れているように見えやすい。

- 固定点が**行末に達する**箇所は、前方一致をやめて完全一致（行末まで固定）にする。後ろに本文が続く箇所だけ前方一致を残し、どの箇所がどちらかをテストのコメントに書く
- 完全一致と前方一致をファイルごとに切り替えるなら、case パターンの後ろに付ける部分（`*` または空）を固定値の変数で持つと、照合の書き方を 1 つに保てる。値が固定定数なら、case パターン中で引用符なしに展開しても単語分割やパス名展開は起きない
- 変異は「tail の後ろへの反転追記」と「tail の内側の否定化」を別々に当て、修正前の検査では前者が通ることも示す。前方一致のまま残る箇所の後ろへの追記は検出できない境界として明記し、必要なら「以降に許可文が現れない」否定の assert で補う

### 検証の決定打

（→ mutation-prove-new-pin に統合: 構文エラー変異は FAIL 数に数えない・修正後の軸で変異を取り直す）

## 集約出力の件数は「対象と対象外が混在する」fixture でも固定する

集約した警告の件数（例: `N 件を除外`）を固定するテストが、対象だけが存在する fixture でしか件数を assert していないと、件数を対象外も含む全体から数える変異が生き残る。どちらの数え方でも同じ数になるためである。対象と対象外が同時に存在するケースを 1 つ選び、そこにも件数の assert を置くと、この変異を単独で検出できる。

例外経路を固定する fixture は、その経路に本当に入る前提（例: dangling symlink なら「lstat では symlink」かつ「exists は偽」）を同じテスト内で check しておく。環境の違いで fixture が別の経路に落ちたとき、assert が何も確かめずに通ってしまうのを防げる。

## 経路ごとの結果を固定する fixture は、各要素が 1 経路でだけ入るように分ける

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 各要素は 1 経路でだけ入る形にする）

## 固定したい条件以外の経路で既に拒否される入力を選ぶと、その条件の変異は生き残る

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 別経路で拒否される入力を選ばない・等価 mutant 主張は反例を探す）

## 複数キーの一致を比べる検査は、キーごとに 1 つだけ変えた不一致 fixture を置く

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: キーごとに 1 つだけ変えた不一致 fixture・常設 assert）

## 受入条件で「変異でそのケースだけが落ちる」と求めるときは変異点を特定する

同じ既定値に依存する既存の負の対照があると、既定値そのものを反転する変異では新しいケースと既存ケースが一緒に落ちる。受入条件が「変異で当該ケースだけが落ちる」と書いていると、reviewer ごとに選んだ変異点（既定値の反転 / 分岐の入れ替え / 許可分岐の書き換え）で成否が分かれ、充足判定がぶれる。

- 受入条件に変異を書くときは、どの行・どの分岐を変えるかまで特定する
- 既存ケースが先に検出する変異と、新しいケースだけが検出する変異を分けて書き、新しいテストが固定したのは後者だと明示する

## 2 つの候補値が一致する fixture では、どちらを参照しているかを区別できない

出力がある値 A を指すべきで、誤った実装なら値 B を指す、という性質を固定したいとき、fixture 上で A と B が常に一致していると、参照先を B へ差し替える変異でも全 assert が通る。手動回復ヒントのパスが main checkout を指すべき場面では、通常の checkout だけの fixture だと main checkout と呼び出し元の toplevel が常に一致する。linked worktree から実行する fixture を足して初めて両者が分かれ、呼び出し元の toplevel へ差し替える変異が落ちた。変更前のテストは同じ変異で全件 green だった。

- 性質が「どちらを指すか」なら、まず候補値が分かれる fixture を置く
- 「A と一致する」assert と「B と一致しない」assert は、A と B の実体パスが異なる限り論理的に同値で、検出力は重複する。受入条件の文言をそのまま読めるように両方置くのは許容される

## 分岐ごとに後始末が違う helper は、全分岐を rc のループで 1 つずつ走らせる

（→ hook-failure-branch-needs-execution-test に統合: 全 rc をループで・分岐固有出力と到達を assert）

## docstring が列挙した分岐とテストを 1 対 1 に揃える

helper の docstring が「この場合に記録を書く」と分岐を列挙しているのに、その一部に対応するテストが無いと、その分岐だけで記録を省く変異が生き残る。列挙された分岐ごとにケースを置き、既存の fixture を流用して足りない分岐（別の経路から入る場合など）を 1 件ずつ加える。変異を一時的に入れて、新しい assert だけが落ちることを確かめてから戻す。


## 正規表現の文字クラスは要素ごとに fixture を持たせる

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 文字クラスは要素ごとに fixture・走査範囲と文書の一致）

## 連言の片側だけが成り立つ組み合わせも fixture に置く

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 連言の片側のみの fixture も置く）

## 規則を足したら、既存 fixture がどの規則で結果に至っているかを確かめる

保持規則を追加すると、既存テストの fixture が新しい規則で先に保持され、本来検証していた規則を外してもテストが通るようになる。追加した規則が効かない値（終端の状態など）に fixture を寄せ、テストごとに 1 つの規則だけで結果が決まるようにする。

寄せるときは、寄せた後の fixture が通る判定経路をすべて列挙する。副次のデータが残っていると別の規則でも同じ結果になり、分離は成立しない。また、どの規則よりも先に必ず走る処理の失敗（例: 判定の前に行う書き込みの失敗）は、fixture の状態を変えても経路が変わらない。規則の順序を読まずに fixture を動かすと、挙動に影響しない差分が入る。コメントには、分離できた範囲だけを書く。

**同じ fixture を複数の除外が落とすと、一機構を無効化してもテストは通る**: 結果から行を除く機構が 2 つあり、両方が同じ fixture を除いていると、片方だけを無効化してももう片方が同じ行を除くのでテストは通る。コメントを狭めて、別の未検査の機構が保証しているかのように書き換えても、保証の置き換えであって検査にはならない。機構を 1 つずつ無効化し、残った機構だけでは通らないことを確かめる。コメントが名乗る範囲は、観測した傾向と印、および fixture の条件に限る。原因そのものを保証した書き方にしない。製品側を変えずにコメントだけを直すときも、未検査の機構の保証へ文を移さない。

**積で書いた除外条件は因子ごとに結果が変わる入力を置く**: 除外を「名前が一致 かつ 種別が一致 かつ symlink でない」の積で書いたら、各因子を 1 つだけ外す変異ごとに結果が変わる入力（同名の通常ファイル、同名のディレクトリ、実在する先を指す symlink）を検査に揃える。どれか 1 つを外しても他の因子が同じ結果を返す入力しかなければ、その因子は固定されない。除外の範囲を ignore 判定で代用すると、ignore 済みディレクトリを入力にしたとき配下がすべて落ちて無検査になるので、対象は名前で限定する。

### 入力の前提を固定する補強

（→ guard-discriminating-power-requires-solo-firing-fixture に統合: 複合キーは列ごとに単独で違う行・列数違いの拒否分岐）

## 関連ページ

- [位置依存の表パースには検査行数ガードを対にする（silent false-pass 遮断）](../patterns/positional-parse-row-count-guard.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](./static-pin-semantic-allowlist-not-notation-denylist.md)
- [抽出述語の厳格化は「壊れた入力」と「入力なし」を同一経路へ畳み、fail-loud を構造的に壊す](../anti-patterns/strict-predicate-collapses-broken-into-absent.md)


## ソース

- [一方向差し替えの不変量誤帰属 + reverse 未 pin を検出](../../raw/reviews/20260703T164934Z-pr-1743.md)
- [均衡入替 TC-6 + reverse pin TC-9 を適用](../../raw/fixes/20260703T165654Z-pr-1743.md)
- [pipe-filter decoy 配置の coverage gap を推奨事項として検出](../../raw/reviews/20260703T180609Z-pr-1743.md)
- [行アンカー `^` / `$` の片側 mutant が 4 件生存](../../raw/reviews/20260805T033632Z-pr-2112.md)
- [項ごとの fixture と read/write 両経路の pin を適用](../../raw/fixes/20260805T040711Z-pr-2112.md)
- [連言 2 項の同時 false による識別力ゼロと、到達しない negative control を検出](../../raw/reviews/20260805T043752Z-pr-2112.md)
- [項ごとの pin 分割と mutation 軸の取り直しを適用](../../raw/fixes/20260805T050456Z-pr-2112.md)
- [全呼び出しを失敗させる mock が 2 つ目の終了コード捕捉を固定していないことを検出](../../raw/reviews/20260912T182103Z-pr-2751.md)
- [失敗注入を呼び出し回数ごとに分けた修正](../../raw/fixes/20260912T182702Z-pr-2751.md)
- [各捕捉の単独固定を変異表で確認したレビュー結果](../../raw/reviews/20260912T183826Z-pr-2751.md)
- [複製した境界条件式の同一性がテストで固定されていないことを検出したレビュー結果](../../raw/reviews/20260912T225833Z-pr-2753.md)
- [条件式の文字列一致では片側だけに足した別行ルールを検出できないことを変異で示したレビュー結果](../../raw/reviews/20260913T005700Z-pr-2757.md)
- [差分テストが区切りの出ない変異を素通りさせることを示したレビュー結果](../../raw/reviews/20260913T020014Z-pr-2760.md)
- [symlink 対照が単独の条件を固定していないことを実測したレビュー結果](../../raw/reviews/20260914T025734Z-pr-2798.md)
- [入力ラベルの値が否定の assert の単独の検出力を奪うことを変異で示したレビュー結果](../../raw/reviews/20260914T091626Z-pr-2813.md)
- [件数の数え方の変異を、対象と対象外が混在するケースの assert で検出したレビュー結果](../../raw/reviews/20260917T132504Z-pr-2936.md)
- [レビュー結果](../../raw/reviews/20260925T005035Z-pr-3063.md)
- [fix 結果](../../raw/fixes/20260925T005815Z-pr-3063.md)
- [拒否 fixture と許可対照を両方固定する原則を検出したレビュー結果](../../raw/reviews/20260926T060817Z-pr-3060.md)
- [別経路で既に拒否される形では条件を区別できないことを確かめたレビュー結果](../../raw/reviews/20260927T031018Z-pr-3199.md)
- [行末 anchor の有無だけで判定が分かれる入力と前提の assert で anchor を固定したレビュー結果](../../raw/reviews/20260926T085328Z-pr-3130.md)
- [集合の要素ごとに他の構造を含まない形の固定が要ることを示したレビュー結果](../../raw/reviews/20260926T141701Z-pr-3147.md)
- [行末に達する tail を完全一致で固定して後ろへの反転追記を検出したレビュー結果](../../raw/reviews/20260926T141827Z-pr-3170.md)
- [比較する複数キーのうち 1 キーだけを変えた不一致 fixture では比較式を弱めても検出できないと指摘したレビュー結果](../../raw/reviews/20260927T080916Z-pr-3245.md)
- [比較キーごとの fixture と変異の形を検討したレビュー結果](../../raw/reviews/20260927T112645Z-pr-3275.md)
- [レビュー結果](../../raw/reviews/20260927T113227Z-pr-3274.md)
- [候補値が一致する fixture では参照先の差し替えを検出できないと確かめたレビュー結果](../../raw/reviews/20260927T144951Z-pr-3289.md)
- [rc ごとの後始末をループで固定し、分岐単位の変異で検出力を確かめたレビュー結果](../../raw/reviews/20260927T162928Z-pr-3309.md)
- [docstring の分岐列挙に合わせてテストを 1 件追加した fix 結果](../../raw/fixes/20260927T171357Z-pr-3318.md)
- [レビュー結果](../../raw/reviews/20260928T005008Z-pr-3365.md)
- [連言の片側を外す変異が生き残ることを示したレビュー結果](../../raw/reviews/20260928T091647Z-pr-3391.md)
- [連言の片側の fixture と、規則ごとに寄せた fixture の fix 結果](../../raw/fixes/20260928T092706Z-pr-3391.md)
- [寄せた fixture に副次のデータが残り分離が成立しないと確かめたレビュー結果](../../raw/reviews/20260928T094130Z-pr-3391.md)
- [積で書いた除外条件を検査したレビュー結果](../../raw/reviews/20260929T054229Z-pr-3434.md)
- [重なった除外の片方を無効化しても通ることを確かめたレビュー結果](../../raw/reviews/20260930T092118Z-pr-3525.md)
- [名乗りを観測した傾向と印に限った fix 結果](../../raw/fixes/20260930T093720Z-pr-3525.md)

- [レビュー・修正結果](../../raw/reviews/20261001T015350Z-pr-3576.md)
