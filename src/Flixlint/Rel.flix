///
/// Layer 3 of the generic AST (docs/design-generic.md 2.1): the relations the families judge, built from the generic AST
/// with the meaning and the spelling of the old fact tables (`def`, `calls`, `arg_type_all`, ...), so that the families can
/// move onto it table by table and each table can be compared with the old one row for row (`FLIXLINT_DUMP_REL`,
/// test/compare-old.sh).
///
pub mod Flixlint.Rel {
    use Flixlint.Ast.{Ast, Node, TypeRef, TypeForm, Stage}
    use Flixlint.AstKinds.{Kind, Slot, Attr}
    import java.io.File
    import java.nio.file.Files

    /// A table: its name (the old TSV's file name without `.tsv`) and its rows, each a list of columns as the old TSV spells them.
    pub type alias Table = { name = String, rows = List[List[String]] }

    /// The names of the tables, in the order `dump` writes them.
    pub def names(): List[String] = List#{
        "source_file", "def", "enum", "eff", "type_alias", "alias_type_all", "eff_alias", "effect_of",
        "arg_type", "arg_type_all", "arg_type_deep", "ret_type", "ret_type_all", "ret_type_deep",
        "case_type", "case_type_all", "case_type_deep",
        "calls", "calls_in_lambda", "arg_lit", "arg_call", "piped_into", "str_lit", "handles", "branch", "constructs",
        "bool_lit", "tag_arg"
    }

    /// Every table.
    pub def tables(ast: Ast): List[Table] =
        let rowsOf = tableOf(ast);
        names() |> List.map(n -> { name = n, rows = rowsOf(n) })

    /// The rows of a table by its name (no rows for a name that is no table). A table is built when it is asked for; the
    /// body tables come from one walk of the bodies, made at the first of them.
    pub def tableOf(ast: Ast): String -> List[List[String]] =
        let bodies = lazy bodyTables(ast);
        name -> match name {
            case "source_file" => Flixlint.Ast.files(ast) |> List.map(f -> f :: Nil)
            case "def" => defRows(ast)
            case "enum" => declRows(ast, Kind.Enum)
            case "eff" => declRows(ast, Kind.Effect)
            case "type_alias" => aliasRows(ast)
            case "alias_type_all" => aliasTypeAllRows(ast)
            case "eff_alias" => effAliasRows(ast)
            case "effect_of" => effectOfRows(ast)
            case "arg_type" => argTypeRows(ast, TypeView.Head)
            case "arg_type_all" => argTypeRows(ast, TypeView.All)
            case "arg_type_deep" => argTypeRows(ast, TypeView.Deep)
            case "ret_type" => retTypeRows(ast, TypeView.Head)
            case "ret_type_all" => retTypeRows(ast, TypeView.All)
            case "ret_type_deep" => retTypeRows(ast, TypeView.Deep)
            case "case_type" => caseTypeRows(ast, TypeView.Head)
            case "case_type_all" => caseTypeRows(ast, TypeView.All)
            case "case_type_deep" => caseTypeRows(ast, TypeView.Deep)
            case _ => Map.getWithDefault(name, Nil, force bodies)
        }

    // ---- declarations ----

    def bool(b: Bool): String = if (b) "true" else "false"

    def defRows(ast: Ast): List[List[String]] =
        Flixlint.Flix.defs(ast) |> List.map(d -> {
            let fn = Flixlint.Flix.nameOf(ast, d);
            fn :: lastName(fn) :: Flixlint.Flix.moduleOf(fn) :: Flixlint.Ast.file(ast, d) :: Int32.toString(Flixlint.Flix.declLine(ast, d))
                :: bool(Flixlint.Flix.isPub(ast, d)) :: Nil
        })

    def declRows(ast: Ast, k: Kind): List[List[String]] =
        Flixlint.Ast.ofKind(ast, k) |> List.map(e -> {
            let name = Flixlint.Flix.nameOf(ast, e);
            name :: Flixlint.Flix.moduleOf(name) :: Flixlint.Ast.file(ast, e) :: Int32.toString(Flixlint.Flix.declLine(ast, e))
                :: bool(Flixlint.Flix.isPub(ast, e)) :: Nil
        })

    def aliasRows(ast: Ast): List[List[String]] =
        Flixlint.Flix.typeAliases(ast) |> List.map(a -> {
            let name = Flixlint.Flix.nameOf(ast, a);
            name :: Flixlint.Flix.moduleOf(name) :: Flixlint.Ast.file(ast, a) :: Int32.toString(Flixlint.Flix.declLine(ast, a))
                :: bool(Flixlint.Flix.isPub(ast, a)) :: Int32.toString(Flixlint.Flix.recordFields(ast, a)) :: Nil
        })

    def aliasTypeAllRows(ast: Ast): List[List[String]] =
        Flixlint.Flix.typeAliases(ast) |> List.flatMap(a -> {
            let name = Flixlint.Flix.nameOf(ast, a);
            Flixlint.Flix.aliasType(ast, a) |> Option.toList |> List.flatMap(t -> typeNames(ast, t, TypeView.All))
                |> List.distinct |> List.map(n -> name :: n :: Nil)
        })

    /// The effects every type alias stands for: the sources' and, from the external declarations, the packages' and the
    /// standard library's.
    def effAliasRows(ast: Ast): List[List[String]] =
        let own = Flixlint.Flix.typeAliases(ast) |> List.flatMap(a -> {
            let name = Flixlint.Flix.nameOf(ast, a);
            Flixlint.Flix.aliasType(ast, a) |> Option.toList |> List.flatMap(effNames(ast)) |> List.distinct |> List.map(e -> name :: e :: Nil)
        });
        let outside = Flixlint.Ast.externals(ast) |> List.filter(e -> e#kind == "alias")
            |> List.flatMap(e -> e#members |> List.map(m -> e#name :: m :: Nil));
        own ::: outside

    def effectOfRows(ast: Ast): List[List[String]] =
        Flixlint.Flix.defs(ast) |> List.flatMap(d -> {
            let fn = Flixlint.Flix.nameOf(ast, d);
            specOf(ast, d) |> Option.flatMap(s -> Flixlint.Ast.attrType(ast, s, Attr.Eff)) |> Option.toList
                |> List.flatMap(effNames(ast)) |> List.distinct |> List.map(e -> fn :: e :: Nil)
        })

    def specOf(ast: Ast, d: Node): Option[Node] = Flixlint.Ast.child(ast, d, Slot.Spec)

    def lastName(qualified: String): String = match String.indexOfRight(substr = ".", qualified) {
        case Some(i) => String.dropLeft(i + 1, qualified)
        case None    => qualified
    }

    // ---- types ----

    /// How a type is named in a row: its head (`arg_type`), every name in it with aliases closed (`_all`), and with
    /// aliases opened (`_deep`).
    pub enum TypeView with Eq {
        case Head
        case All
        case Deep
    }

    /// The rows of a type in a view: one with its head, or one per distinct name in it.
    def viewRows(ast: Ast, t: Option[TypeRef], v: TypeView): List[String] = match (v, t) {
        case (TypeView.Head, Some(t1)) => headName(ast, t1) :: Nil
        case (TypeView.Head, None)     => "?" :: Nil
        case (_, Some(t1))             => typeNames(ast, t1, v) |> List.distinct
        case (_, None)                 => Nil
    }

    def argTypeRows(ast: Ast, v: TypeView): List[List[String]] =
        Flixlint.Flix.defs(ast) |> List.flatMap(d -> {
            let fn = Flixlint.Flix.nameOf(ast, d);
            Flixlint.Flix.params(ast, d) |> List.zipWithIndex |> List.flatMap(match (i, p) ->
                viewRows(ast, Flixlint.Ast.attrType(ast, p, Attr.Tpe), v) |> List.map(n -> fn :: Int32.toString(i) :: n :: Nil))
        })

    def retTypeRows(ast: Ast, v: TypeView): List[List[String]] =
        Flixlint.Flix.defs(ast) |> List.flatMap(d -> {
            let fn = Flixlint.Flix.nameOf(ast, d);
            viewRows(ast, Flixlint.Flix.returnType(ast, d), v) |> List.map(n -> fn :: n :: Nil)
        })

    def caseTypeRows(ast: Ast, v: TypeView): List[List[String]] =
        Flixlint.Ast.ofKind(ast, Kind.Enum) |> List.flatMap(e -> {
            let enumName = Flixlint.Flix.nameOf(ast, e);
            Flixlint.Ast.childrenIn(ast, e, Slot.Cases) |> List.flatMap(c -> {
                let caseName = Flixlint.Ast.attr(ast, c, Attr.Sym) |> Option.getWithDefault("?");
                Flixlint.Ast.attrTypes(ast, c, Attr.Tpes) |> List.zipWithIndex |> List.flatMap(match (i, t) ->
                    viewRows(ast, Some(t), v) |> List.map(n -> enumName :: caseName :: Int32.toString(i) :: n :: Nil))
            })
        })

    /// A function type's name as the old facts spell it: `Arrow(2)` at the typed stage, `Arrow` at the resolved one.
    def arrowName(ast: Ast, n: Int32): String = if (Flixlint.Ast.stage(ast) == Stage.Typed) "Arrow(${n})" else "Arrow"

    /// The name a type form stands for by itself; none for structure (an application, a variable, a record row) and for
    /// the mark of an arrow written without an effect.
    def formName(ast: Ast, f: TypeForm): Option[String] = match f {
        case TypeForm.Cst(n)       => Some(n)
        case TypeForm.Alias(n)     => Some(n)
        case TypeForm.Arrow(n)     => Some(arrowName(ast, n))
        case TypeForm.Record       => Some("Record")
        case TypeForm.Schema       => Some("Schema")
        case TypeForm.Effect(n)    => Some(n)
        case TypeForm.EffUnion(n)  => Some(n)
        case TypeForm.Other(n)     => if (n == "NoEffect") None else Some(n)
        case _                     => None
    }

    /// The head of a type (`List[Int32]` gives `List`, a variable `?`).
    def headName(ast: Ast, t: TypeRef): String = match Flixlint.Ast.form(ast, t) {
        case TypeForm.Apply => Flixlint.Ast.typeArgs(ast, t) |> List.head |> Option.map(headName(ast)) |> Option.getWithDefault("?")
        case f => formName(ast, f) |> Option.getWithDefault("?")
    }

    /// Every name in a type, outermost first; `Deep` also opens what each alias stands for.
    def typeNames(ast: Ast, t: TypeRef, v: TypeView): List[String] = match Flixlint.Ast.form(ast, t) {
        case TypeForm.Alias(n) =>
            let opened = if (v == TypeView.Deep) Flixlint.Ast.expansion(ast, t) |> Option.toList else Nil;
            n :: List.flatMap(a -> typeNames(ast, a, v), Flixlint.Ast.typeArgs(ast, t) ::: opened)
        case TypeForm.Apply => Flixlint.Ast.typeArgs(ast, t) |> List.flatMap(a -> typeNames(ast, a, v))
        case f => formName(ast, f) |> Option.toList
    }

    /// The effects an effect type stands for, aliases opened (`Db = DbRead + DbWrite` gives both). Only a union (and the
    /// other set operations) is looked through, as the old facts do.
    def effNames(ast: Ast, t: TypeRef): List[String] = match Flixlint.Ast.form(ast, t) {
        case TypeForm.Alias(_)  => Flixlint.Ast.expansion(ast, t) |> Option.toList |> List.flatMap(effNames(ast))
        case TypeForm.Effect(n) => n :: Nil
        case TypeForm.Apply if isSetOp(ast, t) => Flixlint.Ast.typeArgs(ast, t) |> List.flatMap(effNames(ast))
        case _ => Nil
    }

    def isSetOp(ast: Ast, t: TypeRef): Bool = match Flixlint.Ast.form(ast, t) {
        case TypeForm.Apply       => Flixlint.Ast.typeArgs(ast, t) |> List.head |> Option.exists(isSetOp(ast))
        case TypeForm.EffUnion(_) => true
        case _ => false
    }

    // ---- bodies: the old walkBody, walkBools and walkTagArgs, on the generic AST ----

    /// The tables built from the bodies of the defs, by name.
    def bodyTables(ast: Ast): Map[String, List[List[String]]] = region rc {
        let out = MutList.empty(rc);
        Flixlint.Flix.defs(ast) |> List.forEach(d -> {
            let fn = Flixlint.Flix.nameOf(ast, d);
            match Flixlint.Ast.child(ast, d, Slot.Exp) {
                case Some(body) =>
                    walkBody(rc, ast, fn, body, out);
                    walkBools(ast, fn, body) |> List.forEach(r -> MutList.push(("bool_lit", r), out));
                    walkTagArgs(ast, fn, body) |> List.forEach(r -> MutList.push(("tag_arg", r), out))
                case None => ()
            }
        });
        MutList.toList(out) |> List.foldRight((p, acc) -> { let (t, r) = p; Map.insertWith((a, b) -> a ::: b, t, r :: Nil, acc) }, Map.empty())
    }

    /// A let-bound expression and the lambda context of its `let` (where its value is computed).
    type alias Bound = { expr = Node, outers = List[String] }

    /// The calls, handlers, constructions, branches, string literals and the shape of each call of a body, attributed to
    /// `fn` (lambdas and local defs count as their enclosing def). As the old walker: an argument that is a let-bound
    /// variable is read as the expression it stands for, and that expression is walked where the variable is first used
    /// as an argument (inside the call's lambda context), else at its `let`.
    def walkBody(rc: Region[r], ast: Ast, fn: String, body: Node, out: MutList[(String, List[String]), r]): Unit \ r =
        let consumed = MutSet.empty(rc);
        let emit = (t, row) -> MutList.push((t, row), out);
        let int = Int32.toString;
        def go(n: Node, outers: List[String], env: Map[String, Bound], inPipe: Bool): Unit \ r = {
            let walkChildren = () -> Flixlint.Ast.children(ast, n) |> List.forEach(c -> go(c, outers, env, false));
            if (Flixlint.Flix.isPipe(ast, n)) {
                if (not inPipe) {
                    let chain = stages(ast, n, env);
                    chain |> List.zipWithIndex |> List.forEach(match (i, (from0, _)) ->
                        List.drop(i + 1, chain) |> List.forEach(match (target, targetLine) -> emit("piped_into", fn :: from0 :: target :: int(targetLine) :: Nil)))
                } else ();
                match Flixlint.Flix.args(ast, n) {
                    case a :: b :: _ =>
                        go(a, outers, env, true);
                        go(b, outers, env, false)
                    case _ => ()
                }
            } else if (Flixlint.Flix.isCall(ast, n)) {
                let callee = Flixlint.Flix.callee(ast, n);
                let loc = Flixlint.Flix.callLine(ast, n);
                emit("calls", fn :: callee :: int(loc) :: Nil);
                List.distinct(outers) |> List.forEach(outer -> emit("calls_in_lambda", fn :: callee :: outer :: int(loc) :: Nil));
                Flixlint.Flix.args(ast, n) |> List.zipWithIndex |> List.forEach(match (i, e) -> {
                    let arg = resolveVar(ast, e, env);
                    strLitOf(ast, arg) |> Option.forEach(s -> emit("arg_lit", fn :: callee :: int(i) :: s :: int(loc) :: Nil));
                    denoted(ast, arg, env) |> Option.forEach(match (g, _) -> emit("arg_call", fn :: callee :: int(i) :: g :: int(loc) :: Nil));
                    let inLambda = lambdaOf(ast, arg, env);
                    match boundVar(ast, e, env) {
                        case Some((sym, b)) =>
                            if (not MutSet.memberOf(sym, consumed)) {
                                MutSet.add(sym, consumed);
                                go(b#expr, if (inLambda) callee :: b#outers else b#outers, env, false)
                            } else ()
                        case None => go(e, if (inLambda) callee :: outers else outers, env, false)
                    }
                });
                Flixlint.Ast.children(ast, n) |> List.filter(c -> Flixlint.Ast.slotOf(ast, c) != Some(Slot.Exps)) |> List.forEach(c -> go(c, outers, env, false))
            } else if (Flixlint.Ast.is(ast, Kind.Expr_Let, n)) {
                let sym = Flixlint.Flix.letBinder(ast, n) |> Option.getWithDefault("?");
                let bound = Flixlint.Ast.child(ast, n, Slot.Exp1);
                Flixlint.Ast.child(ast, n, Slot.Exp2) |> Option.forEach(b ->
                    go(b, outers, bound |> Option.map(x -> Map.insert(sym, { expr = x, outers = outers }, env)) |> Option.getWithDefault(env), false));
                if (not MutSet.memberOf(sym, consumed)) bound |> Option.forEach(x -> go(x, outers, env, false)) else ()
            } else if (Flixlint.Ast.is(ast, Kind.Expr_Cst, n) or Flixlint.Ast.is(ast, Kind.Pattern_Cst, n)) {
                strLitOf(ast, n) |> Option.forEach(s -> emit("str_lit", fn :: s :: int(Flixlint.Ast.line(ast, n)) :: Nil))
            } else if (Flixlint.Ast.is(ast, Kind.Expr_InvokeMethod, n) or Flixlint.Ast.is(ast, Kind.Expr_InvokeStaticMethod, n) or Flixlint.Ast.is(ast, Kind.Expr_InvokeConstructor, n)) {
                javaCallee(ast, n) |> Option.forEach(name -> emit("calls", fn :: name :: int(Flixlint.Ast.line(ast, n)) :: Nil));
                walkChildren()
            } else if (Flixlint.Ast.is(ast, Kind.Expr_Handler, n)) {
                emit("handles", fn :: (Flixlint.Ast.attr(ast, n, Attr.SymUse) |> Option.getWithDefault("?")) :: int(Flixlint.Ast.line(ast, n)) :: Nil);
                walkChildren()
            } else if (Flixlint.Ast.is(ast, Kind.Expr_IfThenElse, n) or Flixlint.Ast.is(ast, Kind.Expr_Match, n) or Flixlint.Ast.is(ast, Kind.Expr_ExtMatch, n)) {
                branchRows(ast, fn, n) |> List.forEach(r -> emit("branch", r));
                walkChildren()
            } else if (Flixlint.Ast.is(ast, Kind.Expr_Tag, n)) {
                emit("constructs", fn :: Flixlint.Flix.tagCase(ast, n) :: int(Flixlint.Ast.line(ast, n)) :: Nil);
                walkChildren()
            } else walkChildren()
        };
        go(body, Nil, Map.empty(), false)

    /// The variable an argument is and what it is bound to, when an enclosing `let` binds it.
    def boundVar(ast: Ast, e: Node, env: Map[String, Bound]): Option[(String, Bound)] =
        if (not Flixlint.Ast.is(ast, Kind.Expr_Var, e)) None
        else Flixlint.Ast.attr(ast, e, Attr.Sym) |> Option.flatMap(s -> Map.get(s, env) |> Option.map(b -> (s, b)))

    /// The expression a variable stands for, when it is let-bound in `env`.
    def resolveVar(ast: Ast, e: Node, env: Map[String, Bound]): Node = match boundVar(ast, e, env) {
        case Some((_, b)) => resolveVar(ast, b#expr, env)
        case None => e
    }

    def isRetype(ast: Ast, n: Node): Bool =
        Flixlint.Ast.is(ast, Kind.Expr_Ascribe, n) or Flixlint.Ast.is(ast, Kind.Expr_CheckedCast, n) or Flixlint.Ast.is(ast, Kind.Expr_UncheckedCast, n)

    def withLet(ast: Ast, l: Node, env: Map[String, Bound]): Map[String, Bound] =
        match (Flixlint.Flix.letBinder(ast, l), Flixlint.Ast.child(ast, l, Slot.Exp1)) {
            case (Some(sym), Some(x)) => Map.insert(sym, { expr = x, outers = Nil }, env)
            case _ => env
        }

    /// Whether an expression is a lambda, seen through the lets and ascriptions around it.
    def lambdaOf(ast: Ast, e: Node, env: Map[String, Bound]): Bool =
        let r = resolveVar(ast, e, env);
        if (Flixlint.Ast.is(ast, Kind.Expr_Lambda, r)) true
        else if (Flixlint.Ast.is(ast, Kind.Expr_Let, r)) Flixlint.Ast.child(ast, r, Slot.Exp2) |> Option.exists(b -> lambdaOf(ast, b, withLet(ast, r, env)))
        else if (isRetype(ast, r)) Flixlint.Ast.child(ast, r, Slot.Exp) |> Option.exists(b -> lambdaOf(ast, b, env))
        else false

    /// The function an expression stands for when it is a call (the call itself, or the lambda or let around one), with
    /// the call's line.
    def denoted(ast: Ast, e: Node, env: Map[String, Bound]): Option[(String, Int32)] =
        let r = resolveVar(ast, e, env);
        if (Flixlint.Flix.isCall(ast, r) and not Flixlint.Flix.isPipe(ast, r)) Some((Flixlint.Flix.callee(ast, r), Flixlint.Ast.line(ast, r)))
        else if (Flixlint.Ast.is(ast, Kind.Expr_Let, r)) Flixlint.Ast.child(ast, r, Slot.Exp2) |> Option.flatMap(b -> denoted(ast, b, withLet(ast, r, env)))
        else if (Flixlint.Ast.is(ast, Kind.Expr_Lambda, r) or isRetype(ast, r)) Flixlint.Ast.child(ast, r, Slot.Exp) |> Option.flatMap(b -> denoted(ast, b, env))
        else None

    /// The stages of a `|>` chain in order: the call that makes the leftmost value, then each function piped into.
    def stages(ast: Ast, e: Node, env: Map[String, Bound]): List[(String, Int32)] =
        let r = resolveVar(ast, e, env);
        if (Flixlint.Flix.isPipe(ast, r)) match Flixlint.Flix.args(ast, r) {
            case a :: b :: _ => stages(ast, a, env) ::: (denoted(ast, b, env) |> Option.toList)
            case _ => Nil
        } else denoted(ast, r, env) |> Option.toList

    def strLitOf(ast: Ast, n: Node): Option[String] =
        if (Flixlint.Ast.attr(ast, n, Attr.Cst) == Some("Str")) Flixlint.Ast.attr(ast, n, Attr.Cst_lit) else None

    /// The callee of a Java call as the old facts spell it (`java.lang.String.length`, `<init>` for a constructor). The
    /// resolved stage knows the class of a static call and of a constructor only.
    def javaCallee(ast: Ast, n: Node): Option[String] =
        let typed = (Flixlint.Ast.child(ast, n, Slot.Method) |> Option.withDefault(default = Flixlint.Ast.child(ast, n, Slot.Constructor)))
            |> Option.flatMap(m -> Flixlint.Ast.child(ast, m, Slot.Ref))
            |> Option.flatMap(r -> match (Flixlint.Ast.attr(ast, r, Attr.Owner), Flixlint.Ast.attr(ast, r, Attr.Name)) {
                case (Some(o), Some(m)) => Some("${o}.${m}")
                case _ => None
            });
        typed |> Option.withDefault(default = Flixlint.Ast.attr(ast, n, Attr.Clazz) |> Option.map(c ->
            "${c}.${Flixlint.Ast.attr(ast, n, Attr.MethodName) |> Option.getWithDefault("<init>")}"))

    /// The branch rows of an `if`, a `match` or an `extmatch` and of the guards of a `match`'s rules (a `let (a, b) = e`
    /// and a `forM` generator are not branches: the compiler makes each a match of one rule).
    def branchRows(ast: Ast, fn: String, m: Node): List[List[String]] =
        let isMatch = Flixlint.Ast.is(ast, Kind.Expr_Match, m);
        let rules = if (isMatch) Flixlint.Ast.childrenIn(ast, m, Slot.Rules) else Nil;
        let pm = Flixlint.Ast.pos(ast, m);
        let destructuring = match rules {
            case r :: Nil =>
                let pr = Flixlint.Ast.pos(ast, r);
                not pm#synthetic and pr#line == pm#line and pr#col == pm#col and pr#endLine == pm#endLine and pr#endCol == pm#endCol
                    and Option.isEmpty(Flixlint.Ast.child(ast, r, Slot.Guard))
            case _ => false
        };
        let generator = match rules {
            case r :: Nil => pm#synthetic and (Flixlint.Ast.child(ast, r, Slot.Pat)
                |> Option.exists(p -> Flixlint.Ast.is(ast, Kind.Pattern_Var, p) or Flixlint.Ast.is(ast, Kind.Pattern_Wild, p)))
            case _ => false
        };
        let kind = if (Flixlint.Ast.is(ast, Kind.Expr_IfThenElse, m)) "if" else if (isMatch) "match" else "extmatch";
        let own = if (destructuring or generator) Nil else (fn :: kind :: Int32.toString(Flixlint.Ast.line(ast, m)) :: Nil) :: Nil;
        own ::: (rules |> List.filterMap(r -> Flixlint.Ast.child(ast, r, Slot.Guard))
            |> List.map(g -> fn :: "guard" :: Int32.toString(Flixlint.Ast.line(ast, g)) :: Nil))

    /// Every `true` / `false` literal of a body with where it is written: the nearest parents, closest first, up to three
    /// (`field:expected < arg:Assert.assertEq:0`), and the line its nearest parent starts on. `not` and ascriptions are
    /// seen through; a literal in a pattern is not one.
    def walkBools(ast: Ast, fn: String, body: Node): List[List[String]] =
        let transparent = n -> Flixlint.Ast.is(ast, Kind.Expr_Unary, n) or isRetype(ast, n);
        def go(n: Node, ctx: List[(String, Int32)]): List[List[String]] =
            if (Flixlint.Ast.is(ast, Kind.Expr_Cst, n) and Flixlint.Ast.attr(ast, n, Attr.Cst) == Some("Bool")) {
                let line = Flixlint.Ast.line(ast, n);
                (fn :: (Flixlint.Ast.attr(ast, n, Attr.Cst_lit) |> Option.getWithDefault("?")) :: (ctx |> List.take(3) |> List.map(fst) |> String.intercalate(" < "))
                    :: Int32.toString(line) :: Int32.toString(ctx |> List.head |> Option.map(snd) |> Option.getWithDefault(line)) :: Nil) :: Nil
            } else
                Flixlint.Ast.children(ast, n) |> List.flatMap(c ->
                    go(c, if (transparent(n)) ctx else (parentOf(ast, n, c), Flixlint.Ast.line(ast, n)) :: ctx));
        go(body, Nil)

    /// How the old facts name a parent of a node: `arg:<callee>:<index>`, `field:<label>`, `tag:<case>`, `tuple`,
    /// `vector`, `array`, `let`, `op:<operator>`, else the node's name.
    def parentOf(ast: Ast, p: Node, below: Node): String =
        let kindName = Flixlint.AstKinds.kindName(Flixlint.Ast.kind(ast, p));
        let short = lastName(kindName);
        let slot = Flixlint.Ast.slotOf(ast, below);
        if (Flixlint.Flix.isCall(ast, p) and slot == Some(Slot.Exps)) "arg:${Flixlint.Flix.callee(ast, p)}:${Flixlint.Ast.indexOf(ast, below)}"
        else if (Flixlint.Ast.is(ast, Kind.Expr_RecordExtend, p) and slot == Some(Slot.Exp1)) "field:${Flixlint.Ast.attr(ast, p, Attr.Label) |> Option.getWithDefault("?")}"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Tag, p)) "tag:${Flixlint.Flix.tagCase(ast, p)}"
        else if (short == "Tuple") "tuple"
        else if (short == "VectorLit") "vector"
        else if (short == "ArrayLit") "array"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Let, p) and slot == Some(Slot.Exp1)) "let"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Binary, p)) "op:${Flixlint.Ast.attr(ast, p, Attr.Sop) |> Option.getWithDefault("?")}"
        else short

    /// Every argument of a case built in a body: its shape and the head of its type (typed stage; `?` at the resolved one).
    def walkTagArgs(ast: Ast, fn: String, body: Node): List[List[String]] =
        (body :: Flixlint.Ast.descendants(ast, body)) |> List.filter(Flixlint.Ast.is(ast, Kind.Expr_Tag)) |> List.flatMap(t -> {
            let kase = Flixlint.Flix.tagCase(ast, t);
            let line = Int32.toString(Flixlint.Ast.line(ast, t));
            Flixlint.Flix.args(ast, t) |> List.zipWithIndex |> List.map(match (i, e) ->
                fn :: kase :: Int32.toString(i) :: Flixlint.Flix.shapeOf(ast, e)
                    :: (Flixlint.Ast.typeOf(ast, e) |> Option.map(headName(ast)) |> Option.getWithDefault("?")) :: line :: Nil)
        })

    // ---- writing ----

    /// The tables as the old facts' TSV files (`<dir>/<name>.tsv`, one row per line, columns by tabs).
    pub def dump(dir: String, ast: Ast): Unit \ IO =
        discard (new File(dir)).mkdirs();
        tables(ast) |> List.forEach(t -> {
            let text = t#rows |> List.map(r -> String.intercalate("\t", List.map(clean, r)) + "\n") |> String.intercalate("");
            discard Files.write((new File("${dir}/${t#name}.tsv")).toPath(), text.getBytes())
        })

    /// A column as the old facts write it (a tab or a line break becomes a space).
    pub def clean(s: String): String =
        if (String.exists(isBreak, s)) String.map(c -> if (isBreak(c)) ' ' else c, s) else s

    def isBreak(c: Char): Bool = c == '\t' or c == '\n' or c == '\r'
}
