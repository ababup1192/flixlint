/// (spike) The custom rules of rules.flix written against the generic AST (Flixlint.Ast) only: the same ids, the
/// same violations expected. Names still come from Flixlint.Names (fnName turns a case into the qualified name).
mod GenericFixtureRules {
    use Flixlint.{RuleSet, customRule, allowIn}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Ast.{Ast, Node}
    use Flixlint.Names.Fn

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.custom("guarded-write", guardedWrite),
        Flixlint.customs(List#{
            customRule({ id = "capability-site", check = capabilitySite })
                |> allowIn(Fn.Orders_permitsInLambda, "an allow on a custom rule"),
            customRule({ id = "silent-parse", check = silentParse }),
            customRule({ id = "raw-alias", check = rawAlias }),
            customRule({ id = "flat-rules", check = flatRules }),
            customRule({ id = "bool-arg", check = boolArg }),
            customRule({ id = "wrapped-bool", check = wrappedBool })
        })
    })

    def name(facts: Facts, fn: Fn): String = Flixlint.Facts.fnName(facts, fn)

    def fileOfDef(ast: Ast, n: Node): String = Flixlint.Ast.file(ast, n)

    /// Calling an Inventory function that takes a Permit proof from src/api without Inventory.guarded in the same function.
    def guardedWrite(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let mutating = Flixlint.Ast.defs(ast)
            |> List.filter(d -> Flixlint.Ast.moduleOf(Flixlint.Ast.nameOf(ast, d)) == "Inventory"
                and (Flixlint.Ast.paramTypes(ast, d) |> List.head |> Option.flatMap(Flixlint.Ast.typeHead(ast))) == Some("Auth.Permit"))
            |> List.map(Flixlint.Ast.nameOf(ast)) |> List.toSet;
        let guarded = name(facts, Fn.Inventory_guarded);
        let callsGuarded = Flixlint.Ast.calls(ast) |> List.filter(c -> Flixlint.Ast.callee(ast, c) == guarded)
            |> List.filterMap(Flixlint.Ast.defOf(ast)) |> List.toSet;
        Flixlint.Ast.calls(ast)
            |> List.filter(c -> Set.memberOf(Flixlint.Ast.callee(ast, c), mutating))
            |> List.filter(c -> Flixlint.Glob.matches("src/api/**", fileOfDef(ast, c)))
            |> List.filter(c -> not (Flixlint.Ast.defOf(ast, c) |> Option.exists(d -> Set.memberOf(d, callsGuarded))))
            |> List.map(c -> Flixlint.Ast.violation(facts, "guarded-write", c, Flixlint.Ast.callLine(ast, c),
                "calls ${Flixlint.Ast.callee(ast, c)}", "bulk writes from the API go through Inventory.guarded"))

    /// Calling an Auth function that asks Auth (has the effect) and returns a proof, from src/domain outside Auth itself.
    def capabilitySite(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let judging = Flixlint.Ast.defs(ast)
            |> List.filter(d -> Flixlint.Ast.moduleOf(Flixlint.Ast.nameOf(ast, d)) == "Auth" and Flixlint.Ast.isPub(ast, d)
                and Set.memberOf("Auth", Flixlint.Ast.effectsOf(ast, d))
                and (Flixlint.Ast.returnType(ast, d) |> Option.flatMap(Flixlint.Ast.typeHead(ast))) == Some("Auth.Permit"))
            |> List.map(Flixlint.Ast.nameOf(ast)) |> List.toSet;
        Flixlint.Ast.calls(ast)
            |> List.filter(c -> Set.memberOf(Flixlint.Ast.callee(ast, c), judging))
            |> List.filter(c -> let f = fileOfDef(ast, c); Flixlint.Glob.matches("src/domain/**", f) and f != "src/domain/Auth.flix")
            |> List.map(c -> Flixlint.Ast.violation(facts, "capability-site", c, Flixlint.Ast.callLine(ast, c),
                "calls ${Flixlint.Ast.callee(ast, c)}", "use cases receive Permit as an argument; only the boundary asks Auth"))

    /// The shape of a case argument: `bool`, `unary:<op>`, `op:<op>`, `call:<callee>`, `var`, else the node's kind.
    def shapeOf(ast: Ast, e: Node): String =
        let s = Flixlint.Ast.seeThrough(ast, e);
        let op = Flixlint.Ast.attr(ast, s, "sop") |> Option.getWithDefault("?");
        if (Flixlint.Ast.isBool(ast, s)) "bool"
        else if (s#kind == "Expr.Unary") "unary:${op}"
        else if (s#kind == "Expr.Binary") "op:${op}"
        else if (Flixlint.Ast.isCall(s)) "call:${Flixlint.Ast.callee(ast, s)}"
        else if (s#kind == "Expr.Var") "var"
        else String.dropLeft(5, s#kind)

    /// A Bool wrapped in Some / Ok / Err: by its type at the typed stage, by its shape at both.
    def wrappedBool(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let wrappers = Set#{"Option.Some", "Result.Ok", "Result.Err"};
        let boolish = s -> s == "bool" or s == "unary:Not" or s == "op:And" or s == "op:Or"
            or String.startsWith(prefix = "call:Eq.", s) or String.startsWith(prefix = "call:Order.", s);
        Flixlint.Ast.ofKind(ast, "Expr.Tag")
            |> List.filter(t -> Set.memberOf(Flixlint.Ast.attr(ast, t, "symUse") |> Option.getWithDefault(""), wrappers))
            |> List.flatMap(t -> Flixlint.Ast.args(ast, t) |> List.map(a -> (t, a)))
            |> List.filter(match (_, a) -> Flixlint.Ast.typeOf(ast, a) == Some("Bool") or boolish(shapeOf(ast, a)))
            |> List.map(match (t, a) -> Flixlint.Ast.violation(facts, "wrapped-bool", t, t#line, "wraps a Bool (${shapeOf(ast, a)})",
                "a wrapped Bool says nothing; an enum case names the answer"))

    /// A `true` / `false` passed straight to a function.
    def boolArg(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        Flixlint.Ast.ofKind(ast, "Expr.Cst")
            |> List.filter(Flixlint.Ast.isBool(ast))
            |> List.filterMap(b -> Flixlint.Ast.placement(ast, b) |> List.head |> Option.map(p -> (b, fst(p))))
            |> List.filter(match (_, p) -> String.startsWith(prefix = "arg:", p))
            |> List.map(match (b, p) -> Flixlint.Ast.violation(facts, "bool-arg", b, b#line, "passes ${p}",
                "a Bool argument is named by an enum case or a record field"))

    /// No `if` or `match` in src/domain/rules.
    def flatRules(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        Flixlint.Ast.branches(ast)
            |> List.filter(match (_, n) -> Flixlint.Glob.matches("src/domain/rules/**", Flixlint.Ast.file(ast, n)))
            |> List.map(match (kind, n) -> Flixlint.Ast.violation(facts, "flat-rules", n, n#line, "branches with ${kind}",
                "a rule is a table read by a lookup; the branching lives in the caller"))

    /// A type alias that stands for a bare Int64, except a record of two or more fields.
    def rawAlias(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        Flixlint.Ast.ofKind(ast, "TypeAlias")
            |> List.filter(a -> Flixlint.Ast.recordFields(ast, a) < 2
                and (Flixlint.Ast.child(ast, a, "tpe") |> Option.exists(t -> Flixlint.Ast.typeNames(ast, t, false) |> List.memberOf("Int64"))))
            |> List.map(a -> Flixlint.Ast.violation(facts, "raw-alias", a, Flixlint.Ast.declLine(ast, a),
                "stands for a bare Int64", "a number is named by a record field or an enum, not by an alias of Int64"))

    /// A value Ids.parse rejects that is dropped (List.filterMap) or replaced by a default (Option.getWithDefault,
    /// directly or through a pipe); a default that is Result.Err is a rejection and not reported.
    def silentParse(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let reason = "a value that does not parse is rejected, not dropped or replaced by a default";
        let parse = name(facts, Fn.Ids_parse);
        let filterMap = name(facts, Fn.List_filterMap);
        let getWithDefault = name(facts, Fn.Option_getWithDefault);
        let parses = Flixlint.Ast.calls(ast) |> List.filter(c -> Flixlint.Ast.callee(ast, c) == parse);
        // dropped: a call to Ids.parse inside a lambda (or a function passed by name) given to List.filterMap
        let dropped = parses
            |> List.filter(c -> Flixlint.Ast.ancestors(ast, c) |> List.filter(a -> a#kind == "Expr.Lambda")
                |> List.exists(l -> Flixlint.Ast.lambdaPassedTo(ast, l) |> List.exists(p -> fst(p) == filterMap)))
            |> List.map(c -> Flixlint.Ast.violation(facts, "silent-parse", c, Flixlint.Ast.callLine(ast, c), "drops the values Ids.parse rejects", reason));
        // defaulted through a pipe: a chain whose stages have Ids.parse before Option.getWithDefault (outermost pipes only)
        let viaPipe = Flixlint.Ast.calls(ast)
            |> List.filter(p -> Flixlint.Ast.isPipe(ast, p) and not (Flixlint.Ast.parent(ast, p) |> Option.exists(q -> Flixlint.Ast.isPipe(ast, q) and p#slot == "exps" and p#index == 0)))
            |> List.flatMap(p -> {
                let stages = Flixlint.Ast.pipeStages(ast, p);
                let seenParse = List.exists(s -> fst(s) == parse, stages);
                let after = stages |> List.dropWhile(s -> fst(s) != parse);
                if (seenParse) after |> List.filter(s -> fst(s) == getWithDefault) |> List.map(s -> snd(s)) else Nil
            })
            |> List.map(n -> (n, n#line));
        // defaulted directly: Option.getWithDefault(d, Ids.parse(..)) (the argument at index 1 stands for Ids.parse)
        let viaArg = Flixlint.Ast.calls(ast)
            |> List.filter(c -> Flixlint.Ast.callee(ast, c) == getWithDefault)
            |> List.filter(c -> Flixlint.Ast.args(ast, c) |> List.drop(1) |> List.head |> Option.flatMap(Flixlint.Ast.denoted(ast)) == Some(parse))
            |> List.map(c -> (c, Flixlint.Ast.callLine(ast, c)));
        let rejecting = Flixlint.Ast.ofKind(ast, "Expr.Tag")
            |> List.filter(t -> Flixlint.Ast.attr(ast, t, "symUse") == Some("Result.Err"))
            |> List.map(t -> (Flixlint.Ast.defOf(ast, t), t#line));
        let defaulted = (viaPipe ::: viaArg)
            |> List.map(match (n, line) -> ((Flixlint.Ast.defOf(ast, n), line), n))
            |> List.distinctWith((a, b) -> fst(a) == fst(b))
            |> List.filter(p -> not List.memberOf(fst(p), rejecting))
            |> List.map(match ((_, line), n) -> Flixlint.Ast.violation(facts, "silent-parse", n, line, "defaults the values Ids.parse rejects", reason));
        dropped ::: defaulted
}
