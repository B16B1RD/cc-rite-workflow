---
type: "patterns"
title: "入力ファイルと記録先が同一実体になりうる helper は書き込み前に resolve 比較で拒否する"
domain: "patterns"
description: "入力ファイルを読み、その検査結果を固定名の記録ファイルへ atomic write する helper は、呼び出し側が記録名を入力名に流用すると入力を記録で上書きし、直後の照合が「入力が別物になった」形で失敗する。読み込みより前に Path.resolve() 同士を比較して同一実体を拒否すれば、絶対・相対・ファイル symlink・ディレクトリ symlink の各表記を単一の比較で覆える。"
created: "2026-09-17T07:50:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-17T07:50:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260917T073541Z-pr-2931.md"
tags: []
confidence: high
---

# 入力ファイルと記録先が同一実体になりうる helper は書き込み前に resolve 比較で拒否する

## 概要

入力ファイルを読み、その検査結果を固定名の記録ファイルへ atomic write する helper は、呼び出し側が記録名を入力名に流用すると入力を記録で上書きし、直後の照合が「入力が別物になった」形で失敗する。読み込みより前に `Path.resolve()` 同士を比較して同一実体を拒否すれば、絶対・相対・ファイル symlink・ディレクトリ symlink の各表記を単一の比較で覆える。

## 詳細

対象になるのは「入力 → 検査 → 記録を固定名で保存 → 後続コマンドが記録と入力を突合する」型の helper で、記録先のファイル名が手順書に載っていると、読み手はその名前を入力の置き場所としても解釈する。入力と記録先が同一実体だと、検査自体は通ってから記録が入力を置き換えるため、失敗は 1 手あとの突合で「context が無い / stale」といった無関係な文言で現れ、原因の特定が遅れる。

ガードの置き場所は読み込みより前にする。読み込み後や検証後に置くと、既に記録で上書きされた入力（利用者が復旧を試みる実状態）では検証側の欠落エラーが先に出て、ガード固有の文言が届かない。位置を前に出せば入力の中身に依らず同じ文言で止まる。

同一実体の判定は `Path.resolve()` 同士の等値比較で足りる。相対表記・ファイル symlink・ディレクトリ symlink の経路はいずれも解決後の絶対パスが一致するため、経路ごとの分岐を持たずに済む。hardlink は解決後のパスが異なるため検出できないが、hardlink を作る呼び出し元が存在しない単一利用者環境では防御対象にしない。大小文字非区別のファイルシステムでは綴り違いを同一実体と見なせない点も、手順書の入力名を守る限り到達しない境界として扱う。

契約対応の pin は「ガード行を削除する」「`resolve()` を外して素の Path 比較にする」の 2 つの mutation で suite が red になることを実測して証明する。前者はガードの存在、後者は解決による同一実体判定を、それぞれ別の失敗文言で捕まえる。手順書側は入力名と記録名を別の名前で明記し、テストが手順書の文言そのものを pin して、記述の再統合を防ぐ。

## 関連ページ

- [同一 placeholder を識別子と resolution-target で再利用すると path-resolution drift を生む](../anti-patterns/placeholder-dual-use-resolution-drift.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)

## ソース

- [レビュー結果](../../raw/reviews/20260917T073541Z-pr-2931.md)
