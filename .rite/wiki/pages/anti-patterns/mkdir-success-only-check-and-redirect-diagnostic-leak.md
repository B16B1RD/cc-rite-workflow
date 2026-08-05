---
title: "mkdir 成功のみの判定漏れと brace group 未使用によるリダイレクト診断メッセージ漏洩"
domain: "anti-patterns"
description: "フォールバック判定を先頭コマンド (mkdir) の終了コードだけに頼ると後続の書き込み失敗を見逃す。是正の write probe (`{ : > FILE; } 2>/dev/null`) 自体も brace group を欠くと `>` が先に評価され open 失敗の診断メッセージが stderr に漏れる。PR #1969 (Issue #1968) で cycle 1 (非対称フォールバック) → cycle 3 (probe への brace group 適用) → cycle 5 (同一ファイル内の隣接行と不統一な新規追加行が回帰) の 3 段階で顕在化した。"
created: "2026-07-22T08:20:00+00:00"
updated: "2026-08-06T00:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260722T050800Z-pr-1969.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T051500Z-pr-1969.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T060230Z-pr-1969-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T070904Z-pr-1969-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T070928Z-pr-1969-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260805T124633Z-pr-2114.md"
tags: []
confidence: high
---

# mkdir 成功のみの判定漏れと brace group 未使用によるリダイレクト診断メッセージ漏洩

## 概要

`if mkdir -p DIR 2>/dev/null; then <実際に書く> else <破棄> fi` のように、フォールバック判定を先頭コマンド (mkdir) の終了コードだけに頼ると、DIR が既存の読み取り専用ディレクトリの場合でも mkdir -p は rc=0 を返すため、後続のファイル open 失敗（権限不一致・パス衝突・ディスクフル）を判定できない。是正には `{ : > FILE; } 2>/dev/null` のような brace group 付き write probe を if 条件に含める必要があるが、この probe 自体（あるいは同種の抑止対象コード）を brace group なしで `cmd > FILE 2>/dev/null` と書くと、bash のリダイレクト評価順序（`>` が先に評価される）のため open 失敗時の診断メッセージが抑制されず stderr に漏れる。両者は同一のイディオム `{ cmd > FILE; } 2>/dev/null` で同時に解決される。

## 詳細

### 発生構造 (3 段階)

1. **cycle 1 (非対称フォールバック)**: `if mkdir -p X 2>/dev/null; then <実際に書く> else <破棄> fi` パターンで、mkdir 成功をディレクトリ作成成功の意味に限定してしまい、後続のファイル open 失敗をカバーし忘れるケースが error-handling / application の 2 reviewer に独立検出された。エラー処理契約が「作成失敗」と「書き込み失敗」の両方を要求していたのに対し、実装は「作成失敗」のみをカバーする非対称になっていた。修正: mkdir 直後に `{ : > FILE; } 2>/dev/null` で truncate を試み、書き込み可否まで if 条件に含める。truncate 自体が「毎回上書き」の役割を兼ねるため実処理は `>>` (append) に切り替える。
2. **cycle 3 (probe への brace group 適用)**: テストフィクスチャで chmod によるパーミッション制限を使う際、制限が対象環境（root 実行、WSL2 DrvFs 等）で実際に強制されるかを probe write で事前検証すべきという教訓。この probe 自体のエラーメッセージ抑制に `{ : > file; } 2>/dev/null` の brace group を使う必要がある — 単純な `: > file 2>/dev/null` だとリダイレクトの open 失敗メッセージが抑制されないケースがあるため。
3. **cycle 5 (回帰)**: 同一ファイル (session-start.sh) の直前行 (391行目) が既に `{ : > "$_reap_log_dir/pr-cycle-cleanup.log"; } 2>/dev/null` という brace group パターンで統一されていたにもかかわらず、新規追加された 392 行目が `printf '*\n' > "$_reap_log_dir/.gitignore" 2>/dev/null || true` と brace group なしで書かれ、bash のリダイレクト評価順序 (`>` が先に評価される) のため open 失敗時の bash 診断メッセージが抑制されず stderr に漏れる回帰を生んだ。実機検証で 93 バイトのリーク（修正後は 0 バイト）を確認。mutation testing で teeth のある回帰テスト (TC-1968-08、`.gitignore` パスをディレクトリと衝突させて open 失敗を強制) を追加して検出力を担保した。

### 教訓 (canonical rule)

- 「エラーメッセージ無しで成功/失敗だけ判定したい」bash コードは常に `{ cmd; } 2>/dev/null` の brace group 形式で書く。`cmd 2>/dev/null` は、cmd 自体がリダイレクトを含む場合（`cmd > file` 等）、リダイレクトの open 自体がシェルによって `cmd` の実行より先に評価されるため抑制対象外になる。
- フォールバック判定は「先頭コマンドの終了コードだけ」でなく「実際に書き込む操作」まで含めて probe する — mkdir 成功はディレクトリ作成の成功しか意味しない。
- 同一ファイル内に既存の brace group パターンがある場合、新規追加コードは必ずそれに揃える。パターン不統一は最も検出しにくい回帰源になる（隣接行が正しいので目視レビューで見逃されやすい）。
- 実機検証 (stderr へのバイト数実測) で severity 判定の確度を上げる。「漏れているはず」という推論だけでなく、実際に漏れたバイト数を確認することで fix 前後の差分を主張できる。

### 追記 (PR #2114 cycle 4): 捨てられるのは「原因が最も要る側」

このスコープ差は「診断が漏れる/漏れない」だけの問題ではない。**どちらの失敗が捨てられるか**を見ると、単純コマンド形の害はより大きい:

| 形 | redirect 自身の失敗 (EACCES / パス衝突) | コマンドの書き込み失敗 (ENOSPC) |
|---|---|---|
| `printf ... > F 2>/dev/null` (単純コマンド) | **stderr へ漏れる** — bash は `2>/dev/null` 適用**前**に報告する | **捨てられる** |
| `{ printf ... > F; } 2>&1` (グループ) | 捕捉できる | 捕捉できる |

つまり単純コマンド形は「原因が最も要る側 (ENOSPC) だけを捨て、要らない側 (EACCES) を漏らす」という最悪の分配になる。**「先例と同型」を名乗る前に、先例の redirect スコープまで読む** — PR #2114 では先例として引いた形がグループスコープで、挙動が逆だった。

この差は「エラーメッセージが出るか」ではなく「**どこに出るか**」でしか観測できないため、静的 pin は文言ではなく**列位置**に取る (`^  .*/\.gitignore: ` が 1 本、列 0 の同型行が 0 本)。あわせて診断 pin を locale に依存させないこと — `Permission denied` に結合させると ja_JP 環境で 1 件も拾えない。構造 (`<path>: `) に anchor し、診断が制御文字 neutralize を通る経路では 0x80-0x9f がバイト単位で潰れて行が invalid UTF-8 になるため、`LC_ALL=C` を付けないと ASCII の anchor すら空振りする (実測)。

## 関連ページ

- [`cmd 2>/dev/null` は no-match と write failure を混同する](./cmd-redirect-or-true-conflates-nomatch-and-write-failure.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)
- [ガードの述語は「守りたい状態」そのものを測る](../heuristics/guard-predicate-measures-the-protected-state.md)
- [診断退避用の tempfile は診断が最も要る場面でだけ消える](../heuristics/diagnostic-tempfile-fails-when-diagnosis-needed-most.md)

## ソース

- [PR #1969 cycle 1 review (対称フォールバック実装の落とし穴)](../../raw/reviews/20260722T050800Z-pr-1969.md)
- [PR #1969 cycle 1 fix (mkdir 成功のみ判定の是正)](../../raw/fixes/20260722T051500Z-pr-1969.md)
- [PR #1969 cycle 3 fix (chmod probe への brace group 適用)](../../raw/fixes/20260722T060230Z-pr-1969-cycle3.md)
- [PR #1969 cycle 5 review (brace group 未使用のリダイレクト評価順序回帰)](../../raw/reviews/20260722T070904Z-pr-1969-cycle5.md)
- [PR #1969 cycle 5 fix (brace group への統一)](../../raw/fixes/20260722T070928Z-pr-1969-cycle5.md)
- [PR #2114 fix results (cycle 4) — 捨てられる側の非対称と列位置 pin](../../raw/fixes/20260805T124633Z-pr-2114.md)
