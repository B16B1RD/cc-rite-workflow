---
type: "patterns"
title: "バグ修正PRが新設したエラーパス自身にも回帰テストを追加する"
domain: "patterns"
promote: rite-plugin
description: "バグ修正の過程で新たに追加したエラーハンドリング分岐（fallback / WARNING 等）は、修正対象のバグと同じ厳格さで回帰テストを追加する。既存テストが全て成功前提を seed していると新分岐は一度も通過されないため、revert test で非空虚性を確認する。"
created: "2026-07-09T06:56:16+00:00"
updated: "2026-07-09T06:56:16+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260709T061246Z-pr-1808-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260709T061632Z-pr-1808-cycle2.md"
tags: [test-coverage, regression-test, revert-test, non-vacuous, self-referential]
confidence: high
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

## 関連ページ

- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](./silent-fallback-observability-via-debug-log.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)

## ソース

- [PR #1808 review results (cycle 2)](../../raw/reviews/20260709T061246Z-pr-1808-cycle2.md)
- [PR #1808 fix results (cycle 2)](../../raw/fixes/20260709T061632Z-pr-1808-cycle2.md)
