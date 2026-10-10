# rite の知見の昇格経路と既存 Wiki の棚卸し

## 決定と適用範囲

rite 自体の挙動・スキル記述法に関する知見は、Wiki ページの新規作成・更新から外し、永続的な昇格候補として出力する。候補の消化には既存の Issue 作成・実装・レビュー経路を使う。Wiki 全体を定期的に移動する仕組みは追加しない。既存分は一括で一覧化した後、同じ責務を持つ機構ごとに分割して棚卸しする。

この文書は設計の決定であり、現行の取り込み動作を変更しない。経路の実装、既存ページの昇格・削除、設定の追加は後続作業で扱う。

判断の規範は [CLAUDE.md のプロジェクト原則](../../CLAUDE.md) と [知見のルーティング](../../plugins/rite/skills/rite-workflow/references/coding-principles.md#knowledge_routing-route-knowledge-to-its-durable-medium) である。強制できる知見は helper・gate・テストに、判断規則は実行時に参照される原則・reference に置く。既存の消費先がある場所を更新し、全文を別ディレクトリへコピーしただけでは完了としない。新しい scheduler・queue・将来用の設定キーは追加せず、人間の役割を要件・仕様の提示と完成品の動作確認に保つ。

## 決定時点の実測

計測日：2026-10-10。変更中の worktree ではなく、次の固定 commit の追跡ファイルを数えた。

| 対象 | 固定 commit | 範囲 | 件数 |
|------|-------------|------|------|
| Wiki 全ページ | `dc2af1f35a6c9d415d8b1eef9385772b894b24d0` | `.rite/wiki/pages/` 以下の Markdown | 686 |
| 印付きページ | 同上 | 冒頭の YAML frontmatter に `promote: rite-plugin` があるページ | 325 |
| 無印ページ | 同上 | 全ページから印付きページを除く | 361 |
| 移動済み reference | `7324cb23b5ea25212a1da74885c2af27e5fb1784` | `wiki-promotions/` の 3 ドメイン以下の Markdown | 38 |
| 印付きかつ `reference` あり | Wiki の固定 commit | frontmatter の `reference` がある印付きページ | 38 |

着手前の記載値である全 685 件・印付き 325 件に対して、再計測値は全ページが +1 件で、印付きは一致する。移動済み 38 件も一致する。異なる時点の内容差の原因は、この計測だけでは確定しない。印付き 325 件には移動済み reference へのポインタも含まれ、「未昇格 325 件」を意味しない。`reference` のない印付きは 287 件だが、こちらも未対応件数とは限らない。

全ページに `index.md`・`log.md`・`SCHEMA.md`・raw は含めない。移動済み件数に [README](../../plugins/rite/references/wiki-promotions/README.md) は含めず、[manifest.txt](../../plugins/rite/references/wiki-promotions/manifest.txt) の 38 パスとも照合した。README を含む Markdown ファイル総数は 39 である。

再計測は repository root から実行する。frontmatter の単一値として書かれた印を読み、本文・コード例中の文字列は数えない。別 commit で数える際は、件数と commit をセットで更新する。

```bash
python3 - <<'PY'
import re
import subprocess

wiki = 'dc2af1f35a6c9d415d8b1eef9385772b894b24d0'
plugin = '7324cb23b5ea25212a1da74885c2af27e5fb1784'

def paths(rev, prefix):
    output = subprocess.check_output(
        ['git', 'ls-tree', '-r', '--name-only', rev, '--', prefix], text=True)
    return [p for p in output.splitlines() if p.endswith('.md')]

pages = paths(wiki, '.rite/wiki/pages/')
marked = linked = 0
for path in pages:
    body = subprocess.check_output(['git', 'show', f'{wiki}:{path}'], text=True)
    match = re.match(r'\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)', body, re.S)
    if not match:
        raise ValueError(f'frontmatter を読めません: {path}')
    fm = match[1]
    if re.search(r'^promote:\s*(?:rite-plugin|"rite-plugin"|\x27rite-plugin\x27)\s*$', fm, re.M):
        marked += 1
        linked += bool(re.search(r'^reference:', fm, re.M))
root = 'plugins/rite/references/wiki-promotions/'
promoted = [p for p in paths(plugin, root)
            if p[len(root):].split('/')[0] in ('patterns', 'heuristics', 'anti-patterns')]
manifest = subprocess.check_output(
    ['git', 'show', f'{plugin}:{root}manifest.txt'], text=True).splitlines()
assert sorted(manifest) == sorted(p[len(root):] for p in promoted)
print(f'pages={len(pages)} marked={marked} unmarked={len(pages)-marked} '
      f'promoted={len(promoted)} marked_with_reference={linked}')
PY
```

取得・解析・照合が失敗したら、その対象と理由を記録して停止する。読めなかったページを件数ゼロや対象外として扱わない。

## 現行経路と再利用できる部分

[wiki-ingest](../../plugins/rite/skills/wiki-ingest/SKILL.md) の「LLM による読解と統合判定」は、rite 知見を昇格分類し、環境非依存なら印を付ける。機械検出可能なものは検出器候補を優先するが、同テーマのページがあれば既存ページを更新する。ページがない候補は `ingest_status: skipped`・`skip_reason: detector-candidate: ...` を raw に残し、log と完了報告に列挙する。したがって、分類節の「ページを作らない」だけでは Wiki への滞留を止められない。

raw・skip 理由・log・候補の完了報告は既にあるため、候補の保管基盤を新設する必要はない。一方、[現行の設計理由](../../plugins/rite/skills/wiki-ingest/references/rationale.md#detector-candidate) は候補を人間が起票を判断する材料としている。候補の起票・消化・完了との突合は既存の列挙だけでは成立しない。`ingested: true` の raw を通常の未取り込み検索だけで探すと候補を取りこぼす点も、後続実装で閉じる必要がある。

## (a) 新規知見の出力先

**採用：rite 自体の知見を永続的な昇格候補へ振り分ける。** 機械検出可能なものだけでなく、スキルの工程・質問の条件・参照文書の置き方も含める。新規ページを作らず、同テーマの既存 Wiki ページへも追記しない。ドメイン固有の知見は引き続き Wiki へ送る。

| 選択肢 | 利点 | 欠点・採否理由 |
|--------|------|----------------|
| 印を付けて Wiki を作り続ける | 現行手順を維持できる | 消費経路のない場所に rite 知見が増えるため不採用 |
| 機械検出可能なものだけ候補化する | 既存の検出器候補分類を使える | 判断規則が残り、既存ページ更新も止まらないため不採用 |
| rite 知見を候補化し、domain 知見を Wiki に残す | 原則に沿い、既存の永続化を再利用できる | 候補を消化する配線が必要だが、採用 |
| 取り込み中に配布プラグインを直接編集する | すぐに反映できる | ユーザーの依存物を変更し、更新時に失われるため不採用 |

候補の正本は raw に残す。既存の `ingest_status`・`skip_reason` の範囲で「Wiki 化をせず、昇格候補として保持した」ことと要約を表現し、既存の log・完了報告には raw へのパスを出す。新しい queue・状態ファイルは設けない。`ingested: true` は抽出完了であり、昇格完了ではない。混在した raw では各知見の行き先を個別に記録し、raw 全体の skip として domain 知見まで捨てない。

候補には、再分類に必要な要約・原文の範囲・適用条件・現行の消費先候補を残す。出力の成功を確認する前に raw を処理済みにしない。保存失敗なら raw を保持して理由を表示し、同じ入力から再実行する。現行の検出器候補に限った `skip_reason` と完了報告を、この意味へ広げる変更はまだ実装されていない。

## (b) 候補を消化する継続経路

**不採用：印付き Wiki を定期的に丸ごと移す経路。採用：候補を既存の Issue・実装経路で消化する経路。** (a) により新規 rite 知見は Wiki に入らないため、定期移動は新規分には不要である。既存分には一度の棚卸しが必要だが、それを常設 scheduler の根拠にしない。

| 選択肢 | 利点 | 欠点・採否理由 |
|--------|------|----------------|
| 定期 scan と全ページコピー | 既存印付きの検出は容易 | 新規経路と責務が重複し、重複・陳腐化も持ち込むため不採用 |
| 候補を表示し、人間が毎回採否を判断する | 新しい配線が少ない | 人間の途中判断を定常化し、消化を保証しないため不採用 |
| AI が既存の Issue 作成・実装経路に接続する | 既存の重複検出・検証・再開を使える | 接続と完了突合の実装が必要だが、採用 |

保守リポジトリで、昇格の消化を目的とする既存ワークフローの実行を入口にする。AI が raw の候補理由と log から処理済み raw も列挙し、未解決の候補を照合する。同じ責務の候補をまとめ、[issue-create](../../plugins/rite/skills/issue-create/SKILL.md) の重複検出・Projects 連携を使って既存の作業に結び付けるか、実装する契約を起こす。実装は [open](../../plugins/rite/skills/open/SKILL.md) と [iterate](../../plugins/rite/skills/iterate/SKILL.md) で進める。候補の検出・分類・起票を人間へ戻さず、要件や相反する仕様を AI だけで決められない場合に限って確認する。

入口の起動は要件の提示に相当する。時刻による自動起動は採らないが、起動後の消化は人間が各候補を選ぶことに依存させない。候補の保存と消化の接続は後続実装の責務であり、現行の完了報告を読むだけで自動化が済んだとは扱わない。

完了は、対象の helper・gate・原則・reference が実際の caller から使われ、対応する検証が通り、保守側の変更がマージされたことで判定する。候補を記録しただけ、起票しただけ、draft PR を作っただけでは完了にしない。raw の候補理由は出典として残し、既存 log に作業への対応と検証先を記録する。再実行時は raw のパスと知見の原文範囲、適用条件、消費先で照合し、既存 Issue とマージ済み変更を調べてから起票する。完了突合ができなければ未解決として保持する。

配布先では、候補の保存・報告までを当該プロジェクト内で行う。インストール済みプラグインを編集せず、保守リポジトリへ自動で内容を送らない。外部への共有は明示的な依頼があるときだけ行う。持ち込まれた候補は保守側で環境固有の情報を除去し、[配布境界](../../plugins/rite/references/distribution-boundary.md) を満たしたものだけ取り込む。単一ユーザーの保守を想定し、汎用の複数リポジトリ配送サービスは追加しない。

## (c) 既存ページの棚卸し

**採用：固定 snapshot で一括一覧化し、同じ責務・機構ごとに分割して処理する。** 1 ページごとの人間による移動判断と、全件を一度にコピーする案は採らない。前者は途中確認を常駐させ、後者は現在の規則と矛盾する記述まで配布してしまう。

対象は印付き 325 件を起点に、無印 361 件も同じ基準で走査する。印の有無で内容検査を省かない。移動済みの 38 ポインタも除外せず、昇格後に追加された知見がないか比較する。棚卸しと文書上の代表例の検証を区別し、この文書の作成で全件判定済みとは扱わない。

### 判定基準

判定単位はページ内の独立した知見である。1 ページで複数の判定が混在してよい。各知見の入力条件・期待結果・責務ファイルを整理し、domain 固有・陳腐化を確認した後、取り込み済みか未対応かを判定する。重複は別の知見との関係として併記でき、取り込み済みの記述にも適用する。どの判定にも必要な実測が取れなければ判断不能にする。

| 判定 | 実測する条件 | 処理 |
|------|--------------|------|
| domain 固有 | rite の変更では解決せず、当該プロジェクトの構造・運用条件が不可欠 | Wiki に残す。印があれば外す |
| 陳腐化 | 現行の責務ファイル・caller と同じ条件で、ページの期待結果が反証される | 現行規則を優先し、誤った記述を廃止。残る有効な知見は別に判定 |
| 取り込み済み | 現行の消費先に同じ条件・期待結果があり、到達する caller と検証結果を確認できる | 再起票・再コピーせず、正本へのポインタを維持 |
| 重複 | 別の知見と入力条件・期待結果・責務が一致し、独自の境界条件や反例がない | 代表に統合。出典と独自の事実は失わない |
| 未対応 | 現在も適用できるが、消費先または必要な検証に不足がある | (b) の候補へ送る |
| 判断不能 | 参照・測定が取れない、または現在の仕様が相反する | 理由と未確認の条件を保持し、成功・重複・陳腐化へ丸めない |

タイトルの類似、日付の古さ、検索での文字列一致だけでは判定しない。取り込み済みは `reference`・manifest の存在だけでは足りず、そのページの現在の内容まで正本に含まれるか確認する。機構へ取り込まれた場合は、ページ名が一致しなくても責務と実行結果で判定する。機械強制の主張なら正常系だけでなく負例が拒否されることを確認する。判断原則なら caller がその原則を読む入口と、条件に沿った判断を記録できることを確認する。

重複は移動先が確定するまで削除しない。取り込み済みのページは発見用ポインタとして残せるが、全文の二重管理は増やさない。ポインタは件数集計から勝手に除外せず、その内訳を明示する。削除や統合では index・関連リンク・backlink も更新し、raw の出典は保持する。

### 手順と完了条件

1. Wiki と plugin の commit を固定し、全 686 ページのパス、印・reference・出典を一覧化する。現行のファイルを直接変更しながら数えない。
2. 全ページを内容で分類し、各知見を抽出する。印付き・無印・ポインタがともに処理対象へ入ったことを確認する。
3. 同じ消費先と責務の単位でまとめる。たとえば tempfile、reviewer 出力、レビュー採否、worktree の機構を分け、各まとまりを既存 Issue の作業結果として記録する。固定の件数上限は置かない。
4. 上表を適用する。対象ページの blob、知見の原文範囲、条件、判定、plugin の責務ファイル、caller、検証コマンドと結果、統合先を既存の作業メモリ・Issue の結果に残す。新しい台帳システムは作らない。
5. 未対応分を既存の実装経路で処理する。矛盾する仕様だけを人間へ確認し、測定環境の失敗は診断・復旧して同じまとまりから再開する。未確認分は保持する。
6. 正本への取り込みを確認したまとまりだけ Wiki を整理し、既存の wiki-lint でリンク・矛盾を確認する。snapshot 以降にページが変わっていたら、差分を再判定してから整理する。

全入力ページの知見が処分先と対応し、未対応・判断不能が既存の作業へ結び付いていることを棚卸しの完了条件とする。知見の取り込み全体の完了は、未対応・判断不能が解消され、配布物の消費先と検証が成立した状態である。ページ数の減少だけをどちらの完了条件にも使わない。

## 印の付与基準

「rite のどの工程・出力・helper・gate・原則を直せば再発を防げるか」を問い、その責務が rite にあり、環境非依存または一般化できるなら rite 知見とする。機械検出可能性は取り込み方法の判断であり、昇格対象か否かとは独立する。

他プロジェクトの言語・モデル・ドメイン・ブランチ運用が不可欠で一般化できない知見は Wiki に残す。1 ページに両方あれば分ける。既存の `promote` は棚卸しの検索の手掛かりとしてのみ扱い、無印を対象外にしない。(a) の実装後は新規 Wiki ページに昇格候補の印を付け続けず、候補出力側で同じ分類を使う。

## 代表例への適用

以下は固定 commit の実ページを読んだ分類例であり、ページ全体の処分や棚卸しの実施ではない。Wiki の出典は上記 snapshot 内の repository 相対パスで示す。Wiki 専用ブランチのパスを、develop に存在する相対リンクとしては記述しない。

| Wiki ページ・対象の知見 | 比較先と観測 | 判定 |
|-------------------------|--------------|------|
| `pages/patterns/exit-code-semantic-preservation.md` の caller に終了コードごとの分岐を要求する規則 | frontmatter の reference と manifest に同名ページがあり、[配布版](../../plugins/rite/references/wiki-promotions/patterns/exit-code-semantic-preservation.md) に「Canonical pattern」「双方向契約」がある。[wiki-ingest](../../plugins/rite/skills/wiki-ingest/SKILL.md) の commit 結果処理にも終了コードごとの分岐がある | この規則は取り込み済み。後から追加された段落も含むページ全体の同期は別途照合 |
| `pages/patterns/trap-register-before-mktemp.md` の trap 登録を tempfile 作成より先にする規則 | [tempfile lib](../../plugins/rite/hooks/scripts/lib/tempfile.sh) は init 前の new を拒否する。[既存テスト](../../plugins/rite/hooks/tests/tempfile-lib.test.sh) が初期化前拒否・signal 終了・cleanup を検証する | この規則は機構に取り込み済み。古い手書き例はそのまま移さない |
| `pages/patterns/mktemp-failure-surface-warning.md` の description と概要に重ねて書かれた「mktemp 失敗を空パスへ握り潰さず WARNING を可視化する」規則 | 同じ mktemp 割り当て失敗を入力とし、silent な空パスへの縮退を避けるという期待結果が一致する。後半の「WARNING だけでは足りない」条件は同一とは扱わない | 重なる記述は重複として代表に統合。異なる失敗後の分岐や条件は独立した知見として残し、陳腐化・取り込み済み・未対応を別に判定 |
| `pages/heuristics/evidence-and-severity-are-independent-gates.md` の「実測済み MEDIUM 以下は修正せず移送する」規則 | [現行 fix 規則](../../plugins/rite/skills/fix/references/fix-relaxation-rules.md) は PR 起因の class A と除外判別子付き class B も fatal とする | 無条件の移送規則は陳腐化。ページの有効な記録規則まで一括廃止しない |
| `pages/heuristics/output-format-gate-needs-producer-side-delimiter-rule.md` | 印はないが reviewer の推奨事項の出力指示・検査・再生成指示の責務を扱う。プロジェクト固有の domain 条件を必要としない | 無印の rite 知見として昇格候補へ再分類。現行 3 箇所の充足を照合してから取り込み済みか未対応かを決める |

### 新規経路の設計上の検証

次の表は後続実装の入出力と観測条件である。現行システムを動かして新規経路が成功したという実測ではない。

| 入力・事象 | 分類・永続出力 | 消化主体と再開条件 | 完了証拠 |
|------------|----------------|--------------------|----------|
| rite 知見のみ | raw に候補理由と原文範囲、log に候補パス。Wiki の作成・更新なし | 保守側の AI が処理済み raw も列挙し、既存 Issue と照合 | 消費先の変更・検証・マージと候補の対応 |
| rite と domain 知見の混在 | 前者は候補、後者は Wiki。各知見の行き先を raw に残す | raw 全体の skipped 判定に依存せず、個別の行き先から未解決分を拾う | domain 知見が残り、rite 知見が Wiki に追加されないこと |
| 候補保存の失敗 | raw を処理済みにせず、失敗理由を表示 | 同じ原文から保存を再実行 | 保存先を再読込し、候補が欠落していないこと |
| 起票・実装・検証の失敗 | raw の候補を残す。作成済み Issue・PR は保持 | 既存作業の状態を照合し、失敗工程から再開 | 検証とマージが確認できるまで未解決 |
| 同じ候補の再実行 | raw パス・原文範囲・条件・消費先で既存作業を照合 | 対応済みなら再起票せず、Wiki に新規ページを作らない | 同じ知見の重複作業が増えず、対応する検証が確認できること |

## 後続実装で同期する記述と検証

本変更のファイルはこの設計文書だけとする。次の箇所は現行動作を説明しているため、経路を実装する変更で同期する。

| 対象 | 同期する節・理由 |
|------|------------------|
| README の Wiki コマンド案内、[wiki-patterns](../../plugins/rite/references/wiki-patterns.md) | Wiki に残る知見と昇格候補、消化の入口を区別する |
| [wiki-ingest](../../plugins/rite/skills/wiki-ingest/SKILL.md) と rationale | 昇格分類、first-match 表、既存ページ更新、raw 処理済み化、log、完了報告を同じルーティングにする |
| [Wiki schema](../../plugins/rite/templates/wiki/schema-template.md)、[page template](../../plugins/rite/templates/wiki/page-template.md) と実体 SCHEMA | 新規ページの promote と混在知見・既存ポインタの扱いを揃える |
| [issue-create](../../plugins/rite/skills/issue-create/SKILL.md) と消化の caller | 候補から既存 Issue への対応、重複検出、起票失敗・再開・完了突合をつなぐ |
| [移動済みページの方針](../../plugins/rite/references/wiki-promotions/README.md) | 全文移動の既存 38 件と、以後の機構・既存原則への統合を区別する |

この文書の確認では (a)(b)(c) の採否と根拠、代表例での判定、固定 commit の件数、無印例、変更ファイルの限定を検証する。文書内の相対リンクと禁止される番号参照は、このファイルを明示して確認する。`git diff --check` で差分の空白を確認し、計測コードを実行して値を照合する。

既存の `bash plugins/rite/scripts/tests/distribution-boundary-promotion-contract.test.sh` は plugin 配下の環境固有トークン・symlink・昇格分類を検査する。この設計文書は `docs/` にあり、その scan 範囲には入らないため、同テストだけで文書検証済みとは扱わない。機構に取り込み済みとした tempfile の代表例は `bash plugins/rite/hooks/tests/tempfile-lib.test.sh` で確認する。検証が失敗したら文書か判定を修正してから commit・PR 作成へ進む。
