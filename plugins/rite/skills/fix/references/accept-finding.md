### 2.1.A accept (認知のみ)

accept = 本 PR では直さない決着を `acknowledged` にし、fingerprint で次 cycle を suppression。別 Issue 化はしない。

**accept 選択時の処理 (4 つを同期実行)**:

1. **accept reason 分類 (必須、AskUserQuestion)**: accept の根拠を `scope-creep` / `out-of-scope` / `minor` / `user-override` の構造化 enum から必ず選択し、追加説明だけを `accept_reason_detail` の free-text として任意入力する。空値・enum 外・同義の自由記述だけで次へ進んではならない。trailer の `reason` 欄は `{accept_reason_class}: {accept_reason_detail}`（detail 空なら class のみ）とする。
   `accept_reason_rendered` を `{accept_reason_class}: {accept_reason_detail}`（detail 空なら class のみ）として一度生成し、reply と commit trailer の両方でこの同じ値を使う。class を含まない durable output は禁止する。
1.5. **Rejection Evidence Gate (state mutation 前)**: 4 分類すべてについて、別 reviewer の cross-validation と reject 対象 scenario の empirical counterfactual/revert test を [promotion-audit-review-fix-loop.md](../../pr-review/references/promotion-audit-review-fix-loop.md#rejection-evidence-gate) に従って実行し、両方の artifact を Decision Log に記録する。どちらかが欠ける場合はステップ 2 の `status = acknowledged` override・reply・fingerprint block・commit trailer の**いずれにも到達せず**、finding を修正対象へ戻すか AskUserQuestion で accept を取り消す。`user-override` も evidence gate の例外ではない。
2. **finding state の override**:
   - `status = "acknowledged"` を設定
   - `scope` を `nit-noted` に override (元 scope は `original_scope` として retain — reply 文言で参照)
3. **reply 投稿**: ステップ 2.4 の reply 機構を再利用（人間由来ゲート適用。rite 由来なら skip、fingerprint は続行）:
   ```
   accepted, will not be fixed in this PR. (reviewer scope: {original_scope}; user decision: accept{reason_suffix})
   ```
   `{reason_suffix}` は常に `; reason: {accept_reason_rendered}`。必須 class があるため空 suffix 経路は存在しない
4. **accept fingerprint 永続化**: `.rite/state/accepted-fingerprints-{pr_number}.txt` に当該 finding の fingerprint を append (詳細は下記 bash block)

**fingerprint 計算式 (ステップ 2.1.A 独自仕様 — accept 抑止専用。cycle 間比較は `pr-review/references/finding-cycling.md` の semantic 判断であり、本 hash はそれとは独立の機械契約)**:

```
fingerprint = sha1(normalize(file_path) + ":" + category + ":" + normalize(message))
```

- `normalize(file_path)`: `./` prefix のみ collapse (case-sensitive filesystem 保護のため lowercase 化・空白除去はしない)
- `category`: review-result-schema.md の `findings[].category` フィールド値 (例: `code_quality`)
- `normalize(message)`: trim + whitespace collapse (lowercase + 行番号除去等は行わない)


**Placeholder data flow** (`{finding_file}` / `{pr_number}` の取得元):

| Placeholder | 取得元 |
|-------------|--------|
| `{finding_file}` | 当該 finding の `findings[].file` / `line` / `category` / `description` を、ステップ 1.2.2 の reload 済み JSON から finding ID で引いて `{"file": ..., "line": ..., "category": ..., "description": ...}` の JSON として Write tool で書いた作業ツリー外の絶対パス。`line` は `integer \| null`（null は anchor sentinel）。pr-review 5.1.2.A の `fingerprint-check` に渡す JSON と同じ形 |
| `{pr_number}` | ステップ 1.0 正規化値。下の呼び出しへ literal substitute |

**finding JSON の `line` が null の場合**: `Acknowledged-finding:` commit trailer / `[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED` retained flag emit / fingerprint normalize すべてで `null` literal を避け、`anchor` sentinel (ステップ 1.3 の thread lookup 規約と統一) に正規化する。

**accept 永続化** (per accepted finding。`{finding_file}` / `{pr_number}` は Claude が事前 substitute):

```bash
bash {plugin_root}/scripts/fix-step.sh accept-persist --pr {pr_number} --finding-file {finding_file}
```

accept は **revocable** (state file の行削除)。`acknowledged` は ステップ 3 の commit 対象外。trailer は 3.2。

**`acknowledged` retained flag namespace** (ステップ 2.1.A 独立、ステップ 1.2.0 reason 表とは別 namespace):

| Flag | reason | Description |
|------|--------|-------------|
| `ACCEPT_FINGERPRINT_PERSISTED` | (success marker) | fingerprint state file への append が成功。`fingerprint=<sha1>; pr=<num>; file=<path>; line=<num\|anchor>` を含む (`line` は null/0/空のとき `anchor` sentinel に正規化される。ステップ 1.3 の thread lookup 規約と統一) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `pr_number_placeholder_residue` | `pr_number` placeholder が literal substitute されていない (空文字 / placeholder 残留 / 非数値)。`fix-step.sh` 経由では dispatcher が先に exit 2 で止める |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `finding_file_invalid` | `{finding_file}` を読めない、または file / category / description を文字列で持つ JSON ではない (category は非空)。空値から fingerprint を計算しない |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `sha1_helper_missing` | sha1sum / shasum のいずれも環境に存在しない (極稀、CI 環境異常) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mkdir_failed` | `.rite/state/` directory 作成失敗 (permission denied / read-only filesystem) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mktemp_failed` | tmpfile 作成失敗 (disk full / inode 枯渇) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mv_failed` | tmpfile から state file への atomic mv 失敗 |
| `ACCEPT_LIMIT_EXCEEDED` | (warning marker) | 同一 PR 内 accept 件数が 5 件以上に達した警告 |

永続化失敗は WARNING + flag で続行 (reply は済、suppression だけ諦める)。
