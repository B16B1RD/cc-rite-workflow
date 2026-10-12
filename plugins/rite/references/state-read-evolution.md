# State Read Contracts

状態の読取・書込の現在の契約は、次の実装と参照文書を SoT とする。

- [`flow-state.sh`](../hooks/flow-state.sh): 状態ファイルの解決と `get` / `set`。
- [Session ID Validation Contract](./session-id-validation-contract.md): パスの安全性を検証する Layer 1 と UUID 形式を検証する Layer 2 の責務。両者の受理条件を統一しない。
- [`_validate-helpers.sh`](../hooks/_validate-helpers.sh) の `DEFAULT_HELPERS`: 依存 helper の存在・実行権限検査。
- [`_resolve-session-id-from-file.sh`](../hooks/_resolve-session-id-from-file.sh): session-id ファイルの選択、空白除去、UUID 検証と空文字 fallback。
- [`_resolve-cross-session-guard.sh`](../hooks/_resolve-cross-session-guard.sh) の Output 契約: legacy state の分類値。診断 stderr は分類 token の stdout と分離する。
- [Bash Trap Patterns](./bash-trap-patterns.md): 一時ファイルの cleanup と signal 処理。

参照にはファイル名と関数名・節見出しなどの意味的アンカーを使う。変更履歴は git log を参照する。

## 状態パス・再入ガードの規則

状態ファイルの保存先、設定キー、再入ガードを設計・変更するときに適用する。条件 → 規則の順で書く。

- 新しい type / key を既存の機構へ流す前に、consumer の受理条件（`if` / `case` の arm）そのものを読む
- 保存パスの基準を変えたら、観測面（旧パスを前提にしたテスト・lint・表示パス・Decision Log・埋込み bash・復旧手順）を同時に sweep する。新しい既定を導入したら、全 caller の明示引数の渡しを grep して bypass を確かめる。standalone の保守ツールまで、「読む・書く・消す・表示する・検査する」の 5 動詞で全域を grep する
- 保護が依存する状態の成立経路を列挙し、3 経路以上あるなら、状態に依存しない置き方（保護対象と同じ場所に置く）を探す
- 完了済みを示すだけの再入ガードは、処理対象が増えると素通りする。処理した範囲を、処理本体と同じ単位で記録し、最新と一致するときだけ skip する
- sentinel 値を持つ上流の値を carry-forward するときは、sentinel を「値あり」と判定せず、除外の適用側と非適用側の両方を assert する
- 保留終了の context と品質合格の context は別に保存し、次の対象へ切り替えるときに履歴を退避する
- cycle カウンタが再入場で 0 にリセットされる仕様のときは、上限が累積でなく入場ごとの回数であることを仕様に明記する
- リセット側も固定キーで書き直さず、退避の記録と復元検証用の記録を残す
