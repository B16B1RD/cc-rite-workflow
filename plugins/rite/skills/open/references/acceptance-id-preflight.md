# 受入条件 ID の入口検査

open の品質評価後、claim・ブランチ作成・実装の前に実行する。`plugin_root`、Issue 番号、`owner_repo` は入口で確定した値を渡し、repo identity を cwd から取り直さない。検査・付与は helper に委譲する。非ゼロなら open を停止し、実装へ進まない。

strict reader は変更しない。まず原文を検査し、ID 欠落だけを補う。フェンス内・対応しない見出し・既存 ID・本文は書き換えない。番号は受理された節の既存 ID と衝突しない最小未使用番号を使う。読み手は本文全体で ID の一意性を要求するため、他の受理された節の ID も予約する。空節・重複 ID・その他の形式不正は候補検査で停止する。

```bash
bash {plugin_root}/hooks/scripts/open-acceptance-id-preflight.sh \
  --issue {issue_number} --repo {owner_repo} --cwd "{execution_cwd}"
```

`--issue` は Issue 番号、`--repo` は入口で一度解決して保持した対象 identity、`--cwd` は固定した実行先の絶対パス。helper は内部で作業先へ移り、origin と保持した identity の一致を検証してから API を呼ぶ。nested 呼出しで対象 identity を現在 cwd から再解決して上書きしない。

helper は `issue-body-safe-update.sh fetch` → 原文の strict extract → 欠落 ID だけ補完 → 候補の strict extract → safe apply → 最新本文の再取得と strict extract → Issue コメント記録の順で実行する。`fetch_failure_reason` / `apply_failure_reason` と reader の診断を隠さず出力する。apply の終了コードだけを成功根拠にしない。最新本文と候補も照合し、更新の不成立や同時変更を見逃さない。付与の記録先は既存の Issue コメントで、作業メモリ初期化前にも残せる。

全項目 ID 付き、または reader が `no_ac_section` として対象外にする本文では edit と付与記録を行わない。reader が拒否する見出しや形式は対象外へ降格せず、原因を表示して停止する。

成功時の stdout の `OPEN_AC_ISSUE_JSON=` 行を JSON として読み、`number` が対象 Issue と一致し `body` が文字列であることを確認する。欠落・不正なら停止する。その `body` でステップ 1.1 で保持した Issue 本文を置き換え、後続の計画・実装・受入条件検査へ渡す。ID 完備・対象外 skip の成功でも同じ置換を行う。helper は終了時に一時ファイルを削除するため、そのパスや修復前の本文を後続入力に使わない。Issue の他の取得済みフィールドと入口で保持した `owner_repo` は維持する。
