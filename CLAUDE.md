# CLAUDE.md

Claude Code Rite Workflow - Claude Code 用 Issue ドリブン開発ワークフロープラグイン

## アーキテクチャ

```
.claude-plugin/                    # マーケットプレイスメタデータ（marketplace.json）
plugins/rite/.claude-plugin/       # プラグイン固有メタデータ（plugin.json）
plugins/rite/
├── skills/           # Claude Code が自動検出するスキル定義（SKILL.md）。/rite:<name> で起動
│   │                 #   各スキル = 薄い SKILL.md + 同梱 references/（行数原則は下記）
│   ├── PR lifecycle  #   open, iterate, pr-review, fix, ready, merge, cleanup, run, pr-create
│   ├── issue 管理     #   issue-create, issue-list, issue-update, issue-close, issue-cancel, issue-edit, issue-implement
│   ├── wiki          #   wiki-init, wiki-query, wiki-ingest, wiki-lint
│   ├── meta/top      #   setup, getting-started, workflow, investigate, learn, lint, recover, skill-suggest, template-reset
│   ├── rite-workflow/  # orchestration context（状態検出・phase routing）+ references/（コーディング原則 等）
│   └── reviewers/      # レビュアー調整（選定 + テーブル）+ references/（各 reviewer profile は agents/{type}-reviewer.md）
├── agents/           # PR レビュー用サブエージェント定義
│                     # _reviewer-base.md（共通原則）+ 9 reviewer agent
├── templates/        # config/（rite-config.yml 最小デフォルト）、
│                     # issue/, pr/, review/, wiki/ の各フォーマット
├── references/       # gh CLI パターン、GraphQL、severity-levels、investigation-protocol、
│                     # wiki-patterns、review-result-schema、bash-trap-patterns 等（複数スキル共有）
├── scripts/          # Projects 統合 Issue 作成、Sub-Issue リンク、レビュー結果抽出・計測 等
└── hooks/            # Claude Code ライフサイクルフック（session / compact /
    │                 # pre-tool-bash-guard / post-tool-wm-sync /
    │                 # wiki-ingest-trigger / wiki-query-inject /
    │                 # session-ownership / hook-preamble 等）+ hooks.json
    ├── scripts/      #   Wiki commit / worktree / backlink / gitignore-health / lint scanner 等のヘルパー
    └── tests/        #   hook レベルの自動テストスイート
rite-config.yml        # プロジェクト固有設定（ブランチ戦略、Projects連携、Wiki、review loop 等）
```

**コンポーネント間の関係**: スキル（`skills/`）が**エントリポイントかつ実行手順書**（v0.7 で旧 `commands/` を全廃しスキルへ統合）。orchestrator スキル（open / iterate / run 等）が sub-skill（pr-review / fix / pr-create / issue-implement 等）を Skill ツール経由で呼び出し、各スキルは `agents/`（Task で spawn）や `references/`（自スキル内 `references/` + plugin-root `references/` の共有分）を参照する。hooks/ は Claude Code のライフサイクルから独立に発火し、orchestrator とコンテキスト注入・sentinel emit で連携する。ディレクトリ・ファイルの完全な一覧は `docs/SPEC.md` の Plugin Structure 節を参照。

**スキル行数原則**: 短いほど良い。増える変更は理由を要する。行数上限までの余白を埋めてはならない。

- **主指標は散文バイト**（`bytes_prose`）。総行数は副次。実測: open パイロット 約 −36%（`plugins/rite/references/skill-diet-method.md` §3.1）、第 1 波 iterate −33.3% / fix −32.3% / pr-review −25.5%。4,000 行上限を「書いてよい量」としては使わない。
- **構成**: outcome + 検証条件 + 機械ステップ。rationale（設計理由・背景解説）は SKILL.md 本体に書かず同梱 `references/` へ退避し、該当箇所に 1 行ポインタ（`rationale: references/<file>.md#<anchor>`）を残す。機械レール（分岐表・sentinel 表・fenced bash・エラー処理指示）は本体に維持する。
- **入口スキル**は薄い SKILL.md を保つ（500 行は薄さの目安であり上限ではない）。新規作成・追記は `plugins/rite/references/skill-diet-method.md` に従う。

## 開発ルール

- **ブランチ**: `develop` ベース、`{type}/issue-{number}-{slug}` 命名
- **コミット**: Conventional Commits 形式（`feat`, `fix`, `docs`, `refactor`, `chore`）
- **PR**: `develop` に向けて作成

## テスト・検証

現時点でビルド・テスト・lint コマンドは未設定（`rite-config.yml` の `commands` セクション参照）。変更の検証は以下で実施:

- `/rite:lint` でプロジェクト設定に基づく品質チェック
- `/rite:pr-review` でセルフレビュー（マルチレビュアー方式）
- 手動: スキル・コマンドの変更は次回呼び出し時に反映されるため、実際に実行して動作確認

## メモリ機能

このプロジェクトでは Claude Code のメモリ機能（`~/.claude/projects/*/memory/`）を使用しない。ワークフローの方針は `rite-config.yml` と `skills/` で表現すること。メモリファイルの新規作成・更新は行わないこと。

## プロジェクト原則（設計判断の恒久規範）

過去のセッションで繰り返し確認された設計原則。セッションを跨いで忘れられる傾向があるためここに明文化する。探索・設計・実装・レビューのすべてで適用する。

- **ユーザー環境第一**: マーケットプレイス配布物は配布先だけで意味が完結するよう書き、開発リポジトリでしか解決できない番号・経緯を前提にしない。Issue / PR 番号を永続成果物に書かない（例外なし）
- **人間の役割は 2 点のみ**: 「要件・仕様を伝える」と「完成品を動かして動作チェックする」。工程の途中に人間の品質判断を常駐させる設計をしない。人間へのエスカレーションは例外処理であり、定常運用の形にしない
- **品質を予算で縛らない・無駄は排除する**: cycle 数やトークン予算を理由に品質を妥協する設計（「予算到達したから飲む」）は採らない。切るべきは発散・空転（無駄）であって、収束に向かう実サイクルではない
- **将来拡張に備えない（no speculative structure）**: 将来の拡張に備えた構造・予約フィールド・拡張点・設定キーは、実需の Issue が存在しない限り追加しない。その未来は滅多に来ないし、来たらその時に時間をかけて対応すれば済む
- **フォールバックよりエラー出力（fail-loud）**: 見過ごしは許さないが、既定の対処は「エラーとして捕捉し、出力して止める」。guard / fallback / 既定値代入が正当化されるのは fail-loud が不可能な場合のみ（coding-principles の `no_unnecessary_fallback` / reviewer 側の Fail-Fast First と同旨）
- **運用環境の前提**: 単一ユーザーの開発機を前提とする。共有ホスト・マルチテナント向けの敵対的堅牢化（TOCTOU 徹底防御・squat 対策等）は、実測付きの指摘であっても要求しない
- **知見のルーティング**: rite workflow 自体の挙動・スキル記述法に関する知見は、プロジェクト Wiki ではなくプラグイン本体（helper / gate / 原則 / references）へ機構として組み込む。Wiki に置くのはプロジェクトドメインの経験則のみ。マーケットプレイス配布先で機能しない知見を Wiki に留置しない（Wiki は「思い出させる」だけで「強制しない」ため、ループ挙動系の知見は Wiki ではローカルですら不活性になる — 実測済み）。plugin へ昇格する知見は環境非依存であることも必須とし、環境固有の知見は一般化してから昇格するか、一般化できなければ domain 知見として Wiki に残す

## エージェント振る舞い原則

rite workflow はワークフロー定義そのものを LLM エージェントで編集するため、以下を厳守する。
（出典: Karpathy 2025-12 "claude coding" 観察）

### 仮定を表明し、確認する
- ユーザーの意図・前提・既存仕様について不確かな点があれば、推測で進めず質問する
- やむを得ず推測する場合は「〇〇と仮定して進めます」と明示してから着手する
- 仕様の矛盾・前提崩壊を見つけたら、修正案を進める前に必ず表面化する

### 押し返すべきときは押し返す
- ユーザーの指示が技術的に不適切・非効率・矛盾している場合、同意せず根拠とともに反論する
- 「いいですね」「もちろんです」で始まる追従的な応答を避ける
- 複数の選択肢があるときは、推奨と理由・トレードオフを提示してから実装に入る

### シンプルさを死守する
- 100 行で済むものを 1000 行にしない。新しい抽象・ラッパー・設定項目・hook を追加する前に「本当に必要か」「既存で表現できないか」を一度問う
- skills/hooks の既存パターンに合わせ、新しい構造を持ち込まない
- タスク完了時にデッドコード・未使用 reference・コメントアウト・旧フォーマットを残さない

### スコープを越えない
- 依頼されたタスクと無関係なコマンド・スキル・hook の変更/削除をしない
- リファクタやスタイル統一を「ついでに」やらない。気になった点は別途 Issue / 報告として切り出す
- 「理解できない」「気に入らない」を理由に既存のワークフロー仕様を書き換えない（rite では仕様変更が即座に他の作業を壊す）

## ドッグフーディング注意事項

このリポジトリは Rite Workflow 自体を Rite Workflow で開発している。

- **`.claude/settings.local.json` の `enabledPlugins["rite@rite-marketplace"]: false` を維持すること**: グローバルな `~/.claude/settings.json` は他プロジェクトでのマーケットプレイス経由インストール（`true`）のために触ってはならない。本リポジトリではプロジェクトローカルの `.claude/settings.local.json` で `rite@rite-marketplace: false` を上書きし、このリポジトリ内のセッションに限ってローカルの `plugins/rite` を優先ロードさせる。この上書きが外れると、キャッシュされた古いマーケットプレイス版が優先ロードされ、ローカルの修正が一切反映されない（実機検証で確認済み）
- **CLAUDE.md の変更は即座に影響する**: 編集内容は現在の Claude Code セッションで即座に参照される
- **skills/ の変更は次回呼び出しから反映**: Skill ツール経由で呼び出されるたびに最新のファイル内容が読み込まれる
- **自己参照ループに注意**: ワークフロー仕様の変更中にそのワークフローを使って作業するため、変更前後で動作が変わる可能性がある
- **worktree セッションでも上書きは維持される（Issue #1943）**: `.claude/` は gitignore 対象のため `git worktree add` では複製されないが、`/rite:open` / `/rite:batch-run` が作成するセッション worktree（`.rite/worktrees/issue-N`）には worktree 作成時に `.claude/settings.local.json` が存在すればスナップショットとして複製される。作成後に main checkout 側の設定を更新しても既存 worktree には反映されない（再作成または手動 `cp` が必要）
- **auto-mode 分類器が定義ファイル編集をブロックすることがある（Issue #1947）**: CLAUDE.md や `plugins/rite/references/*.md` 等「assistant 自身の振る舞いを規定するファイル」への Edit は、Claude Code の auto-mode 分類器に「high-risk」と判定されブロックされる場合がある。rite はワークフロー定義そのものを LLM エージェントで編集するため、この制約とドッグフーディング作業が正面衝突しうる。分類器の挙動は Claude Code 本体の管轄で rite 側では修正不能なため、発生時は permission mode を切り替える（例: 確認モードへ一時変更）か、該当箇所を手動編集する。sandbox 制約（`dangerouslyDisableSandbox` 等）とは別レイヤーの制約であり、sandbox 設定を変更しても解消しない
