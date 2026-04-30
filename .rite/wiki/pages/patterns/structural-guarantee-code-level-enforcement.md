---
title: "structural ownership guarantee は code-level defense-in-depth で enforce する"
domain: "patterns"
created: "2026-04-30T08:03:08Z"
updated: "2026-04-30T08:03:08Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260430T074655Z-pr-750-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T075231Z-pr-750-cycle-2.md"
tags: [defense-in-depth, api-contract, structural-invariant, fast-path]
confidence: high
---

# structural ownership guarantee は code-level defense-in-depth で enforce する

## 概要

「per-session file 構造でファイル名 = session_id にしたから ownership は構造的に保証される」のような structural invariant は、現 caller が必ず resolver 経由で path を組み立てる前提でのみ成り立つ。将来 resolver を経由しない caller が追加されると invariant は silent に崩壊する。fast-path に「filename SID と hook SID の比較」のような明示的 defense-in-depth check を追加することで、API contract を code-level で enforce し、caller 拡張時の silent break を構造的に防ぐ。

## 詳細

### Anti-pattern: 「構造で保証」を信じる API

```bash
# 危険: 「ファイル存在 = 自 session」を構造的保証として扱う
check_session_ownership() {
  local state_file_path="$1"
  if is_per_session_state_file "$state_file_path"; then
    # schema-2 fast-path: ファイル名から session_id が抽出できる構造なので
    # 「path がここに渡って来ている時点で自 session」と判定して 'own' を返す
    echo "own"
    return 0
  fi
  # ... legacy schema-1 経路
}
```

問題: `state_file_path` が「resolver 経由で組み立てられた自 session の path」である invariant は、現 caller (5 site) が全員 `_resolve-flow-state-path.sh` を経由する前提に依存している。将来「他 session の path を直接渡す caller」が追加されると、structural invariant が崩れて silent ownership bypass が起きる。

### Canonical: code-level defense-in-depth

```bash
check_session_ownership() {
  local state_file_path="$1"
  if is_per_session_state_file "$state_file_path"; then
    # Defense-in-depth: hook_sid が非空のとき filename SID と一致を verify する
    local hook_sid="${CLAUDE_SESSION_ID:-}"
    if [ -n "$hook_sid" ]; then
      local filename_sid=$(basename "$state_file_path" .flow-state)
      if [ "$hook_sid" != "$filename_sid" ]; then
        echo "other"  # foreign per-session file
        return 0
      fi
    fi
    echo "own"
    return 0
  fi
  # ... legacy schema-1 経路
}
```

設計ポイント:

1. **structural invariant + code-level enforcement の二重防御**: ファイル構造で ownership を保証しつつ、fast-path 内で明示的 verification を行う。invariant が崩れる将来の caller 追加を構造的に防ぐ
2. **空 hook_sid は backward-compat 経路として allow**: テスト fixture / 過去 caller が hook_sid を渡さない場合の互換性を保つ。`'own'` 判定で fail-secure (許容側) に倒す
3. **helper-level test で 1 TC 複数経路を pin**: AC-4 (mismatched SID hook no-op) を helper-level の `check_session_ownership` で 3 ケース (matching SID で 'own' / foreign per-session で 'other' / 空 hook SID で 'own' backward-compat) に分割すれば、hook integration test に踏み込まずに contract を保護できる

### 上位 Pattern との関係

- `prose-design-without-backing-implementation.md` の派生形: 「散文で structural guarantee を宣言 → 実装で enforce しない」と同じ構造的問題。本 pattern は「structural guarantee + 実装側 enforcement の二重防御」を canonical とする
- `bash-lib-helper-contract-rigour.md` の API contract enforcement と同じ rigor: docstring で宣言した invariant は実装側で破ってはいけない (本 pattern は逆方向 = 実装側で invariant を補強する)

### 検出 / レビュー観点

新規 / refactor で fast-path / structural shortcut を導入する PR では以下を verify:

- [ ] structural invariant が依存する caller 前提を明示しているか (例: 「全 caller が resolver 経由で path を組み立てる」)
- [ ] 将来 invariant を破る caller が追加された場合の silent break を防ぐ defense-in-depth check があるか
- [ ] defense-in-depth check は backward-compat 経路 (空 SID / 旧 caller) を fail-secure (許容側) に倒しているか
- [ ] helper-level test で defense-in-depth check の 3 ケース (期待 ok / 期待 reject / backward-compat) が pin されているか

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [Bash lib helper の contract は実装と同じ rigour で保証する](../patterns/bash-lib-helper-contract-rigour.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #750 fix cycle 1 results](../../raw/fixes/20260430T074655Z-pr-750-cycle-1.md)
- [PR #750 review results (cycle 2 mergeable)](../../raw/reviews/20260430T075231Z-pr-750-cycle-2.md)
