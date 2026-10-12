# Hook・ガード・分類器の設計規則

hooks（`hooks/*.sh`）と、コマンド文字列や diff を解析して許可・拒否を決める guard / 分類器を設計・変更・レビューするときに適用する。条件 → 規則の順で書く。sentinel / marker の規則は [Sentinel Contract](./sentinel-contract.md#設計規則)、worktree 固有の規則は [Git Worktree Patterns](./git-worktree-patterns.md#worktree-と-git-操作の規則) を参照する。

## 脅威モデルと fail 方向

- 拒否 guard の脅威モデルを先に決める。reviewer 向けの guard の脅威は「LLM の書き方の揺れ」であり、実際には書かれない構文の迂回を指摘として採用しない
- 防御の粒度は攻撃面に合わせる。自由文に形状ヒューリスティックを使わず、呼び出し側の literal との exact 突合にする
- 解決手段（正規化・symlink 解決・例外による拒否）を置き換えるときは、旧実装が例外で拒否していた入力を列挙し、新実装でも拒否されることを確かめる。解決の失敗を「対象外」へ合流させると拒否が許可に反転する
- 除外集合を文字列一致で判定し、許可側が symlink を解決して比べると、除外範囲が広がる。両側を同じ正規化で比べる
- substring の over-match でユーザー設定を無言で除去するのは fail-safe でなく integrity 違反である。over-capture しうる pattern は区切りを明示する
- fail-open / fail-closed の設計判断は、対称転記するコメントにも写す。deny gate へ転記する場合は fail-open の危険を明記する
- guard の対象を種別で狭める前に、新たに対象外となる種別が失う副次的な担保と、子起動への委譲経路を列挙し、判断を記録する
- 静的パーサの構文列挙は収束しない。通す形は COMMON-SET と宣言し、完全性を主張しない。残りは上位の層へ渡す
- 構文ごとの特例追加が 3 cycle 以上続き、前の形が壊れるなら、特例を捨てて粗い規則（構造を含むコマンドは一律に動的として扱う等）へ置換する。全 cycle の指摘形を、base・修正前・修正後で通して検証する
- 手書きのシェル解析器は、複合構造（`&&` / `||` / 括弧）を通常の 1 コマンドとして返さない。リスト境界は bash の意味に合わせる（空セグメントは継続演算子を保持する）
- 解析器が追えない構文（閉じない heredoc など）は規則を足さず、判定不能として fail-loud に拒否する。テストは helper に実際に届く形で書く
- ラッパー直後の `--` まで剥がして判定する。算術展開は読み飛ばさず中の置換も読み、`case WORD in` の検出は引用・置換を含む書き方と一致させる
- シェル字句判定器の規則は、偽の git / gh を PATH に置いた bash 実行との差分検証で合わせる
- 同じ検査を別言語の 2 本の parser（bash と Python tokenizer など）で行うと、片方の修正が不一致を増やす。片方を直したらもう片方を同じ変更で揃える
- 構文解析の内部目印は、入力の語に現れない値（NUL 等）で持つ。`()` の literal やプロセス置換と衝突させない
- サブコマンド名の判定に使う閉集合は CLI の alias を解決しない。alias を欠陥クラスとして扱う
- 閉集合へ語を足すときは、hook・テスト・禁止表・仕様の写しを同一変更で揃え、代替の書き方も確かめる

## 制御文字と診断

- 制御文字の除去・拒否で `[:cntrl:]` を使うと C1 制御バイトを見逃す。同一の欠陥クラスが残る reject / strip の箇所を全件探す
- 制御文字の中和をバイト単位で行うと UTF-8 の診断を壊す。`LC_ALL=C` を前置して上流の入力を制約し、安全機構は緩めない。fail-loud 化の価値は、中和フィルタを含む出力経路の全段を通過できるかを実測して確かめる
- 中和のモードは、既存の呼び出し箇所の多数派でなく、信頼境界で選ぶ
- 共有 helper のモード契約を変えるときは、全 call site を数えて波及を確かめる
- 診断の本文を運ぶ変数に sentinel 値（`_polluted=1` など）を入れない
- consume 呼び出しの `2>/dev/null` は `RITE_DEBUG` で gate し、診断を surface する。delete してから return する consume 操作は fail-closed にする

## 防御の検証

- 防御コードには、その失敗経路のテストを付ける。security 起因の防御修正は、防御を外す mutation で FAIL する pin を置く
- 防御機構を導入する修正は、Step 番号を絶対参照にし（相対参照にしない）、防御の有無で攻撃シナリオを再現する revert テストで自己否定を検出する
- defense-in-depth の cleanup を追記するときは、保護対象の race window が trap の install 後にも存在するかを確かめる
- helper に写しを足すときは、下流の防御（symlink 拒否・allowlist）を外さず、caller のファイルを直接渡す
- 処方するコマンドの判別力は実行環境（sandbox の内外）で変わる。実行場所を書き、処方環境で実測する
- 対策の導入前後で、効果を実測できる指標（transcript の stop_reason 件数など）を比べる。宣言的な強制は LLM の end-turn を防げない

## hook の有効化と範囲

- gate を有効化するときは、同じ条件を読む全 hook を grep し、既存の手順を helper の直呼びでなく hook 経由で検証する
- 状態を書くステップへ後から足す復帰手順は、書き込まれた状態の下で hook に通して確かめる
- gate の検査範囲を広げる前に、判定条件を共有する全 caller と後始末を列挙する。これまで skip されていた caller が検査対象に入る
- 停止案内へ退路を足したら、同じ停止を運ぶ全面（hook の出力・skill・テスト・仕様）を同じ commit で揃える
- parity test の sweep 対象に、markdown に埋め込まれた bash（`skills/**/*.md`）も含める。hooks と同じ idiom が skills 側にもある
- 同一機構の全メンバー（skip_file / body_file / author_file など）へ、marker 化や surface の変更を一括で適用する
- state を接頭辞・接尾辞だけの glob で読むと、別の gate の保留ファイルを拾う。名前の全体を固定して読む
- 新設する lint helper は、findings を stdout、summary を stderr（`log()`）に出し、兄弟に揃える。caller は findings を出す helper をコマンド置換で閉じない（指摘が会話から消える）
- best-effort の advisory lock の `exec 9>` は、subshell guard で先に試す
- helper 内部の書込みは bash guard から見えない。「機械的に止まる」とは書かない
