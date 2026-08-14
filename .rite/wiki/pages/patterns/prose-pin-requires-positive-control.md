---
type: "patterns"
title: "散文契約の静的 pin には weakened probe による positive control を課す（見出しラベルで充足する pin を構造的に排除する）"
domain: "patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/patterns/prose-pin-requires-positive-control.md"
description: "SKILL.md の散文（判定ルール・設計宣言）を契約として静的 grep で pin する設計は、pin 自体が容易に vacuous 化する。"
created: "2026-07-26T10:05:51Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260726T062935Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T025351Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T014448Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T092442Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T013737Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T011928Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T003406Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T010703Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260808T063447Z-pr-2150.md"
  - type: "fixes"
    resource: "raw/fixes/20260808T064117Z-pr-2150.md"
  - type: "reviews"
    resource: "raw/reviews/20260810T160134Z-pr-2231.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-11T01:20:00+09:00" }
---

# 散文契約の静的 pin には weakened probe による positive control を課す

## 概要

SKILL.md の散文（判定ルール・設計宣言）を契約として静的 grep で pin する設計は、pin 自体が容易に vacuous 化する。起点事例は同じ欠陥クラスを 2 サイクル連続で再生産したため、個別修正ではなく **pin の作り方そのもの** を変えた。

```
assert_prose_pin <text> <pattern> <weakened-probe> <label>
  # pattern が text に一致すること + weakened-probe に一致しないこと の両方を要求する
```

見出しラベルだけで充足する pin は probe 段で落ちる。これは「既知の違反を検出器に通して発火を先に証明する」positive control の規律を、散文 pin へ適用した形である。

## 詳細

### 再発した欠陥クラス

1. **pin が命題ではなく見出しラベル／語彙にマッチする。** 太字見出し「**さらに prefix は行頭から一致させ、デリミタ内は data として無視する**」に対し `prefix.*行頭.*一致` と書くと、本文の operative 節「肯定・否定とも行頭一致で行う」を「部分一致」に反転しても緑のまま通る。`デリミタ.*data` も、operative な一文を消して見出しに一致して通った。**散文を pin するなら operative な一文を狙う。より強いのは散文ではなく emitter の実出力を pin すること。**

2. **判定値ではなく言い回しを拘束する。** consumer 契約の pin に prose grep を足したところ、AC を満たしたままの言い換え 7 種すべてで赤くなった。**散文を pin するテストは「判定値・識別子・処方コマンド」に限定し、語尾や助詞・行末アンカーを含めない。** 正規表現を緩めて対処すると pin が摩耗するので、最初から契約部分だけを拘束する。修正後は「手動削除→手動で削除」「止められない→抑止できない」等の言い換え mutation で **緑のまま** であることを実測して確認する。

3. **禁止表現の不在だけを検査する。** 「保証する」という literal の不在のみを検査していたため、「必ず残ることを保証します」への書き換えで通った。**禁止表現の不在ではなく、要求される性質（できないことの明示）を肯定形で assert する。** さらに命題 pin は **肯定の存在と否定の不在を両方** 要求する — 「既に削除済みの場合がある」の存在だけでは、同じ語彙で意味を反転した文（「設定に関わらず必ず残る」）が通る。

4. **AC が「A と B を区別して記述」を要求するとき、片側だけの pin では半分が無防備。** 否定表現（できない側）だけを検査していたため、「できる側」を丸ごと削る整理で緑のまま通った。両側を独立に pin する。

### scope と単位の規律

- **pin は「検査したい範囲を抽出してから」掛ける。** ファイル全体を対象にすると、同じ literal が別セクション（判定表・ドキュメント）に存在するだけで充足され、emitter を消しても緑になる。判定ブロックから文を削除して「過去の設計では…」という歴史メモへ格下げする mutation も素通りする。
- **件数一致（`grep -c` == N）は「いくつあるか」しか見ないため、総数を保ったまま帰属を変える mutation に盲目。** 抽出範囲を絞らない件数 pin は、存在を見る pin より強く見えて実は同じ穴を持つ。実測された生存 mutant は 3 つともこの形だった: (a) 2 テンプレに 1 本ずつある行を、一方から削って他方へ複製する（総数 2 のまま。片方のモードで契約が失効する）、(b) 指示節と出力フォーマットの両方に同じ literal があるとき指示節だけを削除する（残り 1 本で条件成立）、(c) 同じ marker が複数箇所にあるとき検出対象の 1 箇所だけ削除する。**N 本あることを数えるなら、その N 本がそれぞれどこにあるかまで固定する** — 区間を切ってから各区間で 1 本ずつ assert する。「テストが green」は「契約が守られている」ではなく「今の実装がテストを通る」でしかない。
- **区間の終端はレベル述語で書き、特定の次節へハードコードしない。** 終端に具体的な見出し名を置くと、その手前に新節が挿入されたとき区間が新節を飲み込んで vacuous に pass する。同レベル以上の見出しで閉じる述語（`^(#{2}|#{3}) ` 等）なら挿入に耐える。あわせて区間の行数レンジを sanity assert する — 件数 0 を期待する assert は区間が空でも真になるため、同区間に件数 1 以上を期待する assert が併存していないと単独で vacuous 化する。
- **section 内の 1 箇所ではなく要素単位で要求する。** `branch=` スコープの pin を section 全体への grep 1 本にしたところ、ルール側のスコープを全部外しても fallback に残った 1 箇所で緑になった。
- **必須文字列はコード行だけに現れる形に狭める。** `push origin --delete` は同じ抽出範囲のコメント（「一方 `git push origin --delete` は tail 解決せず…」）だけで充足され、コマンド本体を消しても素通りした。説明文に登場する語をそのまま必須文字列にすると、その説明文が pin を無効化する。
- **pin は「literal の存在」ではなく「marker 名 ↔ 判定値」の連言で書く。** 存在だけを要求する形は、(a) 判定値を正常系へ反転する mutation、(b) 分岐を `if false` で殺す mutation の両方を素通しする。**条件式そのもの** も pin 対象にする。
- **`grep ... | head -1` は「1 行に収まっている」ことを暗黙の前提にする。** 対象を複数行へ分割するだけで assertion を回避でき、否定表現を 2 行目へ移すと false-fail 方向にも壊れる。宣言の単位（bullet / セクション）を awk で抽出してから検査する。
- **`grep -q` をパイプの終端に置かない。** `printf '%s' "$x" | grep -qF "$lit"` は grep の早期終了で printf が SIGPIPE を受け、pipefail 下でパイプライン status が 141 になり否定条件が誤成立する。here-string（`grep -qF "$lit" <<<"$x"`）なら起きない。
- **`grep` のパターンで `[CONTEXT]` を literal 扱いするには `\[` `\]` エスケープが必須。** BRE ではブラケット式に解釈され、別物を探す。pin を追加したつもりで無効化される典型。パターンが `-` で始まる場合（`--- push stderr begin ---`）は `-e` で明示する。
- **「性質 P を assert する」alternation は各 disjunct が単体で P を含意するか確認する。** 「否定表現の存在」を要求する grep に `抑止できるのは` という断片を混ぜていた。単体では肯定にも否定にもなり得ず、禁止された過大主張を書いたままでもマッチする。

### 抽出アンカーの規律

- **awk による section 抽出は両端を検査する。** 開始アンカー消失は空抽出 → 全 grep 失敗で loud fail するが、閉じアンカー消失は EOF まで走って section スコープが実質無効化される（over-capture）ため silent に緩む。`END{exit !found}` で閉じアンカー到達を rc に反映させ、非空チェックと両方入れる。
- **閉じアンカーの一意性を確認する。** `^esac$` が同一ファイルに 5 箇所あると、ガードの esac を 1 文字変えるだけで抽出が別ブロックまで膨張し、markdown 散文が bash として実行されたのにテストは緑だった。一意にできないなら「抽出結果が構造的にありえないもの（fence terminator 等）を含まないこと」を別途 assert する。fence 終端をアンカーにし、抽出結果へ `bash -n` を掛けて構文完結性を検査するのが頑健。

### mutation testing の規律

- **mutation テストは検証対象の artifact から mutant を導出する。** ハードコードした「修正前の式」を実行しても、それは外部ツールの仕様を再確認しているだけで、現在の実装が load-bearing であることの証明にならない。artifact を `sed` で変異させて初めて mutation test になる。あわせて「変異が実際に入ったこと」を先に検査しないと、抽出側の文字列が変わったとき誤帰属の FAIL になる。
- **mutation が期待どおり赤くならないとき、まず疑うのは fix ではなく mutation。** 検証したい状態が本当に作れているか（「判定ブロック内 0 件・ファイル全体 1 件」を数える等）を先に確認する。
- **reviewer が「緑のまま通過した mutation」を報告したら、その全種を再現して赤化を確認する。** 自分が選んだ mutation セットは自分の盲点を反映するため、検出力の測定には使えない。
- **新しいガードを追加すると既存の mutation 対象が非 load-bearing に後退する。** mutation testing は「今どの検証が結論を支えているか」に合わせて retarget しないと vacuous な緑を出す。
- **実行時 TC は静的 pin より強い。** `if false` 化・de-wrap のような「literal を残したまま経路を殺す」mutation は静的 pin では捕捉できず、実際に経路を通す TC だけが落ちる。静的検査と runtime assertion の二重化は、それぞれ独立に mutation で赤くなることを実測して初めて二重化と言える。
- **mutation は隔離 worktree（`git worktree add --detach`）で行い、親ツリーの working tree を一切触らない。** 検証後に `git worktree remove --force` で回収する。

### 検出器そのものの検証

- **negative assertion には positive control をセットで足す。** 既知違反の probe を **本スキャンと同じ関数** に通し、発火することを確認してから本スキャンへ進む。関数へ括り出すのが要点で、probe と本スキャンで別のコマンドを書くと「control 自身が腐る」経路が残る。
- **バイトレベル検査は入力デコードを明示的に殺す。** `perl -ne '/[\x{80}-\x{FF}]/'` は `PERLIO=:utf8` / `PERL_UNICODE=SD` で見逃す。`LC_ALL=C awk '/[^ -~]/'` は同 env でも検出する。既にファイル内で使っているツールで書ければ可用性プローブも不要になり、「ツール不在時に rc=127 が違反あり分岐へ落ちて存在しない欠陥を名指しする」誤帰属も同時に消える。`grep -P` の `[\x80-\xFF]` はロケール依存で取りこぼす。
- **コメントに書いた rationale 自体が検証対象。** 「救済文言を要求すれば `x` 判定には存在し得ないので堅い」と書いた主張は、文言を残したまま判定値だけ反転する mutation で反証された。誤った rationale は次サイクルの reviewer の探索をそこで止める。
- **プラットフォーム固有の欠陥は static guard で pin する。** `$var。` の多バイト取り込みは glibc では再現せず、Linux leg では behavioral TC が vacuous になる。「壊れることを示すテスト」ではなく「その形を書けなくするテスト」で守る。ただし **既存の invariant テストがあっても走査範囲の外なら守られない** — TC-8b-h は `*.sh` のみを走査し SKILL.md の bash fence は blind spot だった。
- **テンポラリファイルは既存の trap 対象ディレクトリに寄せる。** 新しい `mktemp` を rc 未検査で使うと、失敗時に空パスが検出器へ渡り「検出器が既知の違反を報告しません」という真因と異なる帰属で落ちる。
- **sandbox fixture は同ディレクトリの兄弟テストの setup を読んで揃える。** `commit.gpgsign false` の欠落は署名強制環境でのみ発現し、前段 TC が偶然 PASS するため真因が見えにくい。

### marker 名の存在ではなく指示語を pin する

散文が実装本体である skill では、pin 対象は **marker 名ではなく指示語そのもの**である。`assert_grep` で `CLEANUP_DELEGATED=1` の存在だけを見るテストは、ガードの削除は検出するが「**実行しない**」→「通常どおり実行する」という**指示の反転**を検出しない（PR #2150 の mutation 実測: 4 サイトの指示を反転させても全 assert green）。

pin は指示の効力を担う語まで伸ばす:

```bash
# 弱い: marker 名の存在しか見ていない（指示反転が素通し）
assert_grep "$SKILL" 'CLEANUP_DELEGATED=1'

# 強い: 指示語まで含める（反転すると fail する）
assert_grep "$SKILL" 'CLEANUP_DELEGATED=1` を emit している場合、本ステップの bash を\*\*実行しない\*\*'
```

判定の目安は「この文字列が残ったまま、指示の意味を逆にできるか」。できるなら pin が短すぎる。

## 関連ページ

- [否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す](./negative-assertion-positive-control.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [テストヘルパーの awk flip-flop レンジは start pattern をコード行に一意なプレフィックスでアンカーする](./awk-flip-flop-range-start-pattern-anchoring.md)

## ソース

- [PR #2022 fix results (cycle 11)](../../raw/fixes/20260726T062935Z-pr-2022.md)
- [PR #2022 fix results (cycle 6)](../../raw/fixes/20260726T025351Z-pr-2022.md)
- [PR #2022 fix results (cycle 4)](../../raw/fixes/20260726T014448Z-pr-2022.md)
- [PR #2150 review results (cycle 1: marker 名 pin では指示反転が素通し)](../../raw/reviews/20260808T063447Z-pr-2150.md)
- [PR #2150 fix results (cycle 1: pin を指示語まで伸ばす)](../../raw/fixes/20260808T064117Z-pr-2150.md)
