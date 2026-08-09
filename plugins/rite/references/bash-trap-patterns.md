# Bash Trap + Cleanup Patterns

> **Charter**: Subject to [Simplification Charter](../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

採用 site は `skills/fix/SKILL.md` / `skills/pr-review/SKILL.md` / `skills/open/SKILL.md` /
`skills/merge/SKILL.md` / `skills/wiki-lint/SKILL.md` / `skills/wiki-ingest/SKILL.md` /
`skills/cleanup/SKILL.md` ステップ 5。旧 `commands/` 時代の path は対象外。
本ファイルは **signal-specific trap + cleanup function パターン**の canonical 定義と根拠を集約する。
各 bash block の冒頭では本ファイルへの anchor 参照を pointer コメントとして置く。

> **⚠️ コード層との境界**: rationale / 説明文は本ファイル 1 箇所に集約されるが、cleanup 関数本体と
> 4 行 trap (`EXIT`/`INT`/`TERM`/`HUP`) は対象 5 ファイル各 site にコードとして存在する。signal 動作
> そのものの変更 (HUP 追加、TERM exit code 変更等) は本ファイル更新後に全採用 site の
> 4 行 trap を同時更新すること。

---

## Signal-Specific Trap Template

<a id="signal-specific-trap-template"></a>

> **新規の `hooks/` / `scripts/` helper が tempfile / tempdir を必要とする場合、本テンプレートを手書きせず `hooks/scripts/lib/tempfile.sh` を source する**（`rite_tempfile_init` → `rite_tempfile_new <outvar> [tag]`）。lib は下記の 4 行 trap をそのまま実装したうえで、生成と cleanup 登録を不可分にする。規約の SoT は [coding-principles.md](../skills/rite-workflow/references/coding-principles.md#shell-helper-conventions)「Shell Helper Conventions」。本テンプレートは lib を使えない site（tempfile 以外の cleanup、lib 自身）と既存 site 向けの canonical 定義として残る。

canonical パターン:

```bash
# 1. cleanup 対象変数の先行宣言 (未定義時 silent no-op 化のため空文字列で初期化)
tmpfile=""
jq_err=""
# ... 追加の cleanup 対象変数 ...

# 2. cleanup 関数定義 (責務: rm -f のみ。exit を含めてはならない / return 値は形式により異なる
#    — Form A 採用時は不要、Form B 採用時は末尾に return 0 必須。下記「cleanup 関数の契約」節参照)
_rite_<phase>_cleanup() {
  rm -f "${tmpfile:-}" "${jq_err:-}"
  # ... site-specific な conditional cleanup logic (例: 2-state commit pattern) ...
  # Form B (`[ -n "${var:-}" ] && rm -f "$var"` 形式) を採用する場合は末尾に `return 0` を追加すること
}

# 3. signal 別 trap (4 行): EXIT は元 exit code を保持、INT/TERM/HUP は明示的 exit code を返す
trap 'rc=$?; _rite_<phase>_cleanup; exit $rc' EXIT
trap '_rite_<phase>_cleanup; exit 130' INT
trap '_rite_<phase>_cleanup; exit 143' TERM
trap '_rite_<phase>_cleanup; exit 129' HUP

# 4. この時点で trap は武装済み。mktemp や主処理はこの後に実行する。
tmpfile=$(mktemp) || { ... ; exit 1; }
```

**Instantiation の手順**:

1. cleanup 対象となる全変数を空文字列で先行宣言する (mktemp 実行前)
2. `_rite_<phase>_cleanup` 関数内で `"${var:-}"` 形式で列挙する
3. 4 行の trap を関数定義**直後**に設置する (mktemp 前)
4. mktemp / 主処理を trap 武装後に実行する

---

## Rationale (なぜこの 4 行構造が必要か)

### EXIT trap 単独では不十分

bash の EXIT trap は SIGTERM/SIGHUP/SIGINT でも発火するが、**INT/TERM/HUP の trap action に
明示的な `exit <code>` が無いと bash は signal を consume して次のコマンドへ制御を渡す**
(silent continuation)。`exit 130` を省略すると SIGINT 到達後に cleanup 実行後、bash が block 内の
残命令 (mapfile / for / case 等) を**不完全な状態で継続実行**する debug 困難な silent failure を生む。

### signal 別 exit code (POSIX 慣習: 128 + signal number)

| signal  | exit code | 意味                     |
|---------|-----------|--------------------------|
| SIGINT  | 130       | Ctrl+C / `kill -INT`     |
| SIGTERM | 143       | `kill -TERM` (timeout 等) |
| SIGHUP  | 129       | 端末切断 / session 終了   |

signal 受信時の `$?` は「最後に完了したコマンドの exit status」であり 130/143/129 を set するとは
限らない (例: `printf` 成功直後に SIGTERM が来ると `rc=0` で上位の loop 制御が「正常終了」と誤判定)。
signal 別 trap で**明示的に exit 130/143/129 を返す**ことでこれを防ぐ。

### EXIT trap の `rc=$?` capture (bash classic pitfall)

EXIT trap 発火時点で `$?` は元の exit status を保持するが、cleanup 関数を実行すると関数最後の
コマンド (`rm -f` 等) の戻り値で `$?` が**上書き**される。`trap '_rite_<phase>_cleanup; exit $?' EXIT`
は exit code が常に 0 (rm -f の戻り値) になる致命的バグを生み、block 内の全 `exit 1` が silent に
exit 0 に変換される。**必ず `rc=$?` で関数呼び出し前に元の exit code を保存**してから cleanup → `exit $rc`:

```bash
trap 'rc=$?; _rite_<phase>_cleanup; exit $rc' EXIT
```

### cleanup 関数の契約 (Form A / Form B)

cleanup 関数の責務は **rm -f などの cleanup 操作のみ**で、exit code を変更してはならない。
関数内に `exit` を追加すると signal 別 trap が期待する exit code (130/143/129) を上書きして
silent exit 0 regression を誘発する。return 値の扱いは形式により異なる:

**Form A — `rm -f "${var:-}"` 形式** (短絡なし、rm の rc が常に 0):

```bash
_rite_<scope>_<phase>_cleanup() {
  rm -f "${var:-}"
}
```

`rm -f` が常に 0 を返すため、`rc=$?` で保存済みの元 exit code が trap action の `exit $rc` まで
保持される (関数戻り値は実質無視される)。

**Form B — `[ -n "${var:-}" ] && rm -f "$var"` portability variant** (BSD/macOS 対応):

```bash
_rite_<scope>_<phase>_cleanup() {
  [ -n "${var:-}" ] && rm -f "$var"
  return 0  # set -euo pipefail 下で必須、それ以外でも preemptive defense として無条件推奨
}
```

`var=""` 時に `[ -n "" ]` が rc=1 で短絡し関数末尾の戻り値が 1 になる。`set -euo pipefail` 下で
cleanup が非 0 を返すと **set -e が trap action を中断し後続の `exit $rc` に到達しない** (cleanup の
rc が script exit code として伝播)。`return 0` のみが silent regression を防ぐ唯一の手段であり、
trap action 側の `rc=$?` capture は Form B では機能しない。

`set -e` が無効な caller でも **`return 0` を無条件追加する**: (1) 将来 `set -e` 導入で silent
regression を起こす経路を防ぐ、(2) Form B 単一規範に揃え Asymmetric Fix Transcription の drift を防ぐ。

**まとめ**: Form A → 戻り値無視 OK、Form B → `return 0` 必須。

### `${var:-}` と空引数ガード variant (BSD/macOS rm 対応)

`rm -f "${var:-}"` は `var` が未定義/空文字列のとき `rm -f ""` の silent no-op となり、cleanup が
mktemp 失敗経路や早期 exit 経路で呼ばれても安全に動作する (defense-in-depth)。ただし一部の
BSD/macOS rm (coreutils 非採用環境) では stderr に `cannot remove ''` を出力する場合がある。
portable に保ちたい場合は明示的な空引数ガード (Form B) を使う:

```bash
_rite_<scope>_<phase>_cleanup() {
  [ -n "${var1:-}" ] && rm -f "$var1"
  [ -n "${var2:-}" ] && rm -f "$var2"
  return 0
}
```

推奨条件: (1) cleanup が mktemp 失敗経路を通る可能性がある site、かつ (2) BSD/macOS ユーザーが
実行する可能性がある site (`plugins/rite/` は multi-OS target)。Linux-only CI 等の GNU rm 限定 site
では `rm -f "${var:-}"` のままで問題ない。

#### 採用 site (canonical 参照実装)

- `plugins/rite/skills/wiki-lint/SKILL.md` ステップ 2.2 / 6.0 / 6.2 / 8.3
  - うち **ステップ 6.0 / 6.2** の trap/cleanup 関数実体は `hooks/scripts/wiki-lint-skipped-refs.sh` /
    `wiki-lint-source-refs.sh` へ移設済みで、lint.md 側の bash block は helper を呼び出すだけ (本ファイル
    「Case Statement Indent Convention」節の「参照実装」サブ節の委譲注記と同一の実態)。lint.md 内に inline で残る trap/cleanup は
    **ステップ 2.2 / 8.3** の 2 site (`_cleanup` 定義 + 4 行 trap が lint.md 本文に存在)。
- `plugins/rite/skills/wiki-ingest/SKILL.md` ステップ 2.2 / 2.3 / 5.2

#### 命名規約

- 形式: `_rite_<scope>_<phase>_cleanup`
- `<scope>`: site 識別の接頭辞 (例: `wiki_lint`, `wiki_ingest`, `fix`, `review`, `start`)
- `<phase>`: ステップ/Phase 番号の**小数点を除いた連結形式** (drift 防止)。例: `ステップ 2.2` → `phase22`、
  `ステップ 6.0` → `phase60`、`ステップ 2` → `phase2`、`Phase 6.1` → `phase61` (caller 側 pr/* の Phase 構造維持文脈)
- 短縮形 `_rite_p{NN}_cleanup` は使用しない (scope 不在で複数 site と衝突する)

> **Note**: function 名の `phase{NN}` token は**規約確立時の命名 history を保持**するため、見出しが
> `Phase` → `ステップ` に変わっても **function 名 token は `phase` を維持** すること (新規 site が
> `_rite_<scope>_step22_cleanup` のような `step` 形式を導入してはならない)。既存 site の旧命名
> (`_rite_wiki_lint_phase2_cleanup` 等) も維持し、一括リネームは行わない。
> ステップ 2.2 site (`wiki/lint.md`) は `phase22` 規約確立前の実装で `_rite_wiki_lint_phase2_cleanup`
> として実装されているため、新規 site では `phase22` を採用すること (旧名と規約名が共存しても衝突は起きない)。
> 同一 site に新規 cleanup 関数を追加する場合は必ず規約形式 (`phase22` 等) を採用すること。

### パス先行宣言 → trap 先行設定 → mktemp の順序

mktemp を先に実行して trap を後追いで設定すると、**mktemp 成功〜trap 設定間の race window**で
SIGTERM/SIGINT/SIGHUP が到達した場合に tmp ファイルが orphan として残る。並列 fix/review セッション
や手動の複数セッションで /tmp に累積し、wildcard glob 掃除の誘惑から他セッション破壊につながる
構造的リスクを生む。必ず以下の順序で記述する:

1. cleanup 対象変数を空文字列で先行宣言
2. cleanup 関数定義
3. 4 行 trap 設置
4. mktemp 実行

---

## Instantiation Checklist

新規 bash block で本パターンを利用する際の確認項目:

- [ ] cleanup 対象となる全変数を mktemp 実行**前**に空文字列で初期化した
- [ ] cleanup 関数内の全変数参照を `"${var:-}"` 形式にした
- [ ] cleanup 関数内に `exit` を書いていない
- [ ] **Form A** 採用時: 関数内に `return <非ゼロ>` を書いていない
- [ ] **Form B** 採用時: 関数末尾に `return 0` を追加した
- [ ] 4 行 trap (`EXIT` / `INT` / `TERM` / `HUP`) を揃えて設置した
- [ ] EXIT trap は `rc=$?` で元 exit code を先に capture している
- [ ] INT/TERM/HUP trap は明示的な `exit 130` / `exit 143` / `exit 129` を含む
- [ ] trap 設置は mktemp / 主処理の**前**に行っている

---

## Case Statement Indent Convention

<a id="case-statement-indent-convention"></a>

trap / cleanup パターンとセットで使用される `case "$branch_strategy" in ...` 等の case 文の
indent 規範を canonical 化する。

### Canonical pattern

```bash
case "$variable" in
  pattern_a)
    # body は 4-space indent (case label の 2-space + 2-space)
    command_1
    command_2
    ;;
  pattern_b)
    command_3
    ;;
  *)
    # default arm も同型 indent
    fail_command
    exit 1
    ;;
esac
```

| 要素 | Indent | 例 |
|------|--------|-----|
| `case` / `esac` | 0-space (block 外側に揃える) | `case "$branch_strategy" in` |
| pattern (case label) | **2-space** | `  separate_branch)` |
| body (commands) | **4-space** | `    set +e` |
| `;;` (terminator) | **4-space** | `    ;;` |

### Rationale

- **pattern (2-space) と body (4-space) を 2-space 差で階層化**: 入れ子関係が一目で読み取れる
- **`;;` も body と同じ 4-space**: `;;` は body の終端であり pattern の続きではない。pattern 直下に
  置くと「次の pattern が始まる」と誤読される
- **`*)` (default arm) も同型**: 例外なく同じ indent rule を適用し「`*)` だけ別ブロック?」誤認を排除

### 参照実装

canonical 確立先は `plugins/rite/skills/wiki-lint/SKILL.md` (ステップ 6.0 / 6.2 / 8.2 / 8.3 の dispatch
構造 case 文。うち 6.0 / 6.2 の case 文実体は `hooks/scripts/wiki-lint-skipped-refs.sh` /
`wiki-lint-source-refs.sh` へ移設済みで helper 内にある — lint.md 側の注記と同一の委譲実態)。**Scope**: dispatch 構造の case 文 (placeholder substitute validation gate /
strategy dispatch / rc dispatch) を対象とし、他 case arm 内にネストした dispatch case も含む。
while loop の inner case (per-iteration 状態判定) は scope 外。新規 case 追加時は本 pattern を
採用すること。ステップ番号 + case label の semantic anchor 形式で参照する (line 番号参照は drift する
ため禁止)。

### Anti-patterns

以下は **採用してはならない**:

```bash
# ❌ NG: pattern と body が同じ indent (階層が読み取れない)
case "$x" in
pattern_a)
command_1
;;
esac

# ❌ NG: body と `;;` の indent がずれる (`;;` の所属が曖昧)
case "$x" in
  pattern_a)
    command_1
  ;;
esac

# ❌ NG: 同じ case 内でアームごとに indent が異なる (anti-pattern)
case "$x" in
  pattern_a)
    command_1   # 4-space
    ;;
  pattern_b)
  command_2     # 2-space (非対称)
  ;;
esac
```

### Drift 検出

本 pattern の drift 検出 lint は未実装。手動レビュー時は code-quality reviewer が同一 case 文内の
indent 一貫性を確認する。

---

## Pointer Comment (各 site で使用する anchor 参照)

各 bash block 冒頭で以下の形式で参照する:

```bash
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code、race window 回避、rc=$? capture、${var:-} safety、関数契約)
```

signal 動作そのものを変更する場合は、本ファイル更新後に対象 5 ファイル全 site の 4 行 trap を
Instantiation Checklist に従って同時更新すること。
