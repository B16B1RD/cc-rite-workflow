---
title: "「invariant は logic 上成立」を信頼せず empirical reproduction で verify する"
domain: "heuristics"
promote: rite-plugin
created: "2026-04-27T23:01:24+00:00"
updated: "2026-07-25T14:18:43Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260722T224239Z-pr-1973.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T103301Z-pr-2017-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260427T115727Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T120659Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260503T181256Z-pr-799.md"
  - type: "fixes"
    ref: "raw/fixes/20260503T181755Z-pr-799.md"
  - type: "fixes"
    ref: "raw/fixes/20260503T182831Z-pr-799-cycle3.md"
  - type: "fixes"
    ref: "raw/fixes/20260503T183643Z-pr-799-cycle4.md"
  - type: "reviews"
    ref: "raw/reviews/20260602T064758Z-pr-1246.md"
  - type: "fixes"
    ref: "raw/fixes/20260602T065355Z-pr-1246.md"
  - type: "reviews"
    ref: "raw/reviews/20260605T045347Z-pr-1277.md"
tags: ["verification", "empirical-reproduction", "invariant", "reviewer-discipline", "silent-regression"]
confidence: high
---

# 「invariant は logic 上成立」を信頼せず empirical reproduction で verify する

## 概要

review-fix loop が累積 28+ cycle に達した時点でも、「invariant は logic 上成立する」という reasoning ベースの reviewer 判断は silent regression を見逃す経路となる。AC verification scenario を **/tmp 内に reproduction 環境を構築して helper の挙動を直接観測する** empirical 検証によって初めて顕現する non-trivial silent regression が存在する。canonical 規範: invariant 系の verdict (FIXED / acceptable / scope-creep rejected) を出す前に、AC reproduction scenario を実機で再現し、helper / system が期待通りに振る舞うことを直接観測する step を必須化する。test suite に AC reproduction scenario を直接 pin することも併せて canonical。

## 詳細

### 累積 14 回目の cycle 29 で初顕現した non-trivial silent regression

cycle 28 まで「invariant は logic 上成立」と判断されていた `_resolve_session_state_path` の writer-side fallback が、cycle 29 reviewer が **/tmp 内に AC-4 reproduction scenario を構築** して helper の silent no-op を直接観測することで CRITICAL 認定された:

- **scenario**: `schema_v=2` + valid sid + per-session 不在 + legacy が別 session の遺物
- **expected (logic)**: writer fallback で legacy にフォールバック → patch 反映
- **observed (empirical)**: writer fallback 不在 → silent skip → active=false 維持

→ reader (state-read.sh) は per-session→legacy fallback を実装するが writer (flow-state-update.sh) は同 fallback を持たない非対称が、AC-4 reproduction scenario でのみ顕現する silent regression の根本原因。28 cycle 経ても reasoning だけでは不検出。

### 検出規範

reviewer は invariant claim を以下の手順で empirical 検証:

```bash
# 1. AC scenario を /tmp 内に再現
mkdir -p /tmp/ac-4-repro/.rite-flow-state.d
echo '{"sid":"foreign-uuid-from-other-session","phase":"stale"}' > /tmp/ac-4-repro/.rite-flow-state

# 2. system / helper を invoke
cd /tmp/ac-4-repro
SID=$(uuidgen) bash {plugin_root}/hooks/flow-state-update.sh patch --phase "new" --if-exists

# 3. 期待 invariant が empirical に成立するか直接観測
cat /tmp/ac-4-repro/.rite-flow-state  # phase が "new" になっているか?
```

invariant が logic 上成立すると思っても empirical 結果が異なれば silent regression。reasoning だけで verdict を出さない。

### Test 規範: AC reproduction scenario を test suite で直接 pin

累積 14 回目の cycle 29 までの failure mode は AC-4 reproduction scenario が test suite で直接 pin されていなかったため発生。canonical fix: scenario を 6 sub-assertions の test として永続化し future regression を機械的に捕捉:

```bash
# TC-AC-4-WRITER-FALLBACK
test_writer_fallback_with_per_session_absent_and_legacy_foreign_session() {
  setup_per_session_absent
  setup_legacy_foreign_session
  bash flow-state-update.sh patch --phase "new" --if-exists
  assert_eq "$(jq -r .phase legacy_state.json)" "new"
  # ...
}
```

### `rejected(scope-creep)` 判断の empirical gate

cycle 30 で `rejected(scope-creep)` として author が承認した tradeoff (cross-session takeover) が、cycle 31 reviewer の **empirical revert test** で CRITICAL silent corruption と認定された。reject 判断は reviewer cross-validation で empirical 検証する gate を持たないと、author の主観で CRITICAL 級リスクを silent 通過させる。

→ scope-creep rejection も empirical reproduction で verify する規範 (詳細は [`scope-creep-rejection-empirical-gate.md`](scope-creep-rejection-empirical-gate.md))。

### LLM reviewer 特有の bias

LLM reviewer は invariant の logical consistency を高速に reasoning できるため、「logically sound」と判断したら verdict を出してしまう傾向。実機 reproduction を取る verification discipline は LLM reviewer の構造的 bias への対策として canonical。

### 適用対象

- AC verification: AC が claim する invariant を empirical scenario で再現する。
- Helper migration: helper 経由化後、caller の挙動を実機 invoke で確認 (sandbox eval)。
- Symmetric refactor: 「対称化」claim を strict diff で確認 + 両 side で empirical scenario を流す。
- `rejected(...)` judgment: reject 理由 (scope-creep / out-of-scope / minor) を empirical revert test で gate する。
- **Documentation factual claim**: canonical reference に書かれた CLI ツール / shell ビルトインの挙動 claim (例: 「`realpath -m` は symlink を解決しない」「`realpath --relative-to` は wiki_root 外で空文字列を返す」) は実機で `man` / runtime invoke で裏付ける。
- **Prose 内の「実用上の影響はない」断定**: 「コードブロック内のリンクは行頭 ``` 慣習なので影響なし」のような prose claim は repo 内 grep で反例の有無を確認してから出す。
- **Reviewer 評価の割れ**: 複数 reviewer の verdict が正面から割れたとき、それは多くが coverage gap (各 reviewer が異なる path をテスト) であり真の矛盾ではない。より具体的な runtime evidence を持つ finding を実機再現で確証して採否を決める。

### Documentation factual claim 検証の実例（cycle 1-4）

canonical reference 反証事例で reviewer が canonical reference (`broken-ref-resolution.md`) の factual claim を runtime / grep で 3 件反証:

1. **`realpath -m` の symlink 挙動 (cycle 1 で訂正)**: reference が「`-m` で symlink 解決しない」と書いていたが、prompt-engineer reviewer が GNU coreutils 公式 man page (`man realpath`) で「`-m` は missing components を許容するのみ、symlink は default で resolve される。symlink 非解決には `-s` が必要」と確認。reference を訂正。
2. **「実用上の影響はない」断定の反証 (cycle 1 で訂正)**: reference が「コードブロック内のリンクは行頭 ``` 慣習なので false positive 発生せず」と書いていたが、reviewer が `grep -rE '^[[:space:]]+\`\`\`' .rite/wiki-worktree/.rite/wiki/pages/` で **インデント付き code fence の実在** を立証。prose claim は repo 内検証で裏付ける必要がある (prose-only claim 禁止)。
3. **`realpath --relative-to` 外側挙動の訂正 (cycle 4 で訂正)**: reference が「`realpath --relative-to=wiki_root` は wiki_root 外で空文字列を返す」と書いていたが、cycle 4 で実機検証 (GNU coreutils 9.x) し「実際は `../../etc/passwd` のような相対パスを返し、canonical bash の `*)` 分岐で `broken="false"` になる」と立証。reference を訂正。
4. **Edge Case 表の factual error 訂正 (cycle 3 で訂正)**: cycle 1-2 で書かれた `realpath -m -s --relative-to=.rite/wiki ./pages/foo.md` の結果予測が cycle 3 reviewer の実機検証で `pages/heuristics/pages/foo.md` (`./` 相対は page_dir 起点で展開される) と立証され、Edge Case 注を訂正。

**学習**: canonical reference 内の factual claim (CLI 挙動 / 実観測 / repo 状態) は **必ず実機検証を伴う**。prose-only で claim を出すと連鎖的に Edge Case 表の挙動予測を誤らせ、cycle 境界で reviewer による反証 → 再 fix → 再 review の循環を生む。reviewer は「prose 内の factual claim」を rhetorical claim として受け流さず、必ず repo 内 grep / `man` / runtime invoke で裏付ける discipline を持つ。

### Reviewer 評価の割れは coverage gap として runtime evidence で確証する（cycle 1）

複数 reviewer の verdict が正面から割れたとき、それは多くの場合 **真の矛盾ではなく coverage gap** (各 reviewer が異なる code path をテストした結果) である。coverage gap 事例で error-handling reviewer が「CLEANED 経路 + 内側 mktemp 失敗で exit 1 を leak する」HIGH を runtime observation (mktemp-shim で no-arg call のみ失敗させる) で検出した一方、code-quality / security reviewer は normal path (normal CLEANED / mv-failure) のみテストして「exit 0 維持」と評価していた。

- 後者の評価は **彼らがテストした path では正しい**。特定 edge case (CLEANED + 内側 mktemp 失敗) が未カバーだっただけで、真の contradiction ではない。
- 解決は「どちらの reviewer が正しいか」を reasoning で決めるのではなく、**より具体的な runtime evidence を持つ finding を実機再現で確証**し採否を決める。reasoning ベースで「exit 0 は維持される」と早合点せず、reviewer が指摘した specific scenario を実機で reproduce して観測する。

→ reviewer disagreement を「矛盾」と受け取って一方を棄却するのではなく、各 reviewer がカバーした path を整理し、未カバー edge を runtime evidence で埋めるのが canonical。empirical reproduction over invariant reasoning の multi-reviewer 版。exit-code leak 自体の機構は [[trailing-and-shortcircuit-exit-code-leak]] を参照。

### CRITICAL cross-validation 対立を実機 revert test で決着し 5 cycle で mergeable に収束した事例

cycle 1 review で、既存 helper (`git-status-filtered.sh`、内部で `mktemp` に依存) への新規呼び出し経路が exit code チェックを欠く finding について、error-handling reviewer のみが CRITICAL (「TMPDIR 書込制限下で helper 自身が失敗し worktree drift axis が silent に無効化される」)、他 3 reviewer (application/prompt-engineer/security) は「raw `git status` から意図の変わらない置き換えであり non-blocking」と評価する正面対立が発生した。

cross-validation debate の pre-debate guard (CRITICAL 指摘は自動討論せず即座にユーザーへエスカレーション) が発火し、orchestrator は両者の主張を reasoning で決着させず、TMPDIR を書込不可ディレクトリに向けた状態で `git-status-filtered.sh` を単体実行する **実機 revert test** を実施した。結果、helper は exit 1 で失敗し raw `git status` は成功する非対称を empirical に確認 — error-handling の技術的主張が正しいと実証され、ユーザーがこの評価を採用する判断を下した。「同じ意図の置き換えに見えても依存関係の増加で信頼性プロファイルが変わる」ことを reasoning だけでなく実機観測で決着させた事例。

この PR はさらに cycle 2 で「cycle 1 fix 自身が pipefail dead-code バグを持つ」ことを 5 reviewer 全員が独立検出、cycle 3-4 で test coverage gap (guard logic の pin 漏れ、fixture が実装差分を observable にしていない) が段階的に発見され、severity が CRITICAL (cycle 1) → HIGH (cycle 2, 5 reviewer 一致の高確信度) → MEDIUM/LOW (cycle 3-4, test 品質) → 0 findings (cycle 5, mergeable) と単調に低下しながら 5 cycle (circuit breaker の上限直前) で収束した。CRITICAL な finding ほど早い cycle で発見され、cycle を重ねるごとに finding の性質が「機能的正しさ」から「test 品質」へと移行していくのは、reviewer が浅い層から深い層へ段階的に掘り下げていることを示す健全な収束パターン。

### 全 reviewer の実測検証規律が low-noise 収束を生む positive evidence

security 修正 PR (制御文字 neutralize の C1 8-bit 対応) で 5 reviewer (security / error-handling / test / performance / tech-writer) × 2 cycles の全員が実測検証を実施した:

- **security**: 256 バイト全数 sweep でバイトフィルタの置換範囲を網羅確認
- **error-handling**: PIPESTATUS / pipefail 挙動の実証
- **test**: 3 種 mutation test による pin の識別力実証
- **performance**: µs 単位ベンチ
- **tech-writer**: python3 による UTF-8 エンコード確認 (コードポイント範囲ラベルの検証)

結果、hypothetical finding が 1 件も出ず実証ベースの指摘のみで構成され、唯一の指摘は cycle 1 の MEDIUM 1 件 (コメント内コードポイント範囲ラベルと実装バイト範囲の不整合) → cycle 2 で 0 findings mergeable の low-noise 2-cycle 収束。empirical verification discipline が全 reviewer に行き渡ると、reasoning ベースの憶測 finding によるノイズと cycle 浪費が構造的に消えることを示す positive evidence (本ページが規範とする検出規範の全員適用形)。

### reviewer 間の矛盾は「どちらが正しいか」ではなく「何を測ったか」で解く

同一現象について reviewer の結論が割れた例: 1 名が「このコメントの因果は正確」、2 名が「不正確」と結論した。両者とも実測に基づいていたが、**測った経路が違った**。

| 主張 | 測定した経路 | 結果 |
|---|---|---|
| 正確 | envelope 経由（`file_path` に生 LF） | jq の `@tsv` がエスケープするため到達しない → 0 件 |
| 不正確 | 旧実装の `realpath` 出力経由 | 中間の LF がそのまま残り到達する → 監査レコード 2 行に分割 |

orchestrator が両経路を同一ハーネスで測ると、どちらの測定も正しく、**一般化の範囲だけが誤っていた**ことが判明した（値の入力経路が複数あるとき、1 経路の測定から「到達しない」と結論できない）。

調停の手順は「多数決」でも「severity の高い方を採用」でもなく、**各主張が何を測った結果かを突き合わせ、測っていない経路を orchestrator が埋める**。同 PR ではもう 1 件の矛盾（多層防御が成立するか）も同じ方法で解けた — 一方は「削除」の mutation を、他方は「定義行の再フォーマット」の mutation を測っており、後者では別 TC が捕捉しないことが分かった。

### ハーネス自身の false-negative を control ケースで先に潰す

revert test で新旧を比較するとき、ハーネスの構成ミスで **両方とも「問題なし」に揃う** ことがある。revert test 構成ミス事例では検証用の親リポジトリを `rite-review-mutation-*` 配下の一時ディレクトリに作ったため、ガードがそれを sanctioned な隔離ワークツリーと判定して全許可になり、control ケースまで通ってしまった。

比較を始める前に、**確実に deny になるはずの control 入力で期待どおり deny すること**を確認する。control が期待どおりでないなら、その後の差分測定はすべて無意味。

## 関連ページ

- [レビューが足場を対象に発散したら finding の基準を prompt で明示して止める](./review-finding-bar-stops-scaffolding-divergence.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](../heuristics/reviewer-scope-antidegradation.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #2017 review results (cycle 3) — reviewer 間矛盾を「何を測ったか」で調停](../../raw/reviews/20260725T103301Z-pr-2017-cycle3.md)
- [PR #688 cycle 29 review results — empirical reproduction で初顕現 silent regression](../../raw/reviews/20260427T115727Z-pr-688.md)
- [PR #688 cycle 30 fix results — empirical reproduction-driven fix](../../raw/fixes/20260427T120659Z-pr-688.md)
- [PR #799 cycle 1 review (canonical reference factual claim 反証)](../../raw/reviews/20260503T181256Z-pr-799.md)
- [PR #799 cycle 1 fix (realpath -m symlink 挙動 / prose 断定の grep 反証)](../../raw/fixes/20260503T181755Z-pr-799.md)
- [PR #799 cycle 3 fix (Edge Case 表 factual error 訂正)](../../raw/fixes/20260503T182831Z-pr-799-cycle3.md)
- [PR #799 cycle 4 fix (realpath --relative-to wiki_root 外挙動の実機反証)](../../raw/fixes/20260503T183643Z-pr-799-cycle4.md)
- [PR #1246 review results (cycle 1) — reviewer 評価の割れ (exit 0 維持 vs leak) は coverage gap であり runtime observation で確証](../../raw/reviews/20260602T064758Z-pr-1246.md)
- [PR #1246 fix results — 複数 reviewer 評価の割れを実機再現で確証して採否を決める](../../raw/fixes/20260602T065355Z-pr-1246.md)
- [PR #1277 review results — 全 reviewer の実測検証規律による low-noise 2-cycle 収束](../../raw/reviews/20260605T045347Z-pr-1277.md)
- [PR #1973 cycle 5 review results (mergeable) — CRITICAL cross-validation 対立を実機 revert test で決着、5 cycle で severity 単調減少しつつ収束](../../raw/reviews/20260722T224239Z-pr-1973.md)
