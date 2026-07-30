---
type: "anti-patterns"
title: "`cmd=$(...) || cmd=\"\"` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする"
domain: "anti-patterns"
description: "command substitution は subprocess の exit code に関わらず stdout を正しく捕捉するため、後続で case 文による catch-all 処理をしている限り `|| var=\"\"` フォールバックは不要かつ有害（診断情報の損失）。"
created: "2026-07-13T14:30:00+09:00"
updated: "2026-07-13T21:55:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260713T043138Z-pr-1847.md"
  - type: "fixes"
    ref: "raw/fixes/20260713T043947Z-pr-1847.md"
  - type: "reviews"
    ref: "raw/reviews/20260713T123348Z-pr-1851.md"
tags: ["bash", "command-substitution", "error-handling", "diagnostics", "sentinel"]
confidence: high
---

# `cmd=$(...) || cmd=""` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする

## 概要

`status_json=$(bash script.sh args) || status_json=""` という一見安全な defensive fallback は、`script.sh` が非ゼロ終了したときに **既に stdout へ出力済みの診断 JSON（失敗理由を含む）を空文字列で上書き・破棄する**。command substitution `$(...)` は subprocess の exit code とは独立に stdout を正しくキャプチャするため、後続処理が `case`/`jq` で catch-all のフォールバック処理をしている限り、この `|| var=""` は不要かつ有害（診断情報の損失）である。

## 詳細

### Anti-pattern

```bash
# ❌ NG: script が非ゼロ終了すると、既に出力済みの失敗理由入り JSON を握りつぶす
status_json=$(bash projects-status-update.sh "$args") || status_json=""
status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"')
# script が exit 1 しても stdout に {"result":"failed","warnings":["API rate limit"]} を
# 出力していたなら、この warnings 情報は fallback で握りつぶされ人間に一切見えなくなる
```

`bash script.sh` が exit 1 で終了しても、command substitution `$(...)` 自体は script が既に書き出した stdout を正しく変数へ代入する。しかし `|| status_json=""` の右辺（`$(...)` 全体が非ゼロ終了で失敗と判定された場合の fallback）が発火すると、その捕捉済みの内容を空文字列で **上書き** してしまう。

### Canonical pattern

```bash
# ✅ OK: fallback を付けず、非ゼロ終了時も stdout の内容をそのまま使う
status_json=$(bash projects-status-update.sh "$args")
status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null)
status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
case "$status_result" in
  updated)
    echo "Projects Status を更新しました" ;;
  skipped_not_in_project)
    echo "警告: Project に登録されていません" >&2 ;;
  failed|*)
    # $status_json が空文字列でも jq が "failed" にフォールバックするため、
    # スクリプトの stdout が完全に空だった異常系でも catch-all で安全に処理できる
    [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  /' >&2
    echo "警告: 更新に失敗しました" >&2 ;;
esac
```

`jq -r '.result // "failed"'` 自体が空文字列 / 不正 JSON に対して安全にフォールバックするため、`|| status_json=""` を明示的に書かなくても catch-all (`failed|*)`) が異常系を吸収する。**fallback を消すことで診断情報がむしろ保存される**、という直感に反する結論になる。

### いつ `|| var=""` が正当化されるか

以下のいずれにも該当**しない**場合のみ、この fallback は純粋な劣化（診断情報の損失）である:

- 後続処理が JSON パース失敗時にクラッシュする（`jq` の代わりに素朴な文字列処理をしている等）
- 変数の中身を **表示せず** 単に真偽判定にのみ使う（この場合でも診断ログとして捨てるのは推奨しない）

この 2 条件のどちらも満たさない通常の「JSON を jq でパースし catch-all で処理する」設計では、fallback は診断情報を握りつぶすだけの有害コードである。

### 残存 site の一掃と除去正当性の検証パターン

起点事例が 2 箇所を修正した後、同パターンは skill markdown 内に 4 箇所残存していた (ready skeleton / issue-close Phase 4.6.3 / archive-procedures 本文 + skeleton)。後続 PR で全 call site (6 箇所) が no-fallback に統一され、各 site に「付けない」根拠コメントが置かれた。レビューで確立された検証パターン:

- **除去の正当性は被委譲 script 側の契約で裏取りする**: 「fallback を消して安全」の根拠は diff 内では完結しない。被委譲 script (projects-status-update.sh) が「全失敗経路で stdout に失敗理由入り JSON を emit してから exit する」契約を Read で実確認して初めて、非ゼロ終了 = 診断 JSON あり、が保証される。
- **fallback が下流の check を殺していた実害の特定**: issue-close の site では、fallback が「JSON emit + exit 1」経路の JSON を破棄した結果、後続の `-z "$status_json"` check（JSON-emit 前死亡の補足用）が誤発火し、かつ stderr は空のため診断が完全喪失していた。除去により `-z` check は本来の「emit 前死亡」ケースのみに正しく限定される — fallback 除去が周辺の error handling をむしろ修復する例。
- **誤帰属コメントも同時に修正する**: 旧コメントは「fallback が silent fall-through を防ぐ」と防御機構に誤帰属していた。実際に防ぐのは `jq '.result // "failed"'` と `failed|*)` catch-all であり、コメントの誤った安心感は将来の再複製源になるため文言ごと置換する。

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](../patterns/exit-code-semantic-preservation.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [PR #1847 review (rite workflow 全体で繰り返される `|| status_json=""` パターンの系統的検出)](../../raw/reviews/20260713T043138Z-pr-1847.md)
- [PR #1847 fix (open.md / cleanup.md の2箇所を修正、command substitution の exit-code非依存挙動を根拠に説明)](../../raw/fixes/20260713T043947Z-pr-1847.md)
- [PR #1851 review (残存 4 箇所の一掃 — 被委譲 script 契約の実確認による除去正当性検証、issue-close の -z check 誤発火の実害特定)](../../raw/reviews/20260713T123348Z-pr-1851.md)
