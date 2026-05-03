# Broken Reference Resolution

このドキュメントは `plugins/rite/commands/wiki/lint.md` の **Phase 7 (壊れた相互参照検出)** で使用する
**相対パス解決の canonical 実装**を定義する。

`lint.md` Phase 7.2 の判定テーブルだけでは「相対パス (`./pages/...`, `../pages/...`) を `pages_list` に
どう突合するか」が文字列マッチか path 解決か曖昧で、実装ごとに結果が乖離していた。本ドキュメントは
その解決規約を明文化し、bash 実装サンプルを提供する。

---

## 解決規約

| 項目 | 規約 |
|------|------|
| **基準ディレクトリ** | リンクが書かれた **ページファイルのディレクトリ** (`page_dir`) を起点とする |
| **解決関数** | `realpath -m -s --relative-to "$wiki_root" -- "$page_dir/$link"` で正規化 |
| **`$wiki_root` の値** | `.rite/wiki` (cwd 相対 fixed string)。lint.md には `wiki_root` 変数を生成する Phase が存在しないため、本実装内で初期化し、`[ -d "$wiki_root" ]` の runtime guard で cwd=repo root 前提を fail-fast に検証する |
| **`$page_path` の値** | cwd 相対パス (例: `.rite/wiki/pages/heuristics/foo.md`)。lint.md Phase 4.2 / 6.2 のループで `pages_list` の各要素として渡される |
| **アンカー除去** | `#section` 部分は解決前に除去 (`sed -E 's/#.*$//'`) |
| **照合先 (pages 参照)** | `pages_list_normalized` — Phase 7.1 末尾で `printf '%s\n' "$pages_list" \| sed -E 's\|^\.rite/wiki/\|\|' \| grep -v '^$'` で生成された相対パスのリスト (`pages/...` 形式) |
| **照合先 (raw 参照)** | `raw_list_normalized` — 同様に `raw_list` から `.rite/wiki/` プレフィックスを除去した相対パスのリスト (`raw/...` 形式)。`resolved_path` の prefix で `pages/*` / `raw/*` を判別して照合先 list を切り替える |
| **絶対パス (`/...`)** | HTTP URL 等の可能性があるため対象外 (Phase 7.2 テーブル参照) |
| **外部 URL (`http://`, `https://`)** | 対象外 |
| **コードブロック内** | Phase 7.1 の sed 前処理 (`/^```/,/^```/d`) で抽出時点で除外 (行頭 ` ``` ` のみ。インデント付き fence は除外できない既知の限界あり) |

**`page_dir` の意味**: lint 対象 Wiki ページが `.rite/wiki/pages/heuristics/foo.md` の場合、
`page_dir` は `.rite/wiki/pages/heuristics`。リンク `../patterns/bar.md` は
`.rite/wiki/pages/heuristics/../patterns/bar.md` → `realpath -m -s --relative-to=.rite/wiki` で
正規化後 `pages/patterns/bar.md` として `pages_list_normalized` と突合する。

文字列マッチ (生 link 値を直接 `grep -F`) は **禁止**。`./` / `../` / 連続スラッシュ等の差で false
positive / negative が両方発生する。

---

## Canonical Bash 実装

> ⚠️ **以下のスニペットは LLM が各 link に対して for-loop 内で実行することを前提**とします。
> `continue` は enclosing loop の次 iteration へ進む制御です。loop の骨組みは Phase 4.2 / 6.2 と
> 同型の `while IFS= read -r link; do ... done <<< "$page_links"` を想定。
> Wiki branch 戦略 (`separate_branch`) で page が filesystem に存在しない場合でも本実装は動作します
> (path 文字列処理のみ、`realpath -m -s` は missing components を許容し symlink を解決しない)。

```bash
# 前提 (lint.md Phase 2.2 / 4.2 / 7.1 末尾の契約と整合):
#   $page_path             — lint 対象ページの cwd 相対パス
#                            (例: .rite/wiki/pages/heuristics/foo.md)
#   $link                  — Phase 7.1 で抽出された生リンク文字列
#                            (例: "../patterns/bar.md#section")
#   $pages_list_normalized — Phase 7.1 末尾で生成された pages 相対パスのリスト
#                            (改行区切り、例: "pages/heuristics/foo.md")
#   $raw_list_normalized   — 同 raw 相対パスのリスト (例: "raw/reviews/...md")
# 出力:
#   $resolved_path     — 正規化された相対パス (例: "pages/patterns/bar.md")
#   $broken            — "true" / "false"

# wiki_root を cwd 相対の固定値で初期化 + runtime guard
# (lint.md には wiki_root 変数を生成する Phase が存在しないため本実装内で定義する)
# cwd=repo root 前提が破綻すると `realpath --relative-to` の結果が pages_list_normalized と
# 一致せず全 link が broken-ref と silent 誤判定される経路があるため、fail-fast で検証する。
wiki_root=".rite/wiki"
if [ ! -d "$wiki_root" ]; then
  echo "ERROR: cwd ($PWD) から $wiki_root が見えません。lint は repo root から実行してください" >&2
  exit 1
fi

# 1. アンカー除去
link_no_anchor=$(printf '%s' "$link" | sed -E 's/#.*$//')

# 2. 絶対パス / 外部 URL / 空文字列は対象外
case "$link_no_anchor" in
  /*|http://*|https://*|"")
    # Phase 7.2 テーブル参照、broken_refs カウントから除外
    continue
    ;;
esac

# 3. page_dir 起点で正規化 (realpath -m -s)
# - -m (--canonicalize-missing): missing components を許容 (ファイル不在でも path 解決可能)
# - -s (--no-symlinks):           symlink を解決しない (lint 対象では symlink を想定しない)
# 両者を組み合わせることで `./` / `../` / 連続スラッシュを正規化しつつ symlink resolve を回避する。
# GNU coreutils realpath(1) の仕様: -m 単独では symlink は resolve される (-s 必須)。
page_dir=$(dirname "$page_path")
resolved_abs=$(realpath -m -s -- "$page_dir/$link_no_anchor" 2>/dev/null) || resolved_abs=""

if [ -z "$resolved_abs" ]; then
  # 解決失敗 (極端に異常な path 構造) は broken として扱う
  broken="true"
else
  # 4. wiki_root 起点の相対パスに変換
  # 失敗時 (--relative-to 自体のエラー等) は明示的に "" 設定し silent failure を回避
  resolved_path=$(realpath -m -s --relative-to="$wiki_root" -- "$resolved_abs" 2>/dev/null) || resolved_path=""

  if [ -z "$resolved_path" ]; then
    # --relative-to 失敗 = wiki_root 外への解決等 → broken として扱う
    broken="true"
  else
    # 5. resolved_path の prefix で照合先 list を切り替え (pages / raw)
    # case ベースの判別により pages_list_normalized と raw_list_normalized の混在 list を
    # 作る必要がない (各 list は Phase 7.1 末尾で独立に生成される)。
    case "$resolved_path" in
      pages/*)
        if printf '%s\n' "$pages_list_normalized" | grep -qxF -- "$resolved_path"; then
          broken="false"
        else
          broken="true"
        fi
        ;;
      raw/*)
        if printf '%s\n' "$raw_list_normalized" | grep -qxF -- "$resolved_path"; then
          broken="false"
        else
          broken="true"
        fi
        ;;
      *)
        # pages/ でも raw/ でもない解決結果 (例: wiki_root 直下の README.md, log.md, index.md 等)
        # は broken_refs 検出対象外として扱う (lint.md Phase 5.2 で index.md は別途扱われる)
        broken="false"
        ;;
    esac
  fi
fi

# loop の 1 iteration 完了。$broken / $resolved_path を呼び出し側で issues[] に集約してから次 link へ
```

**`realpath -m -s` の意味**: `-m -s` の組み合わせは missing components を許容しつつ symlink を解決
しないため、`./` / `../` / 連続スラッシュを正規化しつつ symlink を literal path として扱う動作になる。
GNU coreutils `realpath(1)` の仕様上、`-m` 単独では symlink は default で resolve される。`-s`
(`--no-symlinks`, `--strip`) を併用することで symlink を literal path として扱う動作になる。
lint 対象では symlink を想定しないため `-s` を必須とする。

---

## Edge Case

| ケース | 期待挙動 |
|--------|---------|
| `link="./foo.md"` | `page_dir/foo.md` に解決 (page_dir 内のページ参照) |
| `link="../patterns/foo.md"` | `page_dir` の親ディレクトリの `patterns/foo.md` に解決 (page_dir=`.rite/wiki/pages/heuristics` → `pages/patterns/foo.md` で `pages_list_normalized` と突合) |
| `link="../../raw/reviews/x.md"` | page_dir=`.rite/wiki/pages/heuristics` → `raw/reviews/x.md` に解決 → `raw_list_normalized` と突合 |
| `link="foo.md#section"` | アンカー除去後 `foo.md` として `page_dir/foo.md` に解決 |
| `link="http://example.com/x.md"` | 対象外 (broken_refs にカウントしない) |
| `link="/absolute/path.md"` | 対象外 (broken_refs にカウントしない) |
| `link=""` (空文字列) | 対象外 (Phase 7.1 抽出時点で空は来ない想定だが防御) |

**注 (重要)**: `pages_list_normalized` の実エントリは `pages/{patterns,heuristics,anti-patterns}/*.md` 形式のみ
(lint.md Phase 2.2 grep filter `^\.rite/wiki/pages/(patterns|heuristics|anti-patterns)/[^/]+\.md$` 由来)。
Wiki ルート直下に単独で配置されるページ (例: `pages/foo.md` 形式) は構造上存在しないため、
そのような参照を canonical 実装で解決しようとしても `pages_list_normalized` にはヒットしない
(=必ず broken 判定になる)。`pages/` 配下に置く場合は必ず `patterns` / `heuristics` / `anti-patterns`
のいずれかのサブディレクトリに格納する。

**lint.md Phase 7.2 表との整合性**: lint.md Phase 7.2 表は相対パスを `./pages/...` / `../pages/...` のみ
列挙し prose で「Wiki ルート起点の参照 (`pages/...` prefix なし) は使用しない」と明示禁止している。
本 reference の Edge Case も同方針で、`foo.md` (prefix なし) や `pages/x.md` (Wiki ルート起点意図)
のような曖昧な形式は **使用しない** ことを推奨する。万一そのような link が抽出された場合、
本実装は `page_dir` 起点で解決するため Wiki ルート直下にはヒットせず broken と判定される
(これは structural な仕様であり、lint.md と reference 双方で禁止する形式である)。

---

## 既知の限界

| 限界 | 対処方針 |
|------|---------|
| `realpath -m -s` は GNU coreutils 依存 | macOS/BSD 環境では `coreutils` brew パッケージ (`grealpath`) または `python3 -c "import os.path; print(os.path.normpath(...))"` で代替。lint hook は GNU 環境を前提とする |
| URL 内に `)` を含むリンクは Phase 7.1 の `[^)]+` regex で検出されない | Wiki 内で括弧付き URL を使わない規約で回避 (Phase 7.2 既述) |
| 相対パスが Wiki ルート外を指す場合 (`../../etc/passwd` 等) | `realpath -m -s --relative-to` は `wiki_root` 外への path で空文字列を返すため、本実装では `[ -z "$resolved_path" ]` 分岐で broken として正しく検出される |
| シンボリックリンク先のページ | lint 対象では symlink を想定しない。`-m -s` の組み合わせで symlink を解決せず literal path 文字列として比較するため、symlink path がそのまま `pages_list_normalized` に存在する必要がある (実用上 Wiki に symlink は使わないため影響なし) |
| インデント付き code fence (Phase 7.1 sed 前処理の限界) | `sed -E '/^```/,/^```/d'` は行頭 ` ``` ` のみ削除するため、list 項目内の 2-space indent fence を含むページでは fence 内リンクが broken_refs に false positive として残る。awk ベース実装 (例: `awk '/^\s*```/{f=!f; next} !f'`) への移行が今後の課題 |
| Wiki ルート起点参照 (`pages/foo.md` を Wiki ルートからのパスと意図する形式) | 本実装では `page_dir` 起点解決のため検出不可能。`pages_list_normalized` の実エントリが `pages/{patterns,heuristics,anti-patterns}/*.md` のみであることと整合し、ルート直下ページ自体が存在しないため実害なし。リンクは必ず `./` または `../` prefix 付きで書く規約 |

---

## 参考

- `plugins/rite/commands/wiki/lint.md` Phase 7.1 (リンク抽出 + normalized list 生成) / Phase 7.2 (妥当性判定テーブル)
- Issue #798 (本実装の根拠となった false positive 問題の報告)
- GNU coreutils `realpath(1)` man page
