---
name: learn
description: |
  完了した作業セッション (Issue/PR) の理解度を Socratic 方式で確認するスキル: 問題の背景・解決策・
  設計判断・エッジケース・影響範囲をクイズし、全項目を理解するまでセッションを終えない。
  ユーザーが明示的に /rite:learn で起動する。auto-activate しない。
  起動: /rite:learn [issue_or_pr]
argument-hint: "[issue_or_pr]"
---

# /rite:learn

## Contract
**Input**: 任意 — Issue/PR 番号。無ければ現在ブランチから推定。難易度ヒント（`eli5` / `eli14` / `intern`）も任意。
**Output**: 理解度チェックリスト（markdown）→ 段階的クイズ → 最終マスタリーサマリ → sentinel `[learn:complete]`

完了した作業セッション（Issue/PR）を題材に、ユーザー本人が変更を深く理解しているかを Socratic
方式で検証する。問題・解決策・広い文脈を 3 グループのチェックリストにし、AskUserQuestion で
段階的にクイズして、全項目の習得が確認できるまでセッションを終えない。

---

## 背景

rite は実装の多くを Claude が書くため、「動くからマージする」=自分で書いていない変更を理解しない
まま取り込む vibe coding が起きやすい。特にこのワークフローでは hooks / skills の変更が他作業に
即波及するため、理解の取りこぼしのコストが高い。本コマンドは試験官役となり、本人の理解の穴を
炙り出して埋める。**解説して終わりにせず、本人が自力で説明できる状態をゴールにする。**

## 引数

```
/rite:learn [issue/pr番号] [難易度ヒント]
```

例:
- `/rite:learn` — 現在ブランチの Issue/PR を自動特定して理解度確認
- `/rite:learn 123` — Issue/The observed review run を題材にする
- `/rite:learn eli5` — 噛み砕いた説明を多めにする
- `/rite:learn 123 intern` — #123 を「新人インターン向け」の前提で進める

---

## Phase 1: セッション文脈の収集（read-only）

クイズの題材を集める。**この Phase ではファイルを書かない。** 収集物は会話コンテキストにのみ置く。

### 1.1 引数のパースと対象の解決

まず引数トークンを順に走査し、`eli5` / `eli14` / `intern` のいずれかに一致するものを**難易度ヒント**、数値（先頭 `#` は任意）を**番号トークン**として振り分ける。番号トークンが無ければ下表の `(なし)` 経路で対象を解決する。難易度ヒントは Phase 3 の既定粒度に使う（例: `/rite:learn eli5` は番号なし＝`(なし)` 経路 + eli5 粒度、`/rite:learn 1241 intern` は番号 1241 + intern 粒度）。

GitHub では Issue と PR が単一の番号空間を共有するため、番号トークン `#N` は Issue **または** PR のどちらか一方を一意に指す。下表で `{issue_number}` と `{pr_number}` の双方を可能な範囲で解決する（片方しか得られないこともある）。

> `{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute する。

| Input | 解決 |
|-------|------|
| 番号トークン `#N` | まず `gh pr view N -R {owner_repo}` を試す。成功すれば `{pr_number}=N` とし、PR 本文の `Closes/Fixes/Resolves #M`（無ければ head ブランチ名の `issue-<番号>`）から `{issue_number}` を導出。失敗時は**失敗種別を区別する**: stderr が not-found（`Could not resolve to a PullRequest` 等）なら N を Issue とみなして `{issue_number}=N` とし、`gh pr list -R {owner_repo} --state all --json number,headRefName,title,body` の結果から headRefName が `issue-N` を含む PR を選んで `{pr_number}` に充てる（該当 PR が無ければ「#N に対応する PR が見つからないため Issue のみを題材にします」と伝えて Issue のみで進める）。それ以外の失敗（network / auth / rate-limit 等の一時障害）は Issue へ誤分類せず、「PR/Issue の判定に失敗しました（gh の一時障害の可能性）。番号を再指定するか時間をおいて再実行してください」と伝えて中断する |
| (なし) | 現在ブランチ名を `git branch --show-current` で取得し、`rite-config.yml` の `branch.pattern`（既定 `{type}/issue-{number}-{slug}`）から `{issue_number}` を導出 → `gh pr list -R {owner_repo} --head <branch> --state all --json number,title,body` で `{pr_number}` を特定（完了セッションは merged 済みが多いため `--state all` 必須） |

ブランチから Issue 番号を導出できない場合は AskUserQuestion で対象を確認する:

```
理解度確認の対象を教えてください。

オプション:
- 現在の差分（ブランチ全体の変更）を題材にする
- Issue/PR 番号を指定する
```

### 1.2 ベースブランチの確定

`rite-config.yml` の `branch.base`（既定 `main`）を読む。git log/diff の前に存在を検証し、
ローカルが無ければ remote にフォールバックする:

```bash
# ローカル → remote の順に検証
git rev-parse --verify {base_branch} 2>/dev/null \
  || git rev-parse --verify origin/{base_branch} 2>/dev/null
# 両方失敗: "ベースブランチ {base_branch} が見つかりません。rite-config.yml の branch.base を確認してください" と表示して終了
```

以降、ローカルが存在すれば `{base_branch}`、無ければ `origin/{base_branch}` を使う。

### 1.3 文脈の収集（範囲限定の read-only 呼び出し）

1. **差分・コミット**: `git diff {base_branch}...HEAD` と `git log {base_branch}..HEAD --oneline` で「何が変わったか」。
2. **Issue 本文**: `{issue_number}` が解決できていれば `gh issue view {issue_number} -R {owner_repo} --json title,body` → 問題・受入基準・「なぜ存在したか」。（`{issue_number}` 不明、または 1.1 で「現在の差分」を選んだ場合は skip）
3. **PR 本文**: `{pr_number}` が解決できていれば `gh pr view {pr_number} -R {owner_repo} --json title,body` → 解決策の経緯・設計理由。（`{pr_number}` 不明、または「現在の差分」選択時は skip）
4. **過去の決定（任意・あれば）**: commit body から「なぜそうしたか」を読む。

   ```bash
   git log {base_branch}..HEAD --format="%n--- %s ---%n%b"
   ```

   commit body から読み取れた「検討された別アプローチ」「なぜその解決か」「設計判断」を
   クイズ題材に充てる。読み取れる材料が無ければ黙ってスキップ（diff/Issue/PR で十分）。

題材が薄い（diff が極小、Issue/PR 本文がほぼ空）の場合は、その旨を伝え、無理にクイズを膨らませない。

---

## Phase 2: 理解度チェックリストの生成

収集した文脈から、3 グループの running checklist を組み立てて**一度提示する**。各項目はその
セッション固有の具体的な問いに展開する（下はテンプレート。実際は対象に即して具体化する）。

```markdown
## 理解度チェックリスト
### 1. 問題 (Problem)
- [ ] なぜこの問題が存在したか (motivation)
- [ ] 検討された別アプローチ / 分岐
### 2. 解決策 (Solution)
- [ ] なぜこの方法で解決したか
- [ ] 主要な設計判断
- [ ] エッジケース / 失敗時の挙動
### 3. 広い文脈 (Context)
- [ ] なぜこれが重要か
- [ ] この変更が影響する範囲
```

高レベル（motivation）→ 低レベル（business logic, edge case）の順に並べる。各段階の習得を
確認してから次の段階に進む。

---

## Phase 3: 段階的クイズループ（中核）

チェックリスト項目を上から順に扱い、**習得を示すまで次の項目へ進まない。**

各項目で:

1. **まず本人に説明させる（restate-first）**: open-ended に「この点をあなたの言葉で説明してください」と
   問う。本人の認識を先に引き出してから穴を埋める。要望があれば eli5 / eli14 / intern の粒度で
   噛み砕く（難易度ヒントが引数で与えられていればそれを既定にする）。
2. **「なぜ」を先に深掘り**: rationale を繰り返し掘る。なぜが固まってから「何を」「どう」を確認する。
3. **`AskUserQuestion` でクイズ**（open-ended か MCQ）。以下の house rules を厳守する:
   - **正解の位置を質問ごとにシャッフルする**（選択肢の先頭固定など、位置で当てられるパターンを作らない）
   - **提出されるまで答えを明かさない**（解説・正解はユーザーが回答を送信した後にのみ出す）
   - MCQ では誤答に「もっともらしいが間違い」の選択肢を混ぜる（理解の浅さを炙り出すため）
   - MCQ が狭すぎる論点は **Other**（自由記述）で本人の言葉を引き出す
4. **ギャップ補完**: 回答が穴を示したら、その箇所だけを該当コード/Issue/PR を引用して教え、
   同じ項目を**別の角度で再クイズ**する。
5. **チェックオフ**: 本人がヒント無しで正しく説明・回答できたら `[x]`。各項目の後にチェックリストを
   再掲し、進捗をターンを跨いで保持する。

誘導的に答えを教え込まない。本人が辿り着けるよう問いを刻む。

---

## Phase 4: 完了

全項目が `[x]` になったら、短いマスタリーサマリ（本人が理解を示した要点の要約）を出し、最終行に
sentinel を 1 つだけ出して停止する:

```
[learn:complete]
```

> **注意**: learn は Issue→PR の状態機械の外側にある終端 ritual。後段に連鎖しないため、
> flow-state 系 sentinel（`returned-to-caller` 等）や `flow-state.sh` は呼ばない。

---

## よくある失敗パターンと対策

| 失敗パターン | 原因 | 対策 |
|-------------|------|------|
| 解説して満足してしまう | 本人に説明させずに教えた | 必ず restate-first。本人が自力で説明できて初めて `[x]` |
| 「何を」だけ確認して終わる | why を掘らなかった | 各項目でまず「なぜ」を繰り返し問い、固まってから what/how |
| 選択肢の位置で当てられる | 正解を毎回同じ位置に置いた | 質問ごとに正解位置をシャッフル |
| 答えを先に見せてしまう | 解説を質問と同時に出した | 解説・正解は回答送信後にのみ提示 |
| 浅い理解を見逃す | 1 問正解で次へ進んだ | 誤答時は角度を変えて再クイズし、習得を確認してから進む |
| 題材が薄いのに無理に質問 | diff/Issue/PR が乏しい | 薄い旨を伝え、確認可能な範囲に絞る |
