---
type: "heuristics"
title: "変更・削除の掃き出しは旧語彙・置換した条件式・別記法トークンまで広げる"
domain: "heuristics"
promote: rite-plugin
description: "散文が実行契約であるリポジトリでは、機構を 1 つ変更・削除するたびに、その機構を名指しする散文が各所に取り残される。"
created: "2026-07-29T21:32:36+09:00"
updated: "2026-08-10T11:55:05Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T010436Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T012311Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T091817Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T094749Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T010744Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T012520Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T092343Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T235426Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T103500Z-pr-2081.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T104510Z-pr-2081.md"
  - type: "fixes"
    ref: "raw/fixes/20260810T113055Z-pr-2229.md"
tags: []
confidence: high
---

# 変更・削除の掃き出しは旧語彙・置換した条件式・別記法トークンまで広げる

## 概要

散文が実行契約であるリポジトリでは、機構を 1 つ変更・削除するたびに、その機構を名指しする散文が各所に取り残される。**追加のときは「自分が書いた新語彙」で grep すれば波及先が見つかるが、削除のときは新語彙が存在しない**ため同じ手が効かない。起点事例ではこのクラスが 3 cycle にわたり形を変えて再発した。

## 詳細

### 掃く対象は 3 系統ある

**(1) 削除した識別子・機構名（旧語彙）**

cycle 3 で「ステップ 0.6 の発火後再実行 override」を実装ごと削除したのに、それを参照する散文が 3 箇所（同一ファイルの hard invariant ブロック・設計判断、および別ファイルの spec）に残った。同一ファイル内で「override を持たない」と「override が counter をリセットする」が共存する自己矛盾になり、隣接する 2 bullet が互いに排他的な機構を主張する状態まで生じた。**4 レビュアー全員が独立に検出**。

対策は削除した識別子そのもの（`override` / `発火後再実行` / `which resets the cycle counter`）で grep して 0 件になるまで掃くこと。

**(2) 置き換えた値・条件式**

cycle 4 は削除した機構名で掃いて成功したが、同じ cycle で置き換えた条件式（`RESET=failed-refire` → `REFIRE=1`）は掃かず、それを名指しする散文 2 箇所が旧語彙のまま残った。しかも片方は分岐本体より**前**に置かれた共通前文で、実行する LLM が先に読む位置にあった。

cycle 4 のコミットメッセージ自身が「削除時は旧語彙で grep」と書いていたのに、掃いたのは削除した機構名だけで条件式は掃け残っている。**grep 対象は「削除した名前」だけでなく「置き換えた値・条件式」も含める。**

**(3) 記法をまたいだ同型トークン**

最も見落としやすい系統。cycle 1 で「置換マニフェストに載っていないプレースホルダ」`{ROOT}` / `{SID}` を修正したが、同じ注意行ブロックの数行下にある実在確認コマンドの `$root` / `<UUID>` は手つかずだった。**別記法だったため `{ROOT}` の grep では引っかからない。**

`$root` は「値が解決できなかった場合」の案内文でだけ代入される shell 変数で、値が得られた支配的経路では人間の端末に存在しない。結果、正しい値を持つ人間が実行しても guard が常に偽を返し、「root か UUID が誤っている」と誤診されて唯一の復旧手順から遠ざけられていた（3 レビュアーが独立に同一 file:line を検出し HIGH → CRITICAL へ boost）。

**プレースホルダ体系を直すときは、記法をまたいだ「人間が実行するテキストに埋まっている未解決トークン」全般を対象にする。** 修正時に grep 対象を「直したトークン名」に限定すると必ず取りこぼす。命名規約（lowercase-snake）から外れた略記は乖離の兆候として grep で検出しやすい。

### 削除は下流の条件式も孤児にする

機構を消すと、それに依存していた条件が主経路を外れることがある。override を消したことで、判定に使っていた marker が「特定の分岐でしか値を持たない」性質のまま残り、その分岐を通らなくなった経路で条件が成立しなくなった。結果、review を 1 回も回さずに即再発火する当の invocation で注意行が付かない。

**削除した分岐に依存する条件を、条件側から逆に辿る。** 対策は「全経路で無条件に計算される変数」へ載せ替えること。

### 列挙は grep で数えてから直す

同一ファイルに並行する一般記述が複数あるとき（exit path テーブル・yaml コメント・別ファイルの同型テーブル）、変更のトリガーになった 1 箇所だけに carve-out を入れると、同じ文書が自分の invariant を否定したまま残る。指摘されたのが 1 箇所でも、grep で数えてから全部同時に直す。

なお **CHANGELOG の同型記述は遡及編集しない** — 過去リリースの履歴エントリはその時点の仕様を記録するものであり、現在の仕様に合わせて書き換えると履歴としての価値が失われる。

### 散文とスキーマ表は語彙が揃わない

挙動を説明する散文は直したが、同じファイル内のスキーマ表（フィールド定義）が旧規則のまま残る、という形も出た。散文とスキーマ表は読者が違う（利用者 vs 実装者）ため語彙が揃わず、散文側の語彙で grep してもスキーマ表に届かない。**フィールド名そのもの**で grep すると拾える。

### (4) 帰結を反転させる変更は「旧帰結を述べる語」で掃く

4 つ目の系統。**挙動を反転させる変更でドキュメント同期を識別子（marker 名・関数名）の grep で行うと漏れる** — 識別子を含まず帰結だけを述べる散文が同期対象から外れるため。本系統の観測事例では判別の帰結を反転させたのに、同一ファイル内の 5 行違いの記述と、reviewer prompt へ機械注入される別ファイルの記述が旧セマンティクスのまま残った。

**掃く語は「旧帰結を述べる語」にする**（「降格する」「non-blocking になる」等）。識別子ベースの grep は、識別子を書かずに帰結だけを語る散文には届かない。

同型の失敗として、**SoT が実装より狭い / 古い記述を持つと、次の編集者が SoT に従って実装を「直し」、前 cycle で塞いだ欠陥を復活させる**。SoT を写す方向の同期を怠ると、SoT 自体が退行の指示書になる。

### 掃いた後に置く pin を狭めるときは、履歴で「実際に除去した全表記形」を照合する

掃き出しの結果を守るために anti-pattern pin（旧語彙の再導入検出）を置いたあと、**誤発火を防ぐつもりで pattern に文脈語を足すと、実際に除去した表記形を取りこぼす**。PR #2229 cycle 5 では禁止語と文脈語の間に markdown 強調記号が挟まる形が抜け、5 名のレビュアーが「実証済みの検出力を未観測の誤発火リスクと交換している」と指摘した。

判断の手順:

1. **狭めた pattern が、実際に除去した全表記形を今も捕らえるかを `git log -S` で確認する**（掃いた対象は履歴に残っているので照合できる）
2. **誤発火の実例が 0 件なら裸の語のままにする** — 未観測のリスクのために検出力を落とすのは speculative structure。実際に誤発火が入った時点で fail-loud に顕在化させるほうが安全

pin 自体も複製しない。同一 pattern を N サイトへコピーすると、**片方を締めて他を忘れる drift がそのまま再生産される**。既存 idiom（`for f in ...; do assert_not_grep ...; done`）に合わせて pattern は 1 度だけ書く。

### 掃く範囲は「参照している共有 reference の登録リスト」まで含む

canonical snippet / 共有 reference が「新規箇所を追加したら usage site として登録すること」と自ら指示している場合、**その指示は自分の PR にも掛かる**。PR #2229 cycle 5 では save helper へ必須キーを 2 つ足しながら canonical 節へ登録しておらず、snippet に忠実な JSON が save 段で拒否される乖離を作っていた。

> **共有 reference を参照する実装を変えたら、その reference の登録リスト・限定句も同じ commit で更新する。**

ただし snippet 本体を広げるのではなく「write 側だけの追加検証」として書く — read 側は書込済みデータを信頼する設計なので、本体を広げると read 側が誤って厳格化される。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [agent が人間に渡す復旧コマンドは、人間の実行コンテキストで正しいかを検証する](./recovery-command-verified-in-human-execution-context.md)
- [「N 箇所で同期が必要」と指摘されたら、同期する前に N を減らせないか検討する](./reduce-sync-sites-before-syncing-them.md)
- [機械的な述語を文書化するときは意図の語彙ではなく字句の語彙で書く](./mechanical-predicate-prose-lexical-vocabulary.md)

## ソース

- [PR #2081 review results](../../raw/reviews/20260801T103500Z-pr-2081.md)
- [PR #2081 fix results](../../raw/fixes/20260801T104510Z-pr-2081.md)
- [PR #2044 review results (cycle 4)](../../raw/reviews/20260729T010436Z-pr-2044.md)
- [PR #2044 review results (cycle 5)](../../raw/reviews/20260729T012311Z-pr-2044.md)
- [PR #2044 review results (cycle 2)](../../raw/reviews/20260729T091817Z-pr-2044.md)
- [PR #2044 review results (cycle 3, mergeable 到達)](../../raw/reviews/20260729T094749Z-pr-2044.md)
- [PR #2044 fix results (cycle 4)](../../raw/fixes/20260729T010744Z-pr-2044.md)
- [PR #2044 fix results (cycle 5)](../../raw/fixes/20260729T012520Z-pr-2044.md)
- [PR #2044 fix results (cycle 2)](../../raw/fixes/20260729T092343Z-pr-2044.md)
- [PR #2044 fix results](../../raw/fixes/20260728T235426Z-pr-2044.md)
- [PR #2229 fix results (cycle 5) — 狭めた pin が除去済み表記形を取りこぼした](../../raw/fixes/20260810T113055Z-pr-2229.md)
