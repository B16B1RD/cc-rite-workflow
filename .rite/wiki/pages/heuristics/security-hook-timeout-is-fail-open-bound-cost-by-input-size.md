---
type: "heuristics"
title: "セキュリティ境界 hook の timeout は fail-open — 評価コストは入力サイズで O(1) 上限を設けて bound する"
domain: "heuristics"
description: "PreToolUse 等の hook の timeout は **fail-open**（timeout に達すると Claude Code が hook を kill して tool 実行を許可する）である。"
created: "2026-07-03T08:30:23+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260703T070536Z-pr-1736.md"
  - type: "fixes"
    resource: "raw/fixes/20260703T071412Z-pr-1736.md"
  - type: "reviews"
    resource: "raw/reviews/20260703T073719Z-pr-1736.md"
  - type: "fixes"
    resource: "raw/fixes/20260703T075749Z-pr-1736.md"
  - type: "reviews"
    resource: "raw/reviews/20260703T082154Z-pr-1736.md"
  - type: "reviews"
    resource: "raw/reviews/20260715T194532Z-pr-1865.md"
  - type: "fixes"
    resource: "raw/fixes/20260715T195606Z-pr-1865.md"
  - type: "reviews"
    resource: "raw/reviews/20260715T203920Z-pr-1865.md"
  - type: "reviews"
    resource: "raw/reviews/20260715T230852Z-pr-1867.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T043542Z-pr-3379.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T053742Z-pr-3379.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T055141Z-pr-3379.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T051919Z-pr-3388.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T061637Z-pr-3379.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T063605Z-pr-3379.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T085952Z-pr-3379.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T091402Z-pr-3379.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T095306Z-pr-3379.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T100658Z-pr-3379.md"
tags: ["security", "hook", "timeout", "fail-open", "fail-closed", "dos", "input-size-bound", "pretooluse", "super-linear", "bypass", "noglob", "glob", "unquoted-loop"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T10:18:22Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T05:02:36Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T06:02:43Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T09:47:59Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T10:18:22Z" }
---

# セキュリティ境界 hook の timeout は fail-open — 評価コストは入力サイズで O(1) 上限を設けて bound する

## 概要

PreToolUse 等の hook の timeout は **fail-open**（timeout に達すると Claude Code が hook を kill して tool 実行を許可する）である。したがってセキュリティ境界の hook（reviewer subagent の状態変更 git をブロックする guard 等）で、hook の評価コストが入力サイズに対して発散すると、攻撃者が入力を巨大化して評価を timeout させ、deny が emit されないまま危険な操作が実行される **timeout→fail-open bypass** が成立する。反復「回数」の上限だけでは各反復が O(入力長) の場合に防げない。全パターン検査の **前段** に入力バイト長の O(1) ガードを置き、超過時は正規化・検査を一切走らせず fail-closed deny することでコストを入力サイズで bound する。

## 詳細

起点事例（`pre-tool-bash-guard.sh` の Pattern 4 = reviewer 状態変更 git guard を fail-closed 化）で、timeout bypass を 4 cycle かけて塞いだ実測から得た経験則。

### なぜ timeout が bypass になるか

- **PreToolUse hook の timeout は fail-open**（公式 docs で fact-check 済み。timeout / cancel → tool は通常の permission flow に進む = 許可される。command hook のデフォルト timeout は 600s）。
- guard の評価が入力サイズに対し super-linear だと、reviewer subagent が状態変更 git を巨大パディングして評価を timeout 域に押し上げられる。timeout すると deny が emit されず、パディングされた git がそのまま実行される。
- **ERR trap では捕捉できない**: timeout はプロセスが外部から kill されるため、`set -e` / ERR trap は発火しない。crash 系の fail-closed 化とは別の防御が要る。

### なぜ反復回数上限では不十分か

- 「global flag の正規化ループを N 回で打ち切る」ような反復**回数**の上限は、各反復が O(入力長) のコストを持つ場合に無力。128 回の上限でも、各反復が 10KB の flag 値を処理すれば 128×O(10KB) で数十秒に達する（実測 128×10KB=1.28MB → hook 全体で timeout）。
- さらに、正規化ループの **手前** にある whole-string 処理（bash の `${var%%pattern}` パラメータ展開等）自体が huge input で O(n²) になりうる。実測: `${COMMAND%%<<*}`（heredoc 除去）が ~1.3MB の入力で **~45s**。`[[ =~ ]]` 正規表現も数 MB の meta 文字列で **>2min**。これらは反復上限の外にあり、上限を追加しても timeout する。

### 正しい塞ぎ方: 全検査の前に O(1) 入力サイズガード

- 正常なコマンドは高々数 KB。全パターン検査の **前** に `${#COMMAND}`（O(1) で高速。2MB でも ~2.5ms）で総バイト長を測り、閾値（例 64KB）超過なら **正規化も検査も一切走らせず** fail-closed deny する。`BLOCKED_PATTERN` を先に立てることで後続の O(n²) 経路（heredoc 除去・各パターン検査）を一括短絡できる。
- これは反復回数ではなく **入力サイズ** でコストを bound する。巨大 flag 値 / 多数 flag / 巨大 meta 文字列 / 巨大 heredoc body の全経路を 1 つのガードで塞ぐ。反復回数上限は ≤閾値の入力で fork 数を bound する **secondary** な防御として併置する。
- ガードは対象セッション（reviewer subagent 等）に **scope** する。main セッションを size で誤 deny しない（誤 deny 禁止）。main セッションが huge input で遅くなるのは fail-open な convenience パターン側の pre-existing な性質でありセキュリティ bypass ではない（別スコープ）。
- **allow→deny flip が防御価値の証拠**: 本来 allow される read-only なコマンド（例 `git status`）を巨大化したものが deny に変わることを確認すると、ガードが「本来通るものを止めている」ことが実証できる（脅威モデルの本質）。

### 入力サイズ bound を破る glob 展開（unquote for-loop）

上記の O(1) 入力サイズ bound は「トークン数 ≈ 入力バイト長」を暗黙前提とする。**未クォートの `for x in $var` ループはトークンごとにパス名展開（globbing）を起こす**ため、この前提が破れ bound が無効化される:

- length-guard 済みの短い入力（例 20B の `echo /bigdir/*`）でも、`*` が hook プロセス CWD に対し展開され、大ディレクトリなら 100 万トークンに膨れる。**glob 展開は length-guard の後で起きる**ため展開後トークン数は入力バイト長に拘束されず、O(1) サイズガードを素通りして検出ループが無制限反復 → timeout → fail-open。反復回数キャップだけでは（各反復が安価でも反復数が glob 依存で無限に増えるため）防げない。glob メタ文字 `*`/`?`/`[` は `;&|(){}` 等のメタ文字正規化を生き延びる点に注意。
- 加えて glob 展開は CWD 内容に依存した **非決定的な over-DENY 誤検出**も招く（CWD に検出対象 verb 名のファイルがあると正当な read が誤 deny される = 誤検出禁止 AC に反する）。
- **塞ぎ方 = noglob**: 検出ループ区間を `set -f`/`set +f`（noglob）で囲うと、トークンが literal 保持され展開後トークン数が length-guard 済み入力に再 bound される。over-DENY 誤検出と timeout 無制限反復の**両方が同時に閉じ、反復キャップは不要になる**。`case` / `[[ == ]]` のパターンマッチは `set -f` の影響を受けない（パス名展開のみ無効化）ので検出ロジックは不変。直前の noglob 状態を `case $- in *f*)` で save/restore すると、enclosing の shell state を壊さず drift-safe。
- この欠陥は「allowlist 列挙の穴」ではなく**検出機構そのものの構造欠陥**であり、列挙完全性の非 blocking 判断とは別クラスの blocking finding として扱う（[best-effort matcher の COMMON-SET 宣言](./best-effort-matcher-declare-common-set-to-stop-whackamole.md) 参照）。
- **同一ファイル内の全 unquote for-loop に水平展開する**: 先行 PR は (H) gitdir-write tokenizer の 1 ループのみ noglob 化し、兄弟の `for tok in $WT_ARGS`（`git worktree add` 引数走査）を「pre-existing・スコープ外」として残した。この残しは同一の unquote glob 欠陥（over-DENY 誤検出 + timeout 無制限反復）をそのまま抱えるため、follow-up PR で同型の noglob スコープ（`set -f`/`set +f` + `case $-` save/restore、変数名はブロック接頭辞 `_wt_` で衝突回避）を適用して閉じた。**塞ぐべきループは 1 つとは限らない** — レビューは対象ファイル全体の unquoted `for X in $...` を grep で列挙し、全て noglob 化済みか iteration-cap 済みかを確認する（この PR ではファイル全体の unquote word-split は :608 と :789 の 2 箇所のみと確認され、後者が最後の未対応ループだった）。sibling 対称化 PR は grep 照合で短時間・高確信にレビューできる（[極小対称化 PR は sibling site Grep 照合でレビュー](./small-symmetric-pr-sibling-site-grep-review.md) 参照）。
- **over-DENY 回帰テストは fail-on-revert を実機で確認する**: noglob 修正の回帰テストは「未修正なら DENY・修正後は ALLOW」の discriminating 性を実機で確認しないと vacuous になる。CWD に new-branch フラグ名のファイル（例 `-b`）を full path で作成し、glob を含む正当な `git worktree add <path> <ref>` が over-DENY されないことを ALLOW 期待で固定する（姉妹 TC-125 と同型）。テストが緑になるだけでなく、修正を revert すると当該テストが赤に転じることを確認する（[invariant は logic ではなく empirical reproduction で verify](./empirical-reproduction-over-invariant-reasoning.md) 参照）。

### 併走する 2 つの副次教訓

- **テスト用 fault-injection は fail-closed 側限定**: セキュリティ hook をテストするための env var 等の fault-injection を本番コードに置く場合、set 時に **allow へ反転する経路（fail-open injection）を作らない**。deny のみを誘発する self-restrictive な fail-closed 側に限定する。fail-open 側の injection は settings.json の env 等で有効化できる allow-all バックドアになる。fail-open 不変性は injection ではなく trap 配線の static 検証で pin する。
- **外部ツールの挙動主張は fact-check してから finding を確定**: 「hook の timeout は fail-open」のような外部ツール（Claude Code）の挙動主張は、推測でなく公式 docs で fact-check してから採否を決める。reviewer 間で「trigger 経路なし」の判断が割れるのは、解析スコープの差（無限ループの有無だけ見たか、super-linear コストまで見たか）に起因することが多い。

### 「線形時間」の約束は呼び先と前段まで含めて計時する

判定を正規表現から parser へ移し、新しい経路で線形時間を約束したところ、下流の helper（python のコマンド分割処理）と上流のパラメータ展開（`${COMMAND%%<<*}`）が入力長の二乗で遅くなり、約束が破られていた。hook が timeout すれば fail-open で素通りする。受入条件の性能判定は、実装した部分ではなく hook 全体の応答で行われる。判定を別経路へ移すときは、最悪形の入力で呼び先と前段を含めた全区間を計時する。

同じ変更では、テストが hook を呼ぶときに実行セッションの session 環境（`CLAUDE_CODE_SESSION_ID` や state root）を切り離していなかったため、レビュー中のセッションでだけ別のパターンが先に拒否して落ちた（CI では再現しない）。実装を parser へ切り替えたあと、仕様書に旧実装の読み飛ばし範囲が残っていたことも併せて指摘された。

### プラットフォームの暗黙の上限を安全の根拠にしない

線形化の修正を検証していた reviewer が、同じ呼び出し口から届く別の超線形を見つけた。入れ子のコマンド置換の深さと長さの積で伸びる処理と、語ごとに外部プロセスを起動する処理である。Linux では argv の 1 引数あたりの長さに上限があるため入力が頭打ちになり、問題が表に出なかった。その上限を持たない macOS では、hook のタイムアウトを超える。OS の暗黙の上限でたまたま抑えられている経路は、上限の無い環境では抑えられていない。

修正では共有 parser を作り直さず、呼び出し側で入力長を O(1) で打ち切り、超過を fail-closed で拒否した。上限値は、上限ちょうどの長さの最悪形を実測して決めた。上限は OS に任せず、呼び出し側に明示して置く。

線形化そのものの信頼は、旧実装と新実装を数万件のランダム入力で突き合わせる等価性の検証が支えた（関連ページの差分テスト）。一方、線形化した分岐を固定するテストが無いという網羅性の指摘は、実測の裏付けが無いため non-blocking に分類された。

### 走査を足したら、既存の入力長上限が前提にする処理時間を測り直す

reviewer の状態変更を止める guard の字句解析に、1 文字ずつ `${var:i:1}` で進む走査を足したところ、UTF-8 ロケールで二乗時間になり、既存の入力長上限より小さい入力で timeout → fail-open に達した。既存の上限は「この長さなら timeout 内に判定を終える」という処理時間の前提の上に立っている。新しい走査を入れたら、その前提を最悪形の入力で測り直し、走査側にも O(1) の fail-closed 上限を置く。走査自体の直し方（ロケールの固定と入れ子の追跡）は字句解析のページにある。

### 「他の層が担う」と書く前に、その層が実際に検出する軸と照合する

同じ guard の文書は、guard が止めない操作を他の層（事後のドリフト検出）が担うと書いていた。しかしその層が検出するのは branch 名・stash・tracked status などの変化で、push や作業ツリーを汚さない commit はどれにも現れず、検出の対象外だった。防御を別の層へ委ねると書くときは、委ねる操作がその層の検出軸に実際に現れるかを確かめる。

### 上限は入力長ではなく、コストの源ごとに数えて置く

入力長の上限で超線形を抑えた fix が、macOS の CI で崩れた。入力長を抑えても、語ごとの外部プロセスの起動回数は残り、処理時間は起動 1 回の速さに比例する。プロセス起動が遅い macOS では、上限以下の入力でも hook の timeout を超えた。時間の上限は、コストの源ごとに数えて置く。コストの源には、外部プロセスの起動回数・再帰の深さ・置換の段ごとの再走査がある。超えたら fail-loud で拒否し、同じ作業先の解決結果は 1 回の解析の中で使い回す。

コストの源ごとに上限を置いた後も、別の源が残っていた。オプションや cd のたびに伸びるパスを毎回解決し直す処理が、二乗の時間になっていた。解決を使う直前の 1 回に遅らせても、使うたびに解決すれば二乗は残る。累積を生む操作（cd / `-C`）の回数に上限を置き、上限値は上限いっぱいで最悪の形（最も長いパスを組む形）の実測から決めた。新しい作業先は cd / `-C` でしか生まれないので、変更回数の上限が作業先数の上限を兼ね、上限を 1 つにまとめられた。上限を足す fix では、ループの中で入力の累積に比例する処理（パス解決・文字列の結合・再走査）を洗い出す。

上限直下の計時テストは、次の 3 点がそろわないと性質を固定できない。

- 最悪形の入力を定数から組み立てる。上限から導いた最も密な形を使う
- 遅い経路を最後まで通ったことを、理由の assert で確かめる
- 閾値は性質そのもの（hook の timeout）から決める

「timeout に十分収まる」というコメントを、Linux の手元と ubuntu の CI だけの実測で書くと、macOS の CI で反証される。別 OS の CI の完了を待たずに下した FIXED 判定も、次の cycle で覆った。

### 最悪形は「最も長い入力」とは限らない — 上限の値は両側で固定する

上限いっぱいの計時で最も長いパスを組む形を最悪形として選んだところ、長いパスを先に作り、残りの回数でそれを解決し直す形のほうが約 2 倍遅かった。コストは最終的なパスの長さではなく、解決し直す回数とパスの長さの積で決まる。計時テストの最悪形は、コストの式の各因子を最大にする組み合わせから選ぶ。

上限の値を定数から読んで入力を組み立てるテストは、その値に追従する。値を下げる変更を入れても入力が一緒に縮むため、テストは通り続ける。上限の値は少なくとも 1 か所で、実装側とテスト側の両方を同じ値に固定する（共有 parser で読んで比べる等）。上限を差し替えたり改名したりしたときは、名前と説明文を grep して、hook のコメントやテストのラベルに残った旧上限の記述も追従させる。

## 関連ページ

- [consume 操作 (read+delete+return) は delete-then-return 順で fail-closed にする](../patterns/consume-operation-delete-then-return-fail-closed.md)
- [security guard の deny メッセージ改善は判定ロジック不変の subkind タグ分岐で行う](../patterns/security-guard-message-only-subkind-branching.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [検査用のシェル字句解析は判定対象を標準形に絞り、それ以外を fail-closed にする](./inspection-parser-narrow-to-standard-form-fail-closed.md)
- [委譲リファクタの動作保持は原実装との差分テストで機械的に立証する](./delegation-refactor-differential-test-equivalence.md)

## ソース

- [timeout→fail-open bypass の HIGH 指摘 (super-linear 正規化 + fail-open timeout) と fault-injection の allow-all バックドア指摘](../../raw/reviews/20260703T070536Z-pr-1736.md)
- [反復上限で塞ごうとした初回対応 (後に不十分と判明)](../../raw/fixes/20260703T071412Z-pr-1736.md)
- [反復上限では各反復 O(入力長) を縛れず bypass 未解消、O(1) 総バイト長ガードを正規化前に置くべきとの再指摘 (HIGH)](../../raw/reviews/20260703T073719Z-pr-1736.md)
- [全検査の前に ${#COMMAND} の O(1) ガードを追加し O(n²) heredoc 除去 (${COMMAND%%<<*}=45s) と Pattern 2 regex (>2min) を一括短絡](../../raw/fixes/20260703T075749Z-pr-1736.md)
- [全 4 reviewer 指摘ゼロで収束。O(1) 総バイト長ガードで全経路封鎖を実機検証](../../raw/reviews/20260703T082154Z-pr-1736.md)
- [(follow-up cycle1) — 未クォート `for x in $var` の glob 展開が length-guard 後にトークン数を膨らませ入力サイズ bound を破る HIGH（+ CWD 依存 over-DENY 誤検出）](../../raw/reviews/20260715T194532Z-pr-1865.md)
- [(follow-up cycle1) — 検出ループを `set -f`/`set +f` で noglob 化し over-DENY と timeout 無制限反復を同時封鎖、noglob 状態を save/restore](../../raw/fixes/20260715T195606Z-pr-1865.md)
- [(follow-up cycle3) — noglob 修正を全 reviewer が実機検証（fail-on-revert / glob-target が Layer-1 落ちする net-positive）し mergeable 収束](../../raw/reviews/20260715T203920Z-pr-1865.md)
- [が残した兄弟 `for tok in $WT_ARGS`（:608 worktree-add 引数走査）を同型 noglob スコープで水平展開。全 4 reviewer（security/code-quality/error-handling/test）が sibling grep 照合 + fail-on-revert 実機検証で指摘ゼロ収束](../../raw/reviews/20260715T230852Z-pr-1867.md)
- [レビュー結果（下流 helper と上流の展開による二乗コスト）](../../raw/reviews/20260928T043542Z-pr-3379.md)
- [レビュー結果（同じ呼び出し口の別の超線形と、プラットフォームの暗黙の上限）](../../raw/reviews/20260928T053742Z-pr-3379.md)
- [fix 結果（呼び出し側の明示の入力長上限で超線形を抑える）](../../raw/fixes/20260928T055141Z-pr-3379.md)
- [レビュー結果（1 文字ずつの走査が UTF-8 ロケールで二乗時間になる、他の層への委譲の主張）](../../raw/reviews/20260928T051919Z-pr-3388.md)
- [レビュー結果（入力長の上限が macOS の CI で崩れた、計時テストの条件）](../../raw/reviews/20260928T061637Z-pr-3379.md)
- [fix 結果（コストの源ごとの上限、解決結果の使い回し）](../../raw/fixes/20260928T063605Z-pr-3379.md)
- [レビュー結果（伸びたパスを解決し直す二乗が残る）](../../raw/reviews/20260928T085952Z-pr-3379.md)
- [fix 結果（作業先の変更回数に上限を置く）](../../raw/fixes/20260928T091402Z-pr-3379.md)
- [レビュー結果（旧上限の記述の残り、定数に追従するテスト、最悪形の選び方）](../../raw/reviews/20260928T095306Z-pr-3379.md)
- [fix 結果（旧上限の記述の一掃、解決回数とパス長の積の計時、上限の値の両側固定）](../../raw/fixes/20260928T100658Z-pr-3379.md)
