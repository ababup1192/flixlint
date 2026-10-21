/// The custom rules of rules.flix written against the generic AST only (Flixlint.Ast and Flixlint.Flix): the same ids,
/// the same violations expected (test/run.sh compares the two at both stages). What a rule is about is named with a
/// Flixlint.Names value (`Fn.Ids_parse`, `Type.Auth_Permit`), so a name the sources no longer have fails to compile.
mod GenericFixtureRules {
    use Flixlint.{RuleSet, customRule, allowIn}
    use Flixlint.Ast.{Ast, Node}
    use Flixlint.AstKinds.Kind
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Case, Type, Eff, Mod}

    pub def rules(ast: Ast): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "guarded-write", check = _ -> guardedWrite(ast) }),
            customRule({ id = "capability-site", check = _ -> capabilitySite(ast) })
                |> allowIn(Fn.Orders_permitsInLambda, "an allow on a custom rule"),
            customRule({ id = "silent-parse", check = _ -> silentParse(ast) }),
            customRule({ id = "raw-alias", check = _ -> rawAlias(ast) }),
            customRule({ id = "flat-rules", check = _ -> flatRules(ast) }),
            customRule({ id = "bool-arg", check = _ -> boolArg(ast) }),
            customRule({ id = "wrapped-bool", check = _ -> wrappedBool(ast) })
        })
    })

    def name(fn: Fn): String = Flixlint.Names.fnName(fn)

    /// Calling an Inventory function that takes a Permit proof from src/api without Inventory.guarded in the same function.
    def guardedWrite(ast: Ast): List[Violation] =
        let mutating = Flixlint.Flix.defs(ast)
            |> List.filter(d -> Flixlint.Flix.isIn(ast, Mod.Inventory, d)
                and (Flixlint.Flix.paramTypes(ast, d) |> List.head |> Option.exists(Flixlint.Flix.headIs(ast, Type.Auth_Permit))))
            |> List.map(Flixlint.Flix.nameOf(ast)) |> List.toSet;
        let callsGuarded = Flixlint.Flix.callsTo(ast, Fn.Inventory_guarded)
            |> List.filterMap(Flixlint.Flix.defOf(ast)) |> List.toSet;
        Flixlint.Flix.calls(ast)
            |> List.filter(c -> Set.memberOf(Flixlint.Flix.callee(ast, c), mutating))
            |> List.filter(c -> Flixlint.Glob.matches("src/api/**", Flixlint.Ast.file(ast, c)))
            |> List.filter(c -> not (Flixlint.Flix.defOf(ast, c) |> Option.exists(d -> Set.memberOf(d, callsGuarded))))
            |> List.map(c -> Flixlint.Flix.violation(ast, "guarded-write", c, Flixlint.Flix.callLine(ast, c),
                "calls ${Flixlint.Flix.callee(ast, c)}", "bulk writes from the API go through Inventory.guarded"))

    /// Calling an Auth function that asks Auth (has the effect) and returns a proof, from src/domain outside Auth itself.
    def capabilitySite(ast: Ast): List[Violation] =
        let judging = Flixlint.Flix.defs(ast)
            |> List.filter(d -> Flixlint.Flix.isIn(ast, Mod.Auth, d) and Flixlint.Flix.isPub(ast, d)
                and Flixlint.Flix.hasEffect(ast, Eff.Auth, d)
                and (Flixlint.Flix.returnType(ast, d) |> Option.exists(Flixlint.Flix.headIs(ast, Type.Auth_Permit))))
            |> List.map(Flixlint.Flix.nameOf(ast)) |> List.toSet;
        Flixlint.Flix.calls(ast)
            |> List.filter(c -> Set.memberOf(Flixlint.Flix.callee(ast, c), judging))
            |> List.filter(c -> {
                let f = Flixlint.Ast.file(ast, c);
                Flixlint.Glob.matches("src/domain/**", f) and f != "src/domain/Auth.flix"
            })
            |> List.map(c -> Flixlint.Flix.violation(ast, "capability-site", c, Flixlint.Flix.callLine(ast, c),
                "calls ${Flixlint.Flix.callee(ast, c)}", "use cases receive Permit as an argument; only the boundary asks Auth"))

    /// A Bool wrapped in Some / Ok / Err: by its type at the typed stage, by its shape at both.
    def wrappedBool(ast: Ast): List[Violation] =
        let wrappers = Set#{Case.Option_Some, Case.Result_Ok, Case.Result_Err};
        let boolish = s -> s == "bool" or s == "unary:Not" or s == "op:And" or s == "op:Or"
            or String.startsWith(prefix = "call:Eq.", s) or String.startsWith(prefix = "call:Order.", s);
        Flixlint.Flix.tags(ast)
            |> List.filter(Flixlint.Flix.buildsOneOf(ast, wrappers))
            |> List.flatMap(t -> Flixlint.Flix.args(ast, t) |> List.map(a -> (t, a)))
            |> List.filter(match (_, a) -> Flixlint.Flix.typeHead(ast, a) == Some("Bool") or boolish(Flixlint.Flix.shapeOf(ast, a)))
            |> List.map(match (t, a) -> Flixlint.Flix.violation(ast, "wrapped-bool", t, Flixlint.Ast.line(ast, t),
                "wraps a Bool (${Flixlint.Flix.shapeOf(ast, a)})", "a wrapped Bool says nothing; an enum case names the answer"))

    /// A `true` / `false` passed straight to a function.
    def boolArg(ast: Ast): List[Violation] =
        Flixlint.Ast.ofKind(ast, Kind.Expr_Cst)
            |> List.filter(Flixlint.Flix.isBool(ast))
            |> List.filterMap(b -> Flixlint.Flix.placement(ast, b) |> List.head |> Option.map(p -> (b, fst(p))))
            |> List.filter(match (_, p) -> String.startsWith(prefix = "arg:", p))
            |> List.map(match (b, p) -> Flixlint.Flix.violation(ast, "bool-arg", b, Flixlint.Ast.line(ast, b), "passes ${p}",
                "a Bool argument is named by an enum case or a record field"))

    /// No `if` or `match` in src/domain/rules.
    def flatRules(ast: Ast): List[Violation] =
        Flixlint.Flix.branches(ast)
            |> List.filter(match (_, n) -> Flixlint.Glob.matches("src/domain/rules/**", Flixlint.Ast.file(ast, n)))
            |> List.map(match (kind, n) -> Flixlint.Flix.violation(ast, "flat-rules", n, Flixlint.Ast.line(ast, n), "branches with ${kind}",
                "a rule is a table read by a lookup; the branching lives in the caller"))

    /// A type alias that stands for a bare Int64, except a record of two or more fields.
    def rawAlias(ast: Ast): List[Violation] =
        Flixlint.Flix.typeAliases(ast)
            |> List.filter(a -> Flixlint.Flix.recordFields(ast, a) < 2
                and (Flixlint.Flix.aliasType(ast, a) |> Option.exists(t -> Flixlint.Flix.mentions(ast, Type.Int64, t))))
            |> List.map(a -> Flixlint.Flix.violation(ast, "raw-alias", a, Flixlint.Flix.declLine(ast, a),
                "stands for a bare Int64", "a number is named by a record field or an enum, not by an alias of Int64"))

    /// A value Ids.parse rejects that is dropped (List.filterMap) or replaced by a default (Option.getWithDefault,
    /// directly or through a pipe); a default that is Result.Err is a rejection and not reported.
    def silentParse(ast: Ast): List[Violation] =
        let reason = "a value that does not parse is rejected, not dropped or replaced by a default";
        let parse = name(Fn.Ids_parse);
        let filterMap = name(Fn.List_filterMap);
        let getWithDefault = name(Fn.Option_getWithDefault);
        let parses = Flixlint.Flix.callsTo(ast, Fn.Ids_parse);
        // dropped: a call to Ids.parse inside a lambda (or a function passed by name) given to List.filterMap
        let dropped = parses
            |> List.filter(c -> Flixlint.Ast.ancestors(ast, c) |> List.filter(Flixlint.Ast.is(ast, Kind.Expr_Lambda))
                |> List.exists(l -> Flixlint.Flix.lambdaPassedTo(ast, l) |> List.exists(p -> fst(p) == filterMap)))
            |> List.map(c -> Flixlint.Flix.violation(ast, "silent-parse", c, Flixlint.Flix.callLine(ast, c), "drops the values Ids.parse rejects", reason));
        // defaulted through a pipe: a chain whose stages have Ids.parse before Option.getWithDefault (outermost pipes only)
        let outermost = p -> not (Flixlint.Ast.parent(ast, p) |> Option.exists(q -> Flixlint.Flix.isPipe(ast, q)
            and Flixlint.Ast.slotOf(ast, p) == Some(Flixlint.AstKinds.Slot.Exps) and Flixlint.Ast.indexOf(ast, p) == 0));
        let viaPipe = Flixlint.Flix.calls(ast)
            |> List.filter(p -> Flixlint.Flix.isPipe(ast, p) and outermost(p))
            |> List.flatMap(p -> {
                let stages = Flixlint.Flix.pipeStages(ast, p);
                let after = stages |> List.dropWhile(s -> fst(s) != parse);
                if (List.exists(s -> fst(s) == parse, stages)) after |> List.filter(s -> fst(s) == getWithDefault) |> List.map(snd) else Nil
            })
            |> List.map(n -> (n, Flixlint.Ast.line(ast, n)));
        // defaulted directly: Option.getWithDefault(d, Ids.parse(..)) (the argument at index 1 stands for Ids.parse)
        let viaArg = Flixlint.Flix.callsTo(ast, Fn.Option_getWithDefault)
            |> List.filter(c -> (Flixlint.Flix.args(ast, c) |> List.drop(1) |> List.head |> Option.flatMap(Flixlint.Flix.denoted(ast))) == Some(parse))
            |> List.map(c -> (c, Flixlint.Flix.callLine(ast, c)));
        let rejecting = Flixlint.Flix.tagsOf(ast, Case.Result_Err)
            |> List.map(t -> (Flixlint.Flix.defOf(ast, t), Flixlint.Ast.line(ast, t)));
        let defaulted = (viaPipe ::: viaArg)
            |> List.map(match (n, line) -> ((Flixlint.Flix.defOf(ast, n), line), n))
            |> List.distinctWith((a, b) -> fst(a) == fst(b))
            |> List.filter(p -> not List.memberOf(fst(p), rejecting))
            |> List.map(match ((_, line), n) -> Flixlint.Flix.violation(ast, "silent-parse", n, line, "defaults the values Ids.parse rejects", reason));
        dropped ::: defaulted
}
