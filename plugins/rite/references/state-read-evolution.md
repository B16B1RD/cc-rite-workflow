# state-read.sh Evolution History

> 本ドキュメントは `plugins/rite/hooks/state-read.sh` の verified-review cycle 5〜43+ における
> 構造的修正の経緯を記録します。実装の現在の契約は `state-read.sh` 自身を SoT として参照してください。
>
> **目的**: state-read.sh から「歴史的経緯コメント」を分離することで、実装ファイルを「why this exists」と
> 「現在の契約」「機能説明」に集中させる。本書は実装読解の障害となる evolution 説明の保管庫として機能する。
>
> **背景 Issue**: state-read.sh は Issue #687（writer/reader 片肺更新型 silent regression）を解消する
> read helper として PR #688 で導入された。PR は 43+ cycle の verified-review を経て develop にマージされる。
> 各 cycle で検出された anti-pattern を構造的に解消した結果、`state-read.sh` 自身のコメント密度は
> peak で 51〜64% まで増加し、Issue #694 で本ドキュメントへの履歴外出しと併せて約 48%（執筆時点
> の `awk` 計測値）に再収束した。歴史的経緯への参照は本ドキュメントを SoT とする。

---

## Doctrines / Principles

state-read.sh の構造を支配する 3 つの doctrine。本 helper の各 fix はこれらの doctrine の一貫性を
維持するために行われた。

### writer/reader 対称化 doctrine

state-read.sh と `flow-state-update.sh` は同じ flow-state ファイルに対する reader/writer ペア。
同型の logic は両方に同期更新する。Issue #687 の root cause がこの doctrine 違反の典型
（writer 側 guard を cycle 32 で追加、reader 側 guard を cycle 33 で後追い → 片肺更新 drift）。

派生原則: 同形 logic を持つ helper への抽出を最優先（個別 inline は構造的破綻の発生源）。

### DRIFT-CHECK ANCHOR は semantic name 参照

hardcoded 行番号（例: `_resolve-cross-session-guard.sh:93-98`）は drift 源になる。
`# >>> DRIFT-CHECK ANCHOR: <name> <<<` 形式で semantic name 参照する（cycle 38 F-04 / cycle 40 で確立）。
helper の API 契約（header コメント）を SoT として尊重する記述を採用する。

### Form A cleanup minimal contract

`rm -f` 単一行の cleanup 関数は `return 0` 不要（rm -f の rc=0 で十分）。
`commands/pr/references/bash-trap-patterns.md` の Form A 規範に従う最小性 doctrine。
`_resolve-cross-session-guard.sh` の Form A cleanup と統一。

---

## 集約された helper

state-read.sh と flow-state-update.sh で重複していた logic を以下の helper に集約した。
helper を追加する際は `_validate-helpers.sh` 内 `DEFAULT_HELPERS` への 1 行追加のみで両 caller に反映される。

> **Note**: 「関連 cycle」列は **代表的な cycle のみ** を列挙する (helper の起点となった集約 fix が中心)。
> 各 helper の使用サイト周りで適用された全 cycle のリストは下記「Cycle 別の主要な修正」節を参照のこと。
>
> **`DEFAULT_HELPERS` 配列との対応関係**: 本表は **集約 helper 7 件** を列挙するが、`_validate-helpers.sh` の
> `DEFAULT_HELPERS` 配列には **合計 8 件** が登録されている。差分の 1 件は `state-path-resolve.sh` で、
> これは集約 helper ではなく state-read.sh の冒頭 (`STATE_ROOT="$("$SCRIPT_DIR/state-path-resolve.sh" ...)`)
> から直接利用する **base resolver** (= STATE_ROOT 解決の入口) のため、本表からは除外している。
> 「表 7 件 = `DEFAULT_HELPERS` 8 件」の数字差分はこの base resolver 1 件分を反映する。

| helper | 集約された機能 | 関連 cycle |
|--------|---------------|-----------|
| `_validate-helpers.sh` | helper 存在検査 + DEFAULT_HELPERS 配列（helper-list の SoT） | cycle 12 F-04 / 13 F-01 / 38 F-01 |
| `_resolve-session-id.sh` | UUID validation（RFC 4122 strict pattern） | cycle 34 F-01 CRITICAL |
| `_resolve-session-id-from-file.sh` | tr + UUID validate + fallback の compound sequence | cycle 38 F-05 MEDIUM |
| `_resolve-schema-version.sh` | schema_version 解決 + pipefail silent failure 対策 | cycle 5 review |
| `_resolve-cross-session-guard.sh` | foreign / corrupt / invalid_uuid classification | cycle 34 F-02 / 35 F-01 / 41 F-01 / 14 F-04 |
| `_emit-cross-session-incident.sh` | 3 classification × 2 caller の workflow-incident-emit 集約 | PR #688 followup F-01 MEDIUM |
| `_mktemp-stderr-guard.sh` | mktemp + WARNING 3 行 + chmod 600 のパターン集約 | cycle 9 F-02 / 15 F-05 / 38 F-06 |
| `_validate-state-root.sh` | STATE_ROOT path traversal + shell metacharacter + control character 検証 | post-cycle-44 re-review (M-1) |
| `state-path-resolve.sh` (参考: base resolver) | STATE_ROOT 解決の入口 (集約ではないが `DEFAULT_HELPERS` には登録) | (該当なし — base resolver) |

---

## Cycle 別の主要な修正

### Cycle 5 review: writer/reader DRY 化（schema_version）

writer/reader で同一の inline schema_version 解決 logic を持っていた drift リスクを排除するため、
`_resolve-schema-version.sh` 共通 helper に抽出。pipefail silent failure 対策（Issue #687 AC-4 follow-up）も
helper 内で吸収する。

### Cycle 5 test reviewer: 空ファイル edge case（F-C MEDIUM）

旧実装は file 存在チェックのみで、空ファイル（`touch .rite-flow-state` 等）や非 JSON ファイル
（例: 別プロセスが書き込み中）の場合に jq が exit 0 + 空出力を返す → caller default が
効かず空文字列を silent return する経路があった。`[ -s "$STATE_FILE" ]`（size > 0）を追加して
空ファイル時も DEFAULT に落とす（corrupt JSON 経路と挙動を一致させる）。

### Cycle 9（F-01 HIGH / F-02 MEDIUM）: writer/reader 対称化と mktemp helper 集約

- **F-01**: `_resolve-cross-session-guard.sh` 呼び出しの `||` rc capture pattern を writer 側にも適用
  （helper の design contract `exit 0 — always` が将来 regression したときに silent fail しないよう、
  rc を捕捉して非 0 時に WARNING を emit する）。
- **F-02**: 6 hook scripts で重複していた `mktemp + WARNING + chmod 600` を `_mktemp-stderr-guard.sh` に集約。

### Cycle 12（F-04 MEDIUM）/ Cycle 13（F-01 HIGH）: helper-list SoT 集約

- **Cycle 12**: helper existence check の **validation logic** を `_validate-helpers.sh` に集約。
- **Cycle 13**: helper 名 list 自体も `_validate-helpers.sh` 内の `DEFAULT_HELPERS` 配列に集約。
  state-read.sh と flow-state-update.sh の helper-list 重複が構造的に解消され、helper 追加時は
  `_validate-helpers.sh` 内 `DEFAULT_HELPERS` への 1 行追加のみで両 caller に反映される
  （Issue #687 root cause と同型の片肺更新 drift を別 layer で再発させない構造的実装）。

### Cycle 14（F-04 MEDIUM）: hardcoded 行番号 → semantic anchor

`_resolve-cross-session-guard.sh:93-98` / `_mktemp-stderr-guard.sh:36-37 / 47-48` のような
hardcoded 行番号参照を「DRIFT-CHECK ANCHOR は semantic name 参照」doctrine に従って削除し、
helper の API 契約（header コメント）を SoT として尊重する記述に置換。

### Cycle 15（F-05 MEDIUM）: writer/reader 対称化 doctrine 構造的破綻の解消

旧実装は `_classify_err` 用の `mktemp + WARNING 3 行 + chmod 600` を 6 行 inline で書き、
`_mktemp-stderr-guard.sh` の F-02 consolidation スコープから漏れていた。helper API は本ケースを
完全にサポート可能（caller_id / template_suffix / impact_msg を引数化済、chmod 600 は helper 内蔵）。
残置は writer/reader 対称化 doctrine の構造的破綻 — 将来 WARNING 文言や chmod 仕様を変更する際に
両 site 同期更新が必要で、Issue #687 root cause と同型の片肺更新 drift を再導入するリスクがあった。
`_resolve-cross-session-guard.sh`（cycle 9 F-02 で集約済み）と同じ pattern に統一。

### Cycle 34

- **F-01 CRITICAL**: UUID validation を `_resolve-session-id.sh` に抽出。重複していた RFC 4122 strict
  pattern の内訳は **5 sites across 3 files**: `state-read.sh` ×1 + `flow-state-update.sh` ×3 +
  `resume-active-flag-restore.sh` ×1（commit 48bb21b の commit message に当時の内訳が明記）。
  1 箇所に集約することで、将来の pattern tightening（variant bit check 等）を片肺更新 drift から守る。
- **F-02 HIGH**: cross-session guard を `_resolve-cross-session-guard.sh` に抽出。writer 側
  （`flow-state-update.sh _resolve_session_state_path`）と reader 側（state-read.sh）で重複していた
  legacy.session_id 抽出 + 比較 + corrupt 判定ロジックを 1 箇所に集約し、Issue #687 root cause
  「writer-side guard を cycle 32 で追加、reader-side guard を cycle 33 で後追い」型の片肺更新 drift を
  構造的に防ぐ。
- **F-09**（cycle 38 F-01 HIGH + F-09 MEDIUM と関連）: helper 存在検査の対象を `state-path-resolve.sh` のみから
  全 direct/transitive helper に拡張。`bash <missing>` invocation 経路で依存する helper が install 不整合 /
  deploy regression で missing の場合、bash は exit 127 を返すが `set -euo pipefail` の中でも
  `if`/`else`/`||` 文脈では非ブロッキング扱いとなり、silent fall-through 経路が散在する。
  Issue #687（writer/reader 片肺更新型 silent regression）と同型の deploy regression を構造的に塞ぐため、
  依存する全 helper を upfront で fail-fast 検査する。
- **F-11 MEDIUM**: boolean field 誤呼出の mechanical guard。`--default true|false` 検出時に WARNING を emit
  （`{"active": false}` を `--default true` で読むと結果が "true" になる silent regression を
  defense-in-depth で防ぐ）。

### Cycle 35

- **F-01 CRITICAL**: `2>&1` → `2>/dev/null` 修正。`2>&1` は helper の stderr（jq parse error text）を
  classification 文字列に merge して `case "$classification" in corrupt:*) ...` matching を破壊し、
  Issue #687 が specifically introduce した `legacy_state_corrupt` sentinel emit を silent suppress していた。
  helper 側で stderr clean を保証（cycle 35 fix in `_resolve-cross-session-guard.sh`）した上で
  `2>/dev/null` を採用。
- **F-05 / 36 F-15**: trap install を file 冒頭に統合し、`_classify_err` と `_jq_err` を共通の
  `_rite_state_read_cleanup` 関数で cleanup する canonical pattern。
  旧実装は jq stderr 用に `_jq_err` 専用の trap を install し、`_classify_err`（per-session resolver の
  case classification block で declare される変数）は trap 不在の race window を残していた。
- **F-09 LOW**: jq stderr を `2>/dev/null` で抑制せず tempfile に退避し、jq 失敗時に `head -3` で WARNING emit。
  `_resolve-cross-session-guard.sh` の jq stderr capture pattern（cycle 33 F-04 / cycle 34 F-07 fixes）と
  symmetric。

### Cycle 38

- **F-04 MEDIUM**: self-referential drift 修正。旧コメントは「Symmetric with state-read.sh L58」と
  `state-read.sh` 自身の `--field arg parser` ブロック（jq stderr capture とは無関係）を誤参照していた
  self-referential drift。意図したのは `_resolve-cross-session-guard.sh` の jq stderr capture 経路
  （`legacy_sid=$(jq ... 2>"$jq_err")`）で、cycle 33 F-04 / cycle 34 F-07 fix 系列はそちらのパターンを
  確立した。本 PR が警戒する "self-referential drift fractal pattern" の再発を修正。
- **F-05 MEDIUM**: tr + `_resolve-session-id.sh` + fallback の compound sequence 自体も 3 site で重複していた
  （`state-read.sh` / `flow-state-update.sh` / `resume-active-flag-restore.sh`）。`_resolve-session-id-from-file.sh`
  共通 helper に抽出し、将来「hex normalize / base64 UUID」等の上流動作変更で同型片肺更新 drift が
  発生しない設計に転換（writer/reader/resume 3 layer の DRY 化）。
- **F-06 MEDIUM**: mktemp 失敗時の WARNING 必須化。`2>/dev/null || _jq_err=""` で mktemp 失敗
  （/tmp full / permission denied / SELinux deny）を silent fallback すると、後続の
  `2>"${_jq_err:-/dev/null}"` で jq stderr が `/dev/null` に redirect される二重 silent failure になる
  （jq 失敗時の `head -3 _jq_err` 観測経路が無効化）。

### Cycle 41（F-01 HIGH）: WARNING pass-through

helper の正当な WARNING（cycle 39 H-02 で `_resolve-cross-session-guard.sh` の `_mktemp-stderr-guard.sh`
呼び出しブロックに追加された mktemp 失敗 WARNING）が `2>/dev/null` で silent suppress される問題を修正。
stderr を tempfile に退避し、`^WARNING:` で始まる行のみ caller chain に pass-through する。
`/tmp full` / SELinux deny 環境で helper 側の詳細が両層で失われる二重 silent failure を防ぐ
（writer/reader 対称化 doctrine と整合）。

### Cycle 43（F-09 MEDIUM）: mktemp canonical pattern 統一

`_classify_err` mktemp 失敗時の silent fallback を canonical pattern（`if ! ... then` + WARNING 3 行 +
chmod 600）に揃える。旧実装 `|| _classify_err=""` は mktemp 失敗を WARNING なしで silent fallback し、
後続の `2>"${_classify_err:-/dev/null}"` で helper の WARNING（cycle 39 H-02 で追加）が消える入れ子の
silent failure になっていた（cycle 41 F-01 のコメント「pass-through する」と乖離）。
他 5 helper（state-read.sh `_jq_err` / `_resolve-cross-session-guard.sh` /
flow-state-update.sh ×2 / resume-active-flag-restore.sh / `_resolve-session-id-from-file.sh _tr_err`）の
canonical pattern と統一する。trap 統合は別 Issue で追跡（実行時間が短いため race window 小）。

### PR #688 followup（F-01 MEDIUM）: cross-session-incident emit 集約

`foreign:*` / `corrupt:*` / `invalid_uuid:*` arm の `workflow-incident-emit.sh` 呼び出しブロックを
`_emit-cross-session-incident.sh` helper に集約。reader/writer × 3 classification の 6 ブロック
（~84 行）が semantically identical だった drift リスクを排除する。

### PR #688 post-cycle-44 re-review run

`/verified-review` を再実行した際の review results。本節は cycle 番号が cycle 1〜44 シリーズの後に
1〜15 で再採番された経緯（[`workflow-incident-emit-protocol.md` Revision Log の reading note](workflow-incident-emit-protocol.md#revision-log) と同じ）を反映する。

- **F-03 / F11-08（`{parent_issue_number}` placeholder）**: `commands/issue/start.md` の
  `{parent_issue_number}` placeholder description に embed していた fix-cycle reference を本書に外出し。
  Workflow Termination は Phase 5.7 の `[CONTEXT] PARENT_ISSUE=...` emit を LLM-routing signal として
  使い、state を re-read しない。
- **cycle 38 F-17**: 上記 placeholder description から literal block を削除。Workflow Termination
  内に capture pattern を再注入してはならない（cycle 9 F-06 regression 経路の防止）。
- **cycle 9 F-06**: parent issue capture pattern を Workflow Termination に再注入する drift を防ぐ
  ための regression guard。Phase 5.7 / 5.1.2（implement.md）の canonical fail-fast capture pattern
  を SoT とする。
- **`_resolve-cross-session-guard.sh` の inline cycle reference 整理**: 各 cycle 番号付き
  fix-history block を本ドキュメントの該当節に集約し、helper 内のコメントは「現在の契約」と
  「Why this exists」に絞り込んだ（コメント密度の peak 51〜64% → ~48% への再収束に貢献）。
- **`_validate-state-root.sh` 抽出**: `_resolve-session-id-from-file.sh` と
  `_resolve-schema-version.sh` で byte-for-byte 18 行重複していた STATE_ROOT validation block
  （path traversal + shell metacharacter + control character 検証）を新 helper に集約。
  両 caller は 1 行の helper invocation に置換し、`_validate-helpers.sh` 内 `DEFAULT_HELPERS`
  にも追加（writer/reader/schema 3 layer の validation 対称化 doctrine を 1 つの helper で表現）。

---

## 現在の契約（state-read.sh 自身を参照）

以下は state-read.sh のコード本体に **現在の契約** として保持されているもの。本書ではなく
state-read.sh のコメントを SoT として参照する：

- **Why this exists**（Issue #687 AC-4）: schema_version=2 で per-session file に書く writer に対し、
  inline `jq -r '.<field>' .rite-flow-state` で読む reader が stale な legacy ファイルを silent に読む regression
- **Resolution order**: per-session → legacy → DEFAULT
- **Boolean field caveat**: `// $default` operator が JSON null と false の両方を default に置換するため、
  本 helper は boolean field 読み取りに使ってはいけない
- **JSON null handling**: jq の `// $default` operator が null/false 正規化を ネイティブで行う

---

## 関連

- 元 PR: #688
- 関連 Issue: #687（本体）, #694（本ドキュメントの分離）
- 関連 Wiki (これらのページは `wiki` ブランチに保存されています。develop ブランチでは `.rite/wiki/pages/` 配下が空のため、閲覧時は `git show wiki:.rite/wiki/pages/anti-patterns/asymmetric-fix-transcription.md` のように `git show` で参照するか、`/rite:wiki:query <キーワード>` を実行して該当ページの内容を取得してください):
  - `.rite/wiki/pages/anti-patterns/asymmetric-fix-transcription.md`
  - `.rite/wiki/pages/patterns/drift-check-anchor-semantic-name.md`
  - `.rite/wiki/pages/heuristics/design-doc-current-head-verification.md`
  - `.rite/wiki/pages/heuristics/sot-path-reference-existence-check.md`
