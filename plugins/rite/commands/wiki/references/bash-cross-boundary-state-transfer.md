# Bash Cross-Boundary State Transfer Patterns

このドキュメントは `plugins/rite/commands/wiki/*.md` (特に `lint.md` / `ingest.md`) で採用されている
**Bash tool 呼び出し境界を跨いで状態を LLM に伝達する契約パターン**を canonical 定義として集約する。

Skill tool / Bash tool 呼び出しは独立 subprocess として動作するため、シェル変数は呼び出し境界を越えて
保持されない。LLM が後続 Phase で参照する必要がある値は **stdout 経由で明示的に emit** し、LLM が
会話コンテキストから読み取る契約にする必要がある。本ドキュメントはその共通 pattern を文書化する。

---

## Pattern 1: Multi-Value Enum via `key=value` Stdout

<a id="pattern-1-multi-value-enum-via-key-value-stdout"></a>

### 問題

Bash block 内で分岐処理した結果 (成功 / 複数の失敗カテゴリ) を、後続の別 Bash block や LLM 完了レポート
Phase で参照する必要がある。シェル変数 (`$log_read_ok` 等) は Bash tool 呼び出し境界を越えて保持されない。

典型例: 「log.md 読み出し成功 / legitimate absence / 真の IO error / branch_strategy fail-fast」の 4 状態を
区別したい。単純な boolean (`ok/not-ok`) では legitimate absence と IO error を混同し、false positive を
生む (skip 済み raw を欠落概念としてカウントする等)。

### 解決

値を **enum (固定値集合)** として定義し、bash block 末尾で stdout に `key=value` 形式で出力する:

```bash
# 4 値 enum を変数として保持 (初期値 "unknown" は fail-fast 経路でのみ残る、後段未到達)
log_read_ok="unknown"

case "$branch_strategy" in
  separate_branch)
    if log_content=$(git show "${wiki_branch}:.rite/wiki/log.md" 2>"$log_err"); then
      log_read_ok="true"
    else
      if [ -s "$log_err" ] && grep -qE "does not exist|fatal: invalid object name" "$log_err"; then
        log_read_ok="absent"   # legitimate absence (fresh branch / ENOENT)
      else
        log_read_ok="io_error" # 真の IO error (permission / 破損 / race)
      fi
    fi
    ;;
  # ...
esac

# 境界を跨ぐため stdout に emit
echo "log_read_ok=$log_read_ok"
```

LLM は会話コンテキストから `log_read_ok=XXX` を grep し、後続 Phase (完了レポート、次 Phase の分岐) で参照する。

### 設計原則

| 原則 | 理由 |
|------|------|
| **enum 値は固定有限集合** | 自由文字列だと LLM 解釈にブレが生じ、後続分岐が非決定論的になる |
| **初期値は "unknown" 等の "未到達" sentinel** | fail-fast exit 経路で enum が set されなかったことを明示する |
| **値は lowercase の snake_case** | shell/awk/regex でのマッチングを単純化 |
| **原則 stdout に emit、ただし `[CONTEXT]` prefix 付きなら stderr も許容** | stderr は WARNING / ERROR 専用だが、`[CONTEXT] key=value` 形式で machine-readable prefix を付けた状態 emit は grep 可能性が確保されるため stderr でも OK。Bash tool の stdout/stderr はいずれも会話コンテキストに取り込まれる。例: `review.md` Phase 6.1.a の `[CONTEXT] JSON_SAVED=...` は `>&2` で emit されるが、Phase 6.1.c が `[CONTEXT] JSON_SAVED=` で grep して受け取る。単純な `log_read_ok=absent` のような prefix なし状態 emit は stdout に留める |
| **`[CONTEXT]` prefix を使う選択肢もある** | 人間と LLM の両方から識別しやすくしたい場合 (`[CONTEXT] log_read_ok=absent`)。stderr に出す場合は特に本 prefix を付けて「状態 emit vs diagnostic」を区別する |

### 参照実装 (2026-04 時点)

- `plugins/rite/commands/wiki/lint.md` Phase 6.0 — `log_read_ok` 4 値 enum (unknown / true / absent / io_error)
- 同 Phase 6.2 — `all_source_refs_read_ok` 3 値 enum (unknown / true / io_error)。Phase 6.0 の 4 値から
  `absent` を除いた variant (per-page で legitimate absence を吸収するため集合レベルでは absent 状態に
  ならない)
- 同 Phase 2.3 — `index_read_ok` (true / false) の 2 値 enum (簡易版、absent / io_error の区別なし)
- `plugins/rite/commands/pr/review.md` Phase 6.1.a — `JSON_SAVED=true|false`、`FILE_TIMESTAMP=<ts>` の
  `[CONTEXT]` prefix 版。prefix を付けることで Phase 6.1.c が grep 可能になる

---

## Pattern 2: Marker-Delimited Multi-Value Block

<a id="pattern-2-marker-delimited-multi-value-block"></a>

### 問題

列挙値 (集合・リスト) を境界越えで伝達する必要があるが、リスト要素数が不定で `key=value,value,value` の
CSV 形式では要素内の `,` エスケープで複雑化する。また 0 件のとき空文字列で silent に「値未定義」と
区別できず、legitimate な 0 件 (true zero) と read 失敗を混同するリスクがある。

### 解決

**begin/end marker** で囲んだ block を stdout に出力する。0 件時も marker 自体は必ず出力することで
positive confirmation になる:

```bash
# 0 件時も marker は必ず出力する (silent 未定義と区別するため)
echo "---skipped_refs_begin---"
printf '%s\n' "$skipped_refs" | sort -u
echo "---skipped_refs_end---"

# skipped_refs が空でも begin/end marker 自体は出力されるため、LLM は
# 「marker はあるが中身 0 行」を「legitimate 0 件」と明示的に判定できる。
# marker 自体が無い場合は「bash block が途中で異常終了した」と判定する。
```

LLM 側は会話コンテキストから 2 つの marker に挟まれた範囲を正規表現で抽出:

```
^---skipped_refs_begin---$\n((?:.*\n)*?)^---skipped_refs_end---$
```

### 設計原則

| 原則 | 理由 |
|------|------|
| **marker 文字列は 3 連ハイフン囲み** | Markdown の水平線 (`---`) と衝突しにくい `---xxx_begin---` 形式 |
| **block 内は 1 行 1 要素** | CSV より扱いやすく、マルチバイト・特殊文字のエスケープ不要 |
| **空 block でも marker 自体は出力** | silent 未定義 (= bash 途中 crash) と legitimate 0 件を区別する positive confirmation |
| **block 内で `sort -u` 等の正規化**を行う | 重複要素・順序非決定性による LLM parse 結果の揺れを抑える |

### 参照実装 (2026-04 時点)

- `plugins/rite/commands/wiki/lint.md` Phase 6.0 — `---skipped_refs_begin---` / `---skipped_refs_end---` で
  `ingest:skip` 済み raw の集合を伝達
- 同 Phase 6.2 — `---all_source_refs_begin---` / `---all_source_refs_end---` で全 Wiki ページの
  `sources[].ref` 集合を伝達。本 marker block は Phase 6.2 step 3(a) で LLM が登録済み判定 (集合
  包含) を行うために参照される (PR #564 で Pattern 2 の参照実装を拡充)

---

## Pattern 3: Legitimate Absence vs IO Error Classification

<a id="pattern-3-legitimate-absence-vs-io-error-classification"></a>

### 問題

「ファイルが無い」には 2 種類ある:

1. **Legitimate absence**: fresh branch で log.md が未作成 / blob not found — これは正常状態で 0 件扱いが妥当
2. **真の IO error**: permission denied / blob 破損 / wiki_branch 消失 race — これは false positive 警告を
   表示する必要がある

単純に `cmd || fallback_to_empty` で扱うと両方を同じ「空集合」として処理してしまい、IO error 時に
silent に「0 件」と誤認する。

### 解決

stderr を tempfile に退避し、**stderr pattern matching** で legitimate absence / io_error を区別する:

```bash
# F-21 対応: 2 文分割形式 (lint.md Phase 6.0 の R-03 推奨形式) に統一する。
# 旧 `if ! log_err=$(...); then` 形式は bash 既知の罠「`if !` は `$?` が常に 0」と隣接した形で、
# 規範文書として読者を混乱させる。本 Pattern 3 の説明本文 (R-03 対応) では明示的に「2 文分割形式」を
# 推奨しているのに、Pattern 3 例自体が `if ! var=$(...); then` 形式を使うのは内部矛盾の見え方だった。
# F-16 対応: mktemp 失敗時の WARNING + 対処 + 影響 の 3 行 loud emit を canonical とする
# (lint.md Phase 6.0 の log_err mktemp 失敗 WARNING 部と同じ defense-in-depth — silent fallback 禁止)。
# 知らないエラー (mktemp 失敗で stderr 取得不能) を silent に absence と誤認するより、
# WARNING で可視化して io_error 経路に流す方が正しい。
log_err=$(mktemp /tmp/rite-XXXXXX 2>/dev/null) || {
  echo "WARNING: log_err の stderr 退避用 tempfile の mktemp に失敗しました" >&2
  echo "  対処: /tmp の空き容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり、legitimate absence / io_error の区別が付かなくなるため io_error 側に倒します" >&2
  log_err=""
}

if log_content=$(git show "${wiki_branch}:.rite/wiki/log.md" 2>"${log_err:-/dev/null}"); then
  log_read_ok="true"
else
  # 2 primary pattern + 2 safety pattern = 4 pattern 網羅
  # [ -n "$log_err" ] && [ -s "$log_err" ] の 2 段ガード: mktemp 失敗経路 (log_err="")
  # では [ -s "" ] が false でも silent に io_error に流れるが、[ -n ] ガードで
  # 「そもそも stderr 退避を試みたか」を明示する
  if [ -n "$log_err" ] && [ -s "$log_err" ] && grep -qE "does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:\\.rite/wiki/log\\.md'" "$log_err"; then
    log_read_ok="absent"    # legitimate absence — skipped_refs="" は妥当
  else
    log_read_ok="io_error"  # 真の IO error (or mktemp 失敗で原因区別不能) — WARNING 表示
    echo "WARNING: ..." >&2
    [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | sed 's/^/  /' >&2
  fi
fi

[ -n "$log_err" ] && rm -f "$log_err"
```

### 設計原則

| 原則 | 理由 |
|------|------|
| **stderr 退避** | 標準的な `2>/dev/null` では失敗原因が区別できない |
| **primary pattern + safety pattern の併用** | 現行ツール (git 2.x 等) の exact wording + 旧バージョン / 将来 wording 変更への safety margin |
| **pattern 不一致は io_error 扱い** | 知らないエラーを silent に absence と誤認するより、WARNING で可視化 |
| **sub-path (stderr 退避自体も失敗) にも WARNING を出す** | primary 経路との diagnostic 対称性、rc 値を silent に失わない |

### 参照実装 (2026-04 時点)

- `plugins/rite/commands/wiki/lint.md` Phase 6.0 — `log_read_ok` enum の absent / io_error 判別 (現在唯一の完全実装)

> **Note**: `lint.md` Phase 2.3 の `index_read_ok` は 2 値 enum (true / false) で absent と io_error を区別していないため、Pattern 3 (absence vs IO error classification) の参照実装には当てはまらない。Pattern 3 を新規採用する site は本項の Phase 6.0 のみを reference として使うこと。

---

## Instantiation Checklist

新規 Bash tool block で本 pattern 群を利用する際の確認項目:

- [ ] 境界越えで必要な値はすべて stdout (または `[CONTEXT]` prefix 付き stdout) に emit している
- [ ] enum 値は固定有限集合 (snake_case) で、`unknown` 等の "未到達" sentinel を初期値にしている
- [ ] 列挙値を伝達する場合は begin/end marker を使い、0 件でも marker 自体は出力する
- [ ] ファイル読み出しの absence と io_error を区別する場合、stderr pattern matching を使っている
- [ ] pattern 不一致 (未知エラー) は io_error 扱いで WARNING を出している
- [ ] stderr 退避自体が失敗する sub-path にも WARNING がある (primary 経路との対称性)
- [ ] `[CONTEXT]` prefix を使う場合、LLM / caller が grep する形式 (`[CONTEXT] KEY=value;...`) で統一

---

## Regression History

本 pattern 群は複数回の regression を経て現在の形に収束した:

- **PR #547 / #556 (Wiki worktree 化 / origin/wiki fallback)**: Wiki branch / raw source の読み出しで
  legitimate absence と IO error を混同し、fresh branch で「絶大な missing=N 件」を誤報する regression が
  発生。legitimate absence と io_error を区別する classification step (現行 `lint.md` Phase 6.0 に相当)
  を追加して解消。
- **PR #564 (Issue #563 lint 2 カテゴリ分離)**: 本 pattern 群を集約。`log_read_ok` 4 値 enum の導入に
  あわせて、pattern 1-3 を独立ドキュメントとして切り出した。

---

## Related References

- `plugins/rite/commands/pr/references/bash-trap-patterns.md` — signal-specific trap + cleanup の canonical
  定義。本 pattern 群と併用する際の組み合わせ方を示す
