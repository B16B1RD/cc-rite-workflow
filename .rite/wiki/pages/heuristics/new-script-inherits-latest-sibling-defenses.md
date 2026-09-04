---
type: "heuristics"
title: "テンプレート流用の新規スクリプトは最新兄弟の防御を継承する"
domain: "heuristics"
promote: rite-plugin
description: "既存スクリプト（bang-backtick-check.sh）をテンプレートに新規 check スクリプトを作ったところ、兄弟スクリプト群が**後から**獲得した防御 — `wc -l` の空白正規化（BSD/macOS パディング対応、sentinel-contract-check.sh が獲得済み）、usage の exit code 契約と実装の一致（同）— を継承し漏らし、cycle 1 レビューで MEDIUM×2 の指摘になった。"
created: "2026-07-19T15:00:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260719T022247Z-pr-1909.md"
  - type: "fixes"
    resource: "raw/fixes/20260719T022630Z-pr-1909.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T233057Z-pr-2120.md"
  - type: "fixes"
    resource: "raw/fixes/20260807T134638Z-pr-2137.md"
  - type: "fixes"
    resource: "raw/fixes/20260812T133631Z-pr-2278.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-12T18:34:40Z" }
---

# テンプレート流用の新規スクリプトは最新兄弟の防御を継承する

## 概要

既存スクリプト（bang-backtick-check.sh）をテンプレートに新規 check スクリプトを作ったところ、兄弟スクリプト群が**後から**獲得した防御 — `wc -l` の空白正規化（BSD/macOS パディング対応、sentinel-contract-check.sh が獲得済み）、usage の exit code 契約と実装の一致（同）— を継承し漏らし、cycle 1 レビューで MEDIUM×2 の指摘になった。テンプレート流用時は「最も古い兄弟」でなく「最も新しい兄弟」を流用元に選び、family 共通の防御の有無を差分確認する。

## 詳細

起点事例で tmp-hardcode-check.sh を新設した際の実測:

- **wc -l 正規化の欠落**: `total=$(wc -l < file)` は BSD/macOS で先頭空白パディング付きになり、lint 側の count-line regex `findings: (\d+)` と不一致になる。兄弟の sentinel-contract-check.sh は `| tr -d '[:space:]'` で正規化済み、number-reference-check.sh は算術カウンタで回避済み — 新規スクリプトだけが罠を踏んだ。
- **usage 契約と実装の矛盾ごと踏襲**: テンプレート元の bang-backtick-check.sh は「2 = Invocation error (bad args, missing files)」と宣言しながら missing file を WARNING + exit 0 で扱う矛盾を持っており、新規スクリプトはこの矛盾ごと複製した。修正済みの先例（sentinel-contract-check.sh の引数値ガード）が同ディレクトリに存在したのに参照しなかった。

**付随ヒューリスティック — sweep 検証は表現形式を跨ぐ**: sweep 系 PR の取り残しは「grep パターンの検出範囲外の表現形式」（markdown 表セル・説明 prose 等）に集中する。完了検証は変換パターン限定の grep だけでなく、対象文字列そのもの（例: `rite-backups`）でも掃くと表セルや prose の取り残しを拾える。実例: bash-defensive-patterns.md の code example は更新されたが直下の表セルが `/tmp/rite-backups/` のまま残り、機械 check（P2 regex は代入・redirect・-file 形式のみ）では検出されなかった。

### 参照先が「自分自身の系譜」の場合（cycle 1 実測）

流用元が別ファイルの兄弟とは限らない。**数コミット前の自分自身の同種経路**が参照先になる場合があり、こちらの方が見落としやすい。

その事例は `.rite/logs/.gitignore` を生成する 3 番目の書き手を追加したが、guard として 2 コミット前に同一の共有ディレクトリ保護で `[ ! -s ]`（中身検査）+ WARNING + `[CONTEXT]` marker へ明示的に強化された形ではなく、`session-start.sh` の**強化前の形**（`[ -f ]` + `2>/dev/null || true`）を採用していた。

決定的なのは、**実装の形とその根拠の両方が同時に stale になっていた**点である。新規コメントが根拠として挙げた「`/rite:setup` の生成 `.gitignore` が covers するのは 2 エントリ」という記述も、同じ PR で 3 エントリへ増えていた。同一 Issue が同一 PR 内で「実装の形」と「その根拠として引用した事実」の両方を陳腐化させた。

**手順として確定させる**:

1. `git grep` でパターンの全サイトを列挙する
2. 各サイトの最終更新を `git log -S` で確認する
3. 最新版を転記元に選ぶ
4. 転記したコメントが引用している**外部の事実**も、同じ列挙の中で再確認する

修正時に 4 サイトを並べたところ **多数派（2/4）は既に新形式で、転記元だけが少数派**だった。列挙していれば選択を誤らなかった。「直近に読んだ先例」を無自覚に選ぶと、強化の履歴を巻き戻す方向へ転記する。

なお、同じ idiom のコピーが 4 つに分岐している状態そのものが別の問題である（[同一箇所への指摘が N cycle 連続したら、その箇所が何番目のコピーかを数える](./idiom-copy-count-decides-patch-vs-extract.md)）。

### 防御を強制する静的検査が「ファイル名の明示列挙」型なら、新規ファイルはその死角に入る（別の PR での実測）

継承漏れは「先例を参照しなかった」だけが原因ではない。**先例を強制するはずの静的検査そのものが、新規ファイルを構造的に見ない形をしている**ことがある。

`hooks/scripts/lib/context-marker.sh` を新設した際、引数パーサが `shift 2` を使い、値なしフラグが末尾に来ると無限ループした（実測 rc=124）。同ディレクトリの `worktree-git.sh` は同じ失敗を名指しするコメント付きで `shift 2 || shift` を、`review-save-json-verify.sh` 等 10 本は `shift; shift` を既に採用しており、さらに専用テスト `hooks/tests/shift2-loop-hardening.test.sh` の TC-7 が後者を**静的に強制**していた。にもかかわらず新規ファイルだけが後退した理由は単純で、**TC-7 の検査対象がファイル名の明示列挙で、`lib/` 配下を 1 本も含んでいなかった**。新規ファイルは「守られている」と見える family に属しながら、実際にはどのガードにも触れていない。

この形は、[スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md) と同じ「検証側が持つ死角」の一種だが、死角の作り方が違う — あちらはパターンの表現形式、こちらは**対象集合の列挙方式**である。

**手順に足す**:

5. 新規ファイルを既存ディレクトリへ足したら、そのディレクトリを対象にする hardening test / lint を `grep -rl "$(basename <sibling>)" hooks/tests/` 等で洗い、**列挙型ならリストへの登録要否を判断する**
6. 列挙型を見つけたら、`lib/*.sh` のような sweep 型へ置換できないかを同時に検討する（登録漏れは列挙型である限り再発する。列挙そのものを置かない方針は [列挙・全称主張を持つ記述は書き直しでは収束しない — 撤去だけが指摘面を消す](../anti-patterns/enumeration-claim-rewrite-never-converges.md) と同旨）

**修正の検出力は変異で実測する**: 同 PR では引数ガード無効化 + `shift 2` 復元の変異で新規 assertion が rc=124 で落ちることを確認した。「テストを足した」だけでは、それが何を守るのか分からない（[アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](./mutation-testing-measures-assertion-strength.md)）。

### 継承対象は防御だけでなく「抽出述語」そのもの（さらに別の PR での実測）

新規スクリプトが継承し漏らすのは防御（空白正規化・exit code 契約）だけではない。**同じ対象を走査する正規表現そのもの**も継承対象になる。

起点事例では、新規 checker が SKILL.md 群から fenced block を抽出する際に行頭 0 桁アンカーの述語を使い、インデントされた fence を取りこぼした。同じファイル群を走査する `bash-heaviness-check.sh` は既にインデント fence を扱っており、**新規 checker だけが後退していた**。

> **規則**: 新しい checker を書く前に、同じ対象を走査する既存 helper を探し、その抽出述語を流用する。流用しないなら、なぜ違う述語が必要かを明示する。同じ対象に対する違う述語は drift の定義そのものであり、どちらが正しいかは走査結果を突き合わせるまで決まらない。

## 関連ページ

- [再発防止 guard スクリプトは docstring の宣言意図と実装 regex を実測で校正する](./guard-script-contract-calibration.md)
- [スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [同一箇所への指摘が N cycle 連続したら、その箇所が何番目のコピーかを数える](./idiom-copy-count-decides-patch-vs-extract.md)

## ソース

- [レビュー結果](../../raw/reviews/20260719T022247Z-pr-1909.md)
- [fix 結果](../../raw/fixes/20260719T022630Z-pr-1909.md)
- [レビュー結果](../../raw/reviews/20260805T233057Z-pr-2120.md)
- [ファイル名列挙型の hardening test が新規 lib を死角に入れる](../../raw/fixes/20260807T134638Z-pr-2137.md)
- [抽出述語を sibling helper と揃えず新規 checker だけが後退した](../../raw/fixes/20260812T133631Z-pr-2278.md)
