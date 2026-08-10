---
type: "heuristics"
title: "セキュリティ機械ゲートの部分撤去は撤去前 covered set の superset 維持と per-occurrence fail-closed 判定で収束させる"
domain: "heuristics"
description: "denylist / 列挙型の機械ゲートを「一部だけ残して大半を撤去する」リファクタ（例: reviewer read-only 強制の verb 列挙を撤去し .git 書き込み経路のみ機械ゲートに残す）は、単純そうに見えて review-fix ループが長期化しやすい。"
created: "2026-07-18T11:08:13+09:00"
updated: "2026-07-18T11:08:13+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260717T142837Z-pr-1892.md"
  - type: "fixes"
    ref: "raw/fixes/20260717T145126Z-pr-1892.md"
  - type: "fixes"
    ref: "raw/fixes/20260717T212804Z-pr-1892.md"
  - type: "fixes"
    ref: "raw/fixes/20260718T000447Z-pr-1892.md"
  - type: "fixes"
    ref: "raw/fixes/20260718T004618Z-pr-1892.md"
tags: ["security-gate", "partial-removal", "fail-closed", "static-parser", "convergence", "threat-model", "revert-test"]
confidence: high
---

# セキュリティ機械ゲートの部分撤去は撤去前 covered set の superset 維持と per-occurrence fail-closed 判定で収束させる

## 概要

denylist / 列挙型の機械ゲートを「一部だけ残して大半を撤去する」リファクタ（例: reviewer read-only 強制の verb 列挙を撤去し .git 書き込み経路のみ機械ゲートに残す）は、単純そうに見えて review-fix ループが長期化しやすい。6 review cycle を要した実測で収束の鍵となった 4 原則: (1) 撤去集合に維持すべきカテゴリの verb が混在していないか撤去前後の deny/allow ハーネス比較で確認し、維持部分の正規化を「撤去前コードの covered set の superset」にすると検出強度低下（regression）を構造的に防げる。(2) allow-list 判定はコマンド文字列を平坦化した substring マッチではなく per-occurrence の state machine で行い、default を deny-by-default に倒す。(3) 静的パーサの列挙は git バージョン依存で本質的に非収束なので「complete」と主張せず honest な residual として上位層（prompt / sandbox）に委ねる。(4) 機械ゲートの脅威モデル（誤操作防止か敵対的対策か）は設計判断としてユーザーに諮り、「収束済み」の判断は慎重に扱う。

## 詳細

起点事例は `pre-tool-bash-guard.sh`（reviewer subagent の read-only 強制フック）の verb 列挙（working-tree 変更 verb の静的パース）を撤去し、`.git` 書き込み経路のみ機械ゲートに残す refactor。6 review cycle で以下の失敗パターンと対策が実測された。

### 1. 撤去集合への「維持すべきカテゴリ」の巻き添え混入

`(A) Always-deny` ブロックの一括撤去で、撤去対象の working-tree verb（`checkout` / `reset` / `branch` 等 = `git status` で可視・回復可能）と、**維持すべき native .git-write subcommand**（`git config` / `remote` / `update-ref` / `symbolic-ref` = `.git/config core.hooksPath` 経由の main セッション RCE 経路）が同じブロックにいたため、両方まとめて撤去され CRITICAL 回帰を生んだ。

**対策**: [[flatten-refactor-deletion-scope-classification]] の「削除スコープの classification」をセキュリティ挙動にも適用する。撤去前後で **dev 版フックと PR 版フックに crafted stdin を与え deny/allow を比較する revert test**（[[reviewer-regression-claim-revert-test-attribution]]）が、静的 diff 読解より確実に検出強度低下を発見できた。

### 2. 維持部分を「撤去前 covered set の superset」にして regression を構造保証

撤去された正規化ロジック（invocation 正規化 / global-flag 正規化 / dequote）を「subcommand 照合」だけ復元して正規化を落とすと、`/usr/bin/git config`（path invocation）・`\git config`（backslash）・`git -C x config`（global-flag prefix）・`git remote "add"`（quoted sub-action）が素通りする。個別ベクタを review で 1 個ずつ発見するのは非収束。

**対策**: 撤去前コードの正規化 regex から **covered set を authoritative に読み取り**、維持部分の集合をその **strict superset** にする。「(N) は develop の正規化が covered した全 flag を含む superset」だと「develop が deny した carrier 形を PR が allow することはない = not a regression by construction」を構造的に保証できる。arg-taking global flag の集合は一度で完全に列挙する（whack-a-mole を避ける）。

### 3. allow-list は flatten-substring でなく per-occurrence の deny-by-default FSM

コマンド文字列を平坦化して substring マッチする allow-list ゲートは、**複合コマンドで allow token が別の write occurrence を masking する構造的欠陥**を持つ。`git config --list; git config core.hooksPath /evil` は先頭 read 形の substring が文字列全体にマッチし、同居する実 write（RCE）ごと allow される。

**対策**: per-occurrence の state machine で各 git invocation を独立評価し、read/write を「subcommand の直後トークン」で判定、fresh invocation を都度再認識する。核心は **default 方向の反転**: allow-by-default（read substring があれば行全体を exempt）は masking leak を生むので、**deny-by-default**（read allow-list 該当のみ通過、それ以外 deny）にすると想定外 form が leak せず over-block に倒れて収束する。さらに **同種の判定は fail-closed を対称に適用**する — config の read/write と remote の mutating/read で片方 fail-closed・片方 fail-open だと enumeration fragility の非対称が残り reviewer に指摘される（実測では remarg を cfgarg と対称に fail-closed 化した）。関連: [[allowlist-gate-hardening-checklist]]。

### 4. 静的パーサの列挙は非収束 → honest residual に bound

separate-arg global flag の列挙は git バージョン依存で本質的に非収束（git が flag を追加する / 旧 git が現行版の拒否する flag を受理する）。「complete set」と主張すると次 cycle で reviewer が漏れた flag を CRITICAL として指摘し続ける。

**対策**: 「known set（git X.Y 時点）+ 未知の separate-arg flag は上位層 backstop の residual」と honest に bound する（allowlist を COMMON-SET と宣言して tail を Layer 1 に委ねる [[best-effort-matcher-declare-common-set-to-stop-whackamole]] の tactic と同型）。env 経由 config injection（`GIT_CONFIG_*` / `GIT_DIR`）のように bash gate で原理的に塞げない経路がある以上、機械ゲートは adversarial ケースを完全には塞げない。ここで **「列挙完全性の欠落（flag 1 個の追加漏れ = 非 blocking な known-set 更新）」と「検出機構そのものの構造欠陥（flatten-substring masking のような blocking クラス）」を別クラスとして扱う**のが収束判断の要（同ページの分類と一致）。**機械ゲートの脅威モデル（well-behaved reviewer の誤操作防止か / 敵対的 reviewer 対策か）は設計判断としてユーザーに諮る** — 費用対効果は threat model 次第で、Layer 1（prompt 契約）が既に同コマンドを禁止しているなら機械ゲートの churn に見合うか自明でない。

### プロセス: 「収束済み」判断の慎重さ

機械ゲートの「収束済み」は慎重に判断する。**新しい構造クラスの bypass（flag 追加ではなく判定機構そのものの欠陥）が出たら、前提が崩れた旨をユーザーに訂正・再確認する**（silent fix-and-continue しない）。起点事例では「(N) は authoritative で収束済み」と伝えた後に複合コマンドの masking CRITICAL が判明し、訂正のうえ「keep-and-fix」の再承認を得てから構造修正（per-occurrence FSM 化）した。CHANGELOG 更新では bilingual parity（[[bilingual-changelog-sync-conventions]]）の英日同時更新を維持する。

## 関連ページ

- [Flatten refactor の削除スコープは 3 軸で classification する](./flatten-refactor-deletion-scope-classification.md)
- [形状検証 gate の allowlist 化は複数行 bypass・上流 degraded 値・コメント同期をセットで棚卸しする](./allowlist-gate-hardening-checklist.md)
- [reviewer の regression 主張は revert test で本 PR 由来か attribution する](./reviewer-regression-claim-revert-test-attribution.md)
- [best-effort な静的 matcher hardening は allowlist を COMMON-SET と宣言して whack-a-mole を止める](./best-effort-matcher-declare-common-set-to-stop-whackamole.md)

## ソース

- [PR #1892 review (verb 列挙撤去に伴う native .git-write verb 巻き添え撤去の CRITICAL / bilingual parity HIGP)](../../raw/reviews/20260717T142837Z-pr-1892.md)
- [PR #1892 fix cycle 1 (native .git-write subcommand 検出 (N) の復元 + global-flag 正規化必須性)](../../raw/fixes/20260717T145126Z-pr-1892.md)
- [PR #1892 fix cycle 2-3 (invocation/global-flag/dequote の 3 点漏れなし復元、revert test)](../../raw/fixes/20260717T212804Z-pr-1892.md)
- [PR #1892 fix cycle 4 (撤去前 covered set の superset 化・列挙非収束の honest residual・脅威モデル諮問)](../../raw/fixes/20260718T000447Z-pr-1892.md)
- [PR #1892 fix cycle 5 (flatten-substring masking の per-occurrence FSM 化・deny-by-default・fail-closed 対称・収束判断の訂正)](../../raw/fixes/20260718T004618Z-pr-1892.md)
