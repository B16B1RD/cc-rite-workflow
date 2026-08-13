# /rite:recover — 設計理由

`skills/recover/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## context-marker-bridge

後続 Phase は別々の Bash tool 呼び出しとなりシェル変数を引き継げない。`$state_phase` を直接参照
すると常に空になり active=true 復元経路が dead になる。stdout の `[CONTEXT]` marker を LLM が
読んで placeholder を実値置換する。

## worktree-before-crosscheck

git/PR 状態クロスチェックはカレントブランチ依存のため、worktree 再入場はその前に行う。session ⇄
worktree は 1:1 でない（クラッシュで session_id が変わる）ため、issue 番号 → worktree パス導出が
正規の対応関係。flow-state `worktree` field は同一セッション内のヒントに留まる。EnterWorktree は
LLM ツールのため helper からは呼べない。

marker の読み取り規約（行頭アンカー・stderr 混入・`branch=` スコープ・同一 KEY は最新勝ち）は
`marker_get`（`lib/context-marker.sh`）が SoT。本ファイルは case 値ごとのアクションだけを規定する。

## conflict-priority

コンフリクトマーカーが残ったまま generic な「実装途中」で復帰すると、未解決の変更を上書き
コミットへ誘導する。検出は git 実態から完結するため flow-state schema は変えない。rite は
コンフリクトを自動解消・自動コミットしない。

## outstanding-informational

cleanup / completed のときだけ、過去の cleanup が非ブロッキングで残した signal を git 実態から
検出する。新しい記録先は持たない。Phase 3.5 / 5.3 には影響しない。「なし」の明示は cleanup 自身の
完了報告の責務。

## no-switch-in-worktree

worktree 内から base への `git switch` は不可かつ不要。HEAD は既に state branch を指しているはず
なので検証のみ。

## batch-continue-freshness

stale な残骸キューを誤って継続しないよう、鮮度判定を必須とする。閾値 2 時間は
`parse_iso8601_to_epoch` と同じ（新しい定数は増やさない）。1 件目の処理自体が 2 時間を超えて
中断した場合は stale と誤判定されうるが、`updated_at` の更新ポイントを増やさない方を優先する。
session_id 解決不可は fail-loud せず通常の recover 完了へ倒す（read-only 安全側）。

## phase5-passthrough

`phase5_*` 系の legacy 名は `_phase_migrate` の reduction matrix に含まれず pass-through される。
PHASE_ENUM_V3 に該当しないため Phase 2 では変換されず、Phase 3.5 の cross-check で v3 phase へ
解決される。
