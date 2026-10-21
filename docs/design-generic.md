# flixlint を汎用の事実と問い合わせの部品へ作り替える設計書（本番）

- 書いた日: 2026-10-21
- 対象: flixlint（/Users/abab/Desktop/cms/flixlint・origin ababup1192/flixlint・今の版 v0.6.4）
- 材料: スパイク ababup1192/generic-spike 32caeb9（**v0.6.3 = 388ec46 の上に切ってある**。0.6.4 の速さの直し〈反射のキャッシュ・同じ JVM・Deep の遅延〉を含まないので、そのまま merge せず、部品ごとに写す。3 章 v0.7 の手順 1）、速くする作業 ababup1192/speed（/Users/abab/Desktop/flixlint-spans。常駐 server ff66ce6 と Names の絞り f7d741f〈`Unnamed(String)` と names.tsv〉。**どちらも手元のコミットで origin/main より 2 つ先・まだ push していない**〈10-21 の git branch -vv〉）、
  ゲームの規則（id-verify の origin/master 6e1e1719 の lint/rules.flix・lint/limits.json。submodule は v0.6.3 = 388ec46）、nextcms（lint/rules.flix・submodule は v0.4.0）
- 表記: **【測った】** は数を取った物（出どころを書く）、**【見込み】** は計算か推測、**【未測定】** は次の段で測る物

---

## 0. 何のための作り替えか

依頼主の言葉: 「作りの抽象度を上げて、規則を足すたびに flixlint をリリースする効率の悪さを無くしたい」。

### 人が手で触る所の数（準備も含む）

| 場面 | 今（v0.6.4） | 作り替えた後 |
|---|---|---|
| 新しい検査を 1 本足す（今の事実の表で書ける時） | 今も 1 か所（ゲームの rules.flix。数で止めるなら limits.json に 1 行） | 同じ（変わらない） |
| 新しい検査を 1 本足す（AST に載っているが、今の事実の表に無い事が要る時） | **5 か所＋リリース＋submodule**: shim の walker と Sink・Facts.flix の型と読み込み・README の事実の表・テストの期待値・ゲームの rules.flix ＋ リリース（タグ・shim の jar）＋ ゲームの submodule の更新。頻度: v0.5.1・v0.5.2・v0.6.2・v0.6.3 の 4 回のリリースは、どれもゲームの規則のために事実を 1 つ足す物だった（型エイリアス・分岐・Bool の字・case の引数）【測った: flixlint の git log】 | **1 か所**: ゲームの rules.flix だけ（数で止める規則は `lint/limits.json` に上限を 1 行。今のゲームの 7 本のうち 6 本がこの形【測った: id-verify origin/master の limits.json】）。リリースも submodule の更新も無し。rules.flix を変えた後の 1 回目はエンジンの組み直しが入る（今も同じ。15.3s【測った: f7d741f のコミット文・resolved・3 回の中央値】） |
| 部品（後述の層 2）に無い形を使う検査 | 同上 | **1 か所**: rules.flix の中に、層 1 と `Kind` で小さな関数を書く。部品へ移すのは後で、まとめて（急ぎではない） |
| AST に載っていない事（コメント・空白・`mod`/`use` の書き方・Flix 以外のファイル）を見る検査 | 同上 | flixlint では書かない。ゲームの Go の forbid（字の形の検査）に置く（今と同じ）。頻度: flixlint の 14 本に 0 本【測った: スパイクで 14 本全部が汎用の事実で書けた】。ゲームの forbid.local.json 23 本を形で分けると、AST の外が要るのは `child-mod`（`mod A.B` と書くか）の 1 本で、残り 22 本は呼び出し・case の組み立て・record の欄・Bool の型で書ける【見込み: パターンを読んで分けた。書き直してはいない】 |
| コンパイラが AST の外で決める事（体から推論した効果、`ApplySig` がどの instance に解決されたか） | 同上 | shim に足す（shim・テスト・README・リリースの 4 か所）。14 本に 0 本【測った】。頻度は低い見込み |
| Flix の版上げ | shim の walker と Sink（v0.6.4 の Facts.scala 939 行のうち walkBody・Sink・Typed・Resolved の約 560 行【測った: 191d324 の行番号から】）を直す・事実の表を全部見直す | shim の葉の型の扱い（約 30 行【見込み】）と層 2 の名前の対応を直す。生の `Kind` を書いたゲームの規則は、消えた名前の所がコンパイルで止まるので直す。shim の jar は今と同じく Flix の版ごとに 1 つ組む |

**狙いが達成されない所（残る物）**: (1) 数で止める規則は limits.json と 2 か所（ファイルは別でも、同じコミットで書く 1 件）。(2) AST の外の事は flixlint の外（Go の forbid）か shim の変更。(3) Flix の版上げは今と同じくリリースが要り、生の `Kind` を書いた規則は直す事がある。新しい検査の大半（14 本では全部）は狙いの通り rules.flix だけで済む。

---

## 1. 事実のスキーマ

shim は「規則が何を欲しいか」を知らない。AST の節（Node）・節の葉の値（NodeAttr）・型（NodeType の共有の表）と、メタ（SourceFile・外の宣言・Names）だけを出す。

### 1.1 Node（AST の節。1 節 1 行）

| 列 | 型 | 意味 |
|---|---|---|
| `id` | Int32 | 0 から順。親は子より先（shim が書く順） |
| `kind` | Int32（Kind の表の番号） | コンパイラのクラス名から段の頭を外した物（`Expr.ApplyDef`・`Pattern.Tag`・`Def`）。番号は `ast_schema` の kind の名前を辞書順に並べた位置（shim と AstKinds.flix が同じ並べ方で付ける）。表は 1.5 |
| `parent` | Int32 | 親の id。宣言の根は -1 |
| `slot` | Int32（Slot の表の番号） | 親のどの欄に居るか（`exps`・`exp1`・`rules`） |
| `index` | Int32 | 欄が並びの時の位置 |
| `root` | Int32 | その節が入っている宣言（def・enum・type alias・effect・instance の def）の id |
| `line` `col` `endLine` `endCol` | Int32 | コンパイラの位置。位置の無い節は親の物を継ぐ |
| `synthetic` | Bool | コンパイラが作った節（desugar の let・forM の match） |
| `type` | Int32（NodeType の id。無ければ -1） | **typed の段**: 式と pattern の型全部（スパイクは型の頭だけだった）。**resolved の段**: 書かれた型（型の注釈・引数の型）だけ |
| `effect` | Int32（NodeType の id。無ければ -1） | typed の段の式の効果。【未測定】量を見て、要らなければ出さない（決め D-6） |

宣言の型（引数・戻り値・case の欄・alias の右辺）は Node の子にせず、NodeAttr の値として NodeType の id を持つ（下）。スパイクは宣言の型を `Type.*` / `UnkindedType.*` の節として出していたが、段で節の名前が違うので、規則の側に段の違いが漏れていた。

### 1.2 NodeAttr（葉の値。1 値 1 行）

| 列 | 型 | 意味 |
|---|---|---|
| `id` | Int32 | 節の id |
| `name` | Int32（Attr の表の番号） | 欄の名前（`symUse`・`sym`・`cst`・`cst.lit`・`sop`・`label`・`mod`） |
| `value` | 文字列の表の番号 | 記号は修飾名（`List.map`）、変数は `x#123`、定数は種類（`Str`）と字（`cst.lit`） |
| `typeRef` | Int32（-1 か NodeType の id） | 欄が型の時（`tpe`・`retTpe`・`eff`）。この時 `value` は空 |
| `line` | Int32（-1 か行） | 値自身の行が節の行と違う時（呼び出しの名前の行 `symUse.line`。今の `Calls.line` と同じ考え） |

スパイクの `<name>.line` という別の属性は、この `line` 列にまとめる。
記号の `value` の綴りは names.tsv と同じ関数（今の shim の `symName`）で作る。層 2 は `Flixlint.Names.fnName(Fn.X)` の文字列と `value` を `==` で比べるので、綴りが 1 字でも違うと黙って 0 件になる（スパイクはこの形で 14 本が一致した）。

### 1.3 NodeType（共有の型の表。同じ型は 1 行）

型は構造が同じなら 1 行にまとめ（hash-consing）、id で引く。位置（loc）は鍵に入れない。

| 列 | 型 | 意味 |
|---|---|---|
| `tid` | Int32 | 型の id |
| `form` | 小さな enum | `Cst` `Apply` `Alias` `Var` `Arrow` `Record` `RecordRow` `Schema` `Effect` `EffUnion` `Other`。**段に依らない flixlint の語**（`Type.Cst` と `UnkindedType.Cst` のどちらも `Cst`） |
| `name` | 文字列 | `Cst` は型の名前（`Int32`・`List`・enum の修飾名）、`Alias` は alias の修飾名、`RecordRow` は欄の名前、`Var` は空 |
| `args` | Int32 の並び | 子の型（`Apply` は関数側と引数側、`Alias` は alias の引数） |
| `expandsTo` | Int32（-1 か tid） | `Alias` の展開先。**パッケージと標準ライブラリの alias も**（typed の段の `Type.Alias` は展開を持っている） |

スパイクの記録: alias の展開を節として毎回書くと、ゲームで 0.4M 節が 5.76M 節（348MB）になり溢れた【測った: スパイク。shim/Generic.scala の WhyNot】。共有の表なら展開は 1 回だけ書かれ、使う所は id で指す。

- 型の変数（`Var`）は鍵に大域の id を入れると、def ごと・呼び出しごとに別の行になる。鍵は「その型の中で出てきた順の番号」にそろえる（`a -> a` はどの def でも 1 行）。どの変数かを区別する規則は 14 本に無い。
- 歯止め（量）: shim は書きながら行数を数え、**節の数がソースの行数の 20 倍**、または事実の合計が **200MB** を超えたら書くのを止め、exit 4 で「どの表・どの宣言が一番多いか」を出す。今は 379,394 節 / 58,306 行 = 6.5 倍【測った: スパイクの typed と id-verify の src・test の行数】。walker は欄の名前を反射で読んで全部を歩くので、Flix の版上げで大きな欄（展開済みの型など）が増えると黙って膨らむ。それを JVM が溢れる前に、名前つきで止める。

- resolved の段の alias の展開は AST にある（`UnkindedType.Alias` も `tpe` に展開を持つ）。fixture の 4 つの alias とも両段で展開が付いた【測った: v0.7 の手順 3】。パッケージの alias は 1.4 の外の宣言（`ext.*`）にも出す。

### 1.4 メタ

| 表 | 列 | 意味 |
|---|---|---|
| `SourceFile` | `fileId, path` | walk に渡したファイル全部（今と同じ。定義の無いファイルも。`allowInFile` の確かめに要る）。Node の `root` の宣言はここの `fileId` を持つ |
| `ExternalDecl` | `sym, declKind, typeRef, members` | ソースが**使った**パッケージ・標準ライブラリ・Java の宣言だけ（全部は出さない）。`declKind` は def/sig/op/enum/case/alias/effect/java、`typeRef` は型（呼んだ関数の引数と戻り値・alias の展開）、`members` は効果の alias の中身（今の `EffAlias` の役。パッケージと標準ライブラリの効果の alias は使われていなくても出す。規則が書いた `Eff.X` を開くのに要る） |
| `Meta` | `format, stage, flixVersion, schemaHash, counts, ruleAstNames` | 形式の版・段・Flix の版・`ast_schema` の hash・表ごとの行数・規則のファイルが書いた `Kind`/`Slot`/`Attr` の名前ごとの「段に在るか・件数・行」（1.5）。読み込み側は `format` か `schemaHash` が合わなければ exit 4 |
| `Names.flix` ＋ `names.tsv` | （生成する Flix のソースと、全部の名前の表） | speed の絞りの形をそのまま使う。規則が書いた名前（`Fn.Auth_permit`）だけが enum の case で、ほかは `Unnamed(String)`。`names.tsv` は呼べる名前全部（呼ばれていない標準ライブラリの関数も。`disallowFunction` で「まだ誰も呼ばない関数」を書けるのは今と同じ）。**事実の側は Names を使わない**。Names の役は「規則が書いた名前がソースに在るか」をコンパイルで止める事だけ |

source_file と Names は汎用にできない（スパイクの結論）ので、メタとして残す。

### 1.5 Kind・Slot・Attr の表（語彙）と、版上げの境目

- shim は**コンパイラの jar を反射で見て**、TypedAst と ResolvedAst の全部の case class の名前・欄の名前・欄の型を出す（`ast_schema`: `stage, kind, slot, fieldClass`）。ソースが何を書いたかに依らないので、Flix の版が同じなら毎回同じ。
- そこから生成する `Flixlint/AstKinds.flix`（`pub enum Kind { case Expr_ApplyDef ... }`・`Slot`・`Attr`）を、規則の側の生の語彙にする。**両段の和で 1 つ**にする（段ごとに作ると、段を替えるたびにエンジンを組み直す）。**リリースの時に生成して flixlint のリポに置き**、実行のたびには作らない（shim の jar と同じく Flix の版ごとに 1 つ）。AstKinds.flix は `ast_schema` の hash を定数で持ち、shim は同じ hash を `Meta.schemaHash` に書く。違えば exit 4（番号の付け方がずれると kind を取り違えるので、`flixVersion` の比べでなく hash で見る）。
- 段に無い名前・事実に 0 件の名前を引いた時: **`ofKind` などの中では止めない**（規則は `Facts -> List[Violation]` の純粋な関数なので、中から exit も知らせもできない）。代わりに shim が規則のファイルの字から `Kind.X`・`Slot.Y`・`Attr.Z` を拾い（speed の `Names.usedIn` が `Fn.X` を拾うのと同じ正規表現の口）、その名前ごとに「今の段の `ast_schema` に無い」「今の事実に 0 件」を数えて `Meta` に書く。エンジンは判定の後（IO の側）で、それを「lint/rules.flix:行 Kind.X は resolved の段に無い／0 件」と stderr に出す。**違反でも exit 2 でもなく知らせ**（両段で流す規則のファイルが、段で分けて片方の段にだけある kind を書くのは正しい書き方なので、止めると誤って落ちる）。

**版上げで変わる所・変わらない所（shim のリリースが要るのはいつか）**

| Flix の版上げで起きる事 | 直す所 | shim のコードを直すか |
|---|---|---|
| 式の節が増える・名前が変わる・欄の名前が変わる | 層 2 の名前の対応（Flixlint.Flix）。生の Kind を書いた規則はコンパイルで止まる | 直さない（walker は `productElementNames` を読むだけ） |
| 葉の型（Symbol・SymUse・Constant・TypeConstructor・Name・Nel）の形が変わる | shim の葉の扱い（約 30 行） | 直す |
| Type / UnkindedType の形が変わる | shim の NodeType の正規化 | 直す |
| Root の持ち物（defs・instances・enums…）や resolved の段の入口（`Flix` の非公開の 2 つ）が変わる | shim の入口 | 直す |
| 名前は残ったまま、節が 2 つに分かれる・意味が変わる（例: `ApplyDef` から局所の def の呼び出しが別の節へ移る） | 層 2 の対応。生の `Kind` を書いた規則は**コンパイルが通るので止まらない** | 直さない。止める道は 6 章の「規則が引いた名前が事実に 0 件なら知らせる」と、版上げの時に出す `ast_schema` の差（足された・消えた kind と欄の一覧）をリリースノートに貼る事。残る危うさとして書いておく |
| 何も変わらない | — | 直さない |

どの場合も **shim の jar は Flix の版ごとに組み直してリリースする**（今と同じ。jar はコンパイラの内部の AST に対して compile されるため）。作り替えで減るのは「規則を足すたびのリリース」で、「Flix の版上げのリリース」は残る。

---

## 2. 部品（標準ライブラリ）

### 2.1 層の分け方

| 層 | モジュール | 知っている事 | Flix の AST の名前を書くか |
|---|---|---|---|
| 0 事実 | shim（Scala）が書くファイル | AST の形そのもの | — |
| 1 木 | `Flixlint.Ast` | 節・親子・欄・属性・型の表の読み方。Flix の語は知らない | 書かない |
| 2 Flix の語 | `Flixlint.Flix` | `Expr.ApplyDef` などの名前、**段の違い**（typed の `retTpe`・resolved の `tpe`、`bnd.sym` と `sym`） | **ここだけが書く** |
| 3 関係 | `Flixlint.Rel` | 今の事実の表（Calls・EffectOf・Handles・Constructs・ArgLit…）を層 2 から組んだ物。families はこれの上で判定する | 書かない |
| 規則 | 使う側の rules.flix | 層 2・3 を使う。足りない時だけ層 1 と `Kind` を使う | 原則書かない（2.4） |

**段の違いは層 2 で吸う**（スパイクの推し (2)）。型の段の違いは shim が NodeType の `form` を段に依らない語で書くので、層 1 で既に消えている。

### 2.2 API の形（Flix の型。名前は確定でなく形を示す）

層 1 `Flixlint.Ast`:

```flix
pub enum Ast(AstData)                        // 中は列の record（下）。外からは作らせない
pub enum Node(Int32) with Eq, Order, Hash    // 節の id。record を作らない
pub enum TypeRef(Int32) with Eq, Order, Hash // tid
pub enum Stage with Eq { case Resolved, case Typed }
pub enum TypeForm with Eq {                  // 1.3 の form。名前を持つ物だけ String を持つ
    case Cst(String), case Apply, case Alias(String), case Var, case Arrow(Int32),
    case Record, case RecordRow(String), case Schema, case Effect, case EffUnion, case Other
}

// 中の持ち方（pub にしない）。列は Vector[Int32]、索引は lazy で初めて引かれた時に作る。
// 作る所は region の Array で組んで Array.toVector で返す（スパイクの childLists と同じ。純粋な関数の中で書ける）。
type alias AstData = {
    stage = Stage,
    kind = Vector[Int32], parent = Vector[Int32], slot = Vector[Int32], index = Vector[Int32], root = Vector[Int32],
    line = Vector[Int32], col = Vector[Int32], endLine = Vector[Int32], endCol = Vector[Int32],
    synthetic = Vector[Bool], tpe = Vector[Int32],
    strings = Vector[String],
    childStart = Lazy[Vector[Int32]], childIds = Lazy[Vector[Int32]],     // CSR
    kindStart = Lazy[Vector[Int32]], kindIds = Lazy[Vector[Int32]],
    attrStart = Lazy[Vector[Int32]], attrName = Vector[Int32], attrValue = Vector[Int32], attrLine = Vector[Int32], attrType = Vector[Int32],
    typeForm = Vector[Int32], typeName = Vector[Int32], typeArgStart = Vector[Int32], typeArgIds = Vector[Int32], typeExpands = Vector[Int32],
    files = Vector[String]
}

pub def stage(ast: Ast): Stage
pub def ofKind(ast: Ast, k: Kind): List[Node]            // 索引（kind ごとの id の並び）から
pub def kind(ast: Ast, n: Node): Kind
pub def parent(ast: Ast, n: Node): Option[Node]
pub def ancestors(ast: Ast, n: Node): List[Node]          // 近い順
pub def children(ast: Ast, n: Node): List[Node]
pub def child(ast: Ast, n: Node, slot: Slot): Option[Node]
pub def childrenIn(ast: Ast, n: Node, slot: Slot): List[Node]
pub def descendants(ast: Ast, n: Node): List[Node]
pub def slotOf(ast: Ast, n: Node): Slot
pub def pos(ast: Ast, n: Node): { line = Int32, col = Int32, endLine = Int32, endCol = Int32, synthetic = Bool }
pub def root(ast: Ast, n: Node): Node
pub def file(ast: Ast, n: Node): String
pub def attr(ast: Ast, n: Node, a: Attr): Option[String]
pub def attrLine(ast: Ast, n: Node, a: Attr): Int32      // 値の行。無ければ節の行
pub def typeOf(ast: Ast, n: Node): Option[TypeRef]       // resolved の段の式は None

// 型（共有の表）
pub def form(ast: Ast, t: TypeRef): TypeForm             // Cst(name) / Apply / Alias(name) / Var / Arrow(n) / Record / ...
pub def typeArgs(ast: Ast, t: TypeRef): List[TypeRef]
pub def head(ast: Ast, t: TypeRef): Option[String]       // List[Int32] -> List
pub def typeNames(ast: Ast, t: TypeRef, aliases: AliasMode): List[String]   // AliasMode: Closed / Opened
pub def expand(ast: Ast, t: TypeRef): TypeRef           // alias を開く（パッケージの alias も）
pub def show(ast: Ast, t: TypeRef): String
```

層 2 `Flixlint.Flix`（宣言と式を、Flix の語で record にして返す）:

```flix
// 宣言
pub def defs(ast: Ast): List[DefDecl]       // { node, name, module, file, line, isPub, isInstance, annotations }
pub def params(ast: Ast, d: DefDecl): List[{ name = String, tpe = TypeRef, node = Node }]
pub def returnType(ast: Ast, d: DefDecl): Option[TypeRef]
pub def effects(ast: Ast, d: DefDecl): Set[String]       // alias を開いた効果（Db = DbRead + DbWrite は 2 つ）
pub def enums(ast: Ast): List[EnumDecl]     // 欄の型は TypeRef
pub def typeAliases(ast: Ast): List[AliasDecl]           // { name, expansion, recordFields }
pub def effectDecls(ast: Ast): List[EffDecl]

// 式
pub def calls(ast: Ast): List[Call]         // { node, callee, calleeKind (Def/Sig/Op/Java), line, args }
pub def tags(ast: Ast): List[TagUse]        // { node, constructor, args, inPattern }
pub def strLits / boolLits / intLits(ast: Ast): List[Lit]
pub def handlers(ast: Ast): List[Handler]   // run ... with handler
pub def lambdas / lets(ast: Ast): ...
pub def branches(ast: Ast): List[(BranchKind, Node)]     // if / match / typematch / extmatch / guard（分割代入と forM の生成は外す）
pub def placement(ast: Ast, n: Node): List[(String, Int32)]  // arg:<callee>:<i>・field:<label>・tag:<case>・tuple・let・op:<op>
pub def resolve(ast: Ast, n: Node): Node    // 型の注釈と let の束縛を透かす
pub def pipeStages(ast: Ast, e: Node): List[(String, Node)]
pub def lambdaPassedTo(ast: Ast, lam: Node): List[(String, Node)]
pub def shapeOf(ast: Ast, n: Node): String  // bool / unary:Not / op:And / call:<callee> / var / 節の名前

// どの def に居るか・違反の作り方
pub def defOf(ast: Ast, n: Node): Option[DefDecl]
pub def violation(ast: Ast, id: String, at: Node, line: Int32, message: String, reason: String): Violation   // ファイルは Ast から引けるので Facts は要らない

// 対象を Names の値で受ける形（下の「名前の受け渡し」）
pub def callsTo(ast: Ast, fn: Fn): List[Call]           // = calls(ast) を Flixlint.Names.fnName(fn) と比べて絞る
pub def tagsOf(ast: Ast, c: Case): List[TagUse]
pub def defOfFn(ast: Ast, fn: Fn): Option[DefDecl]
```

`Kind`・`Slot`・`Attr` は生成した enum（1.5）。層 1 の中では Int32 で持ち、`kind(ast, n)` の時だけ生成した `kindOfIndex(i: Int32): Kind`（`Vector[Kind]` を引く）で enum にし、`ofKind(ast, k)` は生成した `kindIndex(k: Kind): Int32`（match）で番号にする。どちらも AstKinds.flix に生成する（JVM の 1 メソッド 64KB の上限は、kind が数百なら届かない【見込み】）。

層 3 `Flixlint.Rel`（今の事実の表と同じ名前・同じ意味。一度だけ計算して覚える）:

```flix
pub def calls / effectOf / handles / constructs / callsInLambdaArgOf / argLits / argCalls
      / pipedInto / strLits / branches / argTypesAll / argTypesDeep / retTypesAll / caseTypesAll / caseTypesDeep
pub def reach(facts: Facts, seeds: Set[String], modules: List[String]): Map[String, String]   // transitivelyIn
```

名前の受け渡し: 部品の中は名前を **String** で持つが、**規則が対象を指す引数は Names の値（`Fn`・`Case`・`Enum`・`Type`・`Eff`・`Mod`）で受ける**（例 `Flixlint.Flix.callsTo(ast, Fn.Auth_permit)`・`tagsOf(ast, Case.Result_Err)`）。中で `Flixlint.Names.fnName` などで String にする。
理由: スパイクの汎用の規則は `"Auth.Permit"`・`"Result.Err"` を文字列で書いていた【測った: 32caeb9 の generic.flix・rules-generic.flix】。文字列だと、ソースの側で名前を変えた時に規則が黙って 0 件になる。今の flixlint の約束（README「A rule cannot quietly stop applying」）を守るため、プロジェクトと標準ライブラリの名前は Names の値で書かせる。String を受ける形（`callsToName`）は、Java のように Names に載らない名前のためだけに残す。
Flix で書けるか: `Flixlint.Flix` は flixlint のリポのライブラリだが、実行のたびに生成した Names.flix・AstKinds.flix と同じエンジンの中で組まれる（今の Facts.flix が `Flixlint.Names.fnName` を使っているのと同じ）ので、`Fn`・`Case` を引数の型に書ける。ライブラリの中では `Fn.X` の case を書けない（Names は規則のファイルが書いた名前だけを case にする）ので、ライブラリは `fnName`・`fnOf` の文字列だけを使う。
抜け穴: speed の Names は `Fn.Unnamed("Auth.permit")` を誰でも作れるので、規則がこれを書くと文字列と同じく黙って 0 件になりうる。規則のファイルに `Unnamed(` が在れば、1.5 の拾い方と同じ口で知らせる（止めない）。

### 2.3 読み込みの形（スパイクの推し (4)）

- 【測った: スパイク】typed の段の汎用の事実の読み込みに 9.2s。行ごとに `String.splitOn` して record の List にし、子と属性を節ごとの List に分けていたため。
- 本番: shim は **列ごとの二進のファイル**（Int32 の列・文字列は 1 つの表と位置の列）を書き、エンジンは Java の NIO で配列に読む。節は Int32 のまま扱い、子・属性・kind ごとの索引は「開始位置の列＋中身の列」（CSR）にする。索引は初めて引かれた時に作る（speed の版が Deep の行でやった `Lazy` と同じ考え）。
- Flix の側の持ち方: 列は `Vector[Int32]`（変更できない・読むのは純粋）で持つ。custom 規則は `Facts -> List[Violation]` の純粋な関数なので、region つきの `Array` は規則に渡せない。NIO で読んだ int の並びから `Vector[Int32]` を作るのに、箱詰めと写しがどれだけかかるかは【未測定】。v0.7 の最初の作業として、0.4M 節の列を読んで `kind`・`parent` を引く所だけを作って測り、1.0s に届かなければ Java の `int[]` を包んだ型と、純粋として扱う読み口（`unchecked_cast`）に替える。Flix は型の引数ごとにコードを作り分ける（単相化）ので、`Vector[Int32]` の中身は箱詰めしない `int[]` の見込みで、その時は写し 1 回で済む【見込み・手順 1 で確かめる】。
- 人が grep する TSV は `--facts-tsv` を付けた時だけ書く（決め D-3）。
- 同じ JVM で shim から配列を手渡す道は取らない。エンジンは別の class loader（platform を親にした URLClassLoader）で読まれるので、手渡しには両側の取り決めが要る。二進のファイルの読み込みで目標（4 章）に届くなら要らない。【見込み】typed で 40MB 前後の読み込みは 0.1〜0.3s。

### 2.4 規則の作者が Flix の AST の名前を知る必要はどこまでか

- **層 2・3 で書ける規則は、Flix の AST の名前を知らなくてよい**。スパイクで書き直した 14 本は、層 2 に当たる部品（`calls`・`callee`・`args`・`isPub`・`paramTypes`・`typeNames`・`branches`・`placement`・`seeThrough`）でほぼ書けた。生の名前が残ったのは `Expr.Tag`・`Expr.Cst`・`Pattern.Cst`・`TypeAlias`・`Expr.Unary`/`Expr.Binary`（shapeOf の中）の 5 種類で、これらは層 2 の `tags`・`strLits`・`typeAliases`・`shapeOf` に入れる。
- 層 2 に無い形は、rules.flix の中で層 1 と `Kind` を使って書いてよい（リリース無しで足せるのはこの道があるから）。生の名前は文字列でなく **生成した enum `Kind`・`Slot`・`Attr`** で書くので、Flix の版上げで名前が消えたらコンパイルで止まる（名前が残ったまま節が分かれた時は止まらない。1.5 の表と 6 章）。
- rules.flix で層 1 を使って書いた関数が 2 つのプロジェクトで要るようになったら層 2 へ移す（その時だけリリース。急ぎではない）。

### 2.5 families の置き場所

families（disallowFunction など 11 本）は層 3 の関係の上で判定する。判定の 1 文（README「The judgments」）は変えない。families の項目の書き方（`path = Fn`・`effects = Set[Eff]`）も変えない。今の `Flixlint.Facts` の record（`Call = { caller: Fn, callee: Fn, line }`）は、並走の 2 版の間だけ層 3 から作る写しとして残し（3 章）、消す版で String の record に替える（speed の絞りの後は、`Fn` は規則が書かない名前を `Unnamed` で持てるので、写しは v0.8 でも作れる）。

---

## 3. 移行の段取り（版ごと）

前提の順: **speed（常駐の server ff66ce6 と Names の絞り f7d741f）を先に main へ入れて 0.6.5 を出す** → 汎用の v0.7 → v0.8 → v0.9。v0.7 の枝は 0.6.5 のタグから切る。0.6.5 が出る前に始める時は f7d741f から切り、0.6.5 が出たら rebase する（speed の 2 コミットがそのまま main に入るなら差は出ない）。

### v0.7.0 汎用の事実を足す（旧い事実と並走）

**手順**（上から順に。各手順の終わりで 1 コミット。「入力 → 出力 → 済んだと言える事」）:

| # | 何をする | 入力 | 出力 | 済んだと言える事 |
|---|---|---|---|---|
| 0（1 週目の頭） | 基準を取る | 0.6.5（無ければ f7d741f）・id-verify の origin/master | 4.1 の表の「基準」の 4 つ（resolved・typed の 1 回きり・常駐の 2 回目・最大 RSS） | Mac mini で 5 回の中央値を 4.1 に書いた |
| 1（1 週目） | 読み込みの形を先に決める。スパイクの Generic.scala の walker に、Node の `kind`・`parent` の 2 列だけを二進で書く口を足し、`Flixlint.Ast.load` の最小（2 列を `Vector[Int32]` に読み、`ofKind`・`parent` を引く）を書く | 32caeb9 の shim/Generic.scala（手で写す。0.6.4 の反射のキャッシュ `Facts.field` を使う形に直す）・ゲームの typed の事実 | 2 列のファイル・最小の Ast.flix・測った数 | Mac mini でゲームの typed を 5 回、`load=` の中央値を README の Notes に書く。2 列は約 0.76M 個の Int32 なので、1M 個あたりの秒に直し、全部の列（約 8M 個【見込み: 4.1 の行数×列の数】）で 1.0s に届くなら `Vector[Int32]`、届かなければ `int[]` を包む形に決め、どちらにしたかを Notes に 1 行 |
| 2（1 週目） | `ast_schema` と AstKinds.flix の生成 | コンパイラの jar | `ast_schema`・`src/Flixlint/AstKinds.flix`（`Kind`・`Slot`・`Attr`・番号の変換・hash） | 2 回生成して `diff` が 0。shim が書く番号と AstKinds の番号が、fixture の全節で同じ名前を指す（テスト 1 本） |
| 3 | 1 章の全部を書く（Node の全列・NodeAttr・NodeType の共有の表・ExternalDecl・Meta・量の上限） | 手順 1・2 | 二進の事実一式・`--facts-tsv` の TSV | fixture とゲームで、両段の `Meta.counts` を stderr に出し、4.1 の表に足す（型の表の行数の【未測定】をここで埋める）。量の上限の fixture（完了条件 4） |
| 4 | 層 1 `Flixlint.Ast` の全部 | 手順 3 | Ast.flix | スパイクの Ast.flix の部品を層 1 の上に写し、fixture の custom 7 本（generic.flix）が今の版と同じ違反を両段で出す |
| 5 | 層 2 `Flixlint.Flix` と、14 本を層 2・Names の値で書き直す | 手順 4・spike/game/rules-generic.flix | Flix.flix・test/fixture/rules/generic.flix（make test に入る）・spike/game/rules-generic.flix（ゲームのソースが要るので make test には入れず、Mac mini で id-verify に向けて比べる） | 完了条件 1 |
| 6 | 規則のファイルが書いた `Kind`/`Slot`/`Attr` の知らせ（1.5）と、規則ごとの `judge=` | 手順 5 | shim の拾い・Engine の知らせ | 完了条件 3 |
| 7 | 秒・量・RSS を測り、README（事実の表に「汎用の事実」の節）を書いて 0.7.0 を出す | 全部 | タグ・リリースノート | 完了条件 2・5 |

比べ方（完了条件 1）: 同じソースに、今の規則（rules-current.flix）と汎用の規則（rules-generic.flix）を `--rules` で替えて 2 回流す。`--limits` は付けない（上限で畳まれない全件を出すため）。出力の違反の行を `sort` して `diff`。段は `--stage resolved` と `--stage typed` の 2 回ずつ。

- shim: `Generic.scala` を本番にする（スキーマは 1 章・列ごとの二進・型の共有の表・式の型全部・外の宣言・AstKinds の生成）。旧い walker（Typed/Resolved の emit・Sink）はそのまま。スパイクの shim/Facts.scala・bin/flixlint・Engine.flix・Facts.flix の変更は 0.6.3 の上の物で、0.6.4 と speed の変更を巻き戻す形になっているので、取り込まない（Generic.scala と Ast.flix とテストの規則だけを写す）。
- ライブラリ: `Flixlint.Ast`（層 1）・`Flixlint.Flix`（層 2）を足す。`Flixlint.Facts` に `ast(facts)` を足す。旧い API は触らない。
- 汎用の事実は既定で出す（並走の間の時間の上乗せは 4 章の目標の中）。
- テスト: スパイクの `test/fixture/rules/generic.flix`（fixture の custom 7 本）を make test に入れ、旧い事実で書いた同じ規則と違反を突き合わせる。ゲームの 7 本（`spike/game/rules-generic.flix`）は手順 5 の比べ方で Mac mini で確かめ、出力の差（0 行）をコミット文に貼る。
- **完了条件**（どれも「出力を並べて差が 0」で確かめる）:
  1. custom 14 本（fixture 7 本・ゲーム 7 本）を汎用の事実で書いた版と今の版の違反一覧が、**resolved と typed の両方で全件一致**（ファイル・行・id・文）。examples の規則は今の版のまま `test/expected-examples.txt` と一致。
  2. 秒と量が 4 章の並走の目標の中（Mac mini で 5 回の中央値）。最大 RSS が 0.6.5 の 1.3 倍以下（`/usr/bin/time -l` を 0.6.5 と並べて 1 回ずつ）。
  3. AstKinds を 2 回生成して差が 0。typed にだけある kind を書いた規則を fixture に 1 本置き、resolved で流すと「段に無い」の知らせが出て exit は変わらない（`test/expected-*.txt` に知らせの行を入れて比べる）。
  4. 量の上限（1.3 の 20 倍・200MB）を超える fixture（大きな record の alias を 100 か所で使う）で、溢れずに exit 4 で止まるか、上限の中に収まる。
  5. 手順 1 で測った読み込みの数と、手順 7 の秒・量・RSS を README の Notes に書く。
- 使う側: ゲームは submodule を v0.6.3 から v0.7.0 に上げ、**新しい規則はこの版から汎用で書く**。既にある 7 本は v0.8 までに汎用へ書き直す（スパイクの rules-generic.flix が下書き。見回り役の作業・1 本ずつ・違反一覧の一致で確かめ）。nextcms は触らない（3.5）。

### v0.8.0 families を部品の上へ（旧い事実はまだ出す）

- エンジン: families 11 本の判定を層 3（汎用の事実から組んだ関係）へ移す。`Flixlint.Rel` を足す。
- `Flixlint.Facts` の旧い API は、層 3 から作る写しに替える（shim の旧い TSV は読まない）。custom 規則の書き方は変わらない。
- 確かめのため、shim は旧い TSV をまだ出し、テストの口 `test/compare-old.sh` が「旧い TSV から作った関係」と「汎用の事実から作った関係」を表ごとに比べる。層 3 の関係を旧い TSV と同じ列・同じ綴りで書き出す口（`FLIXLINT_DUMP_REL=DIR`。エンジンの IO の側で、判定の前に 1 回）を v0.8 で足し、compare-old.sh は表ごとに `sort` した 2 つのファイルを `comm` で比べるだけにする。この口は v0.9 で消す。
- **完了条件**: 旧い事実の**全部の表**（ゲームの typed で 28 表: SourceFile・Def・Enum・Eff・EffAlias・TypeAlias・AliasTypeAll・Calls・EffectOf・Handles・Constructs・CallsInLambdaArgOf・ArgLit・ArgCall・PipedInto・StrLit・Branch・BoolLit・TagArg・ArgType/All/Deep・RetType/All/Deep・CaseType/All/Deep【測った: tmp/gb/cur-typed/facts の一覧】）が、層 3 から作った物と行の集合で一致する。fixture・examples・ゲームで、resolved と typed の両方。`test/compare-old.sh` は表ごとに「旧いだけ・新しいだけ」の行数を出し、全部 0 で通る。違反一覧の全件一致を、fixture・examples・ゲームで両段。nextcms の rules.flix（families 9 種を使う唯一の大きな規則ファイル）は、nextcms が Flix 0.76 のまま（flixlint 0.5 以降は Flix 0.78 でしか動かない）なので流せない。代わりに、nextcms の families の項目（disallowFunction・callsTogether・effectsTogether・handlers・constructors・callsInLambda・callsWithArg・caseArgTypes・dependencies）の形を fixture に 1 つずつ写して確かめる。違いが出た表は、どちらが正しいかを 1 行ずつ書いてから直す（旧い walker の誤りなら README の Notes に書く）。
- 使う側: ゲームは v0.8 に上げる（rules.flix の変更は無い見込み）。

### v0.9.0 旧い事実を消す（互換を壊す版）

- shim: 旧い walker（Typed.emit・Resolved.emit・Sink の表）と旧い TSV を消す。
- ライブラリ: `Flixlint.Facts` の旧い record（Fn で型づけした行）を消し、層 3 の String の record だけにする。README の事実の表は、1 章のスキーマと層 2・3 の部品の表に替える。
- 互換を壊す理由（1 行）: 「旧い事実の表とその walker（Flix の版上げのたびに直す約 560 行）を消し、事実を汎用の Node の 1 通りにするため。規則を足すたびのリリースは v0.7 で、ソースが変わるたびのエンジンの組み直しは speed の Names の絞りで、既に無くなっている」。
- **完了条件**: v0.8 と同じ違反一覧の全件一致（fixture・examples・ゲーム、両段）。旧い事実の名前（`calls.tsv` など・`Flixlint.Facts.calls` の Fn 版）が src と shim に 0 件（`grep` の出力を貼る）。秒と量が 4 章の最終の目標の中。リリースノートに 3.5 の「v0.4 から v0.9 へ跳ぶ時に直す所の一覧」がある。
- 使う側: ゲームは custom 7 本が既に汎用なので submodule を上げるだけ。nextcms は v0.4.0 のまま（依頼主の決定 10-21。3.5）。

### 3.4 speed の作業との境界（同じ人が speed → 汎用の順に入れる時にぶつかるファイル）

ファイルの一覧は git から取った【測った: `git show --stat` の ff66ce6・f7d741f（speed）と 32caeb9（スパイク）】。スパイクは 0.6.3 の上なので、スパイクの差分を当てると speed と 0.6.4 の変更を巻き戻す。**スパイクから写すのは新しいファイル（Generic.scala・Ast.flix・generic.flix・spike/game/）だけ**で、既にあるファイルは speed の後の形に手で足す。

| ファイル | speed（ff66ce6・f7d741f）が触った所 | 汎用（v0.7〜v0.9）が触る所 | ぶつかり方と決め |
|---|---|---|---|
| `shim/Facts.scala` | `guarded`/`guardedWith`・`run` と `write` の分け・`--names-of`・`Names` の object（`usedIn`・`enumSource`・names.tsv） | v0.7: `write` の根が取れた 2 か所（typed・resolved）に `Generic.emit` を 1 行ずつ・`--facts-tsv` の引数・`Names.usedIn` の正規表現の横に `Kind`/`Slot`/`Attr`/`Unnamed(` の拾い（1.5）。v0.9: `Typed`/`Resolved` の emit と `Sink` を消す | 同じ関数を触るので、speed を main に入れてからでないと手で合わせる事になる。スパイクの `main`/`run` の形（`sys.exit` に戻した物）は取らない |
| `shim/Generic.scala`（新） | — | 本体 | ぶつからない。スパイクの `field`（毎回 `getMethod`）を、0.6.4 の `Facts.field`（クラスごとのキャッシュ）に替えて写す |
| `shim/Lint.scala`・`shim/Resident.scala` | 常駐・同じ JVM | 触らない | ぶつからない。常駐でも `Facts.write` を通るので汎用の事実も書かれる |
| `bin/flixlint` | `--resident`・`--resident-stop`・`--names-of` | AstKinds.flix を engine/src へ写す 1 行・`--facts-tsv` の受け渡し | 写しの行（`cp "$here"/src/Flixlint/*.flix`）は既に AstKinds.flix を拾うので、実は `--facts-tsv` の 1 行だけ。スパイクの bin/flixlint は取らない（speed の同じ JVM の道を消している） |
| `src/Flixlint/Facts.flix` | names.tsv から名前を読む・`fnName` を Names から | v0.7: `ast(facts)` の 1 欄と `load` の 1 行。v0.8: 旧い API を層 3 の写しに。v0.9: 旧い record を消す | v0.7 は 2 行で済む。スパイクの `fnByName`・`fnOfName` は speed の `Flixlint.Names.fnOf` があるので要らない |
| `src/Flixlint/Engine.flix` | `lint` の入口（環境変数か `--resident NAME=VALUE`）・`judgeAndReport` が exit の番号を返す | v0.7: 規則ごとの `judge=`（`judgeAll` は純粋なので、時間を取るには IO の側で custom 規則を 1 本ずつ呼ぶ形に分ける）と 1.5 の知らせ。v0.8: families の判定の関数と `FLIXLINT_DUMP_REL` | `judgeAll` と `judgeAndReport` の両方に触るので、speed と同じ関数に当たる。上限を規則ごとのファイルに分ける作業（Mac mini）も `judgeAndReport` を触るので、**その作業が main に入ってから v0.7 の手順 6 に入る** |
| `src/Flixlint/Ast.flix`・`Flix.flix`・`Rel.flix`・`AstKinds.flix`（新） | — | 本体 | ぶつからない |
| `README.md`・`Makefile`・`test/run.sh` | 常駐の節・`make test-resident`・server を通すテスト | 汎用の事実の節・Notes・新しい expected | 同じ所に行を足すだけ。`test/run.sh` に足すテストは `make test-resident` でも通る事（常駐で汎用の事実が書かれるか）を見る |
| 増分の walk | 増分 compile | walk は毎回 Root 全体（【未測定】汎用の walk の秒。スパイクは stderr に出していたが数が残っていない） | 常駐の 2 回目は compile が短くなるので、walk・書き出し・読み込みの割合が大きくなる（4.2）。届かなければ「常駐の JVM の中で配列を手渡す」→ ファイルごとの増分の walk の順（この設計の外） |
| `shim/Spans.scala`（`--spans`） | 触らない | 触らない | ぶつからない |

### 3.5 nextcms の追随（次に nextcms を触る時。今の作り替えの間はしない）

依頼主の決定（10-21）: nextcms は次に nextcms を触る時に追随させる。手順:

1. 先に nextcms を Flix 0.76 から 0.78（その時の flixlint が求める版）へ上げる。flixlint 0.5 以降は 0.78 でしか動かないので、この順は変えられない。lint はこの段では v0.4.0 のまま流す。
2. submodule を v0.4.0 から v0.9 以降へ一度に上げる。直す所は v0.9 のリリースノートに置く一覧に従う。一覧の中身（v0.9 を出す時に書く）: families の項目の書き方は変わらない事、custom 10 本が使う `Flixlint.Facts` の関数ごとの書き換え先（層 2・3 のどの関数か）、v0.5〜v0.8 で変わった事（Flix 0.78・`customRule` と allow・limits の口など。各版のリリースノートから拾う）。
3. 確かめ: 上げる前（v0.4.0）と後の違反一覧を並べ、違いを 1 行ずつ「どちらが正しいか」書いてから直す。

---

## 4. 秒と量の目標と測り方

### 4.1 今の数

| 何 | 数 | 出どころ |
|---|---|---|
| ゲームの lint 1 回（resolved） | 9〜11s | 【測った】v0.6.4（memory flixlint-adopt・10-21） |
| ゲームの lint 1 回（typed） | 28〜31s | 同上 |
| 汎用の事実の読み込み（typed） | 9.2s | 【測った】スパイク（FLIXLINT_TIMING=1） |
| 汎用の事実の量（typed） | node 379,394 行（20.8MB）・node_attr 453,393 行（10.4MB）・node_type 377,445 行（7.4MB・型の頭だけ・異なる頭は 550） | 【測った】スパイクの出力 tmp/gb/gen-typed/facts |
| 汎用の事実の量（resolved） | node 327,627 行（18.4MB）・node_attr 339,761 行（8.1MB）・node_type 156 行 | 【測った】tmp/gb/gen-resolved/facts |
| 旧い事実で一番大きい表（typed） | arg_type_deep 206,877 行（11.0MB）・calls 50,059 行（2.4MB） | 【測った】同上 |
| 型の表を全部出した時の行数 | typed 72,694 行（型の引数 140,134）・resolved 11,017 行。節は typed 325,850・resolved 292,018（src と test） | 【測った】v0.7 の手順 3（10-21・Mac mini。ゲームの src と test） |
| alias の展開を節で書いた時（溢れた時） | 5.76M 節・348MB | 【測った】スパイクの途中の版 |
| ソースの行数（id-verify の src・test） | 58,306 行 | 【測った】wc -l |
| ゲームの lint 1 回（resolved・speed の Names の絞りの後・エンジンの組み直し無し） | 7.5s / 7.4s（def を足した時・名前を変えた時） | 【測った】f7d741f のコミット文（ゲームの写し・流した機械は書かれていない）。組み直す時は 15.3s（3 回の中央値） |
| 0.6.5 の 1 回きり（resolved・src と test・エンジンの組み直し無し） | 経過 15.8・21.9・22.7・23.8・25.1 秒（中央値 22.7 秒）。shim の total は中央値 17.0 秒 | 【測った】v0.7 の手順 0（10-21・Mac mini・load average 30〜32。静かな時の数ではない） |
| 0.6.5 の 1 回きり（typed） | 経過 52.7・54.5・55.9・69.7・70.6 秒（中央値 55.9 秒）。shim の total は中央値 50.8 秒 | 【測った】同上（load average 31〜36） |
| 汎用の walk と書き出しの秒 | walk の CPU は typed 4.8 秒・resolved 2.6 秒、書き出し 0.4〜0.9 秒。読み込み（`Flixlint.Ast.load` 全部）は中央値 typed 498 ms・resolved 434 ms | 【測った】v0.7 の手順 3（10-21・Mac mini・load average 30 前後で、静かな時の数ではない。手順 7 で測り直す） |
| 0.6.5 の常駐 | 1 回目 resolved 27.9 秒・typed 61.8 秒。2 回目から（4 回）resolved 8.7〜11.9 秒（中央値 11.4 秒）・typed 7.3〜11.6 秒（中央値 9.3 秒） | 【測った】同上。4.2 の常駐の行の基準 |
| 最大 RSS（0.6.5） | 1 回きり resolved 1.86〜3.55GB（中央値 2.43GB）・typed 3.94〜5.06GB（中央値 4.61GB）。常駐の server は 2 回流した後の heap が resolved 3.46GB 確保・1.28GB 使用、typed 4.47GB 確保・1.90GB 使用（この機械の sandbox では server の RSS を ps・top で読めないので jcmd GC.heap_info） | 【測った】同上（`/usr/bin/time -l` の maximum resident set size。JVM は -XX:MaxRAMPercentage=35） |
| 0.7.0 と 0.6.5（静かな時・交互に 5 回ずつ） | 1 回きり resolved 4.64 → 5.78 秒（+1.14）・typed 10.30 → 12.29 秒（+1.99）。常駐の 2 回目 resolved 2.44 → 3.20 秒（+0.76）・typed 2.25 → 3.78 秒（+1.53）。最大 RSS（1 回きり）resolved 4.42 → 3.56GB・typed 8.70 → 7.85GB。事実と汎用の AST の読み込み 0.70 秒。汎用の walk と書き出し resolved 1.04 秒・typed 2.09 秒（**typed は目標の 1.5 秒を超えている**。0.7.1 か v0.8 の初めに直す） | 【測った】v0.7 の手順 7（10-21・Mac mini・ほかの仕事を止め、load average は始め 4・流している間 10〜18。中央値） |
| 0.7.2 と 0.7.1（静かな時・交互に 5 回ずつ・ゲームは id-x-lintrules2 の規則） | 1 回きり resolved 7.91 → 7.23 秒（−0.68）・typed 14.51 → 13.31 秒（−1.20）。常駐の 2 回目 resolved 4.98 → 4.26 秒（−0.72）・typed 5.75 → 4.38 秒（−1.37）。汎用の walk の上乗せは typed 約 1 秒・resolved ほぼ 0（単体は typed 2.00 秒・resolved 1.06 秒）。最大 RSS（1 回きり）resolved 4.02 → 5.26GB（1.31 倍・0.7.2 は 3.7〜6.1GB と振れる）・typed 7.81 → 7.25GB。判定（judge=）は両版とも約 2 秒（ゲームの規則の same-shape 475ms・test-self-expect 254ms が重い。ゲームの側で軽くする） | 【測った】v0.7.2（10-22・Mac mini・ほかの仕事を止め、load average は始め 7・流している間 9.5〜15。中央値） |

**4.2 の「基準」は 0.6.5（speed を main に入れた版）を Mac mini で 5 回流した中央値**にする。v0.6.4 の 9〜11s / 28〜31s は speed の前の数で、speed の絞りで resolved は 7.5s 前後まで下がっている見込みがあるため【見込み: 上の f7d741f の数は機械が書かれていない】。v0.7 の手順 0 として、0.6.5 の resolved・typed の 1 回きり・常駐の 2 回目・最大 RSS を Mac mini で取り、この表に書いてから手順 1 に入る。

### 4.2 目標

| 版 | resolved の 1 回 | typed の 1 回 | 汎用の事実の読み込み | shim の汎用の walk と書き出し（1 回への上乗せ） |
|---|---|---|---|---|
| v0.7・v0.8（並走） | 基準＋2s まで | 基準＋3s まで | ≦1.0s（両段） | ≦1.5s |
| v0.9（旧い事実を消した後） | **基準以下** | **基準以下** | ≦1.0s | ≦1.5s |

汎用の walk と書き出しの 1.5s は、0.7.2 から「lint 1 回への上乗せ」で見る（0.7.2 で汎用の walk を旧い事実の walk と別のスレッドで並べて走らせるようにしたため。上乗せは旧い walk より長い分だけ）。0.7.2 の測りで上乗せは typed 約 1 秒・resolved ほぼ 0。walk 単体（shim の行の `generic=`）は typed 2.00 秒・resolved 1.06 秒のままで、単体の秒は内訳として見る。単体を削る案: 型をコンパイラのクラスで直に読む・節の位置を欄の番号で読む・シンボルの名前を 1 度だけ作る（0.7.2 に入れた。見込みどおり約 0.1 秒）。残りは JIT が温まるまで（約 0.7 秒）と、温まった後の walk そのもの（1.1 秒）。

常駐の 2 回目（speed の server を通した時）は別の行で見る。compile が短くなる分、汎用の walk・書き出し・読み込み（目標で合わせて 2.5s まで）の割合が大きいので、1 回きりの「＋2s」をそのまま当てはめない:

| 版 | 常駐の 2 回目（resolved・typed とも） |
|---|---|
| v0.7・v0.8（並走） | speed の常駐の 2 回目の数（4.1 で取る）＋2.5s まで |
| v0.9 | speed の常駐の 2 回目の数以下（旧い walk と旧い読み込みが消える分で埋める） |

v0.9 の常駐の行に届かなければ、3.4 の「常駐の JVM の中で配列を手渡す」を先に入れる。届くかどうかは【見込み】で、旧い walk と読み込みの秒を常駐の 2 回目で内訳として取るまでは言えない。

### 4.3 測り方

- 流す場所: **Mac mini**（この Mac では重い処理を流さない）。ゲームの `make lint-flixlint`（resolved）と `make lint-flixlint-typed`。
- 5 回流して中央値。1 回目（エンジンの組み直しを含む）は別に書く。
- 内訳: shim の stderr（`compile=` `walk=`、汎用の walk は別の数で出す）と `FLIXLINT_TIMING=1`（`load=` `judge=`）。v0.7 の手順 6 で `judge=` を規則ごとに出せるようにする（遅い規則を見つけるため。`judgeAll` は純粋なので、`FLIXLINT_TIMING` の時だけ IO の側で custom 規則を 1 本ずつ呼んで時間を取る）。
- 量: shim が表ごとの行数とバイト数を `Meta` に書き、stderr にも 1 行出す。
- メモリ: `/usr/bin/time -l` の最大 RSS（maximum resident set size）を、0.6.5 と並べて取る（基準は手順 0）。

---

## 5. 決めること

### 5.1 依頼主に聞く物

**無し**。依頼主は既に「flixlint の作り替えとリリースは許可」「互換を壊す時は理由を 1 行」と言っており、残っていた問いは下の通り片づいた。

| # | 問い | 扱い |
|---|---|---|
| Q-1 | nextcms を新しい版へ追随させるか | **決定済み（依頼主・10-21）**: 次に nextcms を触る時に追随する。今の作り替えの間は v0.4.0 のまま。手順は 3.5 |
| Q-2 | rules.flix で Flix の AST の名前を直に書くのを許すか | 作りの決めなので見回り役へ（D-10） |
| Q-3 | 並走の 2 版の間の秒の上乗せ | 許可済みの作り替えの中の、2 版かぎりで戻せる決めなので見回り役へ（D-11）。上乗せの数は進捗の文書に書いて知らせる |

### 5.2 見回り役が決めてよい物

| # | 決め | 推し |
|---|---|---|
| D-1 | 型の表の形 | 共有の表（hash-consing・位置は鍵に入れない）。式の型は全部・宣言の型もこの表 |
| D-2 | 読み込みの形 | 列ごとの二進のファイル＋ NIO で配列へ。同じ JVM の手渡しはしない |
| D-3 | 人が読む TSV | `--facts-tsv` を付けた時だけ書く。名前を探すのは今と同じく Names.flix を grep |
| D-4 | 外の宣言 | ソースが使った物だけ出す（標準ライブラリ全部は出さない） |
| D-5 | Doc コメントの字を属性に入れるか | 宣言の根にだけ入れる（量は def の数＝ゲームで 5,019【測った: スパイクの typed の Def 節】）。スパイクの walker は `shared.Doc` を飛ばしているので、根の時だけ字を書くように変える。「doc の無い pub な def」のような規則がリリース無しで書ける |
| D-6 | 式の効果（`effect` 列） | v0.7 で量を測ってから決める。式の効果を見る規則は 14 本に無い |
| D-7 | 版の番号 | 0.7.0（並走）・0.8.0（families）・0.9.0（消す） |
| D-8 | AstKinds の作り方 | コンパイラの jar の反射で全クラスを出す（ソースに依らない）。両段の和で 1 つ、リリースの時に生成してリポに置く |
| D-9 | 増分の walk | この設計では入れない。speed の常駐で walk の秒が目立ったら別に考える |
| D-10 | rules.flix で Flix の AST の名前を直に書くか | 書いてよい。ただし生成した enum（`Kind`・`Slot`・`Attr`）で書き、文字列では書かない。書かせないと部品に無い形のたびにリリースが要り、作り替えの狙いが消える |
| D-11 | 並走の 2 版の秒の上乗せ | 4.2 の通り許す（1 回きり resolved＋2s・typed＋3s、常駐の 2 回目＋2.5s）。v0.9 で戻す |
| D-12 | 規則が対象の名前を書く形 | Names の値（`Fn.X`・`Case.X`）で書く。String は Names に載らない名前（Java）だけ（2.2） |
| D-13 | 量の上限 | 節の数がソースの行数の 20 倍・事実の合計 200MB で exit 4（1.3）。fixture の行数の ±20% のテストは置かない（6 章） |
| D-14 | 段に無い・0 件の `Kind`/`Slot`/`Attr` の扱い | 規則のファイルの字から拾って知らせる（exit は変えない）。部品の中では止めない（純粋な関数の中から知らせられないため。1.5） |

---

## 6. 危うい所と歯止め

| 危うい所 | 何が起きるか | 歯止め |
|---|---|---|
| メモリ | 節を record の List で持つと 1 節あたり数十〜百バイト。スパイクの読み込みが 9.2s だったのも、この作りのため | 節は Int32 のまま・列は配列・索引は CSR で、初めて引いた時に作る。最大 RSS を版を出す時に 1 回測り、0.6.5 の 1.3 倍を超えたら出さない（v0.7 の完了条件 2）。JVM の既定（`-XX:MaxRAMPercentage=35`）は変えない |
| 事実の量が膨らむ | alias の展開を毎回書くと 0.4M 節が 5.76M 節・348MB になり溢れた【測った: スパイク】。式の型を全部書くと型の行が節の数だけ増えうる。walker は全部の欄を歩くので、Flix の版上げで大きな欄が増えると黙って膨らむ | (1) 型は共有の表で 1 型 1 行・型の変数は型の中の番号で鍵にする。(2) shim が書きながら数え、節の数がソースの行数の 20 倍か合計 200MB を超えたら exit 4 で、一番多い表と宣言の名前を出す（ゲームの大きさで効く歯止め）。(3) fixture に大きな record の alias を 100 か所で使う形を 1 つ入れ、(2) の上限で止まるか収まるかを見る（v0.7 の完了条件 4）。表ごとの行数を ±20% で固めるテストは置かない（fixture を足すたびに数を直す手間に対して、(2) と `Meta.counts` の stderr の 1 行で版上げの膨らみは見つかる） |
| 規則が AST に密結合になる | Flix の版上げで節の名前が変わると、文字列で書いた規則は**黙って 0 件**になる | (1) 生の名前は生成した enum でしか書けない（消えた名前はコンパイルで止まる）。(2) 層 2 の部品ごとの両段のテスト（下の「段の違い」の行）が、空でない答えを期待値に持つ（層 2 が使う kind が fixture に出る事はこれで見える）。(3) **規則のファイルが書いた Kind・Slot・Attr が、今の段の `ast_schema` に無い時と、今の事実に 1 件も無い時は、ファイルと行を付けて知らせる**（shim が規則のファイルの字から拾う。1.5。版上げで節が分かれて名前だけ残った時の黙った 0 件を見える所に出す。違反でも exit 2 でもない）。(4) 数で止める規則（limits）は、急に減ると「上限を下げるまで止まる」。違反 0 件で通っている規則（ゲームでは `arena-raw-number`）は (3) だけが頼り（ただし (3) は規則が `Kind` を直に書いた時だけ効く。層 2 だけで書いた規則の黙った 0 件は (2) のテストで見る） |
| 規則が書いた名前がソースから消える | 対象の名前を文字列で書くと、ソースで名前を変えた時に黙って 0 件 | 対象は Names の値で書く（D-12）。消えた名前はコンパイルで止まる（今の約束と同じ） |
| 読み込みの作りが Flix で書けない | 規則は純粋な関数なので、region の `Array` を渡せない | `Vector[Int32]` で持つ。v0.7 の最初に読み込みだけを作って測る（2.3） |
| 段の違いが規則に漏れる | resolved と typed で節の形が違う（`retTpe` と `tpe`、let の束縛の形） | 段の違いは層 2 だけで吸う。層 2 の部品ごとに、両段の fixture で同じ答えを返すテストを置く |
| 旧い walker と汎用の判定の食い違い | 旧い walker の作法（呼び出しの行は名前の行・let で束縛した引数は最初の使用で読む）が汎用で再現されない | v0.8 で関係の表ごとに全件を比べる（3 章）。違いは 1 行ずつどちらが正しいかを書いてから直す |
| 規則の評価が遅くなる | `ancestors`・`descendants` を全節に当てると、節の数×深さになる | 層 3 の関係は 1 回だけ計算して覚える。`judge=` を規則ごとに出し、1 本で 1s を超えた規則は層 2 に索引を足す |
| speed との衝突 | 同じファイルを並んで直してぶつかる | 3.4 の表の通り、speed を先に main へ入れ、汎用はその上に枝を切る。Names の絞り（`Unnamed`）も speed の側で先に入れる |

---

## 付録: 材料の場所

- スパイク: `git -C /Users/abab/Desktop/cms/flixlint show 32caeb9`（shim/Generic.scala・src/Flixlint/Ast.flix・test/fixture/rules/generic.flix・spike/game/rules-generic.flix・rules-current.flix）
- スパイクの事実の出力: /Users/abab/.claude/jobs/94fe305c/tmp/gb/{gen,cur}-{resolved,typed}/facts
- speed の作業場: /Users/abab/Desktop/flixlint-spans（枝 ababup1192/speed。常駐 ff66ce6・Names の絞り f7d741f。どちらも手元のコミットで未 push）
- ゲームの規則: /Users/abab/Desktop/game_engine/id-verify の origin/master（6e1e1719 以降）の lint/rules.flix・lint/limits.json・Makefile の lint-flixlint。字の形の検査は bin/lint-rules/forbid.local.json（23 本）
- nextcms: /Users/abab/Desktop/cms/nextcms/lint/rules.flix（families 9 種と custom 10 本・submodule は v0.4.0・Flix 0.76）

---

## レビュー 1 の反映（2026-10-21）

- 0 章: 「今」の数え方を「5 か所＋リリース＋submodule」にそろえ、数で止める規則は limits.json も書く事（ゲームの 7 本中 6 本）を足した。
- 0 章: 狙いが届かない検査の種類（AST の外・コンパイラが AST の外で決める事・版上げ）と頻度（14 本で 0・forbid.local.json 23 本で 1 本の見込み）を書き、「残る物」の段落を足した。
- 0 章・3 章: 旧い walker の行数「約 700 行」を、v0.6.4 の行番号から取った「約 560 行」に直した。
- 1.3: 溢れた件（5.76M 節・348MB）を書き、型の変数の鍵と、shim が書きながら止める量の上限（行数の 20 倍・200MB で exit 4）を足した。
- 1.4: Names を speed の絞りの形（`Unnamed(String)`・names.tsv）に合わせ、まだ呼ばれていない名前を disallow できる事を保つと書いた。
- 1.5: AstKinds を両段の和で 1 つ・リリースの時に生成してリポに置く形にし、段に無い名前を引いたら exit 2 を足した。
- 1.5: 名前が残ったまま節が分かれる版上げはコンパイルで止まらない事を、表に 1 行足した。
- 2.2: 規則が対象を指す引数を Names の値で受ける形に変えた（スパイクの文字列の名前は、名前を変えると黙って 0 件になる）。
- 2.3: Flix の側の持ち方（`Vector[Int32]`。規則は純粋なので Array を渡せない）と、v0.7 の最初に測る事を足した。
- 2.4: 比喩の「逃げ道」「名前の橋」を言い換えた。
- 3 章: 前提の順と 3.4 の Names の行を、speed の絞りが `Unnamed` で進んでいる今の形に直した（「v0.9 と同じか後」の縛りを外した）。3.4 に bin/flixlint の行を足した。
- 3 章 v0.7: 完了条件を「出力を並べて差が 0」の 5 項目にし、14 本と examples を分けて書いた。ゲームの submodule の今の版（v0.6.3）を直した。
- 3 章 v0.8: 比べる表を、抜けていた Def・Enum・Eff・EffAlias・TypeAlias・AliasTypeAll・head の型の表を含む 28 表全部にした。
- 3 章 v0.9: 互換を壊す理由を直した（ソースが変わるたびの組み直しは speed の絞りで既に無くなっているので、理由に入れない）。
- 3.5: nextcms の追随（依頼主の決定 10-21: 次に触る時。Flix 0.76→0.78 が先・v0.4→v0.9 で直す所の一覧を v0.9 のリリースノートに残す）を 1 段足した。
- 4 章: 常駐の 2 回目の目標を、1 回きりの ±10% から「speed の常駐の数＋2.5s／v0.9 で以下」に直し、届かない時の順（同じ JVM での手渡し → 増分の walk）を書いた。
- 5.1: Q-1 を依頼主の決定済みにし、Q-2・Q-3 は見回り役の決め（D-10・D-11）へ移した。依頼主に聞く物は無し。D-12・D-13 を足した。
- 6 章: 量の歯止め、規則が引いた名前が 0 件の時の知らせ、名前を文字列で書いた時の黙った 0 件、読み込みの作りの危うさの行を足した。
- 材料と付録: ゲームの規則の場所を id-verify の origin/master に、speed の状態（ff66ce6 は手元のコミット・Names の絞りは未コミット）に直した。

## レビュー 2 の反映（2026-10-21・実装に入る人の目で）

- 材料: スパイク 32caeb9 は v0.6.3 の上に切ってあり、0.6.4 と speed の変更を巻き戻す差分なので、新しいファイルだけを写すと書いた（3 章 v0.7・3.4）。speed の Names の絞りは f7d741f でコミット済み（未 push）に直した。
- 3 章 v0.7: 手順 0〜7 の表（入力・出力・済んだと言える事）を足した。1 週目は手順 0（基準を取る）・1（2 列だけで読み込みを測って `Vector[Int32]` か `int[]` を決める）・2（AstKinds の生成）。比べ方（`--rules` を替えて 2 回・`--limits` 無し・`sort` して `diff`・両段）を書いた。
- 3 章 v0.7: ゲームの 7 本はゲームのソースが要るので make test に入れず、Mac mini で比べて差をコミット文に貼る形にした。最大 RSS の比べを完了条件 2 に入れた。
- 1.5・6 章・5.2: 「段に無い kind を `ofKind` に渡したら exit 2」「規則が引いた kind が 0 件なら規則の id で知らせる」は、規則が純粋な関数なので部品の中から書けない。shim が規則のファイルの字から `Kind`/`Slot`/`Attr` を拾い（speed の `Names.usedIn` と同じ口）、段に無い・0 件をファイルと行で知らせる形に替えた（exit は変えない。両段で流す規則が片方の段の kind を書くのは正しいため）。D-14 を足した。
- 1.1・1.4: kind の番号の付け方（`ast_schema` の辞書順）と、shim と AstKinds の番号のずれを `schemaHash` で止める（exit 4）事を書いた。
- 1.2: 記号の綴りは names.tsv と同じ関数で作る（層 2 は `fnName` の文字列と `==` で比べるため）と書いた。
- 2.2: Flix で書けない形を直した（`pub enum Node with ...` → `pub enum Node(Int32) with ...`）。`Ast` の中の列の record・`TypeForm` の enum・`Kind` と Int32 の変換・Names の値で受ける `callsTo` などを書き足し、`violation` は Facts でなく Ast を受ける形にした。ライブラリが Names を引数の型に書ける理由（エンジンの中で一緒に組まれる）と、`Fn.Unnamed("…")` の抜け穴の知らせを足した。
- 2.3: `Vector[Int32]` は単相化で `int[]` の見込み（手順 1 で確かめる）と書いた。
- 3 章 v0.8: compare-old.sh の入力を作る口（`FLIXLINT_DUMP_REL`・v0.9 で消す）を書いた。
- 3.4: speed とスパイクの `git show --stat` から、ぶつかるファイルの一覧を作り直した（Facts.scala・bin/flixlint・Facts.flix・Engine.flix・README/Makefile/test/run.sh）。Engine.flix は上限を規則ごとのファイルに分ける作業とも当たるので、その作業が main に入ってから手順 6 に入ると決めた。
- 4 章: 目標の「今」を v0.6.4 の数から「0.6.5 を Mac mini で測った基準」に替えた（speed の後は resolved が 7.5s 前後の見込みで、v0.6.4 の 11s を上限にすると緩すぎる）。汎用の walk の秒と 0.6.5 の RSS を【未測定】として表に足した。規則ごとの `judge=` は `judgeAll` が純粋なので IO の側で 1 本ずつ呼ぶ形にすると書いた。
- 6 章: 過剰な歯止めを削った。fixture の行数を ±20% で固めるテスト（`expected-counts.txt`）はやめ、量の上限と大きな alias の fixture 1 つに絞った。RSS は実行のたびでなく版を出す時に 1 回測る形にした。
- 0 章: 「今」を、今の事実の表で書ける時（今も 1 か所）と、事実を足す時（5 か所＋リリース）に分けた。後者の頻度を git log から書いた（0.5.1・0.5.2・0.6.2・0.6.3 の 4 回のリリースが、どれもゲームの規則のための事実の追加）。rules.flix を変えた後の 1 回目の組み直し（15.3s・f7d741f）を書いた。
