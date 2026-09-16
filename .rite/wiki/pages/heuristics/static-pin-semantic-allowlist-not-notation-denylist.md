---
type: "heuristics"
title: "静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く"
domain: "heuristics"
description: "静的 pin（ソースの文字列を grep して構造を固定するテスト）を「この表記が出現しないこと」として書くと、**同じ意味を持つ別表記が pin を素通りする**。"
created: "2026-08-05T05:30:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260916T101455Z-pr-2910.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T043752Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T050456Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T040912Z-pr-2715.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T143622Z-pr-2821.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T025549Z-pr-2896.md"
tags: ["test", "static-pin", "allowlist", "mutation", "bash"]
confidence: high
generated: { by: "rite-wiki-ingest/gpt-6-astra", at: "2026-09-16T10:24:00Z" }
verified:
  - { by: "rite-wiki-ingest/gpt-6-astra", at: "2026-09-16T10:24:00Z" }
  - { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-12T04:13:09Z" }
  - { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-14T14:50:00Z" }
  - { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-16T03:09:20Z" }
---

# 静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く

## 概要

静的 pin（ソースの文字列を grep して構造を固定するテスト）を「この表記が出現しないこと」として書くと、**同じ意味を持つ別表記が pin を素通りする**。守っているのは性質ではなく、たまたま今そこにある書き方でしかない。

pin は「成立させたい性質」の側から書く。等価な代替構文を allowlist として並べるか、より強く位置不変条件（定義がどこにあるか）で固定する。

## 詳細

### 実測された症状（cycle 3）

signal trap で回収する tempfile 変数がグローバルであることを守るため、「変数が `local` 宣言に含まれていないこと」を assert する pin を置いた。

bash では `declare` / `typeset` も関数内で同じスコープを作る。`local _x` を `declare _x` に書き換えるだけで、**pin の両半分を通過したまま「関数ローカル化して trap が回収できない」欠陥を再導入できた**。mutation を当てて初めて生存が判明した。

pin の文面は正しく、意図も正しかった。誤っていたのは、意図（関数スコープを作らせない）を実装（`local` という 6 文字）で近似したことである。

### 書き換えの方向

| 弱い pin（denylist） | 強い pin（allowlist / 位置不変条件） |
|---|---|
| `local` を含まない | 関数スコープを作りうるキーワード全体（`local` / `declare` / `typeset`）を対象にする |
| 特定キーワードの不在 | **定義位置が関数の外側であること**を行番号比較で固定する |

位置不変条件のほうが強い。表記の集合は言語やシェルの版で増えうるが、「定義が関数の外にある」は表記に依らず成立する。

### 一般化

- 禁止事項を「今そこにある書き方」で表現した pin は、**表記の言い換えに対してゼロ識別力**になる
- allowlist で書けない（性質を直接表現できない）ときは、denylist であることを明示し、既知の代替表記を列挙したうえで**列挙が非網羅であることをコメントに書く**
- pin を足したら、その場で **表記だけを替える mutation** を当てる。落ちなければ denylist に退化している

### 併せて確認する軸

同じ cycle で、`grep -q` を pin する assertion が「値は含むが位置が違う」形の入力で落ちなかった例も出た。denylist / allowlist の軸とは別に、**位置固定（前方一致 / 最終行の等値）を持つ述語は、位置だけを崩す mutation で識別力を確認する**必要がある。

### 禁止文を含む本文への negative pin は、禁止文を除外してから照合する

契約文書の退路パラグラフに「迂回を許す語彙が出現しないこと」を pin する場面で、本文には既に「helper 内の cd や main checkout への退避で拒否を迂回する経路ではない」という**禁止文そのもの**が含まれていた。禁止文は否定形で許可語彙を名指しするため、本文全体に negative grep を当てると禁止文自身に当たって偽陽性になる。

対処は、禁止文を `sed` で除いた別変数に対して照合し、元の変数と既存の存在 pin は触らないこと。除外が本文全体を消していないことも同時に pin する（除外後に残るべき文言の存在確認）。除外を怠ると negative pin はそもそも置けず、「存在 pin だけで対の負側が無い」状態に戻る。

この場面でも denylist が言い換えを素通りする性質は変わらない。レビューでは「迂回しても構わない」「main checkout 側で実行し直す」といった言い換えが green のまま生存することが実測された。契約側が denylist 方式と限界のコメント化を明示的に要求している場合はそのまま可としつつ、言い換えが実際に混入した時点で語彙を足すのではなく、退路で許容する行動（停止・復旧案内・承認手順）を allowlist として pin する方向へ切り替える。

### denylist を残す場合は「使う側」の allowlist を対にし、denylist は表記揺れに依らない形にする

awk の見出し判定を `==` で書くとロケール照合で誤判定する、という欠陥を denylist `\$0 [!=]= head` で pin していた場面で、演算子の両側の空白 1 個という表記に依存していたため `$0==head` / `head == $0` / `$0 ~ "^### "` はすべて素通りした。判定式の件数 pin も、代入行 `is_head = (...)` が残っていれば使う側の規則を `==` 比較に戻しても件数が動かず、green のまま欠陥が戻る。

対処は 2 段で行う。第一に、**使う側の規則**（`is_head { in_sec=1 }` / `is_head { skip=1; next }` / 節境界式 / count 判定式）を `grep -cF` の allowlist として固定する。代入行が残っていても使う側が書き換われば件数が動く。第二に、denylist を残すなら ERE の選択肢で `\$0[[:space:]]*[!=]=[[:space:]]*head|head[[:space:]]*[!=]=[[:space:]]*\$0|~[[:space:]]*"\^### "` のように空白の有無と被演算子の順序に依らない形へ広げる。denylist の網羅は際限がない（既存規則を残したまま `$0 ~ head` を追加する変異は依然として素通りする）ので、denylist は補助に留め、allowlist が主であることを変えない。

ERE の交替を denylist に使うときは、各枝が非空で単独でも HEAD に 0 hit であることを確認する。枝の一方が空や `^ *` のような常時一致になると assert 自体が恒真化する。実測は fix を外した mutant で suite の exit code が非 0 になること、HEAD で 0 になることの両側で行う。

### 免除は形から推測せず、明示マーカーで宣言させる

モック gh の各 case arm が「実 jq へ dispatch する」ことを静的に pin する場面で、stderr へ出して `exit 1` するだけの純粋なエラー arm を免除する必要があった。免除条件を arm の形から推測する述語 — 「`exit 1` を含む」「stdout writer（echo / printf）を持たない」「exit を見た後に writer が無い」 — は 3 サイクル連続で穴が見つかった。`exit 1` を持ちつつ最後に dispatch する複合 arm が免除され、writer の列挙は `cat` や awk 経由の出力を数え落とし、順序に依存する述語は行の並べ替えで崩れる。推測の外側には必ず抜け道が残り、レビューはそのたびに新しい形を見つけてくる。

対処は免除を推測から宣言へ変えること。免除したい arm には `# no-jq-dispatch: <理由>` のような明示マーカーを書かせ、述語を「dispatch している」「マーカーを持つ」の 2 値に縮約する。どちらでもない arm は無条件に fail する。マーカーは理由を書く欄を兼ねるので、免除の妥当性がレビューで読める。これは denylist（形の列挙）を allowlist（宣言の有無）へ反転する操作でもある。

あわせて、scanner が実際に閉じた arm 数と `grep -c` で数えた arm 数を突合する。終端パターンの取りこぼしで後続 arm が無検査になる経路を scanner 自身に検出させないと、免除述語を直しても走査面の欠落は無音のまま残る。

### コマンド記録の改行で禁止操作を見落とさない

状態保持型の gh shim で変更操作の不在を検証するとき、引数をそのまま複数行に記録すると、GraphQL の `mutation` が次行へ分かれて行単位の denylist を通過する。コマンド境界を保持したうえで引数内の改行を正規化し、許可した読取り操作以外の記録があれば失敗させる。

単一行の通常入力だけでなく、複数行 GraphQL 引数を含む変更操作を注入して検出を確かめる。記録を整形しただけで安全になったとは判定せず、allowlist の拒否を実際に確認する。


## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](./fixture-mutation-isolates-invariants.md)
- [静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く](./static-guard-declare-scan-scope-limits.md)
- [pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する](../patterns/pin-literal-uniqueness-verified-by-mutation.md)

## ソース

- [今回のレビュー結果](../../raw/reviews/20260916T101455Z-pr-2910.md)

- [`declare` / `typeset` で pin を素通りできることを検出](../../raw/reviews/20260805T043752Z-pr-2112.md)
- [静的 pin を allowlist へ反転](../../raw/fixes/20260805T050456Z-pr-2112.md)
- [退路本文への negative pin で禁止文を除外してから照合したレビュー結果](../../raw/reviews/20260912T040912Z-pr-2715.md)
- [denylist の表記依存と使う側の allowlist 不在を mutation で実測したレビュー結果](../../raw/reviews/20260914T143622Z-pr-2821.md)
- [免除条件の推測が 3 サイクル素通りし明示マーカーへ切り替えたレビュー結果](../../raw/reviews/20260916T025549Z-pr-2896.md)
