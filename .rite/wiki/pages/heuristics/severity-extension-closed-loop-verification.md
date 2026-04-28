---
title: "Severity 等級拡張は read/write/parse/measure の closed-loop 6 段階を verify する"
domain: "heuristics"
created: "2026-04-29T05:30:00+09:00"
updated: "2026-04-29T05:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260428T201715Z-pr-708-cycle-3.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T202946Z-pr-708-cycle-4.md"
tags: ["severity-levels", "cross-file-invariant", "silent-fallback", "scope-expansion", "closed-loop-verification"]
confidence: high
---

# Severity 等級拡張は read/write/parse/measure の closed-loop 6 段階を verify する

## 概要

severity 等級 (CRITICAL / HIGH / MEDIUM / LOW など) を**拡張する**ような fundamental change は、宣言した SoT 表だけ更新しても運用層 (write spec / JSON schema / read parser / extract regex / measure dict) のいずれか 1 段階が旧 4 値前提のままだと、reviewer が新等級で finding を発行した瞬間に silent fallback して severity が消失する。closed-loop 6 段階を機械的に verify するチェックリストと、scope expansion が 4 倍化した時点での Issue 分離判断基準を併記する。

## 詳細

### 発生事例 (PR #708 — `LOW-MEDIUM` severity 等級追加)

PR #708 は `severity-levels.md` に COMMENT_QUALITY 軸を追加し、cycle 1 では「同ファイル内の概要表に LOW-MEDIUM を導入」の +56 lines minimum diff だった。cycle 3 review-fix で「4 値運用層が 5 値拡張に追従していない silent fallback 経路」が初検出され、scope は 18 file → cycle 4 で 21 files / +132 lines に 4 倍化した。

具体的に検出された未追従箇所:

| 段階 | 場所 | 旧 4 値前提 → 新 5 値で何が起きるか |
|------|------|----------------------------------|
| (1) reviewer guidance | `severity-levels.md` 同ファイル内 5 箇所 (Severity Levels 表 / Matrix Impact 軸 / Matrix 行 / Rule 文 / Exception Categories 導入文 + Evaluation flowchart + Evaluation 表) | 概要表に追加した新等級が他箇所と矛盾し reviewer 判定が曖昧化 |
| (2) write spec | `pr/review.md` Phase で reviewer に出力させる severity literal 列挙 | 新等級が出力許可リストに無く reviewer LLM が出力時に旧等級へ rounding |
| (3) JSON schema enum | `references/review-result-schema.md` の severity enum | 新等級の JSON 値が schema validation で reject、reviewer 出力が捨てられる |
| (4) read parser | `pr/fix.md` で findings JSON を parse する severity case | 未知 severity literal が default 分岐に落ち silent fallback (例: HIGH に格上げ / LOW に降格) |
| (5) extract regex | `scripts/extract-verified-review-findings.sh` の severity regex | より長い alternative (`LOW-MEDIUM`) を `LOW` より先に置かないと greedy matching で短い方のみマッチして抽出脱落 |
| (6) measure dict | `scripts/measure-review-findings.sh` の集計 dictionary | 新等級が dict key に未登録で集計時に 0 扱い、ダッシュボードから消える |

加えて派生影響: `prompt-engineer-reviewer.md` の calibration 例文 / 13 reviewer skill files の Severity Definitions / Hypothetical Exception Categories の 4 reviewer 名表記 (`devops infra` / `Infrastructure` / `devops` の cross-file drift) がすべて連鎖 verify 対象になる。

### Closed-loop verification checklist

severity 等級を**拡張する** PR は本 PR を merge する前に以下 6 段階を mechanical に再 verify する:

```bash
# (1) reviewer guidance — 同ファイル内 5+ 箇所同期
grep -nE '(CRITICAL|HIGH|MEDIUM|LOW(-MEDIUM)?)' plugins/rite/references/severity-levels.md
# → 全表 / Matrix / flowchart / Exception Categories で新等級が一貫しているか目視 + count

# (2) write spec
grep -rn 'severity.*(CRITICAL|HIGH|MEDIUM|LOW)' plugins/rite/commands/pr/review.md
# → reviewer に literal を許可する列挙箇所で新等級が許可されているか

# (3) JSON schema enum
grep -nA5 '"severity"' plugins/rite/references/review-result-schema.md
# → enum: [...] に新等級が含まれているか

# (4) read parser
grep -rn 'case.*severity' plugins/rite/commands/pr/fix.md
# → case arm に新等級の分岐があるか / default 分岐が silent fallback していないか

# (5) extract regex
grep -n 'severity' plugins/rite/scripts/extract-verified-review-findings.sh
# → 新等級が regex alternative に追加されているか + 長い alternative が先に並んでいるか

# (6) measure dict
grep -nA5 'severity' plugins/rite/scripts/measure-review-findings.sh
# → 集計 dict / counter / option 列挙で新等級が登録されているか
```

いずれか 1 段階でも 4 値前提が残ると **silent severity fallback** 経路が成立する。検出は post-merge の reviewer 出力で初めて顕現するため、本 PR 内では再現困難。

### Regex alternative ordering

extract / measure の regex に新等級を追加する際、より長い alternative を **先に** 置く必要がある:

```bash
# ✗ 短い alternative が先 — `LOW-MEDIUM` の `LOW` 部分にマッチして `-MEDIUM` を取りこぼす
'(CRITICAL|HIGH|MEDIUM|LOW|LOW-MEDIUM)'

# ✓ 長い alternative が先 — `LOW-MEDIUM` 全体にマッチ
'(CRITICAL|HIGH|LOW-MEDIUM|MEDIUM|LOW)'
```

これは hyphenated severity (`LOW-MEDIUM` / `HIGH-CRITICAL` 等) を導入する際の規約として SoT 表に注記すべき。

### Self-reference calibration の stale 化

`prompt-engineer-reviewer.md` のように severity 例文を inline で持つ reviewer file は、参照先 doc (`severity-levels.md`) の structural change で容易に stale 化する。canonical 対策:

1. **具体的数値・例文を inline で書かない**: 「HIGH の代表例として `console.log` 残存」のような具体例は SoT 側に集約し、reviewer 側は forward-pointer (`severity-levels.md` 参照) のみ
2. **inline 例文が必要なら DRIFT-CHECK ANCHOR を併設**: `<!-- >>> DRIFT-CHECK ANCHOR: severity-levels.md の HIGH 等級例 <<<` を埋め込み、参照先と同期更新を契約化
3. **forward-pointer 採用しても分類粒度同期は別軸**: 概要表を SoT に向ける forward-pointer 設計を採用しても、概要表の分類粒度を SoT と意味論的に整合させ忘れると、本ファイル内宣言と矛盾した状態を新規導入する (LOW-MEDIUM vs LOW のような粒度差)

### Progressive scope expansion 制御

severity 拡張のような fundamental change は 1 PR では cross-file invariant 完全同期が困難。PR #708 の実測:

- initial scope: 2 files +56 行
- cycle 3 で 18 file へ拡大
- cycle 4 で 21 files +132 行 (initial の **4 倍**)

scope expansion が **3 cycle 連続で 5 file 超ずつ広がる** 場合、別 Issue / Epic 化を検討する判断基準:

1. **silent regression vs stylistic 区別**: write/read 経路の silent severity fallback (CRITICAL 級) は本 PR で必修。docstring の 4 値表記、ordering comparison の 4 軸列挙、terminology drift 等の stylistic は別 Issue で扱う
2. **HIGH のみ scope 内修正、MEDIUM/LOW は別 Issue**: PR #708 cycle 4 で 12 findings → HIGH 3 件 (silent regression 系) のみ本 PR で修正、残 9 件 (4 MEDIUM + 2 LOW from prompt-engineer/code-quality + 3 MEDIUM from tech-writer) を別 Issue (#709) で追跡する戦略を採用
3. **別 Issue 化の判断条件 (3 cycle / 5 file/cycle ルール)**: cycle 1 → cycle 2 → cycle 3 で同種 finding が継続検出され、各 cycle で 5 file 超の追加修正が必要な場合、本 PR は「Closed-loop の最低限を ship」+ 残作業を別 Issue という scope split を判断する

詳細な累積対策 PR の cycle escalation pattern は [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md) 参照。

### canonical 対策まとめ

1. severity 拡張 PR の **PR description に closed-loop 6 段階 checklist を明記** し、reviewer が本 checklist で mechanical verify する
2. **regex alternative ordering 規約**を SoT 表に注記 (hyphenated severity は長い順に並べる)
3. **forward-pointer 設計でも分類粒度の同期 verification は別軸** として明示
4. **scope expansion が 3 cycle / 5 file/cycle で別 Issue 化判断**: silent regression のみ本 PR、stylistic は follow-up Issue

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する](../anti-patterns/sot-reviewer-expression-drift.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](./canonical-list-count-claim-drift-anchor.md)

## ソース

- [PR #708 cycle 3 fix (closed-loop 6 段階 + regex alternative ordering)](raw/fixes/20260428T201715Z-pr-708-cycle-3.md)
- [PR #708 cycle 4 fix (progressive scope expansion 制御 + 別 Issue 化判断)](raw/fixes/20260428T202946Z-pr-708-cycle-4.md)
