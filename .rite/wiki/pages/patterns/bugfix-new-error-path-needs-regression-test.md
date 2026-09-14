---
type: "patterns"
title: "バグ修正PRが新設したエラーパス自身にも回帰テストを追加する"
domain: "patterns"
promote: rite-plugin
description: "バグ修正PRが対象バグの fallback/WARNING 分岐を新規追加すると、その新分岐自体は「修正対象のバグ」ではないという理由で回帰テストの追加が見落とされやすい。"
created: "2026-07-09T06:56:16+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260709T061246Z-pr-1808-cycle2.md"
  - type: "fixes"
    resource: "raw/fixes/20260709T061632Z-pr-1808-cycle2.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T083015Z-pr-2808.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T091626Z-pr-2813.md"
tags: [test-coverage, regression-test, revert-test, non-vacuous, self-referential]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-14T09:23:49Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-09-14T08:45:00Z"
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-09-14T09:23:49Z"
---

# バグ修正PRが新設したエラーパス自身にも回帰テストを追加する

## 概要

バグ修正PRが対象バグの fallback/WARNING 分岐を新規追加すると、その新分岐自体は「修正対象のバグ」ではないという理由で回帰テストの追加が見落とされやすい。既存テストケースが全て「成功する前提条件」を seed していると、新設した失敗分岐は一度もテストで通過されない。revert test（修正を一時的に取り消して新テストが実際に FAIL することを確認する）で非空虚性を検証するのが canonical。

## 詳細

### 問題の構造

`cleanup-work-memory.sh` の resolver 呼び出し失敗を検出できていなかったバグを修正した PR の事例。cycle 1 の fix で `flow-state.sh path` 呼び出しの失敗経路 (else 節、WARNING 出力 + legacy フォールバック) を新規追加したが、その **新規追加した else 節自体の回帰テスト** は cycle 1 では追加されなかった。既存 TC (TC-001/002/003/008) は全て有効な session-id を事前に seed しており、resolver が成功するケースしか通過しない。結果として、新設した else 節の WARNING 文言やフォールバック挙動が壊れても既存テストスイートは 100% パスし続ける。

cycle 2 review で test-reviewer が HIGH として、error-handling-reviewer が (severity は異なるが) 推奨事項として、独立に同一のギャップを指摘した。**重要度の食い違いは指摘の妥当性を減じない** — 複数 reviewer が同一根本原因を別の重要度で報告した場合、いずれか一方でも指摘があれば対応すべきという運用判断で修正した ([Observed Likelihood Gate](../heuristics/observed-likelihood-gate-with-evidence-anchors.md) の cross-validation 原則と対称)。

### Canonical fix

session-id 不在（resolver が失敗する状態）を模した新規 TC を追加し、以下 2 点を assert する:

1. `'flow-state.sh path resolution failed'` の WARNING 文言を grep で pin する
2. legacy `.rite-flow-state` が実際に `active:false` へリセットされること（outcome の直接検証）

```bash
dir_resolver="$TEST_DIR/tc_resolver_fallback"
mkdir -p "$dir_resolver/.rite-work-memory"
echo '{"active":true,"issue_number":77,"phase":"cleanup"}' > "$dir_resolver/.rite-flow-state"
out_resolver="$TEST_DIR/tc_resolver_fallback.out"
( cd "$dir_resolver" && bash "$HOOK" >"$out_resolver" 2>&1 ) || true
resolver_warning_seen=$(grep -c 'flow-state.sh path resolution failed' "$out_resolver" 2>/dev/null || true)
resolver_active=$(jq -r '.active' "$dir_resolver/.rite-flow-state" 2>/dev/null)
if [ "${resolver_warning_seen:-0}" -ge 1 ] && [ "$resolver_active" = "false" ]; then
  pass "TC-resolver-fallback: WARNING emitted and legacy .rite-flow-state reset to active=false"
else
  fail "TC-resolver-fallback: warning_seen=${resolver_warning_seen:-0}, active=$resolver_active"
fi
```

### Revert test による非空虚性確認 (必須)

新設した TC が「テストを追加した」という自己申告だけで実際に意図した回帰を検出できているとは限らない。最初の revert 試行で stderr redirect (`2>"${_fs_err:-/dev/null}"` → `2>/dev/null`) だけを外したところ、else 節の WARNING echo 自体は残っていたため TC-resolver-fallback は依然 PASS した — これはバグ修正前の実装を正しく再現できていなかったことを意味する。**revert は fix の一部分だけでなく、修正前の元の実装形（この場合は WARNING 自体が存在しない 1 行の fallback）へ完全に戻す必要がある**。バグ再現コードへ正しく戻した上で再実行し、TC-resolver-fallback が FAIL することを確認してから修正を復元して PASS を確認する 2 段階検証で、新設テストの識別力 (identification power) を実証した。

### 値の限定を兼ねるフォールバック分岐も入口テストの対象にする

診断の接頭辞ラベルを引数で受け取り、未知の値なら内部エラーの WARNING を出して既定ラベルに倒す `case` 分岐を足した変更で、その分岐に入るテストが 1 本も無かった。WARNING の echo を消す変異も、既定ラベルへの代入を消す変異も、対象スイートを全緑のまま通過した。

- 今ある呼び出しがすべてリテラルで未知の値を渡す経路が無くても、分岐が **後段の sed 置換に任意文字列を流さないための値の限定** を兼ねているなら、削除や弱体化を検出するテストが要る。見張りが無いと、将来の変更で限定が黙って消える
- テストは関数を抜き出して未知の値で呼び、(1) 内部エラーの文言が出る (2) 詳細行が既定ラベルで出る、の 2 点を assert する
- 到達不能に見えるからと分岐を削ると、値の限定という役割まで一緒に消える。削るか残すかは、その分岐が受けていた入力の行き先を確認してから決める

関数を抜き出す方式には、抽出そのものが静かに崩れる穴がある。sed の範囲指定（定義行から行頭の `}` まで）は、閉じ括弧が字下げされるなど定義の形が変わると途中で切れたり末尾まで取り込んだりするが、「抽出結果が空でない」ことしか見ていないとどちらも通ってしまう。

- 抽出結果に形の条件を課してから使う。定義行がちょうど 1 つ、最終行が `}` だけ、検証したい分岐（`case` 行など）を含む、の 3 点を満たさなければテストを fail させる。とくに最終行の条件は、範囲が末尾まで伸びたとき（helper の最終行が `exit 0` 等）に唯一落ちる
- サブシェルで依存ファイルを source して定義を eval したあと、`declare -F` で関数と依存関数の両方が定義されたことを確かめる。source が失敗しても eval は通るため、ここを見ないと後段の assert がまとめて的外れな理由で落ちる
- eval する中身は同一リポジトリの helper であり、テストが helper 全体を既に実行しているなら新しい信頼境界は生まれない。サブシェルに閉じれば定義や変数もテスト本体へ漏れない

## 関連ページ

- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](./silent-fallback-observability-via-debug-log.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)

## ソース

- [レビュー結果](../../raw/reviews/20260709T061246Z-pr-1808-cycle2.md)
- [fix 結果](../../raw/fixes/20260709T061632Z-pr-1808-cycle2.md)
- [未知ラベルのフォールバック分岐に入るテストが無かった](../../raw/reviews/20260914T083015Z-pr-2808.md)
- [関数を抜き出して到達不能な分岐を固めたテストのレビュー結果](../../raw/reviews/20260914T091626Z-pr-2813.md)
