---
name: issue-audit
description: |
  rite workflow の Issue 監査スキル: Open Issue 群を全体として見直し、同じ根因への分岐・長い派生の系譜・
  実装とずれた/長く進まない Issue を統合・取り下げ・方向修正の提案としてレポートする。採否規則で機械的に
  決まる処分（重複・解消済み・V=C=T=false と記録済み）だけを実行する。
  ユーザーが明示的に /rite:issue-audit で起動する、または /rite:batch-run の完了時に 1 回呼ばれる。
  auto-activate しない。
  起動: /rite:issue-audit
---

# /rite:issue-audit

> 実行入口と工程境界は [Host Runtime Contract](../../references/host-runtime-contract.md#入口と工程境界)、native Skill / Task がない場合の実行は [Host workflow operations](../../references/host-workflow-operations.md) に従う。nested 呼出しは caller の runtime 選択を引き継ぐ。

> セッション worktree 内から呼ばれてシェルブロックがホストの隔離ガードに拒否されたら、[共通作業先契約](../../references/git-worktree-patterns.md#host-worktree-execution) の「入場後のガード拒否の退路」に従う。

個々の PR や根因の単位では見えないもの — 系譜の連鎖、同じファイル・同じ元 PR への集中、長く進まない Issue、実装とずれた Issue 本文 — を Issue 群全体から拾い、レポートにする。常駐・定期巡回はしない。
rationale: references/rationale.md#scope

## Contract

**Input**: なし
**Output**: レポートファイル（`{state_root}/.rite/state/issue-audit-{timestamp}.md`）と完了 sentinel。処分した Issue には close コメントとして根拠が残る

## MUST NOT

- コード全体の再レビューや、新しいレビュー指摘の生成をしない。reviewer agent を spawn せず、`/rite:pr-review` も呼ばない。入力は既存の記録（Issue・PR・残存する判定記録・claim）だけ
- 提案だけで Issue をクローズ・統合・起票しない。実行してよいのはステップ 3 の helper が採否規則から再計算した処分だけ。helper に Issue 番号を渡さない
- 件数を減らすことを目的に取り下げを提案しない。取り下げの提案には、元の契約から見て不要である根拠を添える
- 実装物に Issue 番号と PR 番号を書かない。新しい設定キーを足さない

rationale: references/rationale.md#rule-not-judgement

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo |
| `{base_branch}` | `rite-config.yml` の `branch.base`（未設定時は `main`） |
| `{state_root}` | ステップ 4 の `state-path-resolve.sh` の出力 |
| `{timestamp}` | ステップ 4 の `date` の出力 |

---

## ステップ 1: 集計

```bash
bash {plugin_root}/hooks/scripts/issue-audit.sh collect --repo {owner_repo} --base {base_branch}
```

stdout の snapshot JSON をステップ 2・4 の入力として保持する。各フィールドの意味は helper（`hooks/scripts/lib/issue-audit.py`）の docstring が SoT。

| stderr の marker | アクション |
|---|---|
| `[CONTEXT] ISSUE_AUDIT=ok; ...` | ステップ 2 へ |
| `[CONTEXT] ISSUE_AUDIT=error; ...` / 非ゼロ終了 | stderr の `ERROR:` 行を表示し、ステップ 4 末尾の失敗の返却（`[issue-audit:failed]`）で caller へ返す（ステップ 3 の処分へ進まず、レポートも書かない） |

## ステップ 2: 提案の組み立て（読むだけ）

snapshot の各候補について、`gh issue view <N> -R {owner_repo} --json title,body,comments` と、本文が名指しするファイルを読んで判断する。書き込みはしない。

| 対象 | 入力 | 出すもの |
|---|---|---|
| 統合 | `concentration` の各グループ | 同じ根因かの判定。同じなら統合先と、共通の契約・証拠（本文・コメントの引用） |
| 系譜 | `lineage.chains` の各連鎖 | 連鎖と、根の Issue の契約（受入条件）から見た各世代の必要性（必要 / 取り下げ提案 / 方向修正）と根拠 |
| 方向修正 | `open_issues` のうち `stale: true` のもの、および `files`（本文が名指しするファイル）を持つもの。後者は名指しされたファイルの現状と本文の受入条件を照合する | 食い違い・停滞の事実（引用）と、修正後の方向 |

- 判定の根拠は、Issue・PR・コメント・名指しされたファイルの現状から引用する。引用できない推測は提案にしない
- 新しい欠陥を見つけても指摘として書かない（MUST NOT）。既存 Issue の本文と現状のずれとして書ける範囲だけを扱う
- `dispositions` と `excluded` に載った Issue はステップ 3 の担当であり、ここで重ねて処分を提案しない。`excluded` の理由は ステップ 4 のレポートにそのまま載せる

## ステップ 3: 機械的な処分

```bash
bash {plugin_root}/hooks/scripts/issue-audit.sh dispose --repo {owner_repo} --base {base_branch}
```

helper は snapshot を自分で作り直し、採否規則で決まる Issue だけをクローズする（根拠は close コメントへ逐語で残り、board Status は重複・不採用が `cancelled`、解消済みが `done`）。

| stderr の marker | アクション |
|---|---|
| `[CONTEXT] ISSUE_AUDIT_DISPOSE=ok; ...` | stdout の `results` を保持してステップ 4 へ |
| `[CONTEXT] ISSUE_AUDIT_DISPOSE=failed; ...` | `results` の失敗行（`closed: false` / `status` が `failed` か `skipped_terminal_conflict`）と `WARNING:` 行を保持してステップ 4 へ。レポートを書いたあと `[issue-audit:failed]` で caller へ返す |
| `[CONTEXT] ISSUE_AUDIT=error; ...` / marker 不在 | `ERROR:` 行を保持してステップ 4 へ。レポートを書いたあと `[issue-audit:failed]` で caller へ返す |

## ステップ 4: レポート

```bash
bash {plugin_root}/hooks/state-path-resolve.sh
```

```bash
date +%Y%m%d-%H%M%S
```

Write ツールで `{state_root}/.rite/state/issue-audit-{timestamp}.md` に次の形で書く。節の見出しと順序は固定。該当がない節は「なし」と書く。

```markdown
# Issue 監査レポート（{timestamp}）

対象: {owner_repo}（base: {base_branch}）/ Open Issue <件数> 件

## 処分結果
| Issue | 規則 | 処分 | 結果 |

## 統合提案
### 統合先 #N ← #M, ...
- 共通の契約: <引用>
- 共通の証拠: <引用>

## 系譜
### #A → #B → #C
- 根の契約: <引用>
- 各世代の必要性: #B 必要（<根拠>）/ #C 取り下げ提案（<根拠>）

## 方向修正
### #N（停滞 / 受入条件と実装のずれ）
- 事実: <引用>
- 提案: <修正後の方向>

## 除外
| Issue | 規則 | 理由 |
```

書いたら次の 3 行を出力して caller へ返す（ステップ 1 または 3 が失敗していれば 3 行目は `<!-- [issue-audit:failed] -->`。ステップ 1 で止まったときはレポートが無いので 1 行目を出さない）。batch-run から呼ばれたときはここで turn を終えず、caller が完了通知を出す:

```
監査レポート: {state_root}/.rite/state/issue-audit-{timestamp}.md
<!-- skill return signal: caller must continue next step -->
<!-- [issue-audit:returned-to-caller] -->
```
