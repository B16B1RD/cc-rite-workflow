# Bash 4+ Compatibility Guard (canonical)

`/rite:pr:fix` / `/rite:pr:review` / その他 `mapfile -t` を使用する command file が共有する bash 4+ 互換性チェックの canonical 実装。

## 背景

複数の bash block で `mapfile -t < <(...)` builtin を使用するため、bash 4.0+ が必須。`mapfile` builtin は **bash 4.0 で導入** されたため、bash 3.2 (macOS デフォルト) では動作せず、`mapfile: command not found` で silent fail し後段で `latest_file=""` 経路に流れる silent regression のリスクがある。本ガードにより環境不整合を fail-fast で検出する。

## Canonical 実装

各 command file はエントリポイントの最初の Bash tool 呼び出しで以下のテンプレートを実行する。`{CONTEXT_FLAG}` と `{OUTPUT_PATTERN}` は呼び出し側 command の規約に合わせて置換すること:

```bash
# bash 4+ 互換性チェック (mapfile builtin の存在で判定)
if ! command -v mapfile >/dev/null 2>&1; then
  bash_version=$("$BASH" --version 2>/dev/null | head -1)
  echo "ERROR: bash 4.0+ が必要ですが、現在のシェルは mapfile builtin を持っていません" >&2
  echo "  検出: $bash_version" >&2
  echo "  対処: macOS では brew install bash で 4+ をインストールし、PATH の先頭に追加してください" >&2
  echo "[CONTEXT] {CONTEXT_FLAG}=1; reason=bash_version_incompatible" >&2
  echo "{OUTPUT_PATTERN}"
  exit 1
fi
```

## 呼び出し側の置換規約

| Command | `{CONTEXT_FLAG}` | `{OUTPUT_PATTERN}` |
|---------|------------------|---------------------|
| `/rite:pr:fix` | `FIX_FALLBACK_FAILED` | `[fix:error]` |
| `/rite:pr:review` | `REVIEW_ARG_PARSE_FAILED` | `[review:error]` |

新しい command を追加する際は本表に行を追加すること。`reason=bash_version_incompatible` は全 command で共通。

## Source 検証

- [Bash Manual: Builtins](https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins) — `mapfile` builtin は bash 4.0 で導入
- [Bash 4.0 NEWS](https://tiswww.case.edu/php/chet/bash/NEWS) — 4.0 リリースノート (mapfile / readarray が builtin として追加)
