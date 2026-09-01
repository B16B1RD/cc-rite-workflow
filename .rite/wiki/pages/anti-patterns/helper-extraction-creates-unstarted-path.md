---
type: "anti-patterns"
title: "インライン処理の helper 抽出は「helper が起動しない」経路を新設し、marker 不在＝成功の消費規則を破る"
domain: "anti-patterns"
description: "インライン bash を helper へ切り出すと、抽出前には存在しなかった「呼び出しに到達したが helper が走らなかった」経路（rc=127 の欠落・rc=126 の非可読・usage error・path placeholder の未解決置換）が新たに生まれる。呼び出し側が rc を捨てると marker が 1 本も出ず、消費側が marker 不在を成功と読む設計なら未実行が完了として報告される。"
created: "2026-09-01T20:25:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-01T20:25:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T053153Z-pr-2498.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T055639Z-pr-2498.md"
tags: []
confidence: high
---

# インライン処理の helper 抽出は「helper が起動しない」経路を新設し、marker 不在＝成功の消費規則を破る

## 概要

インライン bash を helper へ切り出すと、抽出前には存在しなかった「呼び出しに到達したが helper が走らなかった」経路（rc=127 の欠落・rc=126 の非可読・usage error・path placeholder の未解決置換）が新たに生まれる。呼び出し側が rc を捨てると marker が 1 本も出ず、消費側が marker 不在を成功と読む設計なら未実行が完了として報告される。

## 詳細

抽出は「同じコードが別のファイルに移るだけ」に見えるが、実際にはプロセス境界を 1 本新設する操作である。境界の向こう側が走らない経路は抽出前には存在しない:

- helper ファイルが配布物から欠落している（rc=127）
- 実行権限がない・読めない（rc=126）
- helper 自身の構文エラー（rc=2）
- 呼び出し側の path placeholder が未解決のまま渡っている

インライン時代はこれらのどれも起こらず、処理は必ず走るか、走って失敗するかのどちらかだった。だから消費側は「失敗 marker が無い＝成功」と読む設計を安全に採れていた。抽出はこの前提を無効化する。

**対処**: 新設した境界の呼び出し側で rc を捕捉し、非 0 を marker へ変換する。

```bash
_rc=0
bash "$SCRIPT_DIR/helper.sh" --arg "$v" || _rc=$?
if [ "$_rc" -ne 0 ]; then
  echo "WARNING: helper が rc=${_rc} で失敗しました。<処理内容> は未処理のまま残っています" >&2
  echo "[CONTEXT] STEP_PARTIAL_FAILURE=1; reason=helper_failed; rc=${_rc}" >&2
fi
```

**抽出元に手本がある**: 抽出対象のインラインコードが、さらに内側の helper を呼んでいて、そこに既に rc → marker 変換のガードを持っていることが多い。その場合、新設した外側の境界へ同じガードを持ち上げるのが最小修正になる。PR #2498 では 3 名の reviewer が独立にこの欠落を検出しており、しかも抽出元には内側 helper 用の同型ガードが既に存在していた（＝「知らなかった」ではなく「自分が作った境界を境界として認識しなかった」）。

**診断の原因候補は呼び先の実態を測ってから書く**: 「原因候補: helper 欠落 (rc=127) / 引数不正 (rc=2)」のような案内文をそのまま sibling からコピーすると、呼び先が実際にはその終了コードを返さない場合に誤った切り分けを配布することになる。PR #2498 の一例では、呼び先が `exit` 文を 1 つも持たず未知オプションを握り潰して rc=0 を返すため rc=2 は helper 自身の構文エラーでしか出ず、さらに呼び出し側が全オプションを値付きでハードコードしているため引数エラー自体が到達不能だった。この call site から到達可能な原因だけを列挙する。

**fail-loud の追加は消費規則とセットで設計する**: 抽出のついでに helper へ引数の必須検証（usage error）を足すと、抽出前は正常に処理していた入力（呼び出し側が公式にサポートする状態、例: Issue 番号が未識別で空を渡す経路）が marker なしで落ちる。fail-loud それ自体は正しい方向だが、呼び出し側の「その入力は正常系」という契約と衝突すれば挙動退行になる。検証を足すなら、その入力が正常系かどうかを呼び出し側の契約で先に確定させる。

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](../patterns/exit-code-semantic-preservation.md)
- [全域で成功する resolver への委譲が既存 fail-fast ガードを silent success 化する](./total-resolver-delegation-defeats-fail-fast-gate.md)
- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](./bash-if-bang-rc-capture.md)

## ソース

- [PR #2498 review results](../../raw/reviews/20260901T053153Z-pr-2498.md)
- [PR #2498 fix results](../../raw/fixes/20260901T055639Z-pr-2498.md)
