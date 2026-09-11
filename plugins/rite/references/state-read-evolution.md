# State Read Contracts

状態の読取・書込の現在の契約は、次の実装と参照文書を SoT とする。

- [`flow-state.sh`](../hooks/flow-state.sh): 状態ファイルの解決と `get` / `set`。
- [Session ID Validation Contract](./session-id-validation-contract.md): パスの安全性を検証する Layer 1 と UUID 形式を検証する Layer 2 の責務。両者の受理条件を統一しない。
- [`_validate-helpers.sh`](../hooks/_validate-helpers.sh) の `DEFAULT_HELPERS`: 依存 helper の存在・実行権限検査。
- [`_resolve-session-id-from-file.sh`](../hooks/_resolve-session-id-from-file.sh): session-id ファイルの選択、空白除去、UUID 検証と空文字 fallback。
- [`_resolve-cross-session-guard.sh`](../hooks/_resolve-cross-session-guard.sh) の Output 契約: legacy state の分類値。診断 stderr は分類 token の stdout と分離する。
- [Bash Trap Patterns](./bash-trap-patterns.md): 一時ファイルの cleanup と signal 処理。

参照にはファイル名と関数名・節見出しなどの意味的アンカーを使う。変更履歴は git log を参照する。
