# Session ID Validation Contract (SoT)

> rite workflow には session_id を検証する validator が **2 つ** 存在し、それぞれ
> **異なる契約**を持つ。本ドキュメントは、その責務分担と「両者を乖離させたまま維持する」
> 契約の Source of Truth (SoT) である。判定ロジックそのものの SoT は各実装ファイルだが、
> **なぜ 2 つに分かれているか / 統一してはいけない理由**の SoT は本書とする。

---

## 2 つの validator、2 つの関心事

| | Layer 1: security boundary | Layer 2: format / identity |
|---|---|---|
| 実装 | `flow-state.sh` の `_validate_session_id` | `_resolve-session-id.sh` |
| 検証内容 | path-traversal (`..` / `/`) と制御文字 (C0 / DEL / C1 8-bit) のみ拒否。**形式は問わない** | 厳格 RFC 4122（`8-4-4-4-12` hex、case-lenient、lowercase 正規化） |
| 通すもの | 任意の opaque token（例: `session-aaaa-1371`） | canonical UUID のみ |
| 関心事 | session_id が**ファイルパス構築・ログ出力に流れる chokepoint** を安全に保つこと（path-traversal / log-injection 遮断） | 候補文字列が **canonical UUID かどうか**を判定し、per-session state file と legacy 単一ファイル fallback を切り分けること |
| 適用経路 | `flow-state.sh` の `_resolve_session_id`（override / `.rite/session-id` with legacy `.rite-session-id` read fallback / `CLAUDE_CODE_SESSION_ID` / `CLAUDE_SESSION_ID`）→ `path` / `set` / `get` 各サブコマンド | `_resolve-session-id-from-file.sh`（new then legacy file 読込 → strict 検証 → 失敗時空文字復帰。新ファイルが不正なら旧 valid へは倒れない）経由で `issue-claim.sh` / `scripts/wiki-ingest-lock.sh`、および cross-session guard（`_resolve-cross-session-guard.sh` が `_resolve-session-id.sh` を直接呼び legacy sid を UUID 検証） |

## なぜ乖離しているか（drift ではなく意図的）

- **Layer 1** は session_id が「filesystem path の一部」または「stderr のログ行」になる単一の
  chokepoint を守る。その唯一の仕事はその操作を**安全**にすること（`.rite/sessions/{sid}.flow-state`
  の外へ書き込ませない、偽の `WARNING:` 行を注入させない）。UUID 形式を**あえて強制しない**ことで、
  - hook test / tooling が可読な opaque sid を使える
  - UUID 形ではない非 Code クライアント由来 / 将来の runtime 識別子でも動作する

- **Layer 2** は、ある文字列が「本物の session id か、ゴミか」を判定して per-session state file を
  選ぶか legacy 単一ファイルへ fallback するかを決める箇所で使う
  (`_resolve-session-id-from-file.sh` → `issue-claim.sh` / `scripts/wiki-ingest-lock.sh`)。ここでの厳格さこそが、その判定を
  decidable にしている。検証失敗時は空文字を返し、caller は「session 不在」相当として legacy 経路へ
  降格する。

両者は**異なるレイヤー**（安全な path 構築 vs 同一性 / 形式判定）で、**異なる問い**に答える。
見た目が似た「session_id validator」だからといって統一すると、安全な path 構築が UUID 形に
結合し、下記の silent-vacuous リスクを再導入する。

## 契約（SoT）

1. **`flow-state.sh` の path validation は format-agnostic を維持する MUST。**
   `flow-state.sh` の `_resolve_session_id` を `_resolve-session-id.sh`（strict UUID）経由に
   切り替えたり、Layer 1 validator に UUID 形式チェックを追加してはならない。

   - **理由**: 複数の hook test が非 UUID opaque sid を `flow-state.sh` に直接渡し、その受理に
     依存している。代表例として `pre-compact.test.sh` の TC-per-session-compact-independence-AC1 は
     `CLAUDE_CODE_SESSION_ID="session-aaaa-1371"` / `"session-bbbb-1371"` を設定し、
     `pre-compact.sh` 内の `flow-state.sh path`（Layer 1 経由）が
     `.rite/sessions/session-aaaa-1371.compact-state` 等へ解決することを期待する。
     もし Layer 1 が strict UUID 検証を採用すると、これらの sid は解決に失敗 / legacy 経路へ
     降格し、test は **loud に失敗するのではなく silent に vacuous 化**する（意図した per-session
     経路ではなく legacy 単一ファイル経路を検証してしまう）。

2. **2 つの validator を統一（DRY 化）してはならない。** 上記のとおり別レイヤー・別関心事であり、
   統一は safe-path-construction を UUID-shape に結合させ silent-vacuous リスクを再導入する。

3. **正の契約は executable test で pin する。** `flow-state.test.sh` の TC-24 が、非 UUID opaque
   sid が `flow-state.sh` の `path` / `set` / `get` を round-trip することを assert する。将来 Layer 1
   を strict 化すると TC-24 が loud に落ち、silent-vacuous リスクを **CI 失敗に変換**する。

## Layer 1（緩い契約）に依存するテスト

以下のテストは非 UUID sid を使い、`flow-state.sh` がそれを受理することに依存する:

- `pre-compact.test.sh` — `session-aaaa-1371` / `session-bbbb-1371`（TC-per-session-compact-independence-AC1 が使う非 UUID opaque sid fixture）
- `pre-compact.test.sh` / `post-compact.test.sh` / `session-start.test.sh` —
  test helper の default sid `test-sid-<dir>`（非 UUID 形）
- `flow-state.test.sh` — TC-24（本契約を pin する正のテスト）

> 将来これらを UUID sid へ移行する場合は、本一覧を更新し、Layer 1 契約を format-agnostic に
> 保つ必要が依然あるかを再評価すること。

## 関連

- `flow-state.sh` `_validate_session_id` — Layer 1 validator（判定ロジック自体の SoT）
- `_resolve-session-id.sh` — Layer 2 validator（strict RFC 4122）
- `_resolve-session-id-from-file.sh` — Layer 2 consumer（file 読込 → strict 検証 → legacy fallback）
- [state-read.sh Evolution History](./state-read-evolution.md) — helper 集約の経緯（cycle 34 F-01 で UUID validation を DRY 化）
- [multi-session-state.md](../../../docs/designs/multi-session-state.md) — per-session state file 構造
