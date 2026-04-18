# Bash Trap + Cleanup Patterns

このファイルは `plugins/rite/commands/pr/fix.md`、`review.md`、`issue/start.md`、および `plugins/rite/commands/wiki/lint.md` の bash block で繰り返し使用される
**signal-specific trap + cleanup function パターン**の canonical 定義と根拠を集約する。

各 bash block の冒頭では、本ファイルの該当セクションへの anchor 参照を pointer コメントとして置き、
verbose な **rationale / 説明コメント**は本ファイルに一元化する。本リファクタリングで 1 箇所に
集約されるのは **rationale / 説明文の層** のみである。

> **⚠️ 重要 — コード層との境界**: 各 site の cleanup 関数本体と 4 行 trap (`EXIT`/`INT`/`TERM`/`HUP`)
> は依然として fix.md / review.md / start.md の各箇所にコードとして存在する。したがって **signal 動作そのもの**
> を変更する場合 (例: HUP を無視する仕様に切り替え、新しい signal を追加、TERM の exit code を変更)
> は、本ファイルの rationale 更新後に **fix.md + review.md + start.md の全 site で 4 行 trap のコード自体を
> 同時更新する必要がある**。本ファイル 1 箇所の更新で自動的に反映されるわけではない。
>
> **rationale 層で集約されること**: 説明文 / 意図 / regression history / checklist の更新は本ファイル
> 1 箇所で完結する。保守者は「なぜこの 4 行構造なのか」を 1 箇所読むだけで把握できる。
>
> **コード層で集約されないこと**: 実際の bash コード (trap 行、cleanup 関数の骨格) は markdown 内の
> 独立した bash block として各ファイルに残っているため、コード変更は依然全 site 同時更新が必要。
> drift 検出 lint の追加は Issue #353 で追跡中。

---

## Signal-Specific Trap Template

<a id="signal-specific-trap-template"></a>

fix.md / review.md / start.md の各 site で使用される canonical パターン:

```bash
# 1. cleanup 対象変数の先行宣言 (未定義時 silent no-op 化のため空文字列で初期化)
tmpfile=""
jq_err=""
# ... 追加の cleanup 対象変数 ...

# 2. cleanup 関数定義 (責務: rm -f のみ。exit/return を含めてはならない)
_rite_<phase>_cleanup() {
  rm -f "${tmpfile:-}" "${jq_err:-}"
  # ... site-specific な conditional cleanup logic (例: 2-state commit pattern) ...
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

### EXIT trap 単独では不十分な理由

bash の EXIT trap は SIGTERM/SIGHUP/SIGINT のいずれでも発火する (GNU bash manual "Signals" で確認済み、
実証済み)。しかし **INT/TERM/HUP の trap action が明示的な `exit <code>` を含まないと、
bash は signal を consume して次のコマンドへ制御を渡してしまう** (silent continuation)。

例: `_rite_fix_fastpath_cleanup; exit 130` の `exit 130` を省略すると、SIGINT 到達後に cleanup 関数が
実行された後、bash は block 内の残りの命令 (mapfile / for / case 等) を**不完全な状態で継続実行**する。
これは debug が極めて困難な silent failure を引き起こす。

### signal 別 exit code の選定 (POSIX 慣習: 128 + signal number)

| signal  | exit code | 意味                     |
|---------|-----------|--------------------------|
| SIGINT  | 130       | Ctrl+C / `kill -INT`     |
| SIGTERM | 143       | `kill -TERM` (timeout 等) |
| SIGHUP  | 129       | 端末切断 / session 終了   |

SIGINT/SIGTERM/SIGHUP 受信時の `$?` は「最後に完了したコマンドの exit status」であり、signal 自体が
130/143/129 を set するとは限らない。例えば `printf` 成功直後に SIGTERM が来ると `rc=0` となり、上位の
fix loop 制御が「正常終了」と誤判定する silent failure が起きる。これを防ぐため signal 別 trap で
**明示的に exit 130/143/129 を返す**。

### EXIT trap の `rc=$?` capture (bash classic pitfall)

bash の EXIT trap が発火した時点で `$?` は元の exit status を保持するが、`_rite_<phase>_cleanup`
関数を実行すると関数最後のコマンド (`rm -f` または `[ ... ]` test) の戻り値で `$?` が**上書き**される。

したがって `trap '_rite_<phase>_cleanup; exit $?' EXIT` は exit code が常に 0 (rm -f の戻り値) に
なる致命的バグを生む (bash block 内の全ての `exit 1` が silent に exit 0 に変換される)。

**必ず `rc=$?` で関数呼び出し前に元の exit code を変数に保存してから**、cleanup → `exit $rc` する:

```bash
trap 'rc=$?; _rite_<phase>_cleanup; exit $rc' EXIT
```

### cleanup 関数の契約 (関数内で exit/return を呼んではならない)

cleanup 関数の責務は **rm -f などの cleanup 操作のみ**であり、exit code を変更してはならない。
関数の戻り値は trap action 側で無視される (`rc=$?` で先に保存済みのため)。

関数内に `exit` や `return <非ゼロ>` を追加すると、signal 別 trap が期待する exit code (130/143/129)
を上書きして silent exit 0 regression を誘発する。

### `${var:-}` 形式で未定義変数を安全化

`rm -f "${var:-}"` は `var` が未定義/空文字列のときに `rm -f ""` の silent no-op となる。
これにより、cleanup 関数が mktemp 失敗経路や早期 exit 経路で呼ばれても安全に動作する (defense-in-depth)。

### BSD/macOS rm の `rm -f ""` 対応 (空引数ガード variant)

`rm -f "${var:-}"` は GNU rm では空引数を silent no-op として扱うが、一部の BSD/macOS rm
実装 (coreutils 非採用環境) では stderr に `cannot remove ''` を出力する場合がある。
portable に保ちたい場合は、代わりに以下の明示的な空引数ガードを使う:

```bash
_rite_<scope>_<phase>_cleanup() {
  [ -n "${var1:-}" ] && rm -f "$var1"
  [ -n "${var2:-}" ] && rm -f "$var2"
}
```

この variant は特に以下の条件を両方満たす site で推奨する:

- cleanup 関数が mktemp 失敗経路を通る可能性がある (= 変数に空文字列が入ったまま cleanup に到達する)
- BSD/macOS ユーザーが本プラグインを実行する可能性がある (`plugins/rite/` は multi-OS target)

本 variant を採用している参照実装 (2026-04 時点):

- `plugins/rite/commands/wiki/lint.md` Phase 2.2 (`_rite_wiki_lint_phase2_cleanup`) — 旧命名 (`phase22` 規約確立前の実装)。既存名は維持し、同一 site に cleanup を新規追加する場合は `_rite_wiki_lint_phase22_cleanup` を採用すること
- `plugins/rite/commands/wiki/lint.md` Phase 6.0 (`_rite_wiki_lint_phase60_cleanup`)
- `plugins/rite/commands/wiki/lint.md` Phase 6.2 (`_rite_wiki_lint_phase62_cleanup`) — PR #564 で追加、page_err / awk_diag / sort_err の 3 tempfile を保護
- `plugins/rite/commands/wiki/ingest.md` Phase 5.2 (`_rite_wiki_ingest_phase52_cleanup`) — PR #564 F-01 対応で旧名 `_rite_ingest_phase52_cleanup` から `wiki` scope prefix 付きにリネーム (scope 衝突回避、規約準拠)。`_reset_err` tempfile を保護

命名規約:

- 形式: `_rite_<scope>_<phase>_cleanup`
- `<scope>`: site を識別する接頭辞。例: `wiki_lint` (wiki/lint.md), `fix` (pr/fix.md), `review` (pr/review.md), `start` (issue/start.md)
- `<phase>`: Phase 番号。**小数点を除いた連結形式**を使う (drift 防止)
  - `Phase 2.2` → `phase22`
  - `Phase 6.0` → `phase60`
  - `Phase 6.2` → `phase62`
  - `Phase 2` (小数なし) → `phase2`
  - 複数 Block を持つ Phase (Fast Path Block A/B/C 等) は `phaseXY_blockA` のように suffix を追加可
- **Phase 2 と Phase 2.2 の collision ガード** (PR #564 F-06 対応): 整数 `Phase 2` の命名が `phase2` で、小数 `Phase 2.2` の命名が `phase22` となるため、形式的な衝突は起きない。ただし他 scope で整数 `Phase N` と小数 `Phase N.M` が同一 site に共存する場合、将来 `Phase N` 側が複数 scope に分岐しても追跡できるよう `phase{N}_main` / `phase{N}_{M}` のような suffix を付けると意図が明確になる (必須ではない、読みやすさ優先)。
- 将来 Phase 6.1 / 6.3 等で cleanup 関数を追加する場合も同形式を採用すること。
- PR #564 レビュー LOW #2 対応で短縮形 `_rite_p{NN}_cleanup` は廃止、scope prefix 付きの 2 階層命名に統一 (scope 不在だと `_rite_phase2_cleanup` が複数 site で衝突するため)。

> **Note — 既存命名の扱い** (PR #564 F-05 対応): 既存 site の旧命名 (`_rite_wiki_lint_phase2_cleanup` 等) は維持し、本 PR では一括リネームを行わない (scope 外、旧名→新名のリネーム作業は別 Issue で追跡)。**同一 site に新規 cleanup 関数を追加する場合は必ず規約形式 (`phase22` 等の小数点除去連結形式) を採用すること** — 旧名と規約名が共存しても衝突は起きないが、新規追加時に旧名 (`phase2`) を踏襲すると規約違反となる。迷った場合は規約 (`phase{N}{M}`) を優先する。

GNU rm のみをターゲットとする site (Linux-only CI 等) では `rm -f "${var:-}"` のままで問題ない。

### パス先行宣言 → trap 先行設定 → mktemp の順序

mktemp を先に実行して trap を後追いで設定すると、**mktemp 成功〜trap 設定間の race window**で
SIGTERM/SIGINT/SIGHUP が到達した場合に作成済み tmp ファイルが orphan として残る。
並列 fix/review セッション (sprint team-execute 等) で /tmp に累積し、wildcard glob で掃除する誘惑 →
他セッション破壊につながる構造的リスクを生む。

したがって必ず以下の順序で記述する:

1. cleanup 対象変数を空文字列で先行宣言
2. cleanup 関数定義
3. 4 行 trap 設置
4. mktemp 実行

---

## Regression History

本パターンは複数回の regression を経て現在の形に収束した。以下は過去に発見されたバグと修正の履歴:

- **H-3 (fix.md Fast Path)**: `gh_api_err` が cleanup 対象から漏れており trap 未保護だった。
  `${var:-}` 形式で cleanup 関数に追加して safety を担保。
- **M-4 (fix.md Phase 4.3.4)**: `project_reg_jq_err` が「短命変数」として統合 trap から除外されていたが、
  mktemp 成功 〜 直後の `rm -f` までの race window で signal 到達時に orphan 化することが判明。
  「短命だから除外してよい」という思い込みを明示的に否定し、全短命変数を統合 trap で保護する方針に変更。
- **H-1 (fix.md Phase 4.5.2)**: trap 設定が mktemp 群より後にあり、race window が存在した。
  「パス先行宣言 → trap 先行設定 → mktemp」パターンに統一。
- **H-7 (fix.md Phase 4.5.2)**: Phase 4.5.1 と Phase 4.5.2 が同一 Bash invocation で連結された場合、
  Phase 4.5.2 の trap が Phase 4.5.1 の trap を上書きするため、Phase 4.5.1 で作成された `pr_body_tmp`
  が orphan 化していた。Phase 4.5.2 の cleanup 関数にも `${pr_body_tmp:-}` を defense-in-depth として追加。
- **#350 H1/H3 (fix.md Phase 2.4 / Phase 4.3.4)**: mktemp 失敗経路でも retained flag を emit する
  必要性 (bash の `exit 1` は Claude のフロー制御にならないため、Phase 8.1 の detection を補助する)。
- **L-6/L-9 (fix.md py_exit2)**: Python script の sentinel exit code (`sys.exit(2)`) を受けた経路で
  tmpfile を preserve しつつ他の一時ファイルは cleanup する必要があり、専用 cleanup 関数 `_rite_fix_py_exit2_cleanup`
  を定義。pr_body_tmp 参照は通常 unset で silent no-op だが、defense-in-depth として残す。

---

## Instantiation Checklist

新規 bash block で本パターンを利用する際の確認項目:

- [ ] cleanup 対象となる全変数を mktemp 実行**前**に空文字列で初期化した
- [ ] cleanup 関数内の全変数参照を `"${var:-}"` 形式にした
- [ ] cleanup 関数内に `exit` / `return <非ゼロ>` を書いていない
- [ ] 4 行 trap (`EXIT` / `INT` / `TERM` / `HUP`) を揃えて設置した
- [ ] EXIT trap は `rc=$?` で元 exit code を先に capture している
- [ ] INT/TERM/HUP trap は明示的な `exit 130` / `exit 143` / `exit 129` を含む
- [ ] trap 設置は mktemp / 主処理の**前**に行っている

---

## Pointer Comment (各 site で使用する anchor 参照)

各 bash block の冒頭では以下の形式で本ファイルを参照する:

```bash
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code、race window 回避、rc=$? capture、${var:-} safety、関数契約)
```

この pointer により、**rationale / 説明コメントの更新は本ファイル 1 箇所に集約される** (冒頭の
「重要 — コード層との境界」で述べた通り、4 行 trap のコード自体はこれとは別に各 site に残っている)。
signal 動作そのものを変更する場合 (例: HUP 追加、TERM の exit code 変更) は、本ファイルの rationale
更新後に fix.md + review.md + start.md の全 site の 4 行 trap を Instantiation Checklist に従って同時更新すること。
