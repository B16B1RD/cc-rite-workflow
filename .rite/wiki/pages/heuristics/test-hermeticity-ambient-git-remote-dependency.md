---
type: "heuristics"
title: "owner/repo 解決テストは ambient な git remote 状態に依存させない (non-hermetic test)"
domain: "heuristics"
description: "owner/repo 解決ロジック (`git-remote.sh resolve-owner-repo` / `gh repo view` 等) のテストケースが、テスト実行環境の**実際の** git remote 設定 (origin の存在・URL 形式・SSH host alias 定義の有無) に依存して結果が決まる構造になっていると、CI とローカル、あるいは異なる開発者の環境間で remote 構成が異なるだけでテストの pass/fail が変わる non-hermetic (非決定的) なテストになる。"
created: "2026-07-20T10:36:25+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260720T013625Z-pr-1921.md"
tags: ["test", "hermeticity", "git-remote", "ambient-dependency", "ci"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-20T10:36:25+09:00" }
---

# owner/repo 解決テストは ambient な git remote 状態に依存させない (non-hermetic test)

## 概要

owner/repo 解決ロジック (`git-remote.sh resolve-owner-repo` / `gh repo view` 等) のテストケースが、テスト実行環境の**実際の** git remote 設定 (origin の存在・URL 形式・SSH host alias 定義の有無) に依存して結果が決まる構造になっていると、CI とローカル、あるいは異なる開発者の環境間で remote 構成が異なるだけでテストの pass/fail が変わる non-hermetic (非決定的) なテストになる。

## 詳細

### 症状

`issue-body-safe-update.sh` の owner/repo 解決を SSH host alias 対応にした PR の review で、TC-15b / TC-30b の 2 テストケースが ambient な origin remote (テスト実行時にその環境に実際に設定されている remote の値) に依存していることを **3 reviewer が独立に指摘**した。テストが「今この環境の origin が指す値」を暗黙の前提にしていたため、origin 未設定環境や別 URL 形式 (HTTPS vs SSH host alias) の環境ではテストの意味が変わる、あるいは failure しうる構造だった。

```bash
# 反面教材 — ambient な origin remote に暗黙依存
test_owner_repo_resolution() {
  result=$(resolve-owner-repo)
  # このテストの妥当性は「今この環境の origin が期待通りの形式である」ことに暗黙依存
  assert_eq "$result" "$(git remote get-url origin)"  # 期待値自体が ambient state
}
```

### なぜ問題か

- **CI と手元で結果が変わる**: CI runner の checkout 方式 (HTTPS clone) とローカルの SSH host alias 設定は一般に異なる。テストが ambient remote に依存すると、CI では通ってもローカルでは別の分岐を通る、あるいは逆に手元でしか成立しない前提を CI が检出できない。
- **fixture 分離ができない**: SSH host alias 対応 (本 PR の主目的) のような分岐ロジックは、alias 有り / alias 無し / 両方失敗、の複数状態を個別に検証する必要があるが、ambient remote 1 状態にしか依存していると他の分岐が未カバーになりやすい (適用 27 [[mutation-testing-test-fidelity]] の tier 別 pin 不足と同系統の症状)。

### 対策

1. **テスト内で remote を明示的にセットアップする**: `git remote add` / `git remote set-url` でテスト用の一時 remote (SSH host alias 形式・HTTPS 形式など各分岐を模した値) を fixture として用意し、実行環境の実際の origin 設定から独立させる。
2. **helper をモック/スタブで隔離する**: `git-remote.sh` や `gh` コマンドをテスト用の fake 実装 (PATH-shim 等) に置き換え、環境依存の実 remote 解決を経由させない。
3. **hermetic 性を明示的にレビュー観点に含める**: owner/repo 解決・リモート URL パースのようなテストを追加する PR では、「テストが ambient な環境設定に依存していないか」を reviewer チェックリストに加える。

## 関連ページ

- [Test の env gate 配置と CI workflow 起動コマンドの claim alignment を empirical 検証する](./test-env-gate-ci-alignment.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #1921 review results (cycle 2) — TC-15b/TC-30b が ambient origin remote に依存する非 hermetic テストであることを 3 reviewer が独立指摘](../../raw/reviews/20260720T013625Z-pr-1921.md)
