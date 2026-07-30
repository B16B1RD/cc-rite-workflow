---
type: "heuristics"
title: "無音失敗を可視化する防御コードには、その防御コード自体を守る失敗パステストを追加する"
domain: "heuristics"
description: "silent failure（`|| true` 等）を WARNING 出力に是正した fix は、その WARNING 自体が将来の編集で無音化に退行しても検出できない。同一 cycle 内で複数 reviewer が独立にこのギャップを指摘するのは、防御コードの追加とそのテストカバレッジが別問題として見落とされやすいことの兆候。mutation testing（意図的に防御コードを退行させてテストが red になるか確認）で検証すると実効性を主張できる。"
created: "2026-07-22T21:35:00+00:00"
updated: "2026-07-22T21:35:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260722T102818Z-pr-1970.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T103236Z-pr-1970.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T112806Z-pr-1970-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T113522Z-pr-1970-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T122232Z-pr-1970-cycle3.md"
tags: []
confidence: high
---

# 無音失敗を可視化する防御コードには、その防御コード自体を守る失敗パステストを追加する

## 概要

`2>/dev/null || true` 等で無音化されていた失敗を「WARNING を stderr へ出力する」形に是正する fix は、成功パスのテストだけでは不十分。追加した WARNING 出力自体が将来 `|| true` へ再退行しても検出できないためで、起点事例の review-fix loop では cycle 1 で追加した WARNING を cycle 2 で error-handling reviewer と test reviewer が独立に「WARNING 自体の失敗パステストが無い」と指摘した（cross-validation で reviewer 2 名が同一箇所を指摘 = high confidence signal）。

## 詳細

### 発生構造

1. **cycle 1**: `[ -f ... ] && mkdir -p ... && cp ... 2>/dev/null || true` という新規複製コードが、mkdir/cp 失敗を完全に無音化していた。同一関数内に既存の WARNING パターン（git fetch リトライ失敗時）があったため、error-handling reviewer が非対称と指摘。fix で `if ... && ! { mkdir -p ... && cp ...; } 2>/dev/null; then echo WARNING; fi` に是正（制御フローは変えず可視化のみ追加）。
2. **cycle 2**: 是正した WARNING 出力そのものを検証する失敗パステストが無いことを、error-handling reviewer（MEDIUM）と test reviewer（LOW-MEDIUM）が独立に指摘。cross-validation で最高重要度（MEDIUM）に統合。fix で「`.claude` を通常ファイルとして git track させたローカルブランチを用意し、worktree checkout 時に `mkdir -p` を決定論的に失敗させる」テストケース（TC-15）を追加。テストの決定論性は「対象パスが既存の非ディレクトリファイルの場合 `mkdir -p` は POSIX 全域で確実に失敗する」という性質に依拠しており、chmod ベースの権限操作より移植性が高い。
3. **cycle 3（検証）**: error-handling reviewer が **mutation test** を実施 — scratchpad 上の隔離コピーで対象コードを cycle 1 以前の無音化パターンに意図的に戻し、新設した TC-15 が確実に red（`32/32 PASS` → `31 PASS / 1 FAIL`）になることを実証。これにより「テストがトートロジーでなく実際に防御コードを検証している」という主張に実測の裏付けを与えた。

### 教訓（canonical rule）

- **防御コード（エラーハンドリング・WARNING 出力）を追加する fix は、その防御コード自体を退行させたときに red になるテストを同一 PR で追加する。** 成功パスのテストだけでは「防御コードが存在すること」しか守れず、「防御コードが機能し続けること」は守れない。
- **複数 reviewer が独立に同一ギャップ（テストカバレッジの欠如）を指摘するのは、単なる偶然の重複ではなく high-confidence signal。** cross-validation で severity を最高値に統合する設計（severity-levels.md の Cross-Validation ルール）はこの種の見落としを拾うために機能する。
- **失敗パステストの決定論性は「対象環境で確実に失敗する条件」を選ぶことで担保する。** 本ケースでは「mkdir -p の対象パスに既存の非ディレクトリファイルを置く」という POSIX 準拠の確実な失敗条件を使い、chmod・symlink 等の環境依存性が高い手法を避けた。
- **新設したテストの実効性は mutation testing（意図的な退行 + red 確認）で実証できる。** 「アサーションが通っている」だけでは、そのアサーションが実際に対象コードの振る舞いに依存しているか（トートロジーでないか）は分からない。隔離環境（scratchpad 等、実リポジトリを汚さない場所）で対象コードを意図的に壊し、新設テストが red になることを確認するのが最も直接的な裏付けになる。

### 副次的な教訓: worktree 環境でのデバッグ時は plugin_root の参照先を要確認

テスト失敗の原因調査中、手動デバッグで `plugin_root` をセッション worktree 内の修正済みコピーではなく main checkout の古いコピー（`/path/to/repo/plugins/rite/...`、md5sum が異なる）に向けてしまい、「fix したはずのコードが動いていない」ように見える偽の失敗を一時的に作り出した。worktree ベースの開発では、デバッグ用の一時スクリプトが参照する `plugin_root` 等のパスが、作業中のブランチが実際にチェックアウトされているディレクトリ（多くの場合セッション worktree）を指しているか、意識的に確認する必要がある。`md5sum` 等でファイル実体を比較するのが最も確実な切り分け方法。

## 関連ページ

- [mkdir 成功のみの判定漏れと brace group 未使用によるリダイレクト診断メッセージ漏洩](../anti-patterns/mkdir-success-only-check-and-redirect-diagnostic-leak.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #1970 review cycle 1](../../raw/reviews/20260722T102818Z-pr-1970.md)
- [PR #1970 fix cycle 1](../../raw/fixes/20260722T103236Z-pr-1970.md)
- [PR #1970 review cycle 2](../../raw/reviews/20260722T112806Z-pr-1970-cycle2.md)
- [PR #1970 fix cycle 2](../../raw/fixes/20260722T113522Z-pr-1970-cycle2.md)
- [PR #1970 review cycle 3 (mergeable, mutation test 実証)](../../raw/reviews/20260722T122232Z-pr-1970-cycle3.md)
