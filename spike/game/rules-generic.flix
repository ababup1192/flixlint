/// internet_dungeon の lint/rules.flix の custom 規則 7 本を、汎用の AST（Flixlint.Ast・Flixlint.Flix）だけで書き直した物。
/// id・allowIn・報告の行と文は lint/rules.flix と同じ。対象の名前は Flixlint.Names の値（Fn・Case）で書く。
/// ゲームのソースが要るので make test には入れない。Mac mini でゲームに向けて test/generic/compare.sh で比べる。
mod GameLintGeneric {
    use Flixlint.{RuleSet, customRule, allowIn}
    use Flixlint.Ast.{Ast, Node, AliasMode}
    use Flixlint.AstKinds.{Kind, Attr}
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Case}

    pub def rules(ast: Ast): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "arena-raw-number", check = _ -> arenaRawNumber(ast) }),
            customRule({ id = "doc-id-literal", check = _ -> docIdLiteral(ast) })
                |> allowIn(Fn.LabTargets_defaults, "LabTargets.defaults は targets.json と同じ値から出発する Doc の既定値（コードには既定値だけ・fail-open）。id はここにあってよい"),
            customRule({ id = "test-branch", check = _ -> testBranch(ast) }),
            customRule({ id = "test-bool-expect", check = _ -> testBoolExpect(ast) }),
            customRule({ id = "test-bool-some", check = _ -> testBoolSome(ast) }),
            customRule({ id = "test-bool-tuple", check = _ -> testBoolTuple(ast) }),
            customRule({ id = "test-only-api", check = _ -> testOnlyApi(ast) })
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

    def inTest(ast: Ast, n: Node): Bool = String.startsWith(prefix = "test/", Flixlint.Ast.file(ast, n))

    def inSrc(ast: Ast, n: Node): Bool = String.startsWith(prefix = "src/", Flixlint.Ast.file(ast, n))

    /// src/ の pub な def のうち、定義元の mod の外の src/ からは呼ばれず、test/ からだけ呼ばれる物
    /// （テストのために公開した口。自分の中で使うだけなら pub を外す）。
    def testOnlyApi(ast: Ast): List[Violation] =
        let defs = Flixlint.Flix.defs(ast);
        let moduleByName = defs |> List.map(d -> (Flixlint.Flix.nameOf(ast, d), Flixlint.Flix.moduleOf(Flixlint.Flix.nameOf(ast, d)))) |> List.toMap;
        // 呼び出しごとに (呼ばれた名前, 呼んだ def)。宣言の外（enum・alias）の呼び出しは無い
        let callers = Flixlint.Flix.calls(ast)
            |> List.map(c -> (Flixlint.Flix.callee(ast, c), Flixlint.Ast.root(ast, c)))
            |> List.filter(p -> Flixlint.Ast.is(ast, Kind.Def, snd(p)));
        let fromTest = callers |> List.filter(p -> inTest(ast, snd(p))) |> List.map(fst) |> List.toSet;
        let fromOtherSrc = callers |> List.filter(match (callee, caller) ->
            inSrc(ast, caller) and (Map.get(callee, moduleByName) |> Option.forAll(m -> m != Flixlint.Flix.moduleOf(Flixlint.Flix.nameOf(ast, caller)))))
            |> List.map(fst) |> List.toSet;
        defs
            |> List.filter(d -> Flixlint.Flix.isPub(ast, d) and inSrc(ast, d))
            |> List.filter(d -> {
                let n = Flixlint.Flix.nameOf(ast, d);
                Set.memberOf(n, fromTest) and not Set.memberOf(n, fromOtherSrc)
            })
            |> List.map(d -> Flixlint.Flix.violation(ast, "test-only-api", d, Flixlint.Flix.declLine(ast, d), "is called from test/ only",
                "テストの値と問いは本体と同じ口で作る。テストのためだけの pub な口を本体に足さない（docs/plan-world-shape.md §2）"))

    /// test/ と src/render/ の文字列に書いた Doc の id（大文字の語を _ で繋ぎ、_ と数字で終わる。ATK_002・MIX_AT_001）。
    /// 文の中の id も 1 つずつ数え、_ で終わる頭（"ATK_" + "002"・"ATK_${n}"）も数える。見るのは文字列の字だけ。
    def docIdLiteral(ast: Ast): List[Violation] =
        let watched = file -> String.startsWith(prefix = "test/", file) or String.startsWith(prefix = "src/render/", file);
        Flixlint.Ast.ofKinds(ast, List#{Kind.Expr_Cst, Kind.Pattern_Cst})
            |> List.filter(n -> Flixlint.Ast.is(ast, Kind.Def, Flixlint.Ast.root(ast, n)) and watched(Flixlint.Ast.file(ast, n)))
            |> List.filterMap(n -> if (Flixlint.Ast.attr(ast, n, Attr.Cst) == Some("Str")) Flixlint.Ast.attr(ast, n, Attr.Cst_lit) |> Option.map(s -> (n, s)) else None)
            |> List.flatMap(match (n, s) -> Regex.submatches(docId(), s) |> List.map(id ->
                Flixlint.Flix.violation(ast, "doc-id-literal", n, Flixlint.Ast.line(ast, n), "writes the Doc id ${id}",
                    "Doc の id を直に書かない（文の中・つないで作る形も）。Doc の既定値から系統・段・並びで引く（期待値は Doc の既定値から導く・quality-assurance）")))

    /// Doc の id の形。末尾は数字か、字の終わり・空白・" の手前の _（つないで作る頭）。
    def docId(): Regex = regex"\\b[A-Z]{2,}(?:_[A-Z]{2,})*_(?:[0-9]+\\b|(?=[\"\\s]|$))"

    /// src/FightArena.flix の pub な def が素の数を取る引数（1 引数 1 つ）。引数の型のどこか（Option・組・record の欄の中も）に
    /// 素の数の型か、それを指すエイリアスがあれば数える。欄が 2 つ以上の record のエイリアスは数えない。
    def arenaRawNumber(ast: Ast): List[Violation] =
        let raw = rawNumbers(ast);
        Flixlint.Flix.defs(ast)
            |> List.filter(d -> Flixlint.Flix.isPub(ast, d) and Flixlint.Ast.file(ast, d) == "src/FightArena.flix")
            |> List.flatMap(d -> Flixlint.Flix.params(ast, d) |> List.zipWithIndex
                |> List.filter(match (_, p) -> Flixlint.Ast.attrType(ast, p, Attr.Tpe)
                    |> Option.exists(t -> Flixlint.Ast.typeNames(ast, t, AliasMode.Closed) |> List.exists(n -> Set.memberOf(n, raw))))
                |> List.map(match (i, _) -> Flixlint.Flix.violation(ast, "arena-raw-number", d, Flixlint.Flix.declLine(ast, d),
                    "takes a raw number as parameter ${i}", "戦いの場の名前つきの口は自由な数を取らない。値は口の名前で決め、数は中で Doc や時計から引く")))

    /// 素の数の型の名前と、それを指すエイリアス（欄が 2 つ以上の record のエイリアスは外す。増えなくなるまで集める）。
    def rawNumbers(ast: Ast): Set[String] =
        let primitives = Set#{"Int8", "Int16", "Int32", "Int64", "Float32", "Float64", "BigInt", "BigDecimal"};
        let aliases = Flixlint.Flix.typeAliases(ast) |> List.filter(a -> Flixlint.Flix.recordFields(ast, a) < 2)
            |> List.map(a -> (Flixlint.Flix.nameOf(ast, a),
                Flixlint.Flix.aliasType(ast, a) |> Option.map(t -> Flixlint.Ast.typeNames(ast, t, AliasMode.Closed)) |> Option.getWithDefault(Nil)));
        let grow = known -> List.foldLeft((acc, p) -> if (List.exists(n -> Set.memberOf(n, known), snd(p))) Set.insert(fst(p), acc) else acc, known, aliases);
        closure(grow, primitives)

    /// f を当てても増えなくなるまで当てた集合。
    def closure(f: Set[String] -> Set[String], s: Set[String]): Set[String] =
        let next = f(s);
        if (Set.size(next) == Set.size(s)) s else closure(f, next)

    /// test/ の中の分岐: if・match（match のラムダも）と、Option・Result の中で Some と None・Ok と Err を分ける
    /// getWithDefault・fold の呼び出し（名前解決の後の名前で数えるので、use の別名も数え、別の型の同じ名前は数えない）。
    def testBranch(ast: Ast): List[Violation] =
        let reason = "テストで分けない（getWithDefault・fold とその別名も）。Option・Result は Some(…)・Ok(…) のまま assertEq で比べ、作る値は本体の型と関数で 1 通りに決める";
        let splitting = Set#{Fn.Option_getWithDefault, Fn.Option_fold, Fn.Result_getWithDefault};
        let byBranch = Flixlint.Flix.branches(ast)
            |> List.filter(match (_, n) -> inTest(ast, n))
            |> List.map(match (kind, n) -> Flixlint.Flix.violation(ast, "test-branch", n, Flixlint.Ast.line(ast, n), "branches with ${kind}", reason));
        let byCall = Flixlint.Flix.calls(ast)
            |> List.filter(c -> Flixlint.Flix.callsOneOf(ast, splitting, c) and inTest(ast, c))
            |> List.map(c -> Flixlint.Flix.violation(ast, "test-branch", c, Flixlint.Flix.callLine(ast, c), "calls ${Flixlint.Flix.callee(ast, c)}", reason));
        byBranch ::: byCall

    /// test/ の def の本体の Bool の字と、そのすぐ上の親（not と型の注釈は透かす）・親の書き始めの行。
    def testBoolLits(ast: Ast): List[(Node, String, Int32)] =
        Flixlint.Ast.ofKind(ast, Kind.Expr_Cst)
            |> List.filter(b -> Flixlint.Flix.isBool(ast, b) and inTest(ast, b))
            |> List.filterMap(b -> Flixlint.Flix.placement(ast, b) |> List.head |> Option.map(match (p, line) -> (b, p, line)))

    /// test/ の中で、述語の答えを Bool の字と比べる形: `expected = true`・`assertEq(true, x)`・`x == true`・`let want = true`、
    /// と assertTrue・assertFalse の呼び出し。`not` は透かして見る。
    def testBoolExpect(ast: Ast): List[Violation] =
        let reason = "述語を true・false と比べない（assertTrue・assertFalse にも渡さない）。述語が見ている値（リスト・Option・enum の case）そのものを assertEq の期待値と比べる";
        let byLiteral = testBoolLits(ast)
            |> List.filter(match (_, p, _) -> comparesWithLiteral(p))
            |> List.map(match (b, _, _) -> Flixlint.Flix.violation(ast, "test-bool-expect", b, Flixlint.Ast.line(ast, b),
                "compares with ${Flixlint.Ast.attr(ast, b, Attr.Cst_lit) |> Option.getWithDefault("?")}", reason));
        let byCall = Flixlint.Flix.calls(ast)
            |> List.filter(c -> Flixlint.Flix.callsOneOf(ast, Set#{Fn.Assert_assertTrue, Fn.Assert_assertFalse}, c) and inTest(ast, c))
            |> List.map(c -> Flixlint.Flix.violation(ast, "test-bool-expect", c, Flixlint.Flix.callLine(ast, c), "calls ${Flixlint.Flix.callee(ast, c)}", reason));
        byLiteral ::: byCall

    /// 字の true・false のすぐ上の親が、比べの相手（expected の欄・位置で渡した assertEq の 1 つ目・== と != の片方・let の右辺）か。
    def comparesWithLiteral(parent: String): Bool =
        parent == "field:expected" or parent == "let" or parent == "arg:Assert.assertEq:0" or parent == "arg:Assert.assertEqWithMsg:0"
            or String.startsWith(prefix = "arg:Eq.eq:", parent)
            or String.startsWith(prefix = "arg:Eq.neq:", parent)

    /// test/ の中で、Bool を Option・Result で包んで比べる形（Some(true)・Ok(a == b)・Some(not x)・Err(a and b)・Some(t: Bool)）。
    /// 包んだ値の形で両方の段で数え、Bool の変数は型で数える（型は typed の段でしか分からない）。
    def testBoolSome(ast: Ast): List[Violation] =
        let wrappers = Set#{Case.Option_Some, Case.Result_Ok, Case.Result_Err};
        let boolish = shape -> shape == "bool" or shape == "unary:Not" or shape == "op:And" or shape == "op:Or"
            or String.startsWith(prefix = "call:Eq.", shape) or String.startsWith(prefix = "call:Order.", shape);
        Flixlint.Flix.tags(ast)
            |> List.filter(t -> inTest(ast, t) and Flixlint.Flix.buildsOneOf(ast, wrappers, t))
            |> List.flatMap(t -> Flixlint.Flix.args(ast, t) |> List.map(a -> (t, a)))
            |> List.filter(match (_, a) -> Flixlint.Flix.typeHead(ast, a) == Some("Bool") or boolish(Flixlint.Flix.shapeOf(ast, a)))
            |> List.map(match (t, a) -> Flixlint.Flix.violation(ast, "test-bool-some", t, Flixlint.Ast.line(ast, t), "wraps a Bool (${Flixlint.Flix.shapeOf(ast, a)})",
                "Bool を Some・Ok で包んで比べない。Option の中身そのもの（Some(値)）か、意味のある enum の case で比べる"))

    /// test/ の中で、Bool の字を要素に直に持つ組・並び（(true, x)・List#{true}・x :: … の中の組・Vector#{false}）。
    /// 組の書き始めの行ごとに 1 件（同じ行に組が 2 つあっても 1 件）。
    def testBoolTuple(ast: Ast): List[Violation] =
        let containers = Set#{"tuple", "vector", "tag:List.Cons"};
        testBoolLits(ast)
            |> List.filter(match (_, p, _) -> Set.memberOf(p, containers))
            |> List.map(match (b, _, line) -> ((Flixlint.Ast.root(ast, b), line), b))
            |> List.distinctWith((x, y) -> fst(x) == fst(y))
            |> List.map(match ((_, line), b) -> Flixlint.Flix.violation(ast, "test-bool-tuple", b, line,
                "a tuple or list starting on this line holds Bool literals",
                "Bool を組や並びにして比べない（Some で包む・let で組む・位置で渡すのも）。何の状態かを表す enum（Showing・Overlay など）か、値そのものを期待値にする"))
}
