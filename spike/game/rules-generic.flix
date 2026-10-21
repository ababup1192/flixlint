/// (spike) internet_dungeon の lint/rules.flix（rules-current.flix）を、汎用の事実（Flixlint.Ast）だけで書き直した物。
/// id・allowIn・報告の行と文は同じ。名前は Flixlint.Names の case から fnName で修飾名にして比べる。
mod GameLintGeneric {
    use Flixlint.{RuleSet, customRule, allowIn}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Ast.{Ast, Node}
    use Flixlint.Names.Fn

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "arena-raw-number", check = arenaRawNumber }),
            customRule({ id = "doc-id-literal", check = docIdLiteral })
                |> allowIn(Fn.LabTargets_defaults, "Doc の既定値"),
            customRule({ id = "test-branch", check = testBranch }),
            customRule({ id = "test-bool-expect", check = testBoolExpect }),
            customRule({ id = "test-bool-some", check = testBoolSome }),
            customRule({ id = "test-bool-tuple", check = testBoolTuple }),
            customRule({ id = "test-only-api", check = testOnlyApi })
                |> allowIn(Fn.ArchetypeDoc_defaults, "Doc") |> allowIn(Fn.BattleDoc_defaults, "Doc")
                |> allowIn(Fn.BoardDoc_defaults, "Doc") |> allowIn(Fn.BoardDoc_fromJson, "Doc")
                |> allowIn(Fn.CardDoc_defaults, "Doc") |> allowIn(Fn.ChipDoc_defaults, "Doc")
                |> allowIn(Fn.ChipDoc_fromJson, "Doc") |> allowIn(Fn.CueDoc_defaults, "Doc")
                |> allowIn(Fn.CueDoc_fromJson, "Doc") |> allowIn(Fn.CycleDoc_defaults, "Doc")
                |> allowIn(Fn.CycleDoc_fromJson, "Doc") |> allowIn(Fn.DungeonDoc_defaults, "Doc")
                |> allowIn(Fn.EnemyDoc_defaults, "Doc") |> allowIn(Fn.FeedDoc_defaults, "Doc")
                |> allowIn(Fn.InstrumentDoc_defaults, "Doc") |> allowIn(Fn.InstrumentDoc_fromJson, "Doc")
                |> allowIn(Fn.KeysDoc_defaults, "Doc") |> allowIn(Fn.KeysDoc_fromJson, "Doc")
                |> allowIn(Fn.LabTargets_fromJson, "Doc") |> allowIn(Fn.OpeningDoc_defaults, "Doc")
                |> allowIn(Fn.OpeningDoc_fromJson, "Doc") |> allowIn(Fn.PuzzleDoc_defaults, "Doc")
                |> allowIn(Fn.RelicDoc_fromJson, "Doc") |> allowIn(Fn.ScriptDoc_defaults, "Doc")
                |> allowIn(Fn.ScriptDoc_fromJson, "Doc") |> allowIn(Fn.SfxTuneDoc_defaults, "Doc")
                |> allowIn(Fn.ShotDoc_fromJson, "Doc") |> allowIn(Fn.ShotDoc_rec, "Doc")
                |> allowIn(Fn.SfxTuneDoc_fromJson, "Doc") |> allowIn(Fn.ThemeDoc_defaults, "Doc")
                |> allowIn(Fn.TutorialDoc_defaults, "Doc") |> allowIn(Fn.TutorialDoc_fromJson, "Doc")
        })
    })

    def inTest(ast: Ast, n: Node): Bool = String.startsWith(prefix = "test/", Flixlint.Ast.file(ast, n))

    def inSrc(ast: Ast, n: Node): Bool = String.startsWith(prefix = "src/", Flixlint.Ast.file(ast, n))

    /// src/ の pub な def のうち、定義元の mod の外の src/ からは呼ばれず、test/ からだけ呼ばれる物。
    def testOnlyApi(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let defs = Flixlint.Ast.defs(ast);
        let byName = defs |> List.map(d -> (Flixlint.Ast.nameOf(ast, d), d)) |> List.toMap;
        // 呼び出しごとに (呼ばれた名前, 呼んだ def)
        let callers = Flixlint.Ast.calls(ast) |> List.map(c -> (Flixlint.Ast.callee(ast, c), Flixlint.Ast.root(ast, c)))
            |> List.filter(p -> snd(p)#kind == "Def");
        let fromTest = callers |> List.filter(p -> inTest(ast, snd(p))) |> List.map(fst) |> List.toSet;
        let moduleOf = d -> Flixlint.Ast.moduleOf(Flixlint.Ast.nameOf(ast, d));
        let fromOtherSrc = callers |> List.filter(match (callee, caller) ->
            inSrc(ast, caller) and (Map.get(callee, byName) |> Option.forAll(d -> moduleOf(d) != moduleOf(caller))))
            |> List.map(fst) |> List.toSet;
        defs
            |> List.filter(d -> Flixlint.Ast.isPub(ast, d) and inSrc(ast, d))
            |> List.filter(d -> let n = Flixlint.Ast.nameOf(ast, d); Set.memberOf(n, fromTest) and not Set.memberOf(n, fromOtherSrc))
            |> List.map(d -> Flixlint.Ast.violation(facts, "test-only-api", d, Flixlint.Ast.declLine(ast, d), "is called from test/ only",
                "テストのためだけの pub な口を本体に足さない"))

    /// test/ と src/render/ の文字列に書いた Doc の id。
    def docIdLiteral(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let watched = file -> String.startsWith(prefix = "test/", file) or String.startsWith(prefix = "src/render/", file);
        Flixlint.Ast.ofKinds(ast, List#{"Expr.Cst", "Pattern.Cst"})
            |> List.filter(n -> Flixlint.Ast.root(ast, n)#kind == "Def" and watched(Flixlint.Ast.file(ast, n)))
            |> List.filterMap(n -> Flixlint.Ast.attr(ast, n, "cst.lit") |> Option.filter(_ -> Flixlint.Ast.attr(ast, n, "cst") == Some("Str")) |> Option.map(s -> (n, s)))
            |> List.flatMap(match (n, s) -> Regex.submatches(docId(), s) |> List.map(id ->
                Flixlint.Ast.violation(facts, "doc-id-literal", n, n#line, "writes the Doc id ${id}", "Doc の id を直に書かない")))

    def docId(): Regex = regex"\\b[A-Z]{2,}(?:_[A-Z]{2,})*_(?:[0-9]+\\b|(?=[\"\\s]|$))"

    /// src/FightArena.flix の pub な def が素の数を取る引数（1 引数 1 つ）。
    def arenaRawNumber(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let raw = rawNumbers(ast);
        Flixlint.Ast.defs(ast)
            |> List.filter(d -> Flixlint.Ast.isPub(ast, d) and Flixlint.Ast.file(ast, d) == "src/FightArena.flix")
            |> List.flatMap(d -> Flixlint.Ast.paramTypes(ast, d) |> List.zipWithIndex
                |> List.filter(match (_, t) -> Flixlint.Ast.typeNames(ast, t, false) |> List.exists(n -> Set.memberOf(n, raw)))
                |> List.map(match (i, _) -> Flixlint.Ast.violation(facts, "arena-raw-number", d, Flixlint.Ast.declLine(ast, d),
                    "takes a raw number as parameter ${i}", "戦いの場の名前つきの口は自由な数を取らない")))

    /// 素の数の型の名前と、それを指すエイリアス（欄が 2 つ以上の record のエイリアスは外す。増えなくなるまで集める）。
    def rawNumbers(ast: Ast): Set[String] =
        let primitives = Set#{"Int8", "Int16", "Int32", "Int64", "Float32", "Float64", "BigInt", "BigDecimal"};
        let aliases = Flixlint.Ast.ofKind(ast, "TypeAlias") |> List.filter(a -> Flixlint.Ast.recordFields(ast, a) < 2)
            |> List.map(a -> (Flixlint.Ast.nameOf(ast, a), Flixlint.Ast.child(ast, a, "tpe") |> Option.map(t -> Flixlint.Ast.typeNames(ast, t, false)) |> Option.getWithDefault(Nil)));
        let grow = known -> List.foldLeft((acc, p) -> if (List.exists(n -> Set.memberOf(n, known), snd(p))) Set.insert(fst(p), acc) else acc, known, aliases);
        closure(grow, primitives)

    def closure(f: Set[String] -> Set[String], s: Set[String]): Set[String] =
        let next = f(s);
        if (Set.size(next) == Set.size(s)) s else closure(f, next)

    /// test/ の中の分岐と、Some と None・Ok と Err を分ける getWithDefault・fold の呼び出し。
    def testBranch(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let reason = "テストで分けない";
        let splitting = Set#{"Option.getWithDefault", "Option.fold", "Result.getWithDefault"};
        let byBranch = Flixlint.Ast.branches(ast)
            |> List.filter(match (_, n) -> inTest(ast, n))
            |> List.map(match (kind, n) -> Flixlint.Ast.violation(facts, "test-branch", n, n#line, "branches with ${kind}", reason));
        let byCall = Flixlint.Ast.calls(ast)
            |> List.filter(c -> Set.memberOf(Flixlint.Ast.callee(ast, c), splitting) and inTest(ast, c))
            |> List.map(c -> Flixlint.Ast.violation(facts, "test-branch", c, Flixlint.Ast.callLine(ast, c), "calls ${Flixlint.Ast.callee(ast, c)}", reason));
        byBranch ::: byCall

    /// test/ の def の本体の Bool の字と、そのすぐ上の親（not と型の注釈は透かす）・親の書き始めの行。
    def testBoolLits(ast: Ast): List[(Node, String, Int32)] =
        Flixlint.Ast.ofKind(ast, "Expr.Cst")
            |> List.filter(b -> Flixlint.Ast.isBool(ast, b) and inTest(ast, b))
            |> List.filterMap(b -> Flixlint.Ast.placement(ast, b) |> List.head |> Option.map(match (p, line) -> (b, p, line)))

    /// test/ の中で、述語の答えを Bool の字と比べる形と、assertTrue・assertFalse の呼び出し。
    def testBoolExpect(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let reason = "述語を true・false と比べない";
        let byLiteral = testBoolLits(ast)
            |> List.filter(match (_, p, _) -> comparesWithLiteral(p))
            |> List.map(match (b, _, _) -> Flixlint.Ast.violation(facts, "test-bool-expect", b, b#line,
                "compares with ${Flixlint.Ast.attr(ast, b, "cst.lit") |> Option.getWithDefault("?")}", reason));
        let byCall = Flixlint.Ast.calls(ast)
            |> List.filter(c -> let f = Flixlint.Ast.callee(ast, c); (f == "Assert.assertTrue" or f == "Assert.assertFalse") and inTest(ast, c))
            |> List.map(c -> Flixlint.Ast.violation(facts, "test-bool-expect", c, Flixlint.Ast.callLine(ast, c), "calls ${Flixlint.Ast.callee(ast, c)}", reason));
        byLiteral ::: byCall

    def comparesWithLiteral(parent: String): Bool =
        parent == "field:expected" or parent == "let" or parent == "arg:Assert.assertEq:0" or parent == "arg:Assert.assertEqWithMsg:0"
            or String.startsWith(prefix = "arg:Eq.eq:", parent)
            or String.startsWith(prefix = "arg:Eq.neq:", parent) or parent == "op:BoolOp.Eq" or parent == "op:BoolOp.Neq"

    def shapeOf(ast: Ast, e: Node): String =
        let s = Flixlint.Ast.seeThrough(ast, e);
        let op = Flixlint.Ast.attr(ast, s, "sop") |> Option.getWithDefault("?");
        if (Flixlint.Ast.isBool(ast, s)) "bool"
        else if (s#kind == "Expr.Unary") "unary:${op}"
        else if (s#kind == "Expr.Binary") "op:${op}"
        else if (Flixlint.Ast.isCall(s)) "call:${Flixlint.Ast.callee(ast, s)}"
        else if (s#kind == "Expr.Var") "var"
        else String.dropLeft(5, s#kind)

    /// test/ の中で、Bool を Option・Result で包んで比べる形。
    def testBoolSome(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let wrappers = Set#{"Option.Some", "Result.Ok", "Result.Err"};
        let boolish = shape -> shape == "bool" or shape == "unary:Not" or shape == "op:And" or shape == "op:Or"
            or String.startsWith(prefix = "call:Eq.", shape) or String.startsWith(prefix = "call:Order.", shape);
        Flixlint.Ast.ofKind(ast, "Expr.Tag")
            |> List.filter(t -> inTest(ast, t) and Set.memberOf(Flixlint.Ast.attr(ast, t, "symUse") |> Option.getWithDefault(""), wrappers))
            |> List.flatMap(t -> Flixlint.Ast.args(ast, t) |> List.map(a -> (t, a)))
            |> List.filter(match (_, a) -> Flixlint.Ast.typeOf(ast, a) == Some("Bool") or boolish(shapeOf(ast, a)))
            |> List.map(match (t, a) -> Flixlint.Ast.violation(facts, "test-bool-some", t, t#line, "wraps a Bool (${shapeOf(ast, a)})",
                "Bool を Some・Ok で包んで比べない"))

    /// test/ の中で、Bool の字を要素に直に持つ組・並び。組の書き始めの行ごとに 1 件。
    def testBoolTuple(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let containers = Set#{"tuple", "vector", "tag:List.Cons"};
        testBoolLits(ast)
            |> List.filter(match (_, p, _) -> Set.memberOf(p, containers))
            |> List.map(match (b, _, line) -> ((b#root, line), b))
            |> List.distinctWith((x, y) -> fst(x) == fst(y))
            |> List.map(match ((_, line), b) -> Flixlint.Ast.violation(facts, "test-bool-tuple", b, line,
                "a tuple or list starting on this line holds Bool literals", "Bool を組や並びにして比べない"))
}
