### 2.2.1 Doc-Heavy Reviewer Override

**Execution condition**: `{doc_heavy_pr} == true`（ステップ 1.2.7）。
**Skip condition**: `{doc_heavy_pr} == false` — 候補を変えず ステップ 2.3 へ。
1. **tech-writer 必須昇格**: 候補にあれば selection_type を `mandatory` へ（`detected → recommended → mandatory`）。無ければ mandatory として追加する。
2. **code-quality co-reviewer 条件付き追加**: ステップ 2.3 「Code block detection in `.md` files」と同じスキャンを再利用し、diff 内に fenced code block があるときだけ追加する。
 **scan ロジック** (ステップ 2.3 と **同じ fenced code block 検出正規表現**。**scope は異なる** — 本ステップは `*.md` 全体、2.3 は Prompt Engineer Activation のみ。本ステップは tagged fence のみ):
rationale: design-rationale.md#doc-heavy-override-relationship

 ```bash
 # rationale: design-rationale.md#code-block-scan-notes
 set -o pipefail

 case "{base_branch}" in
 "{base_branch}"|"")
 echo "ERROR: {base_branch} placeholder が未展開、または空です (Claude の置換忘れ)" >&2
 echo " 対処: rite-config.yml の branch.base から base branch 名を取得して置換してください" >&2
 exit 1 ;;
 esac

 # trap + cleanup パターンの canonical 説明は ../../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
 git_diff_err=""
 _rite_review_p221_cleanup() {
 rm -f "${git_diff_err:-}"
 }
 trap 'rc=$?; _rite_review_p221_cleanup; exit $rc' EXIT
 trap '_rite_review_p221_cleanup; exit 130' INT
 trap '_rite_review_p221_cleanup; exit 143' TERM
 trap '_rite_review_p221_cleanup; exit 129' HUP
 git_diff_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p221-diff-err-XXXXXX") || {
 echo "ERROR: git_diff_err 一時ファイルの作成に失敗" >&2
 exit 1
 }

 # git diff を独立実行し exit code を明示 check (silent failure-hunter Finding 対応)
 if ! diff_out=$(git diff "{base_branch}...HEAD" -- '*.md' 2>"$git_diff_err"); then
 echo "WARNING: ステップ 2.2.1 の git diff が失敗しました (exit != 0)" >&2
 echo " 詳細: $(cat "$git_diff_err")" >&2
 echo " 考えられる原因: shallow clone (base branch 未 fetch) / 不正な branch 名 / git リポジトリ外で実行" >&2
 echo " 対処: git fetch origin {base_branch} を実行後に再試行、または rite-config.yml の branch.base を確認" >&2
 echo " fail-safe: code-quality co-reviewer 追加判定が実行できないため、明示的に追加します (silent skip より明示的追加を選ぶ — reviewer 数が 1 増えるだけの副作用に留めて Doc-Heavy mode の検証強度を維持する)" >&2
 # fail-safe sentinel で「判定不能」を後続に伝達
 has_added_fenced_block="__FAIL_SAFE_ADD__"
 else
 # rationale: design-rationale.md#code-block-scan-notes
 grep_out=$(grep -m 1 -E '^\+[[:space:]]*```[a-zA-Z]' <<< "$diff_out")
 grep_rc=$?
 case "$grep_rc" in
 0)
 has_added_fenced_block="$grep_out"
 ;;
 1)
 # マッチなし (期待動作) — 純粋散文 PR
 has_added_fenced_block=""
 ;;
 *)
 echo "WARNING: ステップ 2.2.1 の grep pipeline が IO/権限エラーで失敗しました (rc=$grep_rc)" >&2
 echo " fail-safe: 同じく __FAIL_SAFE_ADD__ sentinel で code-quality 追加に倒します" >&2
 has_added_fenced_block="__FAIL_SAFE_ADD__"
 ;;
 esac
 fi

 # rationale: design-rationale.md#code-block-scan-notes
 p221_iteration_id="{pr_number}-$(date +%s)"
 case "$has_added_fenced_block" in
 "__FAIL_SAFE_ADD__")
 echo "[CONTEXT] code_quality_coreviewer_add_reason=fail_safe_diff_or_grep_failure; iteration_id=$p221_iteration_id"
 ;;
 "")
 echo "[CONTEXT] code_quality_coreviewer_add_reason=none; iteration_id=$p221_iteration_id"
 ;;
 *)
 echo "[CONTEXT] code_quality_coreviewer_add_reason=fenced_block_detected; iteration_id=$p221_iteration_id"
 ;;
 esac

 # pipefail を block 終了時に解除 (後続 phase の pipeline が pipefail OFF を前提とする可能性があるため)
 set +o pipefail
 ```

 **後続 phase での読み取り**: `[CONTEXT] code_quality_coreviewer_add_reason=` を会話履歴から読む。複数行なら **`iteration_id=` が最大のもの**を最新とする。

 | reason 値 | 操作 |
 |-----------|------|
 | `fenced_block_detected` | code-quality を co-reviewer として追加 (既に候補にあれば selection_type を mandatory に引き上げ) |
 | `fail_safe_diff_or_grep_failure` | 同上 (fail-safe で追加経路に倒す)。WARNING を表示してユーザーに git diff 失敗を通知 |
 | `none` | 純粋散文 PR — code-quality 追加なし (no-op)。ステップ 2.3 の sole reviewer guard が後段で追加可能性を再評価する |

 selection_type の昇格パスは ステップ 3.2 Selection Type テーブルに従う: `detected → recommended → mandatory`。

 具体的な検証期待 (code-quality が追加された場合):
 - ドキュメント内 fenced code block の構文・引用・エラーハンドリング
 - ドキュメントの「実装例」コードが既存の coding style / naming convention と整合しているか
 - サンプル設定ファイル (yaml/toml/json snippets) のキー名・型・必須項目が実装スキーマと一致しているか

 既に候補なら selection_type を `mandatory` へ。fenced block が無ければ code-quality 追加を skip する。
3. **doc-heavy mode 指示の reviewer prompt 注入**: tech-writer 実行時に ステップ 4.5 へ:
 - `{doc_heavy_pr}` placeholder に `true` を set
 - `{doc_heavy_mode_instructions}` placeholder に `tech-writer-reviewer.md` の `## Doc-Heavy PR Mode (Conditional)` heading から **down to (but excluding) the next `##` heading** までを埋め込む (ステップ 4.5 placeholder 表の構造的ルールと**完全一致**。drift 防止のため両者は同じ抽出ルールに統一されている)

 **必須含有性 check**: `{doc_heavy_mode_instructions}` に次の 4 語が揃っていること。欠けたら **ERROR**、`doc_heavy_post_condition=error`、**overall assessment を `修正必要` に強制昇格**:

 - `Doc-Heavy mode finding requirements` — Evidence literal 形式義務化セクション
 - `Doc-Heavy mode finding-count rules` — 件数非依存 META rules セクション (ステップ 5.1.3 Step 2 で必要)
 - `META: All 5 verification categories executed` — 必須 META 行 (variant a/b の prefix)
 - `META: Cross-Reference partially skipped` — 部分スキップ用 META 行 (variant c)

 いずれかが欠けている場合の処理 (ERROR、stderr WARNING のみでは silent non-compliance を許してしまうため processing も block する):

 1. **ERROR を stderr に出力**:
 ```
 ERROR: tech-writer-reviewer.md の `## Doc-Heavy PR Mode (Conditional)` セクションから {doc_heavy_mode_instructions} を抽出しましたが、必須キーワード {missing_keywords} が含まれていません。
 tech-writer-reviewer.md の章立てが過去のバージョンから drift しているため、ステップ 5.1.3 Step 2 (件数非依存 META check) が silent fail する恐れがあります。
 Action: tech-writer-reviewer.md の `## Doc-Heavy PR Mode (Conditional)` セクション全体を確認し、必須サブセクションが含まれているか検証してください。
 Note: 本 drift は章立て(見出し)の canonical name 一致に関するものであり、doc_file_patterns の集合等価性(SoT 参照化により構造的に drift しない)とは別種。章立て drift の自動検出は将来 Issue で追跡。
 ```
 2. **Retained flag set**: `doc_heavy_post_condition = "error"` を context に明示保持。ステップ 5.4 表示でこの値を `error: tech-writer-reviewer.md の章立て drift により protocol 未伝達 (missing: {missing_keywords})` として表示する
 3. **Overall assessment 強制昇格**: ステップ 5 で計算される overall assessment を `修正必要` に強制 set する (本来 `マージ可` だった場合でも override する)。これにより e2e flow の review-fix loop が必ず再実行される
 これにより `internal-consistency.md` の 5 カテゴリ verification protocol が reviewer に直接伝達され、各 finding に `- Evidence: tool=Grep, path=src/config/services.ts, line=5-12` の **literal 形式**の行を必須化する仕様が reviewer 側で有効になる (tool は `Grep` / `Read` / `Glob` / `WebFetch` から 1 つ選択 — 山括弧はメタ記法であり literal に書いてはならない。詳細は [`tech-writer-reviewer.md`](../../../agents/tech-writer-reviewer.md) の "Doc-Heavy mode finding requirements" セクション参照)。ステップ 5.1.3 で post-condition check を実行する。
**Relationship to ステップ 2.3 sole reviewer guard**:
本 Override は ステップ 2.3 および sole reviewer guard の**前**に実行する。確定人数は fenced block 検出で分岐する:

| **`code_quality_coreviewer_add_reason`** | 確定 reviewer | sole reviewer guard の挙動 |
|--------------------------------------|--------------|------------------------------|
| `fenced_block_detected` | tech-writer (mandatory) + code-quality (co-reviewer) → ≥2 reviewers | guard は**発火しない** (既に >=2 のため) |
| `fail_safe_diff_or_grep_failure` | 同上 (fail-safe で code-quality を追加) → ≥2 reviewers | guard は**発火しない** |
| `none` (純粋散文 PR — fenced block なし) | tech-writer のみ 1 人 | **guard が発火**して fallback 経路で code-quality を追加 → 最終的に ≥2 reviewers が保たれる |

Possible `code_quality_coreviewer_add_reason` values: (`fenced_block_detected` / `fail_safe_diff_or_grep_failure` / `none`)
どちらの経路でも最終的に ≥2 reviewers。Override は加算のみで既存候補を消さない。
