# Cycle Scope — cycle 2+ 差分スコープと reviewer 動的選抜の SoT

> **Source of Truth**: 本ファイルは `/rite:pr-review` の **cycle 2+ 差分スコープ**（レビュー対象を前回レビュー起点の diff + 前回 blocking の解消検証に限定する）と、それに伴う **reviewer 動的選抜**の設計根拠・fail-safe 規約・合成規則を定義する。実行時に必要な分岐表・reason 表・marker 名は `SKILL.md` ステップ 1.2.4 / ステップ 2 / ステップ 4.5.1 本体に置き、本ファイルは rationale を持つ。

## なぜ差分スコープにするのか

review⇄fix ループの cycle 2 以降は、fix が触った面に指摘が集中する。にもかかわらず全 reviewer が毎サイクル、未変更部を含むフル diff とコードベースを再調査していた。これは**重複調査**であり、cycle 1 で既に審査済みの面を繰り返し読むコストしか生まない。

削るのは重複であって徹底性ではない。cycle 1 のフルレビュー（全 reviewer・フル diff）は一切変更しない。

## 終了意味論が健全である理由

cycle 2+ で blocking 0 に到達したとき、それは以下の合成で「マージ可」を意味する:

1. **fix が触った面がクリーン** — 差分スコープのフルレビューで新規 blocking が出なかった
2. **前回 blocking が全て解消** — 解消検証パートで未解消が残っていない
3. **未変更部は cycle 1 で審査済み** — cycle 1 がフルレビューであることが前提条件

3 が成立するのは cycle 1 を変更しないため。したがって `overall_assessment` の意味は従来と同一で、ステップ 5.3 系の判定・実測必須ゲート・帰結クラス Gate との合成順序も不変である。

## cycle-count degradation 禁止規範との関係

[finding-cycling.md](./finding-cycling.md) は「cycle 数に応じてレビュー品質を段階的に緩める **progressive relaxation / degradation**」を明示的に禁止し、旧 cycle-count monitor を完全に削除した経緯を持つ。

本機能はこれに抵触しない。理由は**二値**だから:

| | cycle 1 | cycle 2 | cycle 3 | cycle 5 |
|---|---|---|---|---|
| スコープ | フル | 差分 | 差分 | 差分 |
| 指摘の採否基準 | 不変 | 不変 | 不変 | 不変 |

cycle 数が増えても挙動は一切変わらない（cycle 3 と cycle 5 に差がない）。緩むのは**品質基準**ではなく、既に審査済みの面を読み直すかどうかという**調査範囲**のみである。禁止されているのは前者で、本機能が変えるのは後者。

なお本機能は cycle 数を段階判定に使わない — 判定は「前回レビューの永続 JSON が使えるか」の有無だけで、cycle 番号を数えて閾値と比較する経路を持たない。

## スコープ決定の入力は永続 JSON

判定入力は `{state_root}/.rite/review-results/{pr_number}-*.json` の最新ファイルとする（`review-source-resolve.sh` の Priority 2 と同じ探索）。会話コンテキストの数え上げにも、PR コメントの本文照合にも依存しない。

**PR コメントを使わない理由**: `pr_review.post_comment` の既定は `false` で、既定構成では PR コメントが投稿されない。コメントを入力にすると既定構成で差分スコープが一度も発動せず、「設定によってレビュー範囲が変わる」挙動になる。永続 JSON は `post_comment` の値に関わらず ステップ 6.1.a で**常に**保存されるため、入力として唯一安定している。

**cycle 2+ であることの判定**: 「当該 PR の review-results JSON が 1 件以上存在し、その `commit_sha` が現在のリポジトリから到達可能」が成立することをもって cycle 2+ とする。ファイル件数を数えて cycle 番号を作る必要はない（前段の通り段階判定をしないため）。

## fail-safe は必ずフルレビューへ倒す

スコープ決定に必要な情報が 1 つでも欠ければ、差分スコープを諦めてフルレビューへ倒す。「取れなかったから狭いスコープで妥協する」経路は持たない — 欠落時に安全側は常に**広い方**である。

| reason | 状況 | なぜフルへ倒すのが安全側か |
|--------|------|--------------------------|
| `no_prev_json` | 当該 PR の review-results JSON が無い | cycle 1 と区別できない。cycle 1 はフルが正しい |
| `prev_json_unreadable` | JSON が壊れている / 読めない | 前回 blocking の集合が不明。解消検証を組めない |
| `commit_sha_missing` | `commit_sha` が空 / null / キー欠落（旧形式） | 差分の起点が無い |
| `commit_sha_unreachable` | `git cat-file -e {sha}` が失敗（force-push / rebase で消失） | 起点 commit が履歴に無く diff を取れない |
| `diff_failed` | `git diff {sha}..HEAD` が失敗 | 差分自体を取得できない |
| `empty_diff` | `git diff {sha}..HEAD` は成功したが差分ゼロ行 | 前回起点から新規 commit が無く、審査対象も解消検証の材料も空になる |
| `jq_missing` | `jq` が PATH 上に無い | JSON を読む手段が無い。環境欠陥だが、状態を書き換えない本 helper には安全な既定（full）が常に存在するため、レビュー自体は止めずスコープだけ広い方へ倒す |

fail-safe 発火時は WARNING を可視化する（silent fallback 禁止）。「なぜ今回フルに戻ったか」が見えないと、差分スコープが効いていないことに気付けない。WARNING には**対象**（読めなかった JSON のパス、解決できなかった `base_sha`）と**原因**（`jq` / `git` の stderr 先頭数行）を含める — reason だけでは、同一 PR の JSON を複数世代持つ `.rite/review-results/` のどれが壊れていたかを運用者が特定できない。

`no_prev_json` だけは WARNING を出さない。これは cycle 1 の正常経路であり、毎回警告を出すと本当の異常が埋もれるため。`state-path-resolve.sh` の解決に失敗して cwd 相対へ倒れた場合は別途 WARNING が出るので、「黙って cycle 1 扱いになる」経路は塞がれている。

helper が **marker を 1 つも出さずに非ゼロ終了した場合**（引数欠落 / 未知フラグの usage error）も consumer 側で `full` として扱い、reason は `helper_failed` とする。この 7 番目の reason は helper 内の 6 reason では表現できない（marker を出せない状況そのもの）ため、[SKILL.md](../SKILL.md) ステップ 1.2.4 の consumer 側に置く。

この fail-safe の向き（欠落 → 安全側 = 広い方 / 確認を出す方）は、ステップ 3.3 の E2E 判定や ステップ 3.4 の batch 判定が helper 失敗時に interactive へ倒すのと同型である。新しいシグナルを発明せず既存の判定形に揃えている。

## 既存 `review.loop.verification_mode` との合成

既存の verification mode（`review.loop.verification_mode`、既定 `false`）は **PR コメント**から前回レビューを検出し、ステップ 4.5.1 の検証テンプレートを通常テンプレートに**追加**注入する。本機能は**永続 JSON** から検出する。検出源が 2 つあるため、合成規則を明示する。

**規則**: `cycle_scope == incremental` のとき、ステップ 4.5.1 の検証テンプレートは**追加注入しない**。

理由は包含関係にある。4.5.1 の Part 1（前回指摘の修正検証）と Part 2（修正差分のリグレッションチェック）は、差分スコープ mandate の (1) 前回 blocking の解消検証 と (2) fix diff のフルレビュー にそれぞれ包含される。両方を注入すると reviewer に相反する 3 つのスコープ指示（通常テンプレートの「全体をレビュー」／ 4.5.1 の「フルレビューも別途実施されます」／ 差分スコープの「未変更部は再監査しない」）が同時に届き、どれが権威か決まらない。

`cycle_scope == full` に倒れたとき（cycle 1 または fail-safe）は、従来どおり `verification_mode` の判定と 4.5.1 の注入がそのまま動く。差分スコープが使えない状況で、コメント由来の検証情報だけは使えるケースを取りこぼさないため。

## reviewer 選抜をパターンマッチの「入力」で行う理由

cycle 2+ の reviewer 選抜は、ステップ 3.2.1 の cap 適用**後**に落とすフィルタとしては実装しない。ステップ 2.2 のファイルパターンマッチに渡す**入力ファイル一覧**を、PR 全体の変更ファイルから **fix diff のファイル一覧**へ差し替えることで行う。

こうすると以下が全て既存実装のまま成立する:

- ステップ 2.3 の sole-reviewer guard（1 名になったら code-quality を co-reviewer として追加）
- ステップ 3.2 の Security Expert 条件付き選定
- ステップ 3.2.1 / [reviewers/SKILL.md](../../reviewers/SKILL.md) Phase 5 の cap、`mandatory` 保護、`effective floor = max(min_reviewers, sole_reviewer_guard_floor)`

cap 後のフィルタにすると、これらのフロアと `mandatory` 保護を選抜側で再実装することになり、Phase 5 が SoT である不変条件が二重管理になる。

**AC-4（新面のフル審査）が自動的に成立する**: fix が前回レビュー範囲外の共有 helper を触った場合、そのファイルは差し替えた入力一覧に含まれるため、パターンマッチにとって単なる 1 つの変更ファイルとして扱われる。「範囲外だったファイルを昇格させる」特別扱いの分岐を書く必要がない。

## 前サイクル finder を `mandatory` で合流させる理由

前サイクルで blocking を出した reviewer は無条件に再起動する。その reviewer は自分が出した指摘の解消を検証できる唯一の担当だからである。

合流時の `selection_type` は **`mandatory`** とする。`recommended` にしてはならない — Phase 5 の cap が保護を保証しているのは `mandatory` のみで、`recommended` は `max_reviewers` 超過時に落ちうる。落ちると「前サイクル finder は無条件に再起動する」が成立しなくなる。

昇格は既存の昇格 priority（`detected < recommended < mandatory`）に従い、より高い側へのみ動かす。既に `mandatory` の reviewer に対しては no-op。

前サイクル finder は永続 JSON の **`findings[]` と `non_blocking_findings[]` の和**から、gated scope（`current-pr` / `follow-up`）の finding だけを取る。2 つの配列を跨ぐのは、実測必須ゲートが両方向に要素を動かすためである:

- `findings[]` には `scope == "nit-noted"` がゲート対象外として非実測でも残る → **絞らないと余分が入る**
- 非実測の gated 指摘は `non_blocking_findings[]` へ**移送**され `findings[]` から消える → **`findings[]` だけ見ると足りない**

`nit-noted` を和に含めないのは、nit が「修正不要」と決着済みで再検証の価値が無く、含めれば cap 免除枠を占有するだけだから。対して非実測の `current-pr` / `follow-up` は「merge は止めないが未解消」であり、再検証と再記録の価値がある。この違いが母集団を分ける根拠になる（記録コメントは update-in-place で毎 cycle 本文を置換するため、再導出されない指摘は PR 上の記録からも消える）。

`findings[]` 全体を blocking 集合として扱うと、以下 2 系統の欠陥が出る:

- nit しか出していない reviewer が `mandatory` で合流し、Phase 5 が `mandatory` を絶対に落とさない性質から `max_reviewers` の枠を占有して fix diff の実担当を押し出す
- 受け流し済みの nit が解消検証 mandate に注入され、nit-noted は定義上恒久的に NOT_FIXED であるため毎サイクル再掲される（[finding-cycling.md](./finding-cycling.md) の収束設計と逆行する）

絞り込み後の `reviewer` は agent 名（`code-quality-reviewer` 等）のため `-reviewer` サフィックスを除いて `reviewer_type` に正規化し、統合済みの旧 type（`api` / `frontend` / `performance` / `database` / `type-design`）は [reviewers/SKILL.md](../../reviewers/SKILL.md) の Legacy Reviewer Type Aliases 表に従って `application` へ読み替える（silent skip しない）。

抽出用 jq が失敗したときに空文字へ fallback してはならない。空の `prev_finders=` は「前サイクルの blocking が 0 件だった」正常系と**バイト単位で同一**で区別する手段が無く、fallback すると本節が根拠づけた無条件再起動の保証が無音で破れたまま差分スコープへ入る。既存の `prev_json_unreadable`（「前回 blocking の集合が不明」）へ合流させる。

## 選抜表を新設しない理由

[reviewers/SKILL.md](../../reviewers/SKILL.md) の Available Reviewers テーブルが reviewer → ファイルパターンの SoT であり、`reviewer-registry-drift-check.sh`（`/rite:lint` Phase 3.5）が `agents/` との同期を機械検査している。cycle 2+ 用に別表を作ると DRY 違反であるだけでなく、drift 検査の効かない 2 つ目の表ができて silent に腐る。

cycle 2+ で変わるのは表そのものではなく、表に**何を照合させるか**（PR 全体の変更ファイル → fix diff のファイル）だけである。

## 選抜の最低人数フロアを新設しない理由

「選抜が少なくなりすぎないよう N 名の下限を置くか」は設計時の Open Question だったが、**置かない**。

既に 2 つのフロアが存在し、パターンマッチの入力差し替え方式ではそれらがそのまま効く:

- ステップ 2.3 の sole-reviewer guard — 1 名になったら code-quality を追加して 2 名にする
- `min_reviewers` — Phase 4 で適用され、Phase 5 の cap がこれを下回ることは無い

3 つ目のフロアを足すと、どれが効いたのか分からない状態になる。

## Reviewer mandate（差分スコープ適用時に注入する本文）

`REVIEW_CYCLE_SCOPE == incremental` のとき、[reviewer-prompt-generator.md](./reviewer-prompt-generator.md) の `{cycle_scope_mandate}` へ本節の以下の本文を抽出して注入する（`{doc_heavy_mode_instructions}` と同じ conditional 抽出方式）。`full` のときは空文字列とし、セクションごと省略する。

```
このレビューは **cycle 2 以降の差分スコープ**で実行します。cycle 1 で PR 全体のフルレビューは既に完了しています。以下の 4 点を mandate として守ってください。

1. **前回 blocking の解消検証**: 下記の前回指摘が実際に解消されたかを検証する。各指摘について FIXED / NOT_FIXED / PARTIAL を判定し、NOT_FIXED / PARTIAL は指摘事項として再掲する（「前回も言った」ことを理由に手心を加えない）。判定結果は **`### 修正検証結果` 見出しと `| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |` テーブル**で出力すること（この出力契約が無いと、解消検証を silent に skip した出力と「検証した結果 0 件」の出力が区別できず、ステップ 5.1.1.1 の post-condition が機械検出できない）。

{previous_blocking_findings}

2. **fix diff のフルレビュー**: `{cycle_base_sha}..HEAD` の差分は**通常のフルレビューと同じ深さと厳しさ**で審査する。差分スコープはレビュー対象の**範囲**を絞るものであって、範囲内の**基準**を緩めるものではない。指摘の採否基準（4 必須自問・Confidence・Observed Likelihood・実測アンカー）は cycle 1 と完全に同一。

3. **Cross-File Impact Check は縮小しない**: fix が触った symbol（関数・変数・設定キー・sentinel・marker 名）の波及は、差分の**外**にあるファイルも含めて grep で確認する。呼び出し側の未更新・契約の非対称・二重定義の片側だけ更新、はこの検査でしか捕まらない。

4. **未変更部の再監査はしない**: `{cycle_base_sha}..HEAD` に現れないコードを新たに読み直して指摘を作らない。それは cycle 1 で審査済みであり、再監査は重複調査にあたる。ただし**上記 1 の解消検証**と、上記 3 の波及確認で**実際に問題が観測された**場合はこの限りではない（前回指摘の在り処と波及先は差分外でも読んでよい）。

fix が前回レビュー範囲外のファイルへ触れている場合、そのファイルは「新しい面」なのでフルスコープで審査してください（レビュー対象ファイル一覧に含まれています）。
```

## 選抜結果の記録を E2E で省略しない理由

選抜から漏れた reviewer 名と理由は統合レポート（ステップ 5.4）に記録する。この section は **E2E フローでも省略禁止**とする。

cycle 2+ は定義上 `/rite:iterate` の E2E ループからしか発生しない。E2E Output Minimization がこの section を落とすと、記録が生成される唯一の状況で記録が消える — 観測性の要求が実質的に空文になる。同じ理由で `### 実測なし指摘 (non-blocking)` section が E2E 例外として扱われているのと同型の判断である。
