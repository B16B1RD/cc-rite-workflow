---
title: "bash code block 終端は固定 +N 行 window ではなく awk state machine で動的追跡する"
domain: "patterns"
created: "2026-05-08T17:20:17+00:00"
updated: "2026-05-08T17:20:17+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260508T172017Z-pr-906.md"
  - type: "reviews"
    ref: "raw/reviews/20260508T171533Z-pr-906.md"
tags: ["awk", "bash", "state-machine", "test-design", "markdown-parsing", "robustness"]
confidence: high
---

# bash code block 終端は固定 +N 行 window ではなく awk state machine で動的追跡する

## 評価レビュアー

「次に取った行数 +7 まで読む」のような固定 window でツールを書くと、対象行が長文化したり multi-line 引数を取り始めた瞬間に window が代名詞 ``` を越えて散文に到達する silent regression を起こす。`awk` の state machine で `in_block` / `in_create` flag を持ち、bash code block の `\`\`\`` 終端まで読む実装に切り替えれば、行数依存の脆弱性を排除できる。`\0` 区切り出力 + bash の `read -d ''` で portable に受けられる。

## 詳細

### 失敗パターン（cycle 1 で test-reviewer / code-quality reviewer が独立検出）

charter 違反検出 test で「`flow-state-update.sh create` を含む bash block 内で `--phase` / `--issue` 等の引数が揃っているか」を symmetry assertion として実装していた:

```bash
# BAD: 固定 +7 行 window
matches=$(grep -n 'flow-state-update.sh create' "$start_md")
while IFS=: read -r line_num _; do
  end=$((line_num + 7))  # 固定 window
  block=$(sed -n "${line_num},${end}p" "$start_md")
  # block 内で --phase / --issue / --branch / --pr / --next を確認
done <<< "$matches"
```

問題:

- bash code block が短ければ +7 行で十分
- だが `--next` が長文化したり (例: stop-guard HINT を埋め込む 80+ 文字)、引数が改行 line continuation で複数行に分かれると window がコードを抜けて散文に到達
- 散文側に偶然 `--phase` 等の文字列があると false positive、なければ false negative
- test-reviewer と code-quality reviewer が独立に検出した high-confidence finding

### canonical fix (動的 block 抽出)

`awk` の state machine で bash code block の `\`\`\`` 終端を追跡:

```awk
BEGIN { in_block=0; in_create=0; block="" }

# bash code block 開始/終了の追跡
/^```bash/ { in_block=1; next }
/^```/ && in_block { in_block=0; if (in_create) { printf "%s%c", block, 0; in_create=0; block="" }; next }

# block 内の処理
in_block {
  # create 検出時、既に in_create なら前 block を flush
  if (/flow-state-update\.sh create/) {
    if (in_create) {
      printf "%s%c", block, 0
      block=""
    }
    in_create=1
  }
  if (in_create) block = block $0 "\n"
}
```

bash 側で `\0` 区切りを `read -d ''` で受ける:

```bash
while IFS= read -r -d '' block; do
  # block 内の引数を確認 (--phase / --issue / --branch / --pr / --next)
  has_phase=$(echo "$block" | grep -c '\-\-phase ')
  # ... (各引数の確認)
done < <(awk -f extract.awk "$start_md")
```

### この pattern の応用範囲

| 用途 | 固定 window | awk state machine |
|------|-----------|-----------------|
| 単一 1 行マッチ + 固定後続行 (例: 直後 5 行のヘッダ確認) | OK | overkill |
| markdown bash block 内の構文検証 | NG (long-line drift) | canonical |
| 散文に紛れた literal の除外 (`\`\`\`bash` 内のみ対象) | NG (誤検出) | canonical |
| HEREDOC 内の literal 除外 (`<<EOF ... EOF`) | NG | extension で対応可能 (sentinel 追跡) |

### multi-create-per-block の blind spot

cycle 2 review で発見された design flaw: `in_create` flag が一度立つと bash block 終端まで reset されず、同一 block 内に 2 つ目の `create` 呼び出しがあると 2 つの create が単一 block として連結される。**修正**: create 検出時に既に `in_create=1` なら前 block を `printf "%s%c", block, 0` で先 flush し、新 block を `block=$0` で開始する。mutation test (1 block 内 2 creates、2 つ目で `--phase` 欠落) で `total=2 asymmetric=1` 検出を確認。

### 設計原則

- **state machine の境界は語彙的**: bash block の `\`\`\`` / 引用文 / HEREDOC sentinel など語彙レベルで判定し、行数依存しない
- **flush timing を明示**: state を持つ awk は flush 漏れが silent bug の温床。「state 切替時に必ず flush」を invariant として書き下す
- **`\0` 区切り受け渡し**: 改行を含む multi-line block を bash 側で安全に受けるには `\0` 区切り (`read -d ''`) が portable

## 関連ページ

- [Mutation Testing Test Fidelity](./mutation-testing-test-fidelity.md)
- [ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない](./test-counting-occurrence-vs-line-unit.md)
- [State Machine Dual Location Sync](./state-machine-dual-location-sync.md)

## ソース

- [PR #906 fix results (cycle 1)](../../raw/fixes/20260508T172017Z-pr-906.md)
- [PR #906 review results](../../raw/reviews/20260508T171533Z-pr-906.md)
