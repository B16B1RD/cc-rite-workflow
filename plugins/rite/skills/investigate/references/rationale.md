# /rite:investigate — 設計理由

`skills/investigate/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## grep-only-guess

AI エージェントによるコード調査では、grep 結果の行番号だけに頼ってコード構造を推測してしまう
問題が繰り返し発生した。特に複数行にまたがる構造（関数呼び出し、ハッシュ定義、条件式チェーン等）
や、大きなファイル（数百行超）で顕著。「grep → Read → クロスチェック」の 3 段階で推測による
誤報告を防ぐ。

## two-stage-search

コード構造の開始と検索対象が別の行にある場合、単一パターンの grep では見逃す。Step 2 の
キーワードが構造の一部として使われているかどうかは、Read で確認するまで判断しない。

## completeness-check

大きなファイルで grep ヒットが離れた行にある場合、ファイルの一部だけ読んで「全部確認した」と
判断しがち。件数照合がないと未検証が silent に残る。
