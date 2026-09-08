# Session ID Validation Contract (SoT)

Session ID の **選択**と**検証**を分ける。`session-identity.sh` がホストの実 ID を選び、
利用箇所の責務に応じて次の 2 層で検証する。

## 2 つの validator、2 つの関心事

| | Layer 1: security boundary | Layer 2: format / identity |
|---|---|---|
| 実装 | `session-identity.sh` の `validate_session_id_path`（`flow-state.sh` の `_validate_session_id` からも呼ぶ） | `_resolve-session-id.sh` |
| 検証 | path-traversal (`..` / `/`) と制御文字 (C0 / DEL / C1 8-bit) を拒否。形式は問わない | 厳格 RFC 4122 形（`8-4-4-4-12` hex、case-lenient、lowercase 正規化） |
| 受理 | 安全な opaque token | canonical UUID のみ |
| 利用 | runtime adapter、`flow-state.sh` の `path` / `set` / `get` 等 | `issue-claim.sh`、`scripts/wiki-ingest-lock.sh`、cross-session guard |

Layer 1 はファイルパスと診断出力の安全性、Layer 2 は所有者識別の形式を扱う。
**両者を統一してはならない。** `flow-state.sh` を strict UUID 必須にすると、opaque SID を
使う hook/tooling が per-session 経路を使えなくなる。既存の `flow-state.test.sh` の
opaque SID round-trip を正の契約として維持する。

## ホスト ID の選択

`session-identity.sh` は配布プラグインだけで動作し、開発環境の bootstrap を要求しない。

| 入力 | 選択する実 ID |
|---|---|
| `RITE_HOST=claude` | `CLAUDE_CODE_SESSION_ID`、空なら `CLAUDE_SESSION_ID` |
| `RITE_HOST=codex` | `CODEX_THREAD_ID` |
| `RITE_HOST=grok` | `GROK_SESSION_ID` |

- 明示 `--session` がある state/claim/lock コマンドは、その値を最優先する。
  runtime の有無や別ホストの環境変数に左右されず、呼出先の Layer 1 / Layer 2 で検証する。
- `RITE_HOST` は ID の**選択入力**であり、hook 機能の有無を宣言しない。明示選択時は
  他ホストの環境変数が異なる ID でも無視する。選択先が空・欠落・不正なら停止する。
- `RITE_HOST` 未指定では、環境変数が存在するホスト群が 1 つなら自動選択する。
  Claude の 2 変数は同じ群で、従来の `CLAUDE_CODE_SESSION_ID` 優先を維持する。
  Codex/Grok の変数が明示的に空の場合もそのホストを検出し、欠落 ID として停止する。
- 複数のホスト群が存在すれば、同じ ID であっても曖昧として停止し、`RITE_HOST` の
  指定を診断に示す。不明な `RITE_HOST` もエラーとする。
- ホスト名による ID の加工・固定 ID の代入・共有ファイルからの借用は行わない。
  UUID の大文字は Layer 2 と同じ小文字表記に正規化し、opaque ID はそのまま使う。

実行形式 `bash session-identity.sh` と source 後の `resolve_runtime_session_id` は、
成功時に実 ID を stdout へ出力する。rc=0 は選択成功、rc=1 は診断付きエラー、
rc=2 は runtime context 不在（既存 file / Claude payload 互換経路を使用可能）を表す。
エラー時の stdout は空。rc=1 を rc=2 と同じ fallback に変換してはならない。

## 共有ファイルとの互換性と失敗時の境界

runtime context がない場合に限り、`flow-state.sh` は `.rite/session-id`、なければ
旧 `.rite-session-id` を読み Layer 1 で検証する。新ファイルが存在して不正な場合は、
有効な旧ファイルへ倒れない。claim / wiki lock は同じ選択順で
`_resolve-session-id-from-file.sh` の Layer 2 検証を使う。

`resolve_strict_session_id <state_root> [override]` はこの順序を ownership consumer に
提供する。選択された runtime / override が UUID でなければエラーで停止し、共有の
session-id を試さない。旧 file helper 単体の「不在 / 不正なら空文字」の契約は維持する。

flow-state、run queue（`path` の basename）、claim、work memory の state 読取、wiki lock は
同じ選択された ID を使う。同じ実 ID で再開すれば既存の所有権を再利用できる。
`flow-state.sh get` は runtime の選択・検証エラーを nonzero で伝播する。
従来の runtime 不在かつ stored ID 不在の場合だけは、診断と `--default` を返す互換動作を維持する。

`issue-comment-wm-sync.sh` / `cleanup-work-memory.sh` の legacy fallback は runtime 不在に
限定する。runtime identity の失敗時は、legacy state の書込、WM の更新・削除、claim / lock の
取得・解放を行わない。runtime を持つ cleanup は自身の state に記録された Issue の WM のみ削除する。

## 検証

- `runtime-session-identity.test.sh`: 3 ホストの同時 state / claim / queue / WM、lock の排他、
  同一 ID 再開、選択優先、欠落・不正・競合時に foreign / legacy が不変であること。
- `flow-state.test.sh`: opaque ID の path / set / get round-trip（Layer 1 を strict にしない）。
- `issue-claim.test.sh` / `wiki-ingest-lock.test.sh`: UUID ownership と env-first / file fallback 互換。
- `run-tests.sh` は ambient な Claude / Codex / Grok ID、`RITE_HOST`、runtime mode / state root を解除する。

## 関連

- [Host Runtime Contract](./host-runtime-contract.md)
- [State Read Contracts](./state-read-evolution.md)
- `_resolve-cross-session-guard.sh` — legacy state 内の SID の strict 検証
