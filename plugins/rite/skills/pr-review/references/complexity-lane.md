# Complexity Lane — XS/S 軽量レーンの SoT

> **Source of Truth**: 本ファイルは Issue の宣言 Complexity に応じて儀式コスト（reviewer の幅と検証の深さ、implement の生産量）を比例させる **XS/S 軽量レーン**の設計根拠・fail-safe 規約・合成規則を定義する。実行時に必要な分岐表・reason 表・marker 名は `SKILL.md` ステップ 1.3.2 / ステップ 3.2.1 / ステップ 4.5 本体と `skills/issue-implement/SKILL.md` 5.0.C / 5.1.0.8 に置き、本ファイルは rationale を持つ。

## なぜレーンを設けるのか

収束性（実測必須ゲート・発散検出）と churn 抑制（帰結クラス・pin 政策）が解決した後に残った構造問題は、**どの工程も変更の大きさを知らない**ことである。1 行の設定変更でも、9 reviewer がフル装備で起動し、implement が説明的な派生散文を新設し、その散文が次サイクルの churn の燃料になる。工程の固定費が diff サイズと無関係に積み上がる。

削るのは**変更クラスに不釣り合いな儀式**であって徹底性ではない。M 以上のレビュー幅・検証深度・採否基準は一切変更しない。

## レーン境界を二値にする理由

| Complexity | レーン | reviewer 上限 | 検証 mandate | implement 生産量制約 |
|---|---|---|---|---|
| XS | `light` | `complexity_max = 3` | touched テストまで | 新規テストファイル抑制 **+ 説明的派生散文の新設禁止** |
| S | `light` | `complexity_max = 3` | touched テストまで | 新規テストファイル抑制 |
| M / L / XL | `full` | 既存 `max_reviewers`（既定 6） | 現行どおり | なし（現行どおり） |

レーン自体は `{XS, S}` と `{M, L, XL}` の二値で、cycle 数のような段階判定を持たない（[cycle-scope.md](./cycle-scope.md#cycle-count-degradation-禁止規範との関係) の二値性と同じ理由 — 段階を作ると [finding-cycling.md](./finding-cycling.md) が禁じる progressive degradation と区別がつかなくなる）。

**説明的派生散文の禁止だけが XS 限定**なのは、本機能を要求した仕様がそう規定しているためである（適用範囲の記述が「XS では」で始まり、対応する受入基準の Given も XS になっている）。S へ広げると要求されていない制約になる。逆に新規テストファイル抑制が XS/S 両方に効くのは、同じ仕様が「新規テストファイルは M+ の装備」と書いており、その補集合が `{XS, S}` だからである。**細分化はデータが要求してから行う** — 現時点で XS と S に別々の reviewer 上限や別々の mandate を与える実測上の根拠は無い。

## reviewer 上限を Phase 5 に置く理由

[reviewers/SKILL.md](../../reviewers/SKILL.md) Phase 5 が `effective_max` 解決の SoT であり、relevance ordering・`mandatory` 保護・effective floor（`max(min_reviewers, sole_reviewer_guard_floor)`）を所有している。complexity 由来の上限をここに合流させれば、以下がすべて既存実装のまま成立する:

- ステップ 2.3 の sole-reviewer guard（1 名になったら code-quality を追加して 2 名にする）
- ステップ 3.2 の Security Expert 条件付き選定
- `mandatory` reviewer は cap を超えてでも落とさない保証

cap 適用**後**に落とすフィルタとして実装すると、これらのフロアと `mandatory` 保護を選抜側で再実装することになり、Phase 5 が SoT である不変条件が二重管理になる（[cycle-scope.md](./cycle-scope.md#reviewer-選抜をパターンマッチの入力で行う理由) が同じ判断をしている）。

**したがって `light` は「常に 3 名以下」を意味しない**。`mandatory` reviewer が 4 名いれば 4 名起動するし、effective floor が 3 を上回ればそちらが勝つ。cap は上限の候補の 1 つとして `effective_max` の解決に参加するだけである。

## 固定名簿ではなく cap にした理由

「XS/S の cycle 1 は固定 2〜3 名で回すか、diff の領域から導出するか」は設計時の Open Question だった。**領域から導出 + cap = 3** を採る。

固定名簿は、変更が触れた領域と無関係な reviewer を毎回起動し、逆に領域担当を取りこぼす。ステップ 2.2 のパターンマッチは既に「変更ファイル → 領域担当」を解いており、relevance ordering（マッチしたファイル数の多い順）の上位 3 名は定義上その領域の担当そのものである。

`3` という値は、既存の sole-reviewer guard フロア `2` と合成して結果が **2〜3 名**になる最小の上限として選んだ。Issue の要求「2〜3 名 + 領域担当」はこの合成でそのまま満たされる。

## 選抜の最低人数フロアを新設しない理由

[cycle-scope.md](./cycle-scope.md#選抜の最低人数フロアを新設しない理由) と同一の理由でフロアを追加しない。既に `min_reviewers` と sole-reviewer guard の 2 つが存在し、Phase 5 の cap はどちらも下回らない。3 つ目を足すと、どれが効いたのか分からなくなる。

## 何を軽量化し、何を軽量化しないか

軽量化するのは**検証の実行コスト**だけである:

| 対象 | `light` での扱い | 理由 |
|---|---|---|
| touched テストの実行 | 実施する | 変更が壊したものは変更が触れた面のテストで捕まる |
| sandbox での全スイート複製実行 | **M+ の装備**（実施しない） | 1 行の変更に対して全スイートを複製実行する固定費が、実測で 1 サイクル 25〜32 分の検証フロアを作っていた |
| mutation 実験（[_reviewer-base.md](../../../agents/_reviewer-base.md) § Mutation experiments の worktree 手順） | **M+ の装備**（実施しない） | worktree 作成 + 変異 + スイート実行の 3 段が変更規模に対して不釣り合い |

軽量化**しない**もの（cycle 1 の M+ と完全に同一）:

- 4 必須自問・Confidence・Observed Likelihood — 指摘の**採否基準**
- 実測必須ゲートと帰結クラス分類
- **Cross-File Impact Check** — 本機能の Non-goal として明示的に維持を要求されている。これは影響範囲の見落としを防ぐだけでなく、**Complexity 過小宣言を吸収する安全網**でもある。XS と宣言された変更が共有 helper に触れていれば、この検査が波及を検出し、reviewer が宣言の誤りそのものを指摘できる

「軽量レーンだから報告しない」は禁止である。touched テストの範囲で実測できない指摘は、従来どおりアンカー無しで報告し、実測必須ゲートが non-blocking に分類する。

## fail-safe は必ず full へ倒す

レーン判定に必要な情報が 1 つでも欠ければ、軽量レーンを諦めて full（現行フル装備）へ倒す。「取れなかったから軽い方で妥協する」経路は持たない — 欠落時の安全側は常に**儀式を減らさない方**である。

| reason | 状況 | なぜ full へ倒すのが安全側か |
|--------|------|--------------------------|
| `gh_missing` | `gh` が PATH 上に無い | Complexity を読む手段が無い |
| `repo_unresolved` | owner/repo を解決できず `-R` を付けて `gh` を呼べない | 別リポジトリの Issue を誤って読むより読まない方が安全 |
| `issue_fetch_failed` | `gh issue view` が失敗（認証切れ / rate limit / Issue 不在） | 宣言値が不明 |
| `complexity_absent` | どちらの記法からも**英字トークンを取り出せない**（宣言行が無い / 崩れた記法 = lowercase key・全角コロン・リスト項目化 / `{complexity}` のような未展開 placeholder と `<!-- ... -->` / 値行を持たない `## 複雑度` 節 — **両記法とも `{` `<` を値の開始と認めず、かつ記法 2 は節探索を次見出しで止めるため、同じ記入漏れが記法や見出し語の言語によって別 reason へ分裂しない**） | rite 外で作られた Issue 等。宣言が無いものを小さいと決めつけない |
| `complexity_invalid` | 英字トークンは取り出せたが XS/S/M/L/XL のいずれでもない（`Medium` / `Small` / `XSmall` / `ZZ` 等） | 誤記を小さい側へ解釈しない |
| `issue_number_missing` | 関連 Issue を特定できず helper を呼べない（consumer 側） | 対象 Issue が分からなければ宣言値も存在しない |
| `helper_failed` | helper が marker を出さずに非ゼロ終了した（consumer 側） | 判定結果が得られていない |

helper 側 5 reason の語彙は [issue-complexity-lane.sh](../../../scripts/issue-complexity-lane.sh) の docstring が SoT。consumer 側 2 reason は helper が marker を出せない / 起動されない状況そのものを指すため helper 内では表現できず、[SKILL.md](../SKILL.md) ステップ 1.3.2 に置く（[cycle-scope.md](./cycle-scope.md#fail-safe-は必ずフルレビューへ倒す) の `helper_failed` と同型）。

**`full` が保守的な側であるとは限らない consumer が存在する**: レビュー側は `full` = reviewer を減らさない = 安全側だが、`issue-implement` 5.1.0.1 の並列実装ゲートでは `full` = 並列 sub-agent を許可する = 攻撃的な側になる。そのため同ゲートは `COMPLEXITY_LANE=full` 単独ではなく **`complexity=` の存在（= `COMPLEXITY_LANE_FALLBACK` の不在）** を判定キーにし、fail-safe 経路を順次実装へ倒している。**新規 consumer は `full` を「重い側」と仮定せず、必ず `COMPLEXITY_LANE_FALLBACK` を見ること。**

fail-safe 発火時は **全 reason で WARNING を可視化する**（silent fallback 禁止）。consumer 側 2 reason（`issue_number_missing` / `helper_failed`）も同形の `⚠️ Complexity レーン判定のフォールバック: reason=<reason>。フル装備 (M+ 相当) で実行します。` を出力する。sibling の `review-cycle-scope.sh` は cycle 1 の正常経路である `no_prev_json` だけを無警告にするが、本レーンは全 reason を loud にする。**根拠は「宣言が必ずある」ことではない** — 実測では本リポジトリの Issue 60 件中 23 件が宣言を持たず、`complexity_absent` は定常的に出うる。loud にする根拠は、full へ倒れた事実が「この PR ではレーンが働かなかった」という観測値そのものであり、AC-5 の効果計測が分母を数えるために要ることにある。定常出力の中に埋もれさせないため、helper は**宣言らしき行はあるのに値を取り出せなかった場合に限り**対象行の**行番号**を報告する追加 WARNING を出し、値を取り出せない記述（lowercase key / 全角コロン / リスト項目化 / 未展開 placeholder / HTML コメント / 値行を持たない `## 複雑度` 節）を宣言不在と切り分ける。**行の中身も原因の分類も載せない** — 前者は body が第三者の書ける外部入力だからで、後者は退避先が増えるたびに列挙と実態がずれ、同じ列挙を持つ site との同期義務が増えるため（原因分類は本節と helper docstring の reason 表が持つ）。値行が 1 行も無い `## 複雑度` 節では見出し自身の行番号へ退避する（そこが唯一の是正先のため）。

## Complexity の抽出元を Issue body に限る理由

flow-state は complexity フィールドを持たず、Projects の Complexity フィールドはフィールド名のローカライズ解決を伴う別経路になる。Issue body は `gh issue view --json body` 1 回で読め、**rite の Issue テンプレート経由で作られた Issue** は Section 0 Meta に宣言値を持つ。テンプレートを経ない生成経路（`/rite:cleanup` が作る `残作業:` Issue 等）は Complexity を Projects フィールドにしか持たないため body からは読めず、`complexity_absent` で full へ倒れる — レーンが発動する母集団はこの分だけ狭い。

リポジトリ内に 2 つの記法が併存する（`**Complexity**: X` = [template-structure.md](../../../templates/issue/template-structure.md) Section 0 Meta / `## 複雑度` セクション = [common-principles.md](../../rite-workflow/references/common-principles.md)）ため helper は**両方を受理する**。片方だけ読むと、もう片方で書かれた Issue が全て `complexity_absent` で full へ倒れ、レーンが一度も発動しない。記法 1 を優先し、どちらで読んだかは marker の `source=` で区別できる。

**Complexity の自動判定はしない**。宣言値をそのまま使い、誤宣言の是正は既存の issue-create 見積もり手順と、上記 Cross-File Impact Check の安全網に委ねる。判定器の新設は speculative である。

## Reviewer mandate（軽量レーン適用時に注入する本文）

`COMPLEXITY_LANE == light` のとき、[reviewer-prompt-generator.md](./reviewer-prompt-generator.md) の `{complexity_lane_mandate}` へ本節の以下の本文を抽出して注入する（`{cycle_scope_mandate}` / `{doc_heavy_mode_instructions}` と同じ conditional 抽出方式）。`full` のときは**空文字列とし、セクションごと省略する** — 空見出しだけが残ると M+ の prompt が変化し、AC-4（M+ の挙動不変）に違反する。

```
このレビューは **XS/S 軽量レーン**で実行します。関連 Issue の宣言 Complexity が `{complexity}` のため、儀式コストを変更規模に比例させます。以下の 4 点を mandate として守ってください。

1. **検証は touched テストまで**: 実測アンカーのための実行は、この PR が触れたファイルに対応するテストスイートに限定します。**全スイートの sandbox 複製実行と mutation 実験（共通レビュー原則の § Mutation experiments に定義された worktree 手順）は M+ の装備であり、本レーンでは実施しません**。ただし「**契約対応の未 pin**」クラス（Issue の §4.4 MUST / §5 AC の `Then` が規定する挙動を無効化しても suite が green）の判定に限り、本レーンでも mutation 実験を実施してください — 同クラスのアンカー適格な書き方は mutation の実行結果のみで、ここを軽量化すると下記 2 の「実測必須ゲートと帰結クラス分類は不変」が blocking 集合への帰属という観点で成立しなくなります。

2. **指摘の採否基準は緩めない**: 4 必須自問・Confidence・Observed Likelihood・実測アンカー・帰結クラス判定は cycle 1 の M+ と完全に同一です。軽量化するのは**検証の実行コスト**であって、指摘の**採否基準**ではありません。

3. **Cross-File Impact Check は縮小しない**: 変更が触れた symbol（関数・変数・設定キー・sentinel・marker 名）の波及は、差分の**外**にあるファイルも含めて grep で確認します。これは本レーンでも M+ と同じ深さで実施してください。

4. **Complexity 過小宣言はそれ自体を指摘する**: 上記 3 の結果、変更が共有 helper や公開契約へ波及していて `{complexity}` の宣言と釣り合わないと判断した場合、**宣言の誤りそのものを指摘事項として報告**してください（本レーンの軽量化が不適切に適用されたことの唯一の検出経路です）。

touched テストの範囲で実測できない指摘は、従来どおりアンカーを付けずに報告してください（実測必須ゲートが non-blocking に分類します）。「軽量レーンだから報告しない」は禁止です。
```

## 選抜結果の記録を E2E で省略しない理由

軽量レーンで起動しなかった reviewer 名と、軽量化した mandate は統合レポート（ステップ 5.4）に記録する。この section は **E2E フローでも省略禁止**とする。

理由は [cycle-scope.md](./cycle-scope.md#選抜結果の記録を-e2e-で省略しない理由) の「cycle 2+ は E2E からしか発生しない」とは**異なる** — 軽量レーンの cycle 1 は standalone `/rite:pr-review` からも到達する。省略を禁じる根拠は、本機能が動機づけられた経路そのものにある: 想定シナリオの中心である「XS が 1 サイクル収束して**自律マージ**される」経路は `/rite:iterate` の E2E ループでしか起きない。そこで記録を落とすと、「何名スキップし何を軽量化したか」が人間に届く唯一の同期経路が、本機能の主対象シナリオでだけ消える。観測性の MUST が実質的に空文になる点で `### 実測なし指摘 (non-blocking)` の E2E 例外と同型である。
