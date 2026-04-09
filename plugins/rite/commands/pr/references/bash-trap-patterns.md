# Bash Trap + Cleanup Patterns

このファイルは `plugins/rite/commands/pr/fix.md` と `review.md` の bash block で繰り返し使用される
**signal-specific trap + cleanup function パターン**の canonical 定義と根拠を集約する。

各 bash block の冒頭では、本ファイルの該当セクションへの anchor 参照を pointer コメントとして置き、
verbose な説明は本ファイルに一元化する。将来 signal semantics を変更する際
(例: HUP を無視する仕様に切り替え、新しい signal を追加) は、本ファイル **1 箇所のみ**を
更新することで意図を一貫して伝達する。

---

## Signal-Specific Trap Template

<a id="signal-specific-trap-template"></a>

全 9 箇所で使用される canonical パターン:

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

この pointer により、**9 箇所の同時更新が 1 箇所 (本ファイル) の更新に集約される**。
