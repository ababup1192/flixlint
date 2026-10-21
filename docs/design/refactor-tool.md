# Flix の自動リファクタ道具（`bin/fge refactor`）の設計

初版 2026-10-21 朝（この Mac でスパイク 2 本）。同日、flixlint v0.5.0 とゲームへの組み込み・Mac mini の実測・依頼主の回答を受けてレビューし直した（末尾の「レビューで直した所」）。
対象: internet_dungeon・flix_game_engine（fge-go）・flixlint（origin/main = v0.5.0 の c6b1e6a、origin/ababup1192/flix078 = 34af934）。
**[確]** は手で確かめた事、**[推]** は見込み。

---

## 0. 結論

- **backend は「コンパイラの AST から取った名前の位置の索引」のまま**。置き場は flixlint の shim（`shim/Facts.scala`、Scala）。書き換えは fge-go（Go）、確かめは `make check`。
  - 索引は **facts と同じ走行で、別のファイル（`--spans FILE`）に出す**。規則のエンジンには読ませない（§3.1）。
  - **def・case・enum の位置は resolved の段（約 7 s）で取る**。型が要る物（record の欄の受け手・match の受け手の型）だけ typed の段（54〜64 s）で取る [推: resolved の `symUse.loc` が typed と同じ形であることは段 0 で確かめる]。
- Flix LSP は主力にしない（rename は局所変数と型変数だけ・record の欄の references は `[]` [確]）。突き合わせも段 0 の 1 回だけにし、常設の `--cross-check` は作らない（Python の client を残さない）。
- 自前の Go パーサは作らない（型が無いと `w#phase` の `w` が World か決められない。今の `phase-read` の歯止めは変数名 `shown|spec|look|band` を名前で外して凌いでいる [確]）。
- **最初の一歩は読むだけの `refs`・`match-sites`・`field-sites`**。書き換えの最初は **`expand-wildcard`（`case _` を網羅に）と `remove-dead`**。`field-to-accessor` は「口の型が欄と同じ」所だけ機械で替え、残りは一覧にする形に縮める（§1.4 の理由）。

---

## 1. 調べた事と証拠

### 1.1 今ある解析

- ゲームとエンジンの Go の lint（state-shape・record-wrap・quadratic・hoist・verb-names・flix-reserved・forbid・flixdecl）は、**全部が正規表現と括弧の深さ数え** [確]。`package (lexer|parser|ast)` は 0 件、コンパイラに触るのは `checkd`（`flix repl` の常駐）だけ [確]。
- 型と名前解決が要る決まりは flixlint へ移り始めた [確]: ゲームの `origin/ababup1192/id-x-flixlint` で submodule `flixlint/`（v0.5.0）・`lint/rules.flix`（`test-only-api`・`doc-id-literal`）・`lint/limits.json`（98・496）。Makefile は `bin/fge heavy flixlint/bin/flixlint --stage resolved`、precommit には入れない。
- まだ正規表現で残る欄の歯止め: `bin/lint-rules/ratchet.local.json` の `phase-read`・`phase-write`（上限 0）[確]。

### 1.2 Flix のコンパイラと LSP（初版のまま。要点だけ）

- jar は `~/.flix_ge_studio/engines/0.54.0/bin/flix.jar` = Flix 0.78.0、ゲームの `flix.toml` も 0.78.0 [確]。
- LSP（stdio で動く [確]）: `World.moveTo` の references 51 件・22 ファイル、`Phase.Clear` 30 件、`w#scene` は `[]`。rename は def・case で `{"changes": {}}`、局所変数だけ正しい [確]。didChange のたびに全体の検査 26 s。provider の範囲は `javap` と upstream で確認済み [確]。

### 1.3 flixlint を backend にする（v0.5.0 で前提が変わった所）

- **0.78 への移行は済んだ** [確]（93a2895。依存は `new Flix(pkgs, jars, mounts)`・`Source`/`SourceName` に合わせた）。初版の「18 エラー・版の食い違い」は解消。
- 足された物 [確]: `ArgTypeDeep`/`RetTypeDeep`/`CaseTypeDeep`（alias を開く）・`--limits` のラチェット・Def/Enum/Eff の行を名前の位置へ（cd7afed、`sym.loc.startLine`）・`TypeAliasDef(alias, mod, file, line, pub, fields)`/`AliasTypeAll`（34af934、flix078 のみ）。
- **位置はまだ行だけ** [確]。`lineOf(p) = loc.startLine`、列も終わりも出していない。`walkBody` は `symUse` の `sym` だけ読む。
- **宣言の型には alias が残る** [確]。`namesIn` が `Type.Alias(symUse, args, tpe, _)` を拾い、`ArgTypeAll` に alias の名前が出る。式の推論後の型（`exp.tpe`）では消える（スパイク [確]）。→ 受け手の判定は「束ねた所の宣言の型」で取れる（§5-1）。
- 規則のエンジンは TSV を全部 Flix に読む（約 7 s のうち TSV 読みが約 3 s。34af934 で `Facts.load` が JVM のメソッド上限に届いて分けた [確]）。7.5 万行の位置をここへ足すと重くなる [推] → 別ファイルにする理由。

#### 位置の shim のスパイク（初版。この Mac・空いている時）

- `tmp/flixlint-copy/spanshim/Spans.scala`（約 100 行）。`def-decl/def-use/case-decl/case-construct/case-pattern/label-select/match-site/enum-decl` に開始・終了の行と列・囲む def を付けて出す。
- 22 s・3.66 GB・75,193 行。`World.moveTo` 51 件は LSP とファイル・行まで一致、span の字も一致、`Phase.Clear` 30 件一致、`#scene` 14 件は grep と一致 [確]。
- 種類ごと: def-use 39,729・label-select 16,631・case-construct 8,025・case-pattern 3,161・match-site 1,760。`_` の腕を持つ match 309 [確]。

### 1.4 実際のリファクタ（段 2）と、機械で替えられる範囲

依頼主の言う今いちばん多い 4 つ（段 2 の各場面）と、コミットで見た形:

| 種類 | 例 | 機械で替えられるか |
|---|---|---|
| 欄の読み書きを口へ | 04729223 `w#phase` 166 か所 → `World.phaseOf(w)`（同じ型・全域）／7a1a6969 `w#deckCursor` → `World.deckCursorOf(w)`（**`Option` を返す**）・`{ deckCursor = { wheelCarry = c \| w#deckCursor } \| w }` → `World.mapDeckCursor(c -> …, w)` [確] | **口の型が欄と同じ時だけ**。7a1a6969 では読む側が `match`・`Option.flatMap` に組み替わり、引数も足された（`deckShownTop(cursor, w)`）[確]。これは人の判断 |
| 場面ごとの窓の欄を Scene の payload へ | e614fa2f（Deck）・de5dee9d（Puzzle）・164fb62a（Cards） | 移すのは人。道具は「口の外に残る直の読み書き」の一覧と 0 件の確かめ |
| 使われない pub とそのテストを消す | 258b17f9・15a22782・2372d2a3・1180fe3f | **できる**。一覧は既に flixlint の `test-only-api`（98 件、旧 Python とファイル・行・名前まで一致 [確]） |
| `case _` を網羅へ | 3d201641（15 か所） | **できる**（enum の case と arity は宣言から） |

初版で 1 位にした `w#phase` の読み書きは、段 2 の準備①③で既に済んでいる（`phase-read`/`phase-write` の上限 0）[確]。残る場面（Node の feed*・Fight・Title・Opening）の口は Option や payload を返す形になる見込みで、`field-to-accessor` の機械置換が効く所は初版の見積もりより狭い [推]。

---

## 2. backend の比べ（変わった所だけ）

| | A. AST の位置の索引（flixlint の shim） | B. LSP | C. Go のパーサ |
|---|---|---|---|
| 正しさ | 名前解決と型はコンパイラの物 | references は A と一致。rename・欄が無い | 型が無い |
| 版上げ | 0.76 → 0.78 は読み込みの所だけ、歩く所は無傷 [確]。flixlint 側で既に保守される | Flix 次第 | 自分で追う |
| 費用（Mac mini、混んでいる時）[確] | resolved 7 s／typed 54〜64 s・4.8〜5.2 GB | 起動 24〜51 s＋書くたび 26 s | 1 s 未満 [推] |
| 方針との合い方 | Scala の shim＋Go。**Python 無し** | client が要る | Go |

**推す物: A**（変わらず）。依頼主の方針（新しい道具は Go か shim/規則、flixlint は make lint とゲートだけ）とも合う。

---

## 3. 道具の形

### 3.1 索引

- flixlint の shim に `--spans FILE` を足す。付けた時だけ、`kind file sl sc el ec sym owner extra` の 1 行 1 出現を書く。**`Names.flix` にも規則のエンジンにも入れない**（lint の 7 s を増やさない）。
- 段: `--stage resolved` で def/case/enum/match（case の symbol から enum が分かる）、`--stage typed` で `label-select`・`label-update`（受け手の alias 名つき）を足す。操作が要る段だけ流す。
- 置き場: `build/refactor/spans-<stage>.tsv`。鍵は src/test の .flix の内容のハッシュ＋flix.jar＋shim の版。同じなら使い回す。流すのは `bin/fge heavy` 経由（5 GB を並べない）。
- 小さい事実（欄の読み書き `field_access(fn, label, receiverAlias, rw, line)`）は facts にも出し、規則（`lint/rules.flix`）から「口の外の直の読み書き 0 件」を書けるようにする。`phase-read`/`phase-write` の正規表現はこれで置き換えられる [推]。ただし typed の段が要る（§6-1）。

### 3.2 書き換え役（fge-go の `go/internal/refactor`、口は `bin/fge refactor`）

```
bin/fge refactor <op> [args] [--apply] [--json]     # 既定は dry-run
  1. 索引を引く（無いか古ければ heavy で作る）
  2. 計画: 当てる span の一覧（file・行・列・前の字・後の字）。重なる span は内側から、重なりが解けなければ止める
  3. dry-run: build/refactor/last.diff と got/want を出して終わる
  4. --apply: 当てる前に各 span の字が索引と同じか確かめる（違えば止める）→ 書く → last.patch → make check
     → 失敗したら last.patch だけを逆に当てて戻す（触るファイルに未コミットの変更があれば --apply を断る）
```

出力は px・snd と同じ形（`--json` は checkres の `rule/file/line/col/got/want/fix`）:

```
refactor expand-wildcard: enum=World.Scene
  got:    7 matches with `case _` (src 6, test 1) · 2 skipped (body uses the bound value)
  want:   0 `case _` on World.Scene
  status: dry-run (diff: build/refactor/last.diff, 84 lines) · index typed=no resolved=7s (cached)
  next:   bin/fge refactor expand-wildcard --enum World.Scene --apply
```
```
  status: reverted · make check failed: src/X.flix:12: Unable to unify …
  fix:    --skip src/X.flix:12 で外すか、手で直してから --apply をやり直す
```

- 1 回の索引で複数の操作をまとめて当てられるようにする（`--label a,b`）。書いた後の索引は古いので、続けて当てるには作り直しになる。

### 3.3 操作

| 操作 | 段 | 中身 | 確かめ |
|---|---|---|---|
| `refs <Mod.name> [--callers]` | resolved | 宣言と参照を `file:line:col owner` で | 読むだけ |
| `match-sites <Enum> [--catch-all]` | resolved | match の位置・腕の数・`_` の有無 | 読むだけ |
| `field-sites --label x --receiver World` | typed | 欄の直の読み・書き（囲む def・mod つき）。口の外の物を got に | 読むだけ |
| `expand-wildcard --enum E` | resolved | `case _ => body` を残りの case（arity は宣言から `(_)`）に書き出す。body が束ねた値を使う・ガードがある腕は外して fix に | make check |
| `remove-dead [--with-tests]` | resolved | `test-only-api` と参照 0 の def を、前の `///` ごと消す。テストは参照元が @Test だけの物 | make check と make test |
| `field-to-accessor --label x --receiver World --reader World.xOf [--mapper World.mapX]` | typed | 口の戻りの型が欄の型と同じ時だけ `e#x` → `World.xOf(e)`。`{ x = f(e#x) \| e }` で同じ `e` の時だけ `World.mapX(x -> f(x), e)`。違う型・複数の欄の更新・別の受け手は fix に並べる | make check |
| `rename <Mod.old> <new>`（後回し） | resolved | 参照の最後の区切りだけ替え、`use` 行は文字で直す。新しい名前が同じ mod か `use` 先にあれば止める | make check・前後の参照数 |

作らない（今の痛みに無い・頻度が低い）: `rename-field`・`add-param`・`move`・shim の常駐。

---

## 4. 段の計画

| 段 | 中身 | 見込み [推] | 完了条件（測る物） |
|---|---|---|---|
| 0 | shim に `--spans`（resolved と typed）。flixlint の test/fixture に期待の span を足す。`refs`・`match-sites`・`field-sites` | 1〜1.5 日 | `World.moveTo` 51・`Phase.Clear` 30・`#scene` 14 が初版と一致。resolved の span が typed と同じ字を指すか。Mac mini での索引の秒数と GB |
| 1 | `expand-wildcard`・`remove-dead`、dry-run/apply/戻す | 1.5 日 | `test-only-api` の一覧から 1 件を道具 1 回＋check 1 回で消せること。`case _` を 1 enum 分消し、check が 1 回で通ること |
| 2 | `field-to-accessor`（同じ型の時だけ）と `field_access` の facts | 1.5 日 | 段 2 の次の場面で、機械で替えた数と fix に回った数を got に出し、手作業のツール呼び出し数と比べる |
| 3 | `rename` | 1 日 | 前後で参照数と check が同じ |

---

## 5. 危うい所（書き換えの正しさ）

1. **受け手が alias の record**: `exp.tpe` は展開済み。受け手が `Var` なら束ねた所（引数・`let` の注記）の宣言の型を見る。宣言の型には `Type.Alias` が残る [確: §1.3]。それで決まらない時は、閉じた row の欄の集合が World の alias の本体と同じかで決める（World は欄が多いので取り違えはまず無い [推]）。**開いた row（row 多相）と、受け手が式の結果の物は替えずに fix**。
2. **span**: `SymUse.loc` は書かれた名前だけ（`World.moveTo` の 12 字、`use` で入れた素の `moveTo` ならその字）[確]。desugar で同じ式を 2 度通る事があるので `(file, span)` で重ねを除く。
3. **record の更新**: `{ a = 1, b = 2 | w }` は Extend/Restrict が入れ子で loc を分け合う [推]。1 欄だけの更新以外は替えない。
4. **`use`**: 型付き・resolved の AST に `use` 行は残らない。src/test に `use X.{f => g}` は 0 件 [確]、def を入れる `use` は src に 114 行（test は数えていない）[確]。rename は `use` 行を文字で直し、make check に任せる。
5. **影（shadowing）**: def・case は symbol で当てるので取り違えない。新しい名前が局所の名前と重なるのは make check で止まる [推]。
6. **コメント・文字列**: AST に無い。`///` の中の名前・Doc の id・Makefile の `--entrypoint`・`.flow` の語彙は「文字で見つけた候補」として fix に出すだけ。
7. **索引が古い**: ハッシュと、当てる前の字の比べで止める。

---

## 5b. どのプロジェクトでも使える作り（2026-10-21 依頼主の問いを受けて決めた要件）

- 道具は fge-go の `bin/fge refactor` に置き、エンジンから全部のゲームへ配る。索引は flixlint の shim（プロジェクトを知らない作り）。
- ゲームの名前（`World`・欄・口の名前）は道具の中に書かない。`--receiver`・`--label`・`--reader`・`--mapper` で渡す。
- 書いた後の確かめの口はプロジェクトごとの設定（既定 `make check`）。エンジンはゲームと中身が違う。
- 段 0 の完了条件に「エンジンの src でも refs・match-sites が正しい数を出す」を足す（自分の src と、ゲームから見た fpkg の両方の向き）。
- 道具のテストは flixlint の fixture（小さな Flix のプロジェクト）で持ち、ゲームに頼らない。

## 6. 依頼主に聞く事（残り）

1. 欄の歯止め（`field_access`）を flixlint の規則にすると、make lint の flixlint が resolved（7 s）から typed（約 60 s）になる。lint を typed にするか、欄の歯止めは refactor の `field-sites` の 0 件の確かめに留めるか。
2. `remove-dead` の後の確かめを make test まで回してよいか（他の操作は make check だけ）。
3. `--spans` を flixlint の公開の口にしてよいか（ゲーム専用の写しは持たない前提）。

---

## 付録: スパイクの物（捨てる前提）

- LSP の client（Python。方針により残さない）: `/Users/abab/.claude/jobs/94fe305c/tmp/lspspike/`
- 位置の shim: `/Users/abab/.claude/jobs/94fe305c/tmp/flixlint-copy/spanshim/Spans.scala`・索引 `/Users/abab/.claude/jobs/94fe305c/tmp/spans.tsv`

---

## レビューで直した所

- 前提の更新: flixlint は v0.5.0 で 0.78 に移った（「18 エラー・版の食い違い」と §6 の 1〜3 を消した）。索引は Mac mini の heavy で作る。費用を Mac mini の実測（typed 54〜64 s・5 GB、resolved 7 s、check 約 44 s）に替えた。
- 索引を facts と同じ走行の**別ファイル**にした。規則のエンジンは TSV を全部読む（3 s）ので、7.5 万行を混ぜない。
- **resolved の段で足りる操作を分けた**。毎回 60 s 払うのは欄の操作だけにした。
- `field-to-accessor` を縮めた。`w#phase` は既に済み、場面の窓の口は `Option` を返して読む側が組み替わる（7a1a6969）。機械で替えるのは同じ型の時だけにした。
- 最初の書き換えを、今の痛みに合う `expand-wildcard` と `remove-dead`（一覧は flixlint の `test-only-api` に既にある）にした。読むだけの `field-sites` を足した。
- 受け手の判定を「指紋」から「宣言の型の alias（残る [確]）→ 閉じた row の一致 → 開いた row は fix」に直した。初版の「同じ欄を持つ別の record と取り違える」は、閉じた row では起きにくい。危ないのは row 多相の方。
- 戻し方を直した。自分の patch だけを逆に当て、触るファイルが汚れていれば断る。重なる span・複数の欄の更新・desugar の重ねも足した。
- 削った物: `--cross-check`（Python の LSP client が要る）、`rename-field`・`add-param`・`move`・shim の常駐の段。
- 費用の見方: 1 回は索引（7 s か 60 s。同じ中身なら使い回す）＋check 44 s で 1〜2 分。手で 166 か所を置換した時のツール呼び出しより安いので許せる [推]。precommit には入れず、呼ばれた時だけ heavy で流す（依頼主の方針どおり）。

---

## 7. `move-fields`（設計メモだけ。2026-10-21・remove-field と fix-construction の後）

World の欄を幾つかまとめて場面の payload（`Scene.X({ … })` か `type alias XUi = { … }`）へ移す手を、今ある部品の並べ替えで組む。

```
bin/fge refactor move-fields --labels a,b,c --receiver World --into-case Scene.Deck [--reader-prefix World.deckUi] [--apply]
```

1. 前提の確かめ（読むだけ）: 各欄の `field-sites --receiver World --outside <口の mod>` が 0。0 でなければ一覧で止める（remove-field と同じ）。
   つまり「移す前に field-to-accessor で口へ寄せ終わっている」ことを要る条件にする。口の中身を payload を読む形に書き直すのは人
   （場面にいない時の値＝`Option` か既定値か、は設計の判断。7a1a6969 と同じ理由で機械にしない）。
2. 型: payload の record に欄を足し（型の字は World の alias の宣言から写す）、World から消す。
3. 組み立て: World の組み立て（今は initialWith の 1 か所）から欄を消し、その値の式を「payload の組み立てへ足す値」の候補として fix に出す。
   payload の組み立て（`Scene.Deck({ … })`）へは fix-construction --add と同じ当て方で足す。値は `--value-of a=<式>` で受けるか、
   World の初期値の式をそのまま写す（場面に入る拍の値が初期値と違う物は人）。
4. 確かめは make check 1 回。落ちたら全部戻す。

足りない物: case の record の欄の受け手は索引で `recv=?` になり、remove-field の 0 件の確かめが同じ名前の別の欄まで数えて止まる
（ゲームの `IntelWin.Open#top` は 30 件を数えた）。flixlint の shim の `Receivers.of` で、case の payload を束ねた変数の型を
`recv=<Enum.Case> via=case` と出せば正確になる（パターンの変数を declare する 1 か所）。record の式の行（`record-literal`、欄の組と
宣言の型）を shim が出せば、組み立ての当て方も字読みから索引へ移せる。どちらも flixlint の形の版を 3 に上げる変更。

---

## 8. 長く効く作り（2026-10-21 夜・依頼主の方針「突発の手当てでなく、長期で効く汎用の方法で」を受けて）

**[確]** は手で確かめた事、**[推]** は見込み。測った所はこの Mac（別の重い処理が 2 本走っている時）。

### 8.0 ここまでで分かった事（§8 の前提）

- **usages（Find Usages）の途中の物**は ababup1192/refactor-tool の 6b56330c にコミット済み（「途中。設計 §8 のレビュー待ち」。作業ツリーに差分は無い [確: レビュー 2 の時点]。後の 8.6 の段 A の材料）。
  ゲームの写し（origin/master 0877ab5d・189 ファイル）で grep と比べた [確]:

  | 問い | 道具の数 | grep | 誤って拾った行 | 落とした行 | grep の出力 | 道具の既定の出力 |
  |---|---|---|---|---|---|---|
  | `World.moveTo` | 39 | `-w moveTo` | 1 | 0 | 40 行・6,216 字 | 14 行・1,008 字 |
  | `BoardDoc.defaults` | 7 | `-w defaults` | 295 | 0 | 303 行・28,783 字 | 9 行・696 字 |
  | 同上 | 7 | `-F BoardDoc.defaults` | 0 | 1（BoardDoc の中の素の `defaults()`） | 6 行・625 字 | 9 行・696 字 |
  | `Phase.Clear` | 29 | `-w Clear` | 18 | 0 | 48 行・4,064 字 | 14 行・1,046 字 |
  | 同上 | 29 | `-F Phase.Clear` | 0 | 2（`use` で入れた素の `Clear`） | 27 行・2,480 字 | 14 行・1,046 字 |
  | `World.Phase`（enum） | 679 | `-w Phase` | 40 | 27 | 605 行・61,083 字 | 14 行・1,115 字 |

  grep は「短い名前で打つと同じ名前の別物を拾い、長い名前で打つと `use` 越しの素の名前を落とす」のどちらかになる。
  `--unused` はゲームで pub の def 402（参照 0: 45・テストからだけ: 126・同じ mod の中だけ: 231）・使っていない use 35。
  字で 3 件見て 3 件とも正しかった（`use View.sprite` は record の欄名 `sprite` にしか出ない＝grep なら「使っている」と誤る）。
- **Fight で道具が 0 回だった訳**（見回り役の報告）: typed の索引が engine の fpkg の `LwjglLayer.flix` を組めずに止まり、1 回 5〜8 分。
  LWJGL は engine の fpkg の `[mvn-dependencies]`（本体の jar → `lib/cache`）と `[jar-dependencies]`（natives → `lib/external`）[確]。
  flixlint の shim は lib/ を**読むだけ**で入れない（`Deps.ofRoot` が自前で flix.toml と lib/ を歩く）[確]。`flix check` は入れる。
  つまり「lib/ を作ったのは誰か・どの時点か」でゲームの写しごとに結果が変わる。worktree の直後や、fpkg だけ入って maven の jar が
  入っていない lib/ で止まる [推: Mac mini の lib/ は見ていない]。**原因は LWJGL ではなく、依存の解決が 2 つの源（flix 本体と shim の
  自前）に分かれている事** [推: 形は shim のコードで確かめたが、Fight の写しの lib/ で止まった事は再現していない。段 C の始めに
  Mac mini の Fight と同じ写しで再現し、直した後に同じ写しで通る事を見る]。jar を名指しで渡す手当ては、次の別の依存で同じ形で止まる。
  「1 回 5〜8 分」の内訳（prepare の make check・索引・やり直しの回数）は測っていない。段 B の物差しで分けて測る。
- **常駐の効き目** [確]: flixlint の `--resident`（0.6.5）は規則つきの走行にしか効かず、`--spans` だけの走行は毎回 JVM を立てていた。
  shim の `Lint.run` で「engine が無ければ事実（と索引）だけ」を許し、bin/flixlint の spans だけの道も常駐へ流すと（作業ツリーの写し）:
  resolved 1 回目 8.7 s（shim の組み直し込み）→ 2 回目 2.8 s・3 回目 2.8 s、typed 1 回目 18.0 s → 2 回目 4.1 s。索引は 1 回きりの物と同一。
  2 回目以降は**ソースを変えず、同じ引数で流した時**の数。1 ファイル直した後の typed と、lint（resolved・src だけ）と refactor
  （typed・src＋test）を交互に流した時は未測定。checkd の文書は、ゲームで 1 字変えると Typer がほぼ全部やり直しで 2 回目の check も
  40〜60 s と書いている [確: engine の docs/checkd.md]。直した後の typed の索引も同じ桁になる見込み [推]。

### 8.1 索引の作り方: 依存の解決を 1 つの源から

**要件**: どのゲームでも同じ（ゲームごと・ファイルごとの例外を持たない）。`make check` が通る写しなら索引も通る。通らない時は
`make check` と同じ誤りが出る。

| | A. shim が Flix の `Bootstrap` を呼ぶ | B. fge（Go）が依存を組んで `--pkg`/`--jar` で渡す | C. 今の形（shim の自前の `Deps.ofRoot`）＋足りなければ make check |
|---|---|---|---|
| 源 | `flix check` と同じコード（`Bootstrap.bootstrap(path, …)` が fpkg・maven・jar を lib/ へ入れ、`ProjectFiles(sources, pkgs, jars)` を持つ）[確: flix.jar の javap] | fge が flix.toml と fpkg の toml を読む（3 つ目の実装） | shim の自前（2 つ目の実装） |
| lib/ が無い・欠けている | 入れる（check と同じ。ネットワークが要る時は check と同じく要る） | 入れられない（make を呼ぶしかない） | 読めずに exit 3。fge が「無ければ make check」を挟むのは手当て |
| Flix の版上げ | Bootstrap の口（`files` は非公開の欄なので反射で読む。1 か所）| fge が toml の形を追う | shim の `ofRoot` が toml の形を追う（今の約 80 行） |
| lint にも効くか | 効く（flixlint の全部の走行が同じ道） | refactor だけ | 効く（が同じ欠け方をする） |
| 費用 | 1 回目に依存を確かめる分（入っていれば数百 ms [推]） | 同じ | 無い |

**決め: A**（見回り役 2026-10-21）。依存を「解決する」コードを flixlint にも fge にも持たない。flixlint の shim は `Bootstrap` に任せ、
flix.toml を歩く `Deps.ofRoot` は**消す**。`--pkg`/`--jar` を手で渡す口（`Deps.ofPaths`。プロジェクトの外の道具向け）だけ残す。
refactor の側は何も足さない。6b56330c で既に入っている `prepare`（refactor.json の `prepare`・既定 make check）は段 A で**設定の欄ごと**
消し、段 C までの間は flixlint の止めた文（exit 4「flix check を 1 度」）をそのまま `next: make check` の 1 行で示す（道具が裏で
make を流さない）。
依存を入れる振る舞いは `flix check` と同じにする（同じ源なので）。入れた時は 1 行言う。`--offline`（入っていなければ入れずに
`flix check` と同じ文で止める）は選べる旗として置き、既定にはしない。`--offline` を「入っているかを shim が自前で調べる」で作ると
`ofRoot` が戻って源が 2 つになるので、`Bootstrap` の側にネットワークへ出ない形があるか（無ければ、ネットワークの口を塞いで
`Bootstrap` を呼び、出ようとしたら止める）を段 C の始めに確かめる [推: flix.jar の Bootstrap の引数はまだ見ていない]。
LSP も同じ `Bootstrap` を使っている [推: 上流の LspServer を読んでいない] ので、「LSP で通る＝索引も通る」も揃う。

**OS・オフライン・CI でどう動くか**（段 C の fixture と完了条件にする）:

| 場面 | 今（C） | A の後 |
|---|---|---|
| lib/ が揃っている・ネットワーク無し | 通る（読むだけ） | `flix check` が通るなら通る。**`Bootstrap` が揃った lib/ でネットワークへ出ないかは未確認**（今の `ofRoot` の WhyNot は `findTransitiveDependencies` が GitHub へ出ると書いている）。出るなら `flix check` も同じくオフラインで止まる＝今より後退する。その時も「揃っていれば自前で読む」へ戻すのは源を 2 つに戻すので取らず、`--offline` を既定にするかを決め直す |
| lib/ が無い（worktree の直後）・ネットワーク有り | exit 4 | 入れて通る（1 行言う） |
| maven の jar が lib/cache に無い | 止まる（jar の名指しが要る） | `Bootstrap` が入れる（coursier の cache が揃っていればネットワーク無しで足りる [推]） |
| `use-engine` で手元で組んだ fpkg に差し替えた lib/（packages.lock も揃えてある [確: useengine.go の syncLock]） | 通る | `flix check` が通る形なので通る [推]。GitHub に無い版を `Bootstrap` が取りに行かない事を fixture で見る |
| Windows・Linux | shim は Java なので同じ | 同じ。OS の差は shim でなく `bin/flixlint`（bash・`/tmp` の socket・`shasum`・`id -u` [確: bin/flixlint:160]）にある → 8.2 で鍵を作り替える時に Go か Java へ移す |
| CI | make check の後なら通る | make check を挟まずに lint だけ流しても通る（入れる）。lib/ の cache の鍵は flix.toml と packages.lock |

もう 1 つの危うい所: `Bootstrap` が lib/ へ書くのと、checkd の repl・別の `flix check` が同時に lib/ を入れる時の競り合い。
checkd は lib/ の中身が変わると repl を作り直す [確: docs/checkd.md] ので、flixlint が入れた直後に checkd が 1 回作り直す（遅いだけで
結果は同じ）。同時に書いて壊れるかは未確認 [推: 起きるのは lib/ が空の時だけ]。checkd が共有の常駐へ移った後（checkd の C-3）は、lib/ を入れるのは
常駐の中の 1 本の `Bootstrap` と、常駐の外の素の `flix check` だけになる。

### 8.2 索引を lint と refactor の共通の土台に・常駐を 1 つに

**常駐の口・順・予算・戻り方の正は checkd-freshness-design.md の §4.4**（check・lint・spans を 1 つの JVM で頼む形。レビュー 2 で 2 枚を 1 つの決めにした）。
ここには refactor の側から見た理由と、refactor が変える所だけを書く。

- **1 つの常駐**（flixlint の `Resident`）が、プロジェクトの根ごとに温まったコンパイラを持ち、(a) lint の事実と違反、(b) refactor の索引、
  (c) `make check` の型検査（checkd。見回り役の決め: flixlint の Resident に check の口を足して共有する）、(d) 後の汎用の事実（v0.7）を返す。
  いま fge の refactor は `build/refactor/flixlint`、lint は `build/flixlint` と**別の build ディレクトリ＝別の常駐**になる [確: 常駐の鍵は PWD と build の組]。
  → 鍵を「根 × identity」にし、build ディレクトリは走行ごとの引数にする（1 プロジェクト 1 JVM・typed で約 5 GB [確: Mac mini の 1 回きりの走行] を 2 本にしない）。
  **0.7 の前に入れてよい**（見回り役の決め。flixlint の作り替えとリリースは依頼主の許可済み・nextcms は常駐を使っていない）。v0.7 の設計 3.4 は
  `shim/Resident.scala` を「触らない」、`bin/flixlint` を 1 行だけ触る前提なので、この変更を先に main へ入れ、v0.7 はその上に積む（v0.7 の 3.4 の表を 1 行直す）。
- **鍵を変える時に一緒に直す物**（今のままだと 1 JVM にした途端に壊れる）:
  1. **identity（身元）にも PWD が入っている** [確: bin/flixlint:159]。identity の違う呼び出しが来ると server は止まる [確: Resident.scala の serve]。
     identity は「flix.jar・shim の jar」のハッシュだけにし、違う identity は止めずに別の常駐へ行く（checkd §4.4 の 2）。
  2. **lint と refactor（と checkd）が同じ flixlint を使う**。今 refactor は自分で flixlint と flix.jar を探し（config.go）、ゲームの lint は submodule のタグの
     release の shim を落とす [確: Makefile の FLIXLINT_SHIM]。探す所をエンジンが指す 1 か所にする（checkd §4.3 の版の結びつき）。
  3. **ソースの集まり**: ゲームでは lint も refactor も既に `src`・`test` を渡している [確: Makefile の lint-flixlint-run・refactor の config.go の既定]
     （レビュー 1 で「lint は src だけ」と書いたのは誤り）。どのプロジェクトでもずれないよう、コンパイルは 8.1 の `Bootstrap` の `sources` で行い、
     SRC の引数は事実と索引を書くファイルの絞りにだけ使う（checkd §4.4 の 4）。
  4. **socket の置き場**を `/tmp/flixlint-<uid>-<hash>.sock`（bash で作る）から、ユーザーの cache の下へ。式は checkd §4.4 の 5。
- **同時に頼まれた時**: 今の server は 1 本ずつ accept する [確: Resident.scala の server]。共有の後は「check を先に 1 本・追い越しは 1 回まで・ほかは来た順」
  （checkd §4.4 の 3）。refactor の `--apply` の後の確かめ（`make check`）も同じ常駐へ並ぶ。待つ側は 'Q' の枠で「前に 1 本流れています」を 1 行出す（8.3 の 5）。
- **壊れた時の戻り方**: 生きている server がある時は必ず並ぶ（1 回きりの JVM を立てない。5 GB が 2 本になる）。落ちた時は 1 回だけ立て直してやり直し、
  2 回目も落ちたらログの終わり 12 行で止める（checkd §4.4 の 7。check だけは素の CLI へ落ちる）。残った socket は次の server が消してから bind する [確]。
- **メモリ**: 今は flixlint の JVM が `-XX:MaxRAMPercentage=35` [確: bin/flixlint:58]、checkd が物理メモリの 33% を常駐の数で割り、1 本の線は 3.5〜4 GB
  （`rssLimit.minMB` 3584・`maxMB` 4096 [確: hooks.json]）。共有の後は 1 つの予算（`hooks.json` の `checkd` から呼び手が引数で渡す。flixlint は数を持たない）。
  typed の 4.8〜5.2 GB は今の checkd の線を超えるので、線は checkd の C-1 の RSS の実測で決め直す（checkd §4.4 の 6）。§3.1 の「heavy 経由で流す」は
  server を立てる 1 回目にだけ効き、以後の並びは server が受けるので、`bin/fge heavy --status` に常駐の server も 1 行で出す。
- **段の扱い**: 1 つのコンパイラで resolved と typed の両方を返せる（同じ常駐で両方流せた [確]）。`Resolved.run` は `Flix` から sources を読むだけで、増分の状態には
  書かない [確: Facts.scala] ので、check と同じ `Flix` で流す（checkd §4.2 の 3）。lint が resolved、refactor が typed を続けて頼んだ時の秒は未測定（8.0 の 3 つ目）。共-1 で測る。
- **v0.7（docs/design-generic.md・generic-v07）とのつなぎ**: v0.7 の `Node` は位置（line・col・endLine・endCol）と `root`（囲む宣言）、
  `NodeAttr` は `symUse` の修飾名、`NodeType` は書かれた型（resolved）と推論の型（typed）を持つ。refactor の索引の種類はどれも
  この 3 表の**見方**になる: def-use＝`Expr.ApplyDef` の `symUse`、case-*＝`Expr.Tag`/`Pattern.Tag`、label-*＝`Expr.RecordSelect`/
  `RecordExtend`＋受け手の宣言の型、type-use＝resolved の `NodeType` の `Alias`/`Cst`、use＝`UseOrImport`（v0.7 の表に無い。足す）。
  → **v0.7 の段 3 が出たら、`--spans` は「汎用の事実から組む層 3 の 1 つ」に置き換え、Spans.scala の walker は消す**（walker を 2 本
  持たない）。それまでは今の `--spans` を形の版 2 のまま使い、種類は足すだけ（今回の use・type-use・alias-decl と同じく `adds=`）。
  受け手の判定（`Receivers`）だけは v0.7 の層 2 に「欄の読み書きの受け手の alias」として入れる（lint の欄の歯止めも同じ物を使う）。
- **作り直しの合図**: 常駐は中身の変わったファイルだけ組み直すので、refactor 側の「鍵が違えば作り直す」はそのまま常駐への 1 回の
  問いになる（鍵の計算は残す。常駐が無い時の 1 回きりの走行と同じ形）。

### 8.3 出力の約束（fge の道具全体）

refactor の field-to-accessor の比べで「dry-run の diff 全文・索引のログ・check の出力をそのまま返して、手作業より多くかかった」[見回り役]。
道具の出力はそのまま AI の読む量になるので、fge の道具全体の約束にする:

1. **既定は数行**: 何に当てたか 1 行・数 1 行・注 0〜3 行・場所の上位 10 行・ファイルごとの数 1 行。
2. **詳しい物はファイル**: 場所の全部（`build/<道具>/last-<操作>.txt`）・diff・ログ・確かめの出力。画面には場所だけ 1 行。
3. **`-v`/`--verbose` で全文**（今までの出力。依頼主の決め）。`--json` は機械向けの全部（`checkres` の形）。
4. **終わりに次のコマンド**（`next:`。写してそのまま流せる物だけ。訳は別の行）。止めた時は fix の 1 行と、止めた行の場所だけ。
5. **索引・JVM の準備は 1 行**（「作ります（ログ …）」）。失敗した時だけログの終わりを 12 行。

今ある物 [確: fge-refactor の go/internal]: `checkres` は px・snd・tickets・stateshape・refactor が既に使っている「1 件の結果」
（got/want/status/fix）と、まとめ・`NextOf`（次の手）を持つ。無いのは**場所の一覧を畳む所**（上位 10 行・ファイルごとの数・全部を
ファイルへ・`-v` で全文）。8.0 の usages と A/B（pointerShown 36 か所）で量が出たのはこの所。

置き場: `checkres` に「場所の一覧」（場所の値の列・畳み方・全部の置き場）を足し、`Summary` の書き出しと同じ所から画面へ出す。
各道具は値を返すだけで、画面へは書かない。

順（見回り役の決め）: **refactor で先に形を固め**（段 A）、固まった形を `checkres` へ移す。px・snd など他の道具は、次にそれぞれを
触る時に 1 本ずつ寄せる（一度に全部は替えない）。

歯止め（構造を先に）: 道具の package が場所の行を自分で回して書く道を無くす＝場所の一覧は `checkres` の型でしか画面へ出せない形にする。
Go の lint で `fmt.Fprint*` の回し方を数える規則は、構造で止められなかった道具が残った時だけ足す（どの形を数えるかが曖昧で、
誤って当たりやすい）。

### 8.4 操作の一覧（IDE の名前で）と、索引のどの事実を使うか

| 操作（IDE の名前） | 今 | 使う事実 | 機械で決める所 / 人へ回す所 |
|---|---|---|---|
| find-usages（`usages`） | 途中の物あり | def-use・case-*・label-*・type-use・use・record の式（字） | 全部機械。受け手の決まらない欄は `?` |
| call-hierarchy（`usages --callers --depth N`） | 同上 | def-use の owner | 全部機械 |
| safe-delete（`remove-dead`＋`usages --unused`） | remove-dead あり | def-decl（pub・ann）・def-use・use | 参照 0 は消す。テストからだけはテストごと。同じ mod の中だけは「pub を外す」を出す（消さない） |
| rename | 未 | def-use・case-*・type-use・use（alias= の字）・label-*（欄の時は typed） | 書いた名前の最後の区切りだけ替える。use の `{a, b}` の中も span がある（use の行は宣言の場所を持つ）。文字列・コメント・`.flow` は候補として fix |
| change-signature（引数を足す・並べ替える・消す） | 未 | def-use の呼び出しの span（＋引数の式の範囲＝v0.7 の Node の子） | 足す引数の値は `--value EXPR`、決められなければ fix。関数を値で渡す所（`参照`）は fix（lambda で包むかは人） |
| move（def を別の mod へ） | 未 | def-decl の ext・def-use・use | 本体を写し、呼び出しの修飾名を替え、use を直す。移す先で名前がぶつかれば止める |
| **change-case-shape**（enum の case の形を変える: `Scene.Deck(a, b)` → `Scene.Deck({ a, b })`） | 未 | case-construct・case-pattern（＋引数の span）・match-arm | Fight で手の一番かかった物（場面の case を payload の形へ 26 か所）。作る所は `{ a = x, b = y }` へ包み、当てる所は `Scene.Deck(p)` と束ねて本体の `a` を `p#a` へ（使わない欄は落とす）。ガードや入れ子の型は fix |
| move-fields（§7） | 設計メモ | label-*（typed）・record の式・case の payload | §7 のとおり。field-to-accessor（口を作る）→ 移す の 2 段 |
| field-to-accessor | あり（口を作る所は途中） | label-*（typed）・型 alias の宣言 | 口が無ければ作る（`<欄>Of`・`with<欄>`）。型の合わない読みは fix |

足りない事実: (1) 呼び出しの引数ごとの範囲（change-signature・change-case-shape）。v0.7 の Node の子で取れる。
(2) case の payload を束ねた変数の型（§7 の `recv=<Enum.Case>`）。(3) use の `{…}` の中の 1 つずつの範囲（rename）。今の use の行は
`use` の宣言 1 つに 1 行で、範囲は `Mod.name` の字 [確: fixture の `use Shapes.area` が 3:9–3:20]。`{a, b}` の時の範囲は未確認。

**優先の順と本番の記録の突き合わせ**: Fight で手で直した所は (a)10 (b)3 (c)2 (d)26 (e)17 (f)14（見回り役の報告）。一番多い (d) は
change-case-shape、World の形のリファクタの段 4 では change-signature が数百か所の見込み（見回り役）。この 2 つはどちらも足りない事実の (1)
（引数ごとの範囲）に掛かっていて、それを v0.7 の段 3 まで待つと、一番効く 2 つが一番後ろになる（レビュー前の段取りでは change-signature を D に置いていたが、
E と同じ事実を待つので D では作れなかった）。→ **(1) は今の `--spans` に `adds=arg` として先に足す**（use・type-use を足したのと同じ形。段 F で層 3 へ移す時に
一緒に置き換わる）。順は「usages（A）→ 引数の範囲を足す（B と並べて）→ change-case-shape と change-signature（D）→ rename・
safe-delete（E）」にする。rename・safe-delete は Fight の記録に当たる行が無い [推: (a)〜(f) の中身の対応はこの表に書かれていない]。
(a)〜(f) の各々がどの操作か（または道具の外か）を、この表の右に 1 列で書く（書けない物は道具の外として数える）。

### 8.5 AI が自然に使う導線

1. **早見表**（agents-pack の AGENTS.md）: 「対象の名前が分かっていれば先に道具。読むのは道具が止めた行だけ」を 1 行。
   usages・field-to-accessor・remove-dead をそれぞれ 1 行（やりたい事の語で）。
2. **lint の違反が fix のコマンドを持つ**: flixlint の規則（`test-only-api`・欄の歯止め）と fge の lint の違反の行に
   `fix: bin/fge refactor remove-dead --def X` のような写せる 1 行。違反を見た AI は grep せずにそれを流す。
3. **道具の出力が次の手を示す**（8.3 の 4）。止めた時は「止めた行の場所＋直し方の 1 行」だけ。
4. **2 つに分けて測る**。agent-eval は「道具を選べるか」だけを測る作りで、走らせる claude は読むだけ（Edit・Write を禁止、Bash は
   `make api`・`grep` などに限る。`bin/fge` は許していない）[確: agenteval.go の allowedTools・disallowedTools]。記録からは
   入力のトークン・ツールの呼び出しの数・読んだファイルを数えている [確: 同じファイルの tool_use の数え]。
   (a) **選べるか**: agent-eval に「名前だけ与えて、使う所を替えさせる」お題を足し、答えに `bin/fge refactor usages` などが出るかで採点。
   (b) **減ったか**: A/B（pointerShown 36 か所）と同じ場面を、同じコミットの worktree で道具あり・なしを同じ日に 3 回ずつ流し、agent-eval の記録の数え方
   （入力のトークン・ツールの呼び出しの数・Read の数）を流用して中央値で並べる。走らせる claude は Edit と `bin/fge` を許す（agent-eval の読むだけの設定とは別）。
   前回の A/B の数は、ゲームのコミットも道具の版も違うので基準にしない（両方の腕を流し直す。LLM の走行はばらつくので 1 回ずつでは比べない）。

### 8.6 段取り（どの順で入れ、何で効いたと言うか）

**checkd の段と合わせた順の正は checkd-freshness-design.md の §6.1**（R-A＋C-0 → 共-1（＝下の B）→ 共-2（＝下の C）→ C-1 → C-2＋R-D → C-T＋R-E → C-3 → R-F）。
下の表の B・C は共有の常駐の段として checkd の C-1 の前に入る。

| 段 | 中身 | 効いたと言う物（測る物） |
|---|---|---|
| A（R-A） | 出力の約束（8.3）を refactor 全体へ（6b56330c の途中の物を仕上げる）＋ usages＋口を作る field-to-accessor。6b56330c の `prepare`（設定の欄と既定の make check）を消し、止めた時は `next: make check` の 1 行 | (b) の比べ（8.5 の 4）: pointerShown 36 か所と同じ場面を、ゲームの同じコミット（A の始めに 1 つ名指しし、ここに書く）の worktree で、道具あり・なしを**同じ日に 3 回ずつ**流し、入力のトークンの中央値が道具ありの方が小さい事（前回の A/B は減らなかった。前回の数は写せた分だけ並べ、基準には使わない）。合わせてツールの呼び出しの数・Read の数の中央値。(a) agent-eval の新しいお題（`make agent-eval ONLY=<お題>`）で道具を選ぶ。usages の正しさ: ゲームの 0877ab5d の写しで 8.0 の表と同じ数が出る（go の test に固定）。口を作る field-to-accessor: 口の無い欄を 1 つ（A の始めに名指しし、ここに書く）に当て、道具 1 回＋`make check` 1 回で通る |
| B（共-1） | flixlint: 共有の常駐の土台（checkd §4.4 の 1〜7 のうち check 以外）。spans だけの走行も常駐へ・鍵を「根 × identity」・同じ flixlint・コンパイルの集まりは 1 つで SRC は絞り・予算は引数で。refactor は `--resident` を既定に。並べて `--spans` に `adds=arg`（8.4） | 同じ写しで (1) resolved・typed の 1 回目・2 回目の秒（今 8.7→2.8 s・18.0→4.1 s）、(2) 1 ファイル直した後の typed の秒、(3) lint→refactor→lint と交互に流した時の各秒と JVM の数（1）、(4) server の最大 RSS、(5) 並びの待ちの最長（'Q' の経過秒）。Mac mini の Fight と同じ写しで (1) を測り、8.0 の「5〜8 分」の内訳と並べる。Scala と Go で protocol 2 と socket の式の fixture が一致 |
| C（共-2） | flixlint: 依存の解決とソースの集まりを `Bootstrap` へ（8.1 の A）・`Deps.ofRoot` を消す・オプションを CLI と同じに。fixture は lib/ の無い worktree・maven の jar の無い lib/・use-engine で差し替えた lib/・揃った lib/ でネットワーク無し の 4 つ | Fight の止まり方を先に再現し、直した後に同じ写しで `bin/fge refactor usages X` が make を挟まずに通る。`ofRoot` が 0 行。4 つの fixture が `flix check` と同じ結果（通る・同じ文で止まる）。オプションを揃えた前後で lint の違反一覧と索引の行が一致（違えば 1 行ずつ理由） |
| D（R-D） | change-case-shape・change-signature（引数の範囲は B で足した物） | Fight の (d) 26 か所と同じ形（Fight の前のコミットを名指しする）を道具 1 回＋check 1 回で、手で直した後と同じ差分になる。change-signature は World の段 4 の最初の 1 本で、道具 1 回＋check 1 回と、手で直した同じ形の本の呼び出しの数（記録から数える） |
| E（R-E） | rename・safe-delete（usages --unused を remove-dead に寄せる）・move-fields（§7。case の受け手の事実が要る） | 前後で参照数が同じ・check が 1 回で通る。対象は名指しした 1 件ずつ（rename は `World.moveTo` の 39 か所など 8.0 の表の物） |
| F（R-F） | v0.7 の汎用の事実が出たら `--spans` を層 3 へ置き換え、Spans.scala の walker を消す | 索引の行が今の `--spans` と全件一致（fixture とゲーム・両段） |

決めた事（見回り役 2026-10-21。§8 の各節に反映済み）:
1. 8.1 は A（shim が `Bootstrap` を呼ぶ）。依存を入れる振る舞いは `flix check` と同じ。`--offline` は選べる旗で、既定にしない。
2. 常駐の鍵を根だけにする変更は 0.7 の前に入れてよい（flixlint の作り替えとリリースは依頼主の許可済み・nextcms は常駐を使っていない）。レビュー 2 で鍵は「根 × identity」に直した（版の違う呼び手が止め合わないため。checkd §4.4 の 2）。
3. 出力の約束は refactor で先に形を固め、`checkres` に入れてから、px・snd など他の道具は次にそれぞれを触る時に 1 本ずつ寄せる。
4. checkd の常駐は flixlint の Resident に check の口を足して、lint・refactor と共有する（エンジンには置かない）。口と順の正は checkd-freshness-design.md の §4.4・§6.1。

## §8 レビュー 1 の反映（2026-10-21）

- 8.0: 「原因は依存の解決が 2 つの源」を [推] にし、段 C の始めに Fight の写しで再現する事を足した。「1 回 5〜8 分」の内訳は未測定と書いた。
- 8.0: 常駐の 2 回目の秒は「ソースを変えず同じ引数」の時だけと書き、直した後・lint と交互の秒は未測定（checkd の文書では 1 字で 40〜60 s）とした。
- 8.1: 見回り役の決め（A・入れる振る舞いは flix check と同じ・`--offline` は選べる旗で既定にしない）を書いた。
- 8.1: 「`Deps.ofRoot` は手で渡す時だけ残す」を直した。手で渡す口は `ofPaths`。`ofRoot` は消す。
- 8.1: 6b56330c で既に入っている `prepare` を、設定の欄ごと段 A で消し、段 C までは `next: make check` の 1 行で示すとした。
- 8.1: `--offline` を自前の walk で作ると源が 2 つに戻るので、Bootstrap の側の口を段 C の始めに確かめるとした。
- 8.1: OS・オフライン・CI・use-engine の lib/ の 6 つの場面の表を足した。揃った lib/ でネットワークへ出るかは未確認として段 C の fixture にした。
- 8.1: Bootstrap が lib/ へ書く時の checkd との競り合い（checkd が repl を作り直す）を足した。
- 8.2: 鍵だけ根にすると身元（PWD 入り）の違いで server が止め合うので、身元も根にする事を足した。
- 8.2: lint と refactor が同じ flixlint を使う事（refactor は 5 か所から探している）を足した。
- 8.2: 常駐のコンパイラはファイルの集まりを 1 つ持つので、lint（src）と refactor（src＋test）で集まりを揃える事を足した。
- 8.2: 同時に頼まれた時（1 本ずつ・JVM は増えない・待つ側に 1 行）と、壊れた時（1 回だけ立て直す・1 回きりの JVM へ落ちない）を足した。
- 8.2: メモリ（flixlint 35%・checkd 33%/本数で、合わせて約 11 GB になりうる [推]）と、予算を hooks.json の 1 か所から引く事を足した。
- 8.2: checkd とは今は 1 つにしない理由（checkd の文書が内部の API を見送っている）と、checkd-freshness-design.md が無く突き合わせていない事を書いた。
- 8.2: 根だけの鍵を 0.7 の前に入れ、v0.7 の 3.4 の「Resident.scala は触らない」を 1 行直す順を書いた。見出しの「index server」を「常駐を 1 つに」にした。
- 8.3: px・snd・tickets・stateshape・refactor が既に checkres を使っている [確] と書き、足すのは「場所の一覧を畳む所」だけとした。
- 8.3: 広げる順を見回り役の決め（refactor → checkres → 他は触る時に 1 本ずつ）にし、歯止めを lint の規則から構造（型でしか画面へ出せない）へ替えた。
- 8.4: 最多の (d) と段 4 の change-signature が引数の範囲を待つので、`--spans` に `adds=arg` を先に足すとし、(a)〜(f) と操作の対応の列を求めた。
- 8.5: agent-eval は読むだけで道具を流せない [確] ので、「選べるか」（agent-eval）と「減ったか」（A/B と同じ場面の再演）に分けた。A/B の基準の数を写す事を求めた。
- 8.6: 段の順を D＝change-case-shape・change-signature、E＝rename・safe-delete・move-fields に入れ替え、各段の物差しを数で比べられる形にした。
- 8.6: 「決めてほしい事」を「決めた事」に替えた。
- 言葉: 「網」を「ネットワーク」にした。

## §8 レビュー 2 の反映（2026-10-21・2 枚の突き合わせ）

- 8.0: usages の途中の物は「未コミット」でなく 6b56330c にコミット済み（作業ツリーに差分無し）と直した。
- 8.1: lib/ の競り合いは、checkd が共有の常駐へ移った後は常駐の中の 1 本と素の `flix check` だけになると足した。
- 8.2: 「checkd とは今は 1 つにしない」を、見回り役の決め（flixlint の Resident に check の口を足して共有）に替え、口・順・予算・戻り方の正を checkd §4.4 の 1 か所にした。
- 8.2: 「lint は src だけ」は誤り（ゲームの lint は既に `src test` [確: Makefile]）と直し、コンパイルは `Bootstrap` の sources・SRC は出力の絞りだけとした。
- 8.2: 鍵を「根」から「根 × identity」に直し、違う identity は server を止めずに別の常駐へ行くとした（止め合いで 1 回目の秒を毎回払わない）。
- 8.2: lint と refactor と checkd が同じ shim の jar を使い、探す所をエンジンの 1 か所にするとした（ゲームの lint は submodule のタグの jar を落としている [確]）。
- 8.2: 同時に来た時の順を「1 本ずつ accept の列」から「check を先に 1 本・追い越しは 1 回まで・'Q' の枠」に替えた（今の server は順を選べない [確]）。
- 8.2: メモリは今の checkd の線（maxMB 4096 [確]）が typed の約 5 GB に合わない事を書き、予算は呼び手が引数で渡し、線は checkd の C-1 の実測で決め直すとした。
- 8.2: resolved は `Flix` の増分の状態に書かない [確: コード] ので、check と同じ `Flix` で流すとした（checkd の設計の「別の Flix」をやめた）。
- 8.5・8.6: 段 A の物差しを「前回の数を基準に」から「同じコミット・同じ日に両方の腕を 3 回ずつ・中央値」に替えた（前回の数が無く、版も違うため）。
- 8.6: 段 A に usages の正しさ（0877ab5d の写しで 8.0 の表と同じ数を go の test に固定）と、口を作る field-to-accessor の完了条件を足した。
- 8.6: B・C を共通の段（共-1・共-2）とし、B に protocol 2 と socket の式の Scala・Go の一致と並びの待ちの最長を、C にオプションを CLI に揃えた前後の一致を足した。合わせた順の正を checkd §6.1 にした。
- 8.6: 決めた事に 4（checkd の共有）を足し、2 に鍵の直しを書いた。

## 段 A（R-A）の名指しと記録（2026-10-21・実装の担当）

- ゲームのコミット: internet_dungeon の **0877ab5d**（id-verify の origin/master と同じ）。索引は flixlint の spans-uses の 7923ecb。
- 口の無い欄: **`World#pointerShown`**（口 0・直の読み書き 36。A/B と同じ題材）。`field-to-accessor --label pointerShown --receiver World --apply`
  の 1 回で口 2 つ（`World.pointerShownOf`・`World.withPointerShown`）を作って 36 か所を替え、道具の中の `make check` 1 回で通った。
  next の `field-sites … --outside World --max 0` で外の直の読み書き 0。
- usages の正しさ: 8.0 の表の 4 つ（39・7・29・679）と `--unused` の def（402・45・126・231）を
  `go/internal/refactor/game_test.go`（絞った索引 `testdata/game-0877ab5d-resolved.tsv.gz`・作り直しは `-game-index`）に固定。
  使っていない use 35 はソースの字が要るので写しでだけ確かめた。

## 共-2（段 C）の記録（2026-10-22・flixlint 0.8.1）

- 8.1 の A を入れた（c3b553c・53ac4ba）。shim の `Deps.ofRoot`・`ofProject`・`need`・`listJars` は 0 行（grep）。自前の道は手で渡す
  `--pkg`/`--jar`（`ofPaths`）だけ。依存とソースは `Bootstrap.bootstrap(根, token)` の `ProjectFiles`、mounts は flix.toml から。
- `Bootstrap` に網へ出ない形は無い【確: flix.jar の javap。`bootstrap(path, token)(formatter, out)` だけ】。なので `--offline` は
  Java の proxy selector を閉じた口へ向けた間に `Bootstrap` を呼び、出ようとしたら最初の URI を名指して exit 4 にした。
  揃った lib/ では網を塞いでも通る【確: 下の full-offline。JFR のソケットの出来事 0 件】。8.1 の表の「未確認」はこれで「出ない」。
- オプション: CLI の check は `Options.Default` に lib = All・installDeps = true・GitHub の token・progress = true【確: Main$ の javap
  と Options.Default・CmdOpts() を出した試し】。flixlint は progress だけ切って同じにした。揃えた前後でゲームの違反一覧（3279 行）と
  spans の索引（resolved 182,837・typed 188,170 行）が両段とも cmp で同じ【確】。
- 4 つの場面（と揃った lib/）は `test/bootstrap-cases.sh PROJECT BUILD_DIR [LOCAL_FPKG LOCAL_TOML]`。ゲームの写しで全部 flix check と
  揃った【確】: full-offline・no-lib（flixlint は「Flix installed 31 …」の 1 行）・no-lib-off（両方止まる。flixlint は GitHub の
  flix.toml の URI を名指す）・no-maven・local-fpkg（配布版を詰め直して指紋を変えた fpkg に lock を揃え、網を塞いで両方通る。流した後も
  lib/ の fpkg は手元の物）。
- 残す物: SRC は今もコンパイルの集まりを絞る（`Bootstrap` の sources のうち SRC の下）。「コンパイルは `Bootstrap` の sources 全部・SRC は
  出力の絞りだけ」（checkd §4.2 の 1・§4.4 の 4）は walker・Generic・Spans・Names の出力の絞りが要るので共-1（または C-1）で入れる。
  Fight の止まり方の再現と `bin/fge refactor usages X` が make を挟まずに通る事は、エンジンの側（R-A の prepare を消す所）で確かめる。
