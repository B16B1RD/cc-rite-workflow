# Broken Reference Resolution

このドキュメントは `plugins/rite/commands/wiki/lint.md` の **Phase 7 (壊れた相互参照検出)** で使用する
**相対パス解決の canonical 実装**を定義する。

`lint.md` Phase 7.2 の判定テーブルだけでは「相対パス (`./pages/...`, `../pages/...`, `pages/...`) を
`pages_list_normalized` にどう突合するか」が文字列マッチか path 解決か曖昧で、実装ごとに結果が
乖離していた。本ドキュメントはその解決規約を明文化し、bash 実装サンプルを提供する。

---

## 解決規約

| 項目 | 規約 |
|------|------|
| **基準ディレクトリ** | リンクが書かれた **ページファイルのディレクトリ** (`page_dir`) を起点とする |
| **解決関数** | `realpath -m --relative-to "$wiki_root" -- "$page_dir/$link"` で正規化 |
| **アンカー除去** | `#section` 部分は解決前に除去 (`sed -E 's/#.*$//'`) |
| **照合先** | `pages_list_normalized` (Phase 1.4 で生成された `pages/...` 相対パスのリスト) |
| **絶対パス (`/...`)** | HTTP URL 等の可能性があるため対象外 (Phase 7.2 テーブル参照) |
| **外部 URL (`http://`, `https://`)** | 対象外 |
| **コードブロック内** | Phase 7.1 の sed 前処理 (` ```/,/``` /d`) で抽出時点で除外 |

**`page_dir` の意味**: lint 対象 Wiki ページが `.rite/wiki/pages/heuristics/foo.md` の場合、
`page_dir` は `pages/heuristics`。リンク `../patterns/bar.md` は `pages/heuristics/../patterns/bar.md`
→ 正規化後 `pages/patterns/bar.md` として `pages_list_normalized` と突合する。

文字列マッチ (生 link 値を直接 `grep -F`) は **禁止**。`./` / `../` / 連続スラッシュ等の差で false
positive / negative が両方発生する。

---

## Canonical Bash 実装

```bash
# 前提:
#   $wiki_root         — Wiki データのルート絶対パス (例: /repo/.rite/wiki)
#   $page_path         — lint 対象ページの絶対パス (例: /repo/.rite/wiki/pages/heuristics/foo.md)
#   $link              — Phase 7.1 で抽出された生リンク文字列 (例: "../patterns/bar.md#section")
#   $pages_list_normalized — Phase 1.4 で生成された pages 相対パスのリスト (改行区切り)
# 出力:
#   $resolved_path     — 正規化された pages 相対パス (例: "pages/patterns/bar.md")
#   $broken            — "true" / "false"

# 1. アンカー除去
link_no_anchor=$(printf '%s' "$link" | sed -E 's/#.*$//')

# 2. 絶対パス / 外部 URL は対象外
case "$link_no_anchor" in
  /*|http://*|https://*|"")
    # Phase 7.2 テーブル参照、broken_refs カウントから除外
    continue
    ;;
esac

# 3. page_dir 起点で正規化 (realpath -m はファイル不在でもパス解決可能)
page_dir=$(dirname "$page_path")
resolved_abs=$(realpath -m -- "$page_dir/$link_no_anchor" 2>/dev/null) || resolved_abs=""

if [ -z "$resolved_abs" ]; then
  # 解決失敗 (極端に異常な path 構造) は broken として扱う
  broken="true"
else
  # 4. wiki_root 起点の相対パスに変換
  resolved_path=$(realpath -m --relative-to="$wiki_root" -- "$resolved_abs" 2>/dev/null)

  # 5. pages_list_normalized に存在するか確認
  if printf '%s\n' "$pages_list_normalized" | grep -qxF -- "$resolved_path"; then
    broken="false"
  else
    broken="true"
  fi
fi
```

**`realpath -m` の意味**: `-m` は「ファイルが存在しなくてもパス文字列としてのみ解決」する。
`./` / `../` / 連続スラッシュを正規化し、シンボリックリンクは解決しない (lint 対象では symlink を
想定しないため)。

---

## Edge Case

| ケース | 期待挙動 |
|--------|---------|
| `link="./foo.md"` | `page_dir/foo.md` に解決 |
| `link="../bar.md"` | `page_dir` の親ディレクトリの `bar.md` に解決 |
| `link="foo.md"` (prefix なし) | `page_dir/foo.md` に解決 (`./foo.md` 同等) |
| `link="pages/x/y.md"` | `page_dir/pages/x/y.md` に解決 (Wiki ルート直下を意図する場合は `../` プレフィックス必須) |
| `link="foo.md#section"` | アンカー除去後 `foo.md` として解決 |
| `link="http://example.com/x.md"` | 対象外 (broken_refs にカウントしない) |
| `link="/absolute/path.md"` | 対象外 (broken_refs にカウントしない) |
| `link=""` (空文字列) | 対象外 (Phase 7.1 抽出時点で空は来ない想定だが防御) |

---

## 既知の限界

| 限界 | 対処方針 |
|------|---------|
| `realpath -m` は GNU coreutils 依存 | macOS/BSD 環境では `coreutils` brew パッケージ (`grealpath`) または `python3 -c "import os.path; print(os.path.normpath(...))"` で代替。lint hook は GNU 環境を前提とする |
| URL 内に `)` を含むリンクは Phase 7.1 の `[^)]+` regex で検出されない | Wiki 内で括弧付き URL を使わない規約で回避 (Phase 7.2 既述) |
| 相対パスが Wiki ルート外を指す場合 (`../../etc/passwd` 等) | `realpath -m` は解決自体は成功するが `pages_list_normalized` に含まれないため broken として正しく検出される |
| シンボリックリンク先のページ | lint 対象では symlink を想定しない。`realpath -m` は symlink を解決しないため、symlink path をそのまま `pages_list_normalized` と突合 |

---

## 参考

- `plugins/rite/commands/wiki/lint.md` Phase 7.1 (リンク抽出) / Phase 7.2 (妥当性判定テーブル)
- Issue #798 (本実装の根拠となった false positive 問題の報告)
- GNU coreutils `realpath(1)` man page
