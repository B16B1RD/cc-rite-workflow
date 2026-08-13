---
name: unknowns
description: |
  rite workflow の実装前探索セッションスキル: 新機能やアイデアの構想段階で、盲点（unknown unknowns）
  の洗い出し・複数アプローチのブレインストーミング・使い捨て HTML プロトタイプ・要件インタビューを
  対話的に組み合わせ、最後に「探索サマリ」を出力して /rite:issue-create 等の後続ワークフローへ渡す。
  ユーザーが明示的に /rite:unknowns で起動する。auto-activate しない。
  起動: /rite:unknowns [テーマ]
argument-hint: "[テーマ]"
---

# /rite:unknowns — 実装前の探索セッション

実装前の安い段階で unknowns を減らす探索セッション。
rationale: references/rationale.md#field-guide

unknowns は 4 象限で捉える:

| | 既知 | 未知 |
|---|---|---|
| **既知の** | プロンプトに書けること | まだ決めていないと自覚していること |
| **未知の** | 当たり前すぎて書かないが、見れば分かること | 考慮すらしていないこと |

右列（既知の未知・未知の未知）と左下（見れば分かる系）を、実装より安いコストで左上に移す。

## 大原則

- **探索と実装を混ぜない**。実行中は本実装のコード変更を行わない。実装に進む機運が高まったら探索サマリを出して終える
  rationale: references/rationale.md#no-implement-in-session
- **調べて分かることは質問しない**。聞くのはユーザーの頭の中にしかない判断・好み・トレードオフだけ
- **同意は unknowns を減らさない**。欠陥や見落としは根拠とともに指摘する
- **ユーザーが応答できない環境**（ヘッドレス等）では仮定を明示して進め、確認できなかった点を探索サマリの「未解決の問い」に残す

## 出力言語

`rite-config.yml` の `language` 設定に従う（`auto`: ユーザーの入力言語を検出、`ja`: 日本語固定、`en`: 英語固定）。未設定時は会話言語に合わせる。

## 進め方

### 0. 出発点の把握

まずユーザーの現在地を掴む。すでに会話にある情報は聞き直さない。足りなければ 1〜2 問だけ:

- 何を作りたい / 解決したいか（一言で十分。曖昧でもよい）
- 対象ドメイン・コードベースへの習熟度（unknowns の在り処を推定する材料になる）
- すでに決めていること / 決めていないと自覚していること

「よく分かっていない」という状態自体が正常な入力。ここで要件を固めようとしない。

### 1. テクニックの選択と提案

状況シグナルからテクニックを選び、「この順で探索するのを提案します」と一言添えてから始める。ユーザーが特定のテクニックを指定したらそれに従う。複数の組み合わせ・往復が普通で、1 つで終わることのほうが珍しい。

| シグナル | テクニック |
|---------|-----------|
| 領域・コードベースが未知。「何を聞けばいいかも分からない」 | ブラインドスポットパス |
| 方向性が複数ありえる。スコープや打ち手が発散している | ブレインストーミング |
| 見た目・UX・体感が判断材料。「見れば分かる」 | プロトタイプ |
| 方向は決まっているが詳細が曖昧 | インタビュー |

### 2. 各テクニック

#### ブラインドスポットパス（unknown unknowns の洗い出し）

ユーザーが考慮していない可能性のある事項を、コードベース・Web の調査に基づいて列挙する。

- 「知らないまま進むと後で高くつく順」に並べる。各項目に「なぜ重要か」「今決めるべきか、後回しでよいか」を付ける
- ユーザーにとって未知のドメインなら、選択肢を評価できるようになる最小限の基礎を教える。目的は知識の網羅ではなく、ユーザーが「何が良いか」の判断基準を持てるようにすること
- 「この変更が触れないが、壊れうる隣接領域は何か」「ユーザーが知らなそうな既存の制約・慣習は何か」を自問して探す

**Wiki 連携（Conditional）**: 盲点候補の材料としてプロジェクトの蓄積経験則を注入する。

Step 1: `wiki.enabled: true` かつ `wiki.auto_query: true`（`rite-config.yml`）のときのみ実行する。いずれか false なら以下を silent skip し、通常の盲点洗い出しのみ行う（エラー・警告は出さない）:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_query=""
if [[ -n "$wiki_section" ]]; then
  auto_query=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_query:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_query:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
```

Step 2: `{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files) で解決する。`{keywords}` はユーザーのテーマ・対象ドメイン用語をカンマ区切りで生成する（他コーラー skills/issue-create/SKILL.md 4.0 / skills/fix/SKILL.md 0.5.W / skills/pr-review/SKILL.md 4.0.W / skills/issue-implement/SKILL.md 5.0.W と同形式）:

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -n "$plugin_root" ] && [ -f "$plugin_root/hooks/wiki-query-inject.sh" ]; then
  wiki_context=$(bash "$plugin_root/hooks/wiki-query-inject.sh" --keywords "{keywords}" --format compact 2>/dev/null) || wiki_context=""
  [ -n "$wiki_context" ] && echo "$wiki_context"
fi
```

非空の `wiki_context` は盲点候補の材料として提示に反映する。空 / エラー時は通常の盲点洗い出しのみ行う（エラー・警告は出さない）。

#### ブレインストーミング（方向性の発散と反応）

性格の異なる 3〜5 案を、最小・安価な案から野心的な案の順で提示する。

- 各案: 概要 / 得られるもの / コスト / リスク / この案が合う状況
- 目的は**決めさせる**ことではなく**反応してもらう**こと
  rationale: references/rationale.md#brainstorm-for-reaction
- 全案が同じ方向の濃淡にならないようにする。1 案は意図的に毛色を変える

#### プロトタイプ（見て反応するための使い捨てモック）

目的は「見て反応してもらう」こと。動く本物を作ることではない。

- 実データ・実バックエンドに配線しない。fake data で見た目と操作感だけ再現する
- Artifact ツールが使える環境ではそれで HTML を提示する。使えなければ自己完結 HTML（外部依存なし）をファイルに書き、ブラウザで開くパスを案内する
- デザインの複数方向を見たいときは、1 ページに並べて比較できるようにする
- プロトタイプのコードは使い捨てであることを明示する。本実装への流用を前提にしない
  rationale: references/rationale.md#prototype-disposable

**レビューモードをデフォルトで組み込む。** [references/feedback-mode.html](references/feedback-mode.html) を組み込む。手順・マークアップ・CSS/JS はテンプレート冒頭コメントに従う。要点:

- 反応してほしい単位ごとにコンテナへ `data-fb="ブロック名"` を付ける（7±3 個が目安）＋末尾に「全体コメント」ブロックを 1 つ
- 各ブロックに「👍 このまま / 🔧 要調整」とコメント欄。「フィードバックをまとめる」で Markdown 生成 → ユーザーがコピーしてチャットに貼る。ページ内バナーにコピペの橋渡しであることを明記する
- 例外: 反応が単純な比較ページはレビューモードを省略してよい
- プロトタイプ自体が成果物になる場合は、レビューモード付きの版とクリーン版を別ファイル・別 Artifact URL で管理する

#### インタビュー（曖昧さの的を絞った解消）

1 問ずつ聞く。回答がアーキテクチャやスコープを大きく変える順に優先する。

- 選択式にできる問いは、選択肢と推奨案を付けて提示する（AskUserQuestion が使えるならそれで）
- 回答が設計をもう変えなくなったら打ち切る。全部聞くことが目的ではない
- 質問の前に自分で調べる。「コードを読めば分かること」を聞くのはこのスキルの禁じ手

### 3. ループと終了判定

反応を受けてテクニックを往復する。次のいずれかが終了シグナル:

- 新しい unknown が出なくなった
- ユーザーが方向性を確信した（「これでいこう」）
- ユーザーが実装に進みたがっている

終了時は必ず探索サマリを出力する。
rationale: references/rationale.md#summary-as-handoff

### 4. 探索サマリ

以下の形式で出力する（言語は「出力言語」節に従う）。ユーザーがファイル保存や後続ワークフローへの受け渡しを求めたら、markdown ファイルとして保存する。

```markdown
# 探索サマリ: {テーマ}

## 出発点
{ユーザーの当初の問題意識・現在地}

## 確定したこと
{選んだ方向性と、その理由}

## 却下した代替案
- {案}: {却下理由（Why not）}

## 未解決の問い
- {自覚できたが、まだ答えの出ていない問い。実装計画時に解消すべきもの}

## 発見した盲点
- {探索で浮上した、当初考慮していなかった事項}

## 成果物
- {プロトタイプのパス / Artifact URL 等}

## 次のステップ
{例: このサマリを /rite:issue-create の入力として渡し Issue 起票に進む / 実装計画を立てる}
```

`/rite:issue-create` や実装計画の入力として使える粒度で書く。

`/rite:issue-create` はこの見出しを自動検出し軽量化パスに入る。マッピング・線引き: `../issue-create/references/unknowns-boundary-rationale.md#なぜ探索サマリ検出で-4050-を丸ごとスキップしないか`
