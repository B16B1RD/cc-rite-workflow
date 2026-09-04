---
type: "heuristics"
title: "無音失敗を可視化する防御コードには、その防御コード自体を守る失敗パステストを追加する"
domain: "heuristics"
promote: rite-plugin
description: "`2>/dev/null || true` 等で無音化されていた失敗を「WARNING を stderr へ出力する」形に是正する fix は、成功パスのテストだけでは不十分。"
created: "2026-07-22T21:35:00+00:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260806T013904Z-pr-2120.md"
  - type: "reviews"
    resource: "raw/reviews/20260825T141342Z-pr-2360.md"
  - type: "fixes"
    resource: "raw/fixes/20260825T141757Z-pr-2360.md"
  - type: "reviews"
    resource: "raw/reviews/20260722T102818Z-pr-1970.md"
  - type: "fixes"
    resource: "raw/fixes/20260722T103236Z-pr-1970.md"
  - type: "reviews"
    resource: "raw/reviews/20260722T112806Z-pr-1970-cycle2.md"
  - type: "fixes"
    resource: "raw/fixes/20260722T113522Z-pr-1970-cycle2.md"
  - type: "reviews"
    resource: "raw/reviews/20260722T122232Z-pr-1970-cycle3.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-25T14:36:47Z" }
verified:
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-25T14:36:47Z" }
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

### security 起因の防御はとくに pin を忘れやすい（cycle 4 実測）

同じギャップが security 起因の修正で再現し、**なぜ忘れるのかが一般化できる形で観測された**。cycle 3 で security 指摘に応えて 4 つの WARNING に制御文字の中和を追加したが、その中和に回帰テストを付け忘れた。補間 9 箇所を素の変数展開へ戻しても hook 全 114 suite が green のまま通る状態で、test と security の 2 reviewer が独立に同じ mutation で実測した。

**security 起因の修正は「脅威が塞がったか」の確認に意識が向き、「塞いだ状態が将来も維持されるか」の pin まで届かない。** 前者は 1 回の観測で完了する（実測して raw バイトが `?` になることを確認すれば済む）が、後者は assert として残さないと次の編集で消える。

**対策は security fix のチェックリストに「この防御を外す mutation を当てて FAIL するか」を入れること。** cycle 1〜3 で繰り返し学んだはずのことが、cycle 3 の中和追加でだけ抜けていた。

なお、部分的に中和した経路の regression test は素朴な形では書けない（隣接する未中和行が混ざる）。詳細は [制御文字中和を通した出力への grep assert はロケールで検出能力を失う](../anti-patterns/locale-dependent-error-message-grep-assertion.md) の「中和の pin は『隣の未中和行』に邪魔される」節を参照。

### WARNING 文面のパスを pin しないと可視化是正が退行する（別の PR での実測）

終了済み Issue の flow-state / run-queue を回収する経路で、cycle 1 は識別 jq の silent skip と lock 残置を WARNING に是正した。しかし AC が要求する「WARNING に対象パスを明示する」こと自体をテストが pin しておらず、error-handling と test が独立に指摘した。cycle 2 で T-01 が stale WARNING のパスを、T-04 が corrupt JSON の読み取り失敗 WARNING を固定した。

**可視化を足しただけでは、パス欠落や `|| empty` への再退行は成功パスでは検出できない。** WARNING の本文に対象パスが含まれることと、corrupt 入力でその WARNING が出ることを別 fixture で pin する。

### 副次的な教訓: worktree 環境でのデバッグ時は plugin_root の参照先を要確認

テスト失敗の原因調査中、手動デバッグで `plugin_root` をセッション worktree 内の修正済みコピーではなく main checkout の古いコピー（`/path/to/repo/plugins/rite/...`、md5sum が異なる）に向けてしまい、「fix したはずのコードが動いていない」ように見える偽の失敗を一時的に作り出した。worktree ベースの開発では、デバッグ用の一時スクリプトが参照する `plugin_root` 等のパスが、作業中のブランチが実際にチェックアウトされているディレクトリ（多くの場合セッション worktree）を指しているか、意識的に確認する必要がある。`md5sum` 等でファイル実体を比較するのが最も確実な切り分け方法。

## 関連ページ

- [mkdir 成功のみの判定漏れと brace group 未使用によるリダイレクト診断メッセージ漏洩](../anti-patterns/mkdir-success-only-check-and-redirect-diagnostic-leak.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [レビュー結果](../../raw/reviews/20260722T102818Z-pr-1970.md)
- [fix 結果](../../raw/fixes/20260722T103236Z-pr-1970.md)
- [レビュー結果](../../raw/reviews/20260722T112806Z-pr-1970-cycle2.md)
- [fix 結果](../../raw/fixes/20260722T113522Z-pr-1970-cycle2.md)
- [mergeable, mutation test 実証](../../raw/reviews/20260722T122232Z-pr-1970-cycle3.md)
- [security 起因の防御に pin が抜けた実例](../../raw/fixes/20260806T013904Z-pr-2120.md)
- [WARNING パス未 pin](../../raw/reviews/20260825T141342Z-pr-2360.md)
- [T-01 パス pin / T-04 corrupt JSON pin](../../raw/fixes/20260825T141757Z-pr-2360.md)
