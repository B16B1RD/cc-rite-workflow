# レビュー指摘への返信テンプレート (Why-only)

reviewer の指摘コメントへ返信する際は本テンプレートに従う。
**本文には Why のみを書き、Issue 番号 / PR 番号 / 修正履歴は記載しない**。

---

## 基本ルール

- **本文 = Why の 1〜3 文** + 必要なら該当行の inline 引用
- 同意して修正する場合も「何を意図したか / なぜそう直したか」を 1 文添える
- 禁止句リストの語句を含めない (commit message / PR description には許容)

## 禁止句リスト

reply 本文に書かない語句の一覧は
[Comment Best Practices](../../skills/rite-workflow/references/comment-best-practices.md)
の「禁止句リスト (SoT)」節 (原則 2 `no_journal_comment` 内) を参照する。

本ファイルは reply 用テンプレートだが、禁止句リストは **in-source コメント /
レビュアー返信 / docstring の全てに適用される共通 SoT** となっている。reply 本文
固有の追加禁止句は無く、SoT のリストに従えば十分。

**理由 (要約)**: コメントに番号や履歴を書くと、後追いで読むレビュアーが GitHub の
commit / PR / Issue ページを行き来する負担が増える。番号は将来の rename / squash
で意味を失う。**「なぜそうしたか」(Why) が分かれば commit history は code から
辿れる**ため、本文は Why に集中する。詳細は SoT 側を参照。

## 許可される構造

```
{Why の 1〜3 文}

{必要なら該当行への引用 (>) や短いコード片}
```

### 良い例

```
race window 回避のため flock を outermost block に移動しました。
deeper scope 内で bash の `local` で declare されると親 trap で
unset できないため、cleanup が機能しない既知問題があります。
```

### 悪い例 (禁止句あり)

```
ご指摘ありがとうございます。Fixed in commit abc1234.
別の PR 番号を理由の代わりに参照しないでください。
```

→ 番号と履歴に依存しており、なぜ修正したかが読み取れない。

## 役割分担

| 場所 | 番号・履歴 | 役割 |
|------|----------|------|
| reply 本文 | **書かない** | Why の 1〜3 文 |
| commit message | 書く | What + Why + Issue trailer |
| PR description | 書く | サマリ + `Closes #{N}` 等 |

reply は「会話の場」、commit は「履歴の場」、PR description は「サマリの場」。

---

📜 rite review reply template
