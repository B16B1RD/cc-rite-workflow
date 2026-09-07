#### Target Comment Fast Path — when `{target_comment_id}` is set

When `{target_comment_id}` has been extracted from a comment URL argument, retrieve that specific comment directly and skip the broad comment retrieval below:


取得・所属 PR 検証・handoff の生成は helper が順番に実行する。`BLOCK_A_COMPLETE` / `BLOCK_B_COMPLETE` / `BLOCK_C_COMPLETE` と既存の failure reason は維持される。非ゼロ終了後は解析へ進まない。

```bash
bash "{plugin_root}/scripts/review-target-comment-fetch.sh" \
  --owner-repo "{owner}/{repo}" --pr "{pr_number}" --comment-id "{target_comment_id}" || {
  echo "[fix:error]"
  exit 1
}
```

**Parsing rule**:

> `$target_body` の実体は Block C が書き出した body_file であり、Claude は **Block C の `[CONTEXT] BLOCK_C_COMPLETE` marker の `body_file=` 値をリテラル使用して Read tool で読む**（Read tool は `${TMPDIR:-/tmp}` を展開できないため documented path 形式では読めない。specific path 必須、wildcard glob 禁止）。

1. If `$target_body` contains `## 📜 rite レビュー結果`: **ステップ 1.2.1 で定義された table パースロジック** (`### 全指摘事項` を起点に reviewer サブセクションごとの table を解析し ID ごとの finding を保持する手順) を `$target_body` に対して適用する。**ステップ 1.2.1 のコメント取得処理 (broad retrieval) は実行しない** — 対象コメントは既に取得済みのため
2. Otherwise (外部ツール: `/verified-review` skill、`pr-review-toolkit:review-pr` plugin、手動コメント等): **best-effort parse**
   - **期待スキーマ**: 最低 **4 カラム** または **5 カラム** を持つ markdown table。デフォルト列順は `| severity | file:line | content | recommendation [| confidence] |` (5 列目の confidence は optional)。ヘッダー行が存在する場合はそこから列順を推定する
   - **ヘッダー行検出 (正規キーワードセット)**: 表の 1 行目に以下のキーワードのいずれかを含む行を検出した場合、その列順を使用する。検出成否は必ずログに記録する:

     | 列名 | 認識キーワード (大文字小文字無視) | 必須/任意 |
     |------|-----------------------------------|----------|
     | severity | `severity`, `重要度`, `sev`, `level`, `深刻度`, `priority` | 必須 |
     | file:line | `file`, `ファイル`, `path`, `location`, `場所` | 必須 |
     | content | `content`, `内容`, `message`, `description`, `指摘`, `issue` | 必須 |
     | recommendation | `recommendation`, `推奨`, `fix`, `suggestion`, `対応`, `action` | 必須 |
     | confidence | `confidence`, `信頼度`, `conf`, `score`, `確信度` | **任意** (5 列目) |

     **検出ログ**: 以下を **stderr に必ず出力** する。E2E Output Minimization の対象外とし、parse の健全性を後追いできるようにする:
     - ヘッダー検出成功 (4 列): `Header detected: yes (4 columns). Column order: [severity, file, content, recommendation]. Confidence column: not found (will use Confidence=70 暫定値)`
     - ヘッダー検出成功 (5 列): `Header detected: yes (5 columns). Column order: [severity, file, content, recommendation, confidence]. Confidence column: found at index {N}`
     - ヘッダー検出失敗: `Header detected: no. Using default column order [severity, file, content, recommendation]. Confidence column: not assumed`
   - **ヘッダー行なし**: デフォルト列順 `severity | file:line | content | recommendation` を仮定する (上記の `Header detected: no` ログを stderr に必ず出力する)。Confidence 列はヘッダーなしの場合は仮定しない (ユーザーが明示的にヘッダー行を書いた場合のみ confidence 列を尊重する)
   - **カラム数不足の扱い**:
     - **3 カラム以下**: そのテーブル行を "unparseable" として skip し、警告ログ (`WARNING: Skipping unparseable row (columns < 4): <row preview>`) に記録する
     - **4 カラム**: severity / file:line / content / recommendation として抽出 (Confidence 列なし → Confidence=70 暫定値、後述の取り扱いルール参照)
     - **5 カラム以上**: ヘッダー行で confidence 列が検出された場合はその index から抽出。検出されなかった場合は最初の 4 カラムを使用し、5 列目以降は **silent 破棄せず WARNING で通知する**:
       ```
       WARNING: 5 列以上のテーブルですが、ヘッダー行から confidence 列を特定できませんでした。
       5 列目以降の値は破棄されます。Confidence 列を使うにはヘッダー行に
       'confidence' / '信頼度' / 'conf' / 'score' / '確信度' のいずれかを含めてください。
       ```
   - **severity 別名マッピング** (大文字小文字無視で完全一致を試行する。Title Case や lower case の値も正規化対象): CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW 以外の値が出現した場合、以下の別名マッピングを試行する。**比較は必ず case-insensitive** で行うこと (例: `Critical` / `critical` / `CRITICAL` はいずれも `CRITICAL` にマッチ):

     | 認識される別名 (case-insensitive 比較) | 正規化先 |
     |---------------------------------------|---------|
     | `Critical`, `BLOCKER`, `CRIT`, `🔴`, `重大`, `致命` | `CRITICAL` |
     | `Important`, `MAJOR`, `HIGH`, `🟠`, `重要`, `高` | `HIGH` |
     | `Minor`, `MEDIUM`, `🟡`, `中`, `Normal` | `MEDIUM` |
     | `Low-Medium`, `LowMedium`, `low_medium`, `中低`, `軽中` | `LOW-MEDIUM` |
     | `Low`, `INFO`, `TRIVIAL`, `🔵`, `低`, `情報` | `LOW` |

     > Title Case (`Critical` / `Important`) は CRITICAL / HIGH へ正規化する。
rationale: design-rationale.md#external-tool-title-case

     - 上記のいずれにもマッチしない場合、`MEDIUM` をデフォルトとし、**認識不能な severity 値の一覧をユーザーに必ず警告表示する** (silent fallback 禁止):
       ```
       警告: 認識不能な severity 値が {N} 件あります
       - 値: ['{val_1}', '{val_2}', ...]
       - すべて MEDIUM として扱いますが、適切な対応のため手動で再分類してください
       - 認識可能な severity: CRITICAL / HIGH / MEDIUM / LOW-MEDIUM / LOW (または上記の別名)
       ```
   - **全テーブル行がパース不能** または **抽出結果 0 件** の場合、警告を表示してユーザーに確認を求める (silent failure 回避):
     ```
     警告: コメント #{target_comment_id} ({reviewer_display}) から finding をパースできませんでした
     - スキップした行: {N} 行 (4 カラム未満)
     - 認識された行: 0 件
     内容プレビュー: {target_body の先頭 300 文字}
     オプション:
       - 手動で finding を入力
       - 別のコメント URL を指定
       - キャンセル
     ```

     **`{reviewer_display}` の展開**: ステップ 2.1 の `{reviewer_display}` 展開ルール表を参照する。Fast Path 経由で `target_author_mention_skip == "true"` の場合は `(不明なレビュアー)` / `(unknown reviewer)` に置換し、`@` prefix は絶対に生成しない (silent `@unknown` 誤記録防止)。通常時は `@{target_author}` を使用する。

   **選択肢の処理ルール (silent fall-through 禁止)**:

   | ユーザー応答 | 処理 |
   |-------------|------|
   | **手動で finding を入力** | ステップ 1.4 (Display Comment List) で finding 手動入力モードに移行 (入力スキーマ: `severity \| file:line \| content \| recommendation` のテーブル) |
   | **別のコメント URL を指定** | **Fast Path ハンドオフ一時ファイルを cleanup してから** ステップ 1.0 から再実行 (新しい argument を要求)。詳細は下記「Cancel/Re-run 経路でのハンドオフ cleanup 義務」参照 |
   | **キャンセル** | **Fast Path ハンドオフ一時ファイルを cleanup してから** `[fix:cancelled-by-user]` を出力して exit 0 |

   **Cancel/Re-run 経路でのハンドオフ cleanup 義務** (silent orphan ファイル防止):

   `[fix:cancelled-by-user]` exit 0 / `[fix:error]` exit 1 / ステップ 1.0 再実行のいずれかへ進む直前に、Fast Path で作成した一時ファイル (ハンドオフ 3 + raw_json + intermediate 3 + confidence_override、合計 8 本) を **明示的に削除する** bash 呼び出しを必ず実行する。これは ステップ 1.5 cleanup を経由しないすべての終了経路における defense-in-depth であり、ステップ 1.4 末尾の ステップ 1.5 cleanup から到達しない経路をカバーする:

   ```bash
   # Cancel / Re-run / Step C error 共通: ハンドオフ 3 + raw_json + intermediate 3 + confidence_override + pr-comment tempfile (合計 9 本) を削除してから exit する
   # Fast Path bash block 外なので変数は失われている → specific path で直接削除する
   # (wildcard glob は並列セッション破壊のため絶対禁止。rm -f は idempotent なので二重削除でも副作用なし)
   rm -f "${TMPDIR:-/tmp}/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
         "${TMPDIR:-/tmp}/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
         "${TMPDIR:-/tmp}/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt" \
         "${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt" \
         "${TMPDIR:-/tmp}/rite-fix-raw-{pr_number}-{target_comment_id}.json" \
         "${TMPDIR:-/tmp}/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt" \
         "${TMPDIR:-/tmp}/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt" \
         "${TMPDIR:-/tmp}/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt" \
         "${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt"
   ```

   この cleanup を実行する 3 つの経路:
   - Cancel 選択 → cleanup → **(E2E flow 時) FINALIZE handoff set** → `[fix:cancelled-by-user]` 出力 → exit 0。FINALIZE handoff (`FINALIZE:fix:cancelled-by-user:{pr_number}`) は ステップ 1.4 cancel と同一 — ステップ 1.4 の「FINALIZE handoff の設定 (E2E flow 時のみ)」bash を参照し、standalone では実行しない (AC-4)
   - Re-run 選択 → cleanup → ステップ 1.0 から新しい引数で再実行 (handoff は set しない — 終了ではなく再実行のため)
   - Step C 「2 回目も解釈不能」→ cleanup → `[fix:error]` 出力 → exit 1 (handoff は set しない — `[fix:error]` は clean terminal ではないため)

   **解釈不能の判定基準と再質問ループ** (silent fall-through 防止):

   **Step A — option ID 完全一致の厳格判定** (最優先):

   まず、ユーザー応答を trim + lowercase した文字列が以下の option ID 集合のいずれかに**完全一致**するかを判定する:

   | Option ID | 対応する選択肢 |
   |-----------|----------------|
   | `1`, `a`, `手動`, `manual` | 手動で finding を入力 |
   | `2`, `b`, `url`, `link` | 別のコメント URL を指定 |
   | `3`, `c`, `cancel`, `キャンセル` | キャンセル |

   完全一致が成立した場合、それを採用する。**これにより「キャンセルせず手動で入力する」のような否定形文は Step A では完全一致しないため次の Step B に進む**。

   **Step B — 否定語前処理を伴う部分マッチ判定** (Step A で完全一致しなかった場合):

   1. **否定語前処理**: ユーザー応答に否定語 (`せず`, `しないで`, `ではなく`, `なしで`, `without`, `not`) が含まれる場合、否定語**直前**のキーワードを打ち消し集合に加える。例: 「キャンセルせず手動で」 → 否定語「せず」の直前「キャンセル」を打ち消し集合 `{キャンセル}` に加える
   2. **キーワード判定表** (打ち消し集合を除外した上で、優先順位順に**最初にマッチした option を選択**):

      | 優先 | Option | マッチ条件 (大文字小文字無視、OR) |
      |------|--------|----------------------------------|
      | 1 | キャンセル | `キャンセル`, `cancel`, `中止`, `やめ`, `abort`（打ち消し集合に含まれる語はスキップ） |
      | 2 | 手動で finding を入力 | `手動`, `入力`, `manual` |
      | 3 | 別のコメント URL を指定 | `別`, `url`, `link`, `新しい`, `別の URL`, `another`（「コメント」単独は誤マッチが多いため削除。Step A の Option 2 と語彙を揃える） |

   <!-- rationale: design-rationale.md#interpretation-priority -->

   **Step C — Step A も Step B も決着しない場合**: 以下のいずれかに該当すれば**解釈不能**と判定する:

   - Step A で完全一致せず、Step B でもマッチキーワードが 1 つもない応答 (例: 「さあ...」「どうしよう」)
   - 空文字列 / whitespace のみの応答
   - 打ち消し集合により Step B の全 option がスキップされた結果、マッチが 0 件になった応答

   解釈不能を検出した場合の処理:

   1. **1 回だけ再質問**: 以下のメッセージを表示し、もう 1 度同じ AskUserQuestion を発行する。**「これは 2 回目の質問です」を必ず明示**する:
      ```
      ⚠️ これは 2 回目の質問です。応答を解釈できませんでした。
      3 つの option のいずれかを明確に選択してください (番号 1/2/3 または略語 a/b/c も可):

      1. 手動で finding を入力
      2. 別のコメント URL を指定
      3. キャンセル

      次回も解釈不能な応答の場合、処理を中止します。
      ```
   2. **再質問の応答も解釈不能の場合**: 上記「Cancel/Re-run 経路でのハンドオフ cleanup 義務」の bash block を実行して Fast Path の全一時ファイル (合計 8 本) を削除してから、`[fix:error]` を出力して exit 1 (**parse 0 件のまま ステップ 2 進入は禁止**)。エラーメッセージに「解釈不能な応答が 2 回続いたため処理を中止しました。fix loop を手動で再実行してください」を含める

   **重要**: parse 0 件で ステップ 2 (Categorization) に進入することは silent failure として禁止する。必ず上記の選択肢のいずれかを処理した上で次の Phase へ進むこと。
3. `{target_comment_id}` 経由で取得した finding のみを fix ループの対象とする。ステップ 1.2 の「全コメント取得」はスキップされる

**外部ツール由来 finding の Confidence ゲート** (`feedback_review_zero_findings` / `feedback_review_quality.md` 準拠):

外部ツールコメントは Confidence 列が無いことが多い。未記載のまま入れると 80+ ゲートを破る。

**取り扱いルール**:

| 状況 | 処理 | `confidence_override_findings` 追跡 |
|------|------|------------------------------------|
| テーブルに Confidence 列が存在し数値がある (`>= 80`) | そのまま Confidence として採用、取り込み | 不要 (override ではない通常の取り込み) |
| テーブルに Confidence 列が存在し数値がある (`< 80`) | 警告表示の上でスキップ | 不要 (取り込まないため) |
| Confidence 列がない、または数値が欠落 | **暫定値 Confidence=70 (< 80) を割り当て**、LOW に降格し、以下の警告を **stderr に必ず出力** する (silent pass 禁止): `WARNING: 外部ツール由来 finding {N} 件に Confidence 記載なし。暫定的に LOW/Confidence=70 として扱います。取り込み前にユーザー確認を求めます。` | **必須**: ユーザーが「Confidence 70 のままバイパス」を選択した finding を `confidence_override_findings` に append |
| severity 別名マッピングによる MEDIUM fallback (severity 不明) | 同様に Confidence=70 扱いとし、ユーザー確認を求める | **必須**: 上記と同じく override が確定した finding を append (severity 不明 fallback も Confidence override の追跡対象として扱う) |

暫定 Confidence 値が割り当てられた finding については、`AskUserQuestion` で以下のいずれかを選択させる:
- **Confidence 70 のまま 80+ ゲートをバイパスして投入 (policy override)** — finding を fix ループに投入するが、Confidence は 70 のまま保持し、`confidence_override=true` フラグを finding metadata に記録する。昇格ではなくバイパスであることをユーザーに明示する
- **LOW として記録のみ** — fix ループには投入せず、後日レビュー対象として残す

**Confidence override の追跡義務** (silent 改竄防止): 「Confidence 70 のままバイパス」を選択した finding については、以下の出力箇所で明示的に可視化する:
- ステップ 4.6 完了報告に `confidence_override: N 件` を追加
- ステップ 4.5.3 work memory のレビュー対応履歴に `- confidence_override: {file:line} (外部ツール由来、ユーザーがバイパスを承認)` を記録

**Retained context flags + tempfile-based persistence** (ステップ 4.5.3 / 4.6 / 4.3.4 の placeholder 展開時に参照する変数):


| Flag | 型 | 初期値 | 永続化先 |
|------|---|--------|---------|
| **`confidence_override_count`** | int | `0` | `wc -l < ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` の出力 (空ファイル → `0`) |
| **`confidence_override_findings`** | list[str] (`"file:line"` の配列) | `[]` | `${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` の各行 (1 行 1 finding) |

**Tempfile lifecycle** (specific path 必須、wildcard glob 禁止):

- **Path**: `${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` ({pr_number} は ステップ 1.0 で正規化済み)
- **作成タイミング**: ステップ 1.2 best-effort parse で最初の override 候補が出現した時点で **truncate 付きで作成** (`: > {path}` または `printf '' > {path}`)。`touch` は既存ファイルを truncate しないため使用禁止 (理由: [design-rationale.md#confidence-gate-notes](design-rationale.md#confidence-gate-notes))。
- **追記タイミング**: AskUserQuestion で「Confidence 70 のままバイパス」が選択されるたびに `printf '%s\n' "{file}:{line}" >> {path}`
- **読み出しタイミング**: ステップ 4.6 / 4.5.3 / 4.3.4 で `wc -l < {path}` (件数) / `cat {path}` (本文) で取得
- **削除タイミング**: 以下の **すべての終了経路** で明示的に削除する (orphan 防止、specific path 必須):
  - **E2E flow**: ステップ 5.1 の output pattern emit 直後
  - **Standalone flow**: ステップ 5 は skip されるため、ステップ 4.6 の completion report 出力後に明示的 cleanup bash block を実行する
  - **ステップ 1.4 cancel 経路**: 既存の Fast Path 一時ファイル cleanup bash block に追加 (同一 block 内で削除)
  - **ステップ 1.2 best-effort parse error 経路**: Cancel/Re-run cleanup に追加
- **並列セッション分離**: `{pr_number}` suffix で specific path とすることで、並列 fix 実行時の他セッション破壊を防ぐ。`${TMPDIR:-/tmp}/rite-fix-confidence-override-*.txt` のような wildcard glob は **絶対に使わない**

**Claude による retain と再注入の手順** (data flow の具体化、ファイル永続化版):

1. **H-1 修正**: ステップ 1.2 進入時 (Fast Path / Broad Retrieval bash block 冒頭の両方) で `: > ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` を **無条件 truncate** する。これにより、SIGINT/SIGTERM/SIGHUP で前セッションの override file が orphan として残った場合でも、次回起動時の混入を決定論的に防ぐ。また、ステップ 1.2 best-effort parse で最初の override 候補が出現した時点でも追加で truncate してよい (defense-in-depth、害なし)
2. AskUserQuestion で「Confidence 70 のままバイパス」が選択されるたびに、bash block 内で `printf '%s\n' "{file}:{line}" >> ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` を実行 (追記、`>>` で append)
3. ステップ 4.6 / 4.5.3 / 4.3.4 の placeholder 展開時、bash block で以下を実行して値を取得 (会話履歴 grep に依存しない、`2>/dev/null` の silent IO suppression も撤廃):
   ```bash
   override_path="${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt"
   if [ -f "$override_path" ]; then
     # wc -l の stderr を独立退避 (IO エラーの silent count=0 化で監査トレースが drop するのを防ぐ)
     override_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-confidence-override-err-XXXXXX") || {
       echo "ERROR: override_err mktemp 失敗" >&2
       echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=mktemp_failed_override_err" >&2
       exit 1
     }
     if ! confidence_override_count_raw=$(wc -l < "$override_path" 2>"$override_err"); then
       echo "ERROR: wc -l による override_path 読み出し失敗: $(cat "$override_err")" >&2
       echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=wc_io_error; path=$override_path" >&2
       rm -f "$override_err"
       exit 1
     fi
     confidence_override_count=$(printf '%s' "$confidence_override_count_raw" | tr -d ' ')
     # findings 一覧 (1 行 1 finding) は paste で "; " 区切りに変換
     if ! confidence_override_findings_raw=$(paste -sd ';' "$override_path" 2>"$override_err"); then
       echo "ERROR: paste による override_path 読み出し失敗: $(cat "$override_err")" >&2
       echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=paste_io_error; path=$override_path" >&2
       rm -f "$override_err"
       exit 1
     fi
     confidence_override_findings_str=$(printf '%s' "$confidence_override_findings_raw" | sed 's/;/; /g')
     rm -f "$override_err"
   else
     confidence_override_count=0
     confidence_override_findings_str=""
   fi
   ```
4. fix ループ中に他のフェーズから上記ファイルを上書きしない (append-only)
5. 終了経路の明示的削除:
   - **E2E flow (ステップ 5.1)**: `rm -f ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt`
   - **Standalone flow (ステップ 5.2)**: ステップ 4.6 の completion report 出力後に明示的 cleanup bash block で削除
   - **ステップ 1.4 cancel 経路**: Fast Path ハンドオフ cleanup bash block 内で同時に削除 (下記 Cancel cleanup block 参照)
   - **ステップ 1.2 best-effort parse cancel/error 経路**: 「Cancel/Re-run 経路でのハンドオフ cleanup 義務」bash block 内で同時に削除

**互換性**: 旧 `[CONTEXT] confidence_override_count = N; confidence_override_findings = [...]` 行の emit は、debug 補助として **継続して併用してよい** (人間が tail で見えるケースのため)。ただし機械的な値の取得は必ずファイル経由とし、`[CONTEXT]` 行の grep には依存しない。

**ステップ 4.6 / 4.5.3 / 4.3.4 で参照する placeholder 一覧**:

| Phase | placeholder | 展開ルール |
|-------|-------------|----------|
| 4.6 (完了報告) | `{confidence_override_count}` | `confidence_override_count` の値をそのまま展開 (0 含む) |
| 4.6 (完了報告) | `{confidence_override_files_suffix}` | `confidence_override_count == 0` なら空文字列、`>= 1` なら ` (file_a.ts:10; file_b.ts:42; ...)` (先頭スペース付きカッコ + 配列を `; ` 区切り) |
| 4.5.3 (work memory) | `{confidence_override_section}` | `confidence_override_count == 0` なら `なし`、`>= 1` なら同一行に `; ` 区切りで `findings` を列挙 (改行不要、Markdown bullet 構造を壊さない) |
| 4.3.4 (Issue 本文) | `{confidence_value}` | finding 単位の値。rite review 由来なら finding の severity (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW)、外部ツール由来かつ Confidence 列なしなら literal `70 (暫定)` |
| 4.3.4 (Issue 本文) | `{confidence_override_value}` | finding 単位の boolean。`confidence_override_findings` に当該 file:line が含まれていれば `true (外部ツール由来、Confidence 70 のまま 80+ ゲートをバイパスする policy override、ユーザー承認済み)`、それ以外は `false` |

override は常に trackable。パース後は ステップ 1.2.2 の共通 triage へ。Fast Path では Broad Retrieval / 1.2.1 フィルタを走らせず、1.2.1 の table parse だけを `$target_body` に適用する。
rationale: design-rationale.md#confidence-override-h1
