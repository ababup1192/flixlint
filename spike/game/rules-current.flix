/// このゲームの決まりのうち、型と名前解決が要る物（flixlint の規則）。
///
/// flixlint（submodule の flixlint/）が src/ と test/ の型つき AST から取った事実と突き合わせる。
/// 流すのは make lint の口（lint-test-only-api・lint-ratchet・lint-flixlint）。数で止める規則の上限は lint/limits/<規則>.json
/// （上限ちょうどで通る・増えたら止まる・減ったら上限を下げるまで止まる）。一覧を見るなら make lint-list。
/// 名前は flixlint が作る Flixlint.Names から取るので、消えた def を指す allowIn はコンパイルで止まる。
mod GameLint {
    use Flixlint.{RuleSet, customRule, allowIn}
    use Flixlint.Facts.{Facts, Def}
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Type, Case}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "arena-raw-number", check = arenaRawNumber }),
            customRule({ id = "doc-id-literal", check = docIdLiteral })
                |> allowIn(Fn.LabTargets_defaults, "LabTargets.defaults は targets.json と同じ値から出発する Doc の既定値（コードには既定値だけ・fail-open）。id はここにあってよい"),
            customRule({ id = "test-branch", check = testBranch }),
            customRule({ id = "test-bool-expect", check = testBoolExpect }),
            customRule({ id = "test-bool-some", check = testBoolSome }),
            customRule({ id = "test-bool-tuple", check = testBoolTuple }),
            customRule({ id = "test-only-api", check = testOnlyApi })
                |> allowIn(Fn.ArchetypeDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.BattleDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.BoardDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.BoardDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.CardDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.ChipDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.ChipDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.CueDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.CueDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.CycleDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.CycleDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.DungeonDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.EnemyDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.FeedDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.InstrumentDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.InstrumentDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.KeysDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.KeysDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.LabTargets_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.OpeningDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.OpeningDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.PuzzleDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.RelicDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.ScriptDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.ScriptDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.SfxTuneDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.ShotDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.ShotDoc_rec, "Doc の中身を読む口（rec）。橋渡しテスト（TestShotDoc）がディスクの shots.json の山札を並べ、全部が card.json で引けるかを見る（本体の道具は名前で deckOf を引くだけ）")
                |> allowIn(Fn.SfxTuneDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
                |> allowIn(Fn.ThemeDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.TutorialDoc_defaults, "Doc の既定値（note の defaults）")
                |> allowIn(Fn.TutorialDoc_fromJson, "Doc の JSON を読む口（note の fromJson）")
        })
    })

    /// src/ の pub な def のうち、定義元の mod の外の src/ からは呼ばれず、test/ からだけ呼ばれる物
    /// （テストのために公開した口。自分の中で使うだけなら pub を外す）。
    /// 呼び出しは名前解決の後の物なので、use の別名・同じ名前の別の mod の def を取り違えない。
    /// A が src の B からだけ呼ばれ、B が test からだけ呼ばれる時、A は本体から呼ばれていると数える（B だけが出る）。
    def testOnlyApi(facts: Facts): List[Violation] =
        let inSrc = d -> String.startsWith(prefix = "src/", d#file);
        let inTest = d -> String.startsWith(prefix = "test/", d#file);
        // 呼ばれた def ごとに「定義元の外の src から呼ばれたか」「test から呼ばれたか」を 1 巡で集める。
        let callers = Flixlint.Facts.calls(facts) |> List.filterMap(c ->
            Flixlint.Facts.defOf(facts, c#caller) |> Option.map(d -> (c#callee, d)));
        let fromTest = callers |> List.filter(p -> inTest(snd(p))) |> List.map(fst) |> List.toSet;
        let fromOtherSrc = callers |> List.filter(p ->
            let (callee, caller) = p;
            inSrc(caller) and (Flixlint.Facts.defOf(facts, callee) |> Option.forAll(d -> d#module != caller#module)))
            |> List.map(fst) |> List.toSet;
        Flixlint.Facts.defs(facts)
            |> List.filter(d -> d#isPub and inSrc(d))
            |> List.filter(d -> Set.memberOf(d#fn, fromTest) and not Set.memberOf(d#fn, fromOtherSrc))
            |> List.map(d -> Flixlint.Violation.atDef(facts, "test-only-api", d, "is called from test/ only",
                "テストの値と問いは本体と同じ口で作る。テストのためだけの pub な口を本体に足さない（docs/plan-world-shape.md §2）"))

    /// test/ と src/render/ の文字列に書いた Doc の id（大文字の語を _ で繋ぎ、_ と数字で終わる。ATK_002・MIX_AT_001）。
    /// 文の中の id（"id ATK_002"・"ATK_001,DEF_001"）も 1 つずつ数え、_ で終わる頭（"ATK_" + "002"・"ATK_${n}"）も数える。
    /// 見るのは文字列の字だけ（コメント・名前は見ない）。差し込み "${…}" の前後は別の字として届く。
    def docIdLiteral(facts: Facts): List[Violation] =
        let watched = file -> String.startsWith(prefix = "test/", file) or String.startsWith(prefix = "src/render/", file);
        Flixlint.Facts.strLits(facts)
            |> List.filter(s -> Flixlint.Facts.defOf(facts, s#fn) |> Option.exists(d -> watched(d#file)))
            |> List.flatMap(s -> Regex.submatches(docId(), s#text) |> List.map(id ->
                Flixlint.Violation.inBody(facts, "doc-id-literal", s#fn, s#line, "writes the Doc id ${id}",
                    "Doc の id を直に書かない（文の中・つないで作る形も）。Doc の既定値から系統・段・並びで引く（期待値は Doc の既定値から導く・quality-assurance）")))

    /// Doc の id の形。末尾は数字か、字の終わり・空白・" の手前の _（つないで作る頭）。
    def docId(): Regex = regex"\\b[A-Z]{2,}(?:_[A-Z]{2,})*_(?:[0-9]+\\b|(?=[\"\\s]|$))"

    /// src/FightArena.flix の pub な def が素の数を取る引数（1 引数 1 つ）。名前つきの口は自由な値を取らない決まり
    /// （戦いの場の値は口の名前で決め、数は中で Doc や時計から引く）。引数の型のどこか（Option・組・record の欄の中も）に
    /// 素の数の型か、それを指すエイリアスがあれば数える。エイリアスは修飾された名前で引くので、別の mod の同じ名前を
    /// 取り違えない。欄が 2 つ以上の record のエイリアス（RelicCostMark・Rec）は、欄の名前が数の意味を言うので数えない。
    def arenaRawNumber(facts: Facts): List[Violation] =
        let raw = rawNumbers(facts);
        Flixlint.Facts.defs(facts)
            |> List.filter(d -> d#isPub and d#file == "src/FightArena.flix")
            |> List.flatMap(d -> Flixlint.Facts.argTypesAllOf(facts, d#fn)
                |> List.filter(a -> Set.memberOf(a#tycon, raw))
                |> List.map(a -> a#index) |> List.distinct
                |> List.map(i -> Flixlint.Violation.atDef(facts, "arena-raw-number", d, "takes a raw number as parameter ${i}",
                    "戦いの場の名前つきの口は自由な数を取らない。値は口の名前で決め、数は中で Doc や時計から引く")))

    /// 素の数の型と、それを指すエイリアス（欄が 2 つ以上の record のエイリアスは外す。増えなくなるまで集める）。
    def rawNumbers(facts: Facts): Set[Type] =
        let primitives = Set#{"Int8", "Int16", "Int32", "Int64", "Float32", "Float64", "BigInt", "BigDecimal"};
        let aliases = Flixlint.Facts.typeAliases(facts) |> List.filter(a -> a#fields < 2) |> List.map(a -> a#typeAlias);
        let seeds = Flixlint.Facts.argTypesAll(facts) |> List.map(a -> a#tycon)
            |> List.filter(t -> Set.memberOf(Flixlint.Facts.typeName(facts, t), primitives)) |> List.toSet;
        let grow = known -> List.foldLeft((acc, a) ->
            if (Set.exists(t -> Set.memberOf(t, known), Flixlint.Facts.aliasTypesAllOf(facts, a))) Set.insert(a, acc) else acc,
            known, aliases);
        closure(grow, Set.union(seeds, primitiveTypesInAliases(facts, primitives)))

    /// エイリアスの中に現れる素の数の型（引数に直には出ない Float32 などもエイリアス越しに数えるため）。
    def primitiveTypesInAliases(facts: Facts, primitives: Set[String]): Set[Type] =
        Flixlint.Facts.typeAliases(facts)
            |> List.flatMap(a -> Set.toList(Flixlint.Facts.aliasTypesAllOf(facts, a#typeAlias)))
            |> List.filter(t -> Set.memberOf(Flixlint.Facts.typeName(facts, t), primitives))
            |> List.toSet

    /// f を当てても増えなくなるまで当てた集合。
    def closure(f: Set[Type] -> Set[Type], s: Set[Type]): Set[Type] =
        let next = f(s);
        if (Set.size(next) == Set.size(s)) s else closure(f, next)

    /// test/ の中の分岐: if・match（match のラムダも）と、Option・Result の中で Some と None・Ok と Err を分ける
    /// getWithDefault・fold の呼び出し。呼び出しは名前解決の後の物なので、use で付けた別名も数え、
    /// Map.getWithDefault のような別の型の同じ名前は数えない。テストは本体の型と関数で値を 1 通りに決め、分けない。
    def testBranch(facts: Facts): List[Violation] =
        let inTest = fn -> Flixlint.Facts.defOf(facts, fn) |> Option.exists(d -> String.startsWith(prefix = "test/", d#file));
        let reason = "テストで分けない（getWithDefault・fold とその別名も）。Option・Result は Some(…)・Ok(…) のまま assertEq で比べ、作る値は本体の型と関数で 1 通りに決める";
        let splitting = Set#{Fn.Option_getWithDefault, Fn.Option_fold, Fn.Result_getWithDefault};
        let byBranch = Flixlint.Facts.branches(facts)
            |> List.filter(b -> inTest(b#fn))
            |> List.map(b -> Flixlint.Violation.inBody(facts, "test-branch", b#fn, b#line, "branches with ${b#kind}", reason));
        let byCall = Flixlint.Facts.calls(facts)
            |> List.filter(c -> Set.memberOf(c#callee, splitting) and inTest(c#caller))
            |> List.map(c -> Flixlint.Violation.atCall(facts, "test-branch", c, reason));
        byBranch ::: byCall

    /// test/ の中で、述語の答えを Bool の字と比べる形: `expected = true`（名前つき引数の expected の欄）・`assertEq(true, x)`・
    /// `x == true`・`let want = true`、と assertTrue・assertFalse の呼び出し。`not` は透かして見る。
    def testBoolExpect(facts: Facts): List[Violation] =
        let reason = "述語を true・false と比べない（assertTrue・assertFalse にも渡さない）。述語が見ている値（リスト・Option・enum の case）そのものを assertEq の期待値と比べる";
        let byLiteral = testBoolLits(facts)
            |> List.filter(b -> comparesWithLiteral(nearest(b#placement)))
            |> List.map(b -> Flixlint.Violation.inBody(facts, "test-bool-expect", b#fn, b#line, "compares with ${b#value}", reason));
        let byCall = Flixlint.Facts.calls(facts)
            |> List.filter(c -> (c#callee == Fn.Assert_assertTrue or c#callee == Fn.Assert_assertFalse) and inTest(facts, c#caller))
            |> List.map(c -> Flixlint.Violation.atCall(facts, "test-bool-expect", c, reason));
        byLiteral ::: byCall

    /// 字の true・false のすぐ上の親が、比べの相手（expected の欄・位置で渡した assertEq の 1 つ目・== と != の片方・let の右辺）か。
    /// 位置で渡す assertEq(true, x) は expected が record の引数なので型が止めるが、resolved の段の lint は型を見ないのでここでも数える。
    def comparesWithLiteral(parent: String): Bool =
        parent == "field:expected" or parent == "let" or parent == "arg:Assert.assertEq:0" or parent == "arg:Assert.assertEqWithMsg:0"
            or String.startsWith(prefix = "arg:Eq.eq:", parent)
            or String.startsWith(prefix = "arg:Eq.neq:", parent)

    /// test/ の中で、Bool を Option・Result で包んで比べる形（Some(true)・Ok(a == b)・Some(not x)・Err(a and b)・Some(t: Bool)）。
    /// 包んだ値の形（字の true・false・not・and・or・== などの比べ）で両方の段で数え、Bool の変数は型で数える。型は
    /// typed の段でしか分からないので、make lint（resolved の段）が止めるのは形の分だけ。
    def testBoolSome(facts: Facts): List[Violation] =
        let wrappers = Set#{Case.Option_Some, Case.Result_Ok, Case.Result_Err};
        let boolish = shape -> shape == "bool" or shape == "unary:Not" or shape == "op:And" or shape == "op:Or"
            or String.startsWith(prefix = "call:Eq.", shape) or String.startsWith(prefix = "call:Order.", shape);
        Flixlint.Facts.tagArgs(facts)
            |> List.filter(a -> Set.memberOf(a#constructor, wrappers) and inTest(facts, a#fn) and (a#tycon == "Bool" or boolish(a#shape)))
            |> List.map(a -> Flixlint.Violation.inBody(facts, "test-bool-some", a#fn, a#line, "wraps a Bool (${a#shape})",
                "Bool を Some・Ok で包んで比べない。Option の中身そのもの（Some(値)）か、意味のある enum の case で比べる"))

    /// test/ の中で、Bool の字を要素に直に持つ組・並び（(true, x)・List#{true}・x :: … の中の組・Vector#{false}）。
    /// 組の書き始めの行ごとに 1 件（同じ行に組が 2 つあっても 1 件。入れ子の組は書き始めの行が違えば別に数える）。
    def testBoolTuple(facts: Facts): List[Violation] =
        let containers = Set#{"tuple", "vector", "tag:List.Cons"};
        testBoolLits(facts)
            |> List.filter(b -> Set.memberOf(nearest(b#placement), containers))
            |> List.map(b -> (b#fn, b#parentLine)) |> List.toSet |> Set.toList
            |> List.map(match (fn, line) -> Flixlint.Violation.inBody(facts, "test-bool-tuple", fn, line, "a tuple or list starting on this line holds Bool literals",
                "Bool を組や並びにして比べない（Some で包む・let で組む・位置で渡すのも）。何の状態かを表す enum（Showing・Overlay など）か、値そのものを期待値にする"))

    /// test/ の def の本体の Bool の字。
    def testBoolLits(facts: Facts): List[Flixlint.Facts.BoolLit] =
        Flixlint.Facts.boolLits(facts) |> List.filter(b -> inTest(facts, b#fn))

    def inTest(facts: Facts, fn: Fn): Bool =
        Flixlint.Facts.defOf(facts, fn) |> Option.exists(d -> String.startsWith(prefix = "test/", d#file))

    /// 字のすぐ上の親（`placement` の先頭）。
    def nearest(placement: String): String =
        String.splitOn({substr = " < "}, placement) |> List.head |> Option.getWithDefault(placement)
}
