///
/// Layer 2 of the generic AST (docs/design-generic.md 2.1): the Flix words. It is the only place that names the
/// compiler's nodes (`Kind.Expr_ApplyDef`) and knows where the stages differ (a `let` binds `bnd.sym` at the typed stage
/// and `sym` at the resolved one; a return type is `retTpe` and `tpe`), so a rule written with these functions reads the
/// same at both stages, and a Flix upgrade that renames a node is fixed here.
///
pub mod Flixlint.Flix {
    use Flixlint.Ast.{Ast, Node, TypeRef, TypeForm}
    use Flixlint.AstKinds.{Kind, Slot, Attr}
    use Flixlint.Violation.Violation

    // ---- declarations ----

    /// Every def of the sources (instance defs too), in file and line order.
    pub def defs(ast: Ast): List[Node] = Flixlint.Ast.ofKind(ast, Kind.Def)

    /// Every type alias the sources declare.
    pub def typeAliases(ast: Ast): List[Node] = Flixlint.Ast.ofKind(ast, Kind.TypeAlias)

    /// The qualified name of a declaration (`Auth.permit`).
    pub def nameOf(ast: Ast, decl: Node): String = Flixlint.Ast.attr(ast, decl, Attr.Sym) |> Option.getWithDefault("?")

    /// The line a declaration's name is on (a doc comment above it does not move it).
    pub def declLine(ast: Ast, decl: Node): Int32 = Flixlint.Ast.attrLine(ast, decl, Attr.Sym)

    /// The module part of a qualified name (`Auth` of `Auth.permit`; the root module is "").
    pub def moduleOf(qualified: String): String = match String.indexOfRight(substr = ".", qualified) {
        case Some(i) => String.takeLeft(i, qualified)
        case None    => ""
    }

    /// Whether a declaration is `pub` (a def's modifiers are on its signature).
    pub def isPub(ast: Ast, decl: Node): Bool =
        let mods = Flixlint.Ast.child(ast, decl, Slot.Spec) |> Option.flatMap(s -> Flixlint.Ast.child(ast, s, Slot.Mod))
            |> Option.withDefault(default = Flixlint.Ast.child(ast, decl, Slot.Mod));
        mods |> Option.exists(m -> Flixlint.Ast.attrs(ast, m, Attr.Mod) |> List.memberOf("Public"))

    /// The def `n` is in, by name; none for a node of an enum, an alias, an effect.
    pub def defOf(ast: Ast, n: Node): Option[String] =
        let r = Flixlint.Ast.root(ast, n);
        if (Flixlint.Ast.is(ast, Kind.Def, r)) Some(nameOf(ast, r)) else None

    /// The parameters of a def, in order.
    pub def params(ast: Ast, def0: Node): List[Node] =
        Flixlint.Ast.child(ast, def0, Slot.Spec) |> Option.toList |> List.flatMap(s -> Flixlint.Ast.childrenIn(ast, s, Slot.Fparams))

    /// The declared type of each parameter of a def, in order (a parameter of the resolved stage written without a type has none).
    pub def paramTypes(ast: Ast, def0: Node): List[TypeRef] = params(ast, def0) |> List.filterMap(p -> Flixlint.Ast.attrType(ast, p, Attr.Tpe))

    /// The declared return type of a def.
    pub def returnType(ast: Ast, def0: Node): Option[TypeRef] =
        Flixlint.Ast.child(ast, def0, Slot.Spec)
            |> Option.flatMap(s -> Flixlint.Ast.attrType(ast, s, Attr.RetTpe) |> Option.withDefault(default = Flixlint.Ast.attrType(ast, s, Attr.Tpe)))

    /// The effects a def declares, aliases opened (`Db = DbRead + DbWrite` gives both).
    pub def effects(ast: Ast, def0: Node): Set[String] =
        Flixlint.Ast.child(ast, def0, Slot.Spec) |> Option.flatMap(s -> Flixlint.Ast.attrType(ast, s, Attr.Eff))
            |> Option.toList |> List.flatMap(effectNames(ast)) |> List.toSet

    /// The effects in an effect type, aliases opened.
    pub def effectNames(ast: Ast, t: TypeRef): List[String] = match Flixlint.Ast.form(ast, t) {
        case TypeForm.Effect(n) => n :: Nil
        case TypeForm.Alias(_)  => Flixlint.Ast.expansion(ast, t) |> Option.toList |> List.flatMap(effectNames(ast))
        case TypeForm.Apply     => Flixlint.Ast.typeArgs(ast, t) |> List.flatMap(effectNames(ast))
        case _ => Nil
    }

    /// The type a type alias stands for.
    pub def aliasType(ast: Ast, alias0: Node): Option[TypeRef] = Flixlint.Ast.attrType(ast, alias0, Attr.Tpe)

    /// The number of record fields a type alias stands for (`{ a = Int32, b = Bool }` gives 2), or -1 when it is not a record.
    pub def recordFields(ast: Ast, alias0: Node): Int32 =
        match aliasType(ast, alias0) |> Option.map(t -> applied(ast, t)) {
            case Some((h, row :: Nil)) if Flixlint.Ast.form(ast, h) == TypeForm.Record => rowLength(ast, row)
            case _ => -1
        }

    /// An application taken apart: its head and its arguments in order.
    pub def applied(ast: Ast, t: TypeRef): (TypeRef, List[TypeRef]) = appliedAcc(ast, t, Nil)

    def appliedAcc(ast: Ast, t: TypeRef, args: List[TypeRef]): (TypeRef, List[TypeRef]) =
        match (Flixlint.Ast.form(ast, t), Flixlint.Ast.typeArgs(ast, t)) {
            case (TypeForm.Apply, f :: a :: Nil) => appliedAcc(ast, f, a :: args)
            case _ => (t, args)
        }

    /// The labels along a record row.
    def rowLength(ast: Ast, row: TypeRef): Int32 = match applied(ast, row) {
        case (h, _ :: rest :: Nil) => match Flixlint.Ast.form(ast, h) {
            case TypeForm.RecordRow(_) => 1 + rowLength(ast, rest)
            case _ => 0
        }
        case _ => 0
    }

    // ---- expressions ----

    /// Whether `n` calls a def, a trait signature or an effect operation.
    pub def isCall(ast: Ast, n: Node): Bool =
        Flixlint.Ast.is(ast, Kind.Expr_ApplyDef, n) or Flixlint.Ast.is(ast, Kind.Expr_ApplySig, n) or Flixlint.Ast.is(ast, Kind.Expr_ApplyOp, n)

    /// Every call of a def, a trait signature or an effect operation, in id order.
    pub def calls(ast: Ast): List[Node] = Flixlint.Ast.ofKinds(ast, List#{Kind.Expr_ApplyDef, Kind.Expr_ApplySig, Kind.Expr_ApplyOp})

    /// The qualified name a call calls.
    pub def callee(ast: Ast, call: Node): String = Flixlint.Ast.attr(ast, call, Attr.SymUse) |> Option.getWithDefault("?")

    /// The line of the callee's name (a call's own location starts at a comment written above it).
    pub def callLine(ast: Ast, call: Node): Int32 = Flixlint.Ast.attrLine(ast, call, Attr.SymUse)

    /// The arguments of a call or a tag, in order.
    pub def args(ast: Ast, n: Node): List[Node] = Flixlint.Ast.childrenIn(ast, n, Slot.Exps)

    /// Every use of an enum case as a value (`Some(x)`), in id order.
    pub def tags(ast: Ast): List[Node] = Flixlint.Ast.ofKind(ast, Kind.Expr_Tag)

    /// The case a tag builds (`Option.Some`).
    pub def tagCase(ast: Ast, tag: Node): String = Flixlint.Ast.attr(ast, tag, Attr.SymUse) |> Option.getWithDefault("?")

    pub def isBool(ast: Ast, n: Node): Bool = Flixlint.Ast.is(ast, Kind.Expr_Cst, n) and Flixlint.Ast.attr(ast, n, Attr.Cst) == Some("Bool")

    pub def strLit(ast: Ast, n: Node): Option[String] =
        if (Flixlint.Ast.is(ast, Kind.Expr_Cst, n) and Flixlint.Ast.attr(ast, n, Attr.Cst) == Some("Str")) Flixlint.Ast.attr(ast, n, Attr.Cst_lit) else None

    /// The head of the type of an expression (`Bool`, `List`); the typed stage only.
    pub def typeHead(ast: Ast, n: Node): Option[String] = Flixlint.Ast.typeOf(ast, n) |> Option.flatMap(Flixlint.Ast.head(ast))

    /// A node that only re-types its child (`e: T`, casts).
    pub def isAscription(ast: Ast, n: Node): Bool =
        Flixlint.Ast.is(ast, Kind.Expr_Ascribe, n) or Flixlint.Ast.is(ast, Kind.Expr_CheckedCast, n) or Flixlint.Ast.is(ast, Kind.Expr_UncheckedCast, n)

    /// `n` seen through ascriptions.
    pub def seeThrough(ast: Ast, n: Node): Node =
        if (isAscription(ast, n)) Flixlint.Ast.child(ast, n, Slot.Exp) |> Option.map(seeThrough(ast)) |> Option.getWithDefault(n) else n

    /// The variable a `let` binds.
    pub def letBinder(ast: Ast, let0: Node): Option[String] =
        Flixlint.Ast.child(ast, let0, Slot.Bnd) |> Option.flatMap(b -> Flixlint.Ast.attr(ast, b, Attr.Sym))
            |> Option.withDefault(default = Flixlint.Ast.attr(ast, let0, Attr.Sym))

    /// The expression a variable is bound to by an enclosing `let` (the desugarer binds partial applications and
    /// functions passed by name this way).
    pub def boundTo(ast: Ast, v: Node): Option[Node] =
        if (not Flixlint.Ast.is(ast, Kind.Expr_Var, v)) None
        else Flixlint.Ast.attr(ast, v, Attr.Sym) |> Option.flatMap(sym ->
            Flixlint.Ast.ancestors(ast, v) |> List.find(a -> Flixlint.Ast.is(ast, Kind.Expr_Let, a) and letBinder(ast, a) == Some(sym))
                |> Option.flatMap(l -> Flixlint.Ast.child(ast, l, Slot.Exp1)))

    /// `n` seen through ascriptions and let-bound variables.
    pub def resolve(ast: Ast, n: Node): Node =
        let m = seeThrough(ast, n);
        match boundTo(ast, m) {
            case Some(b) => resolve(ast, b)
            case None    => m
        }

    /// The uses of the variable a `let` binds, in its body.
    pub def usesOf(ast: Ast, let0: Node): List[Node] = match (letBinder(ast, let0), Flixlint.Ast.child(ast, let0, Slot.Exp2)) {
        case (Some(sym), Some(body)) =>
            (body :: Flixlint.Ast.descendants(ast, body)) |> List.filter(d -> Flixlint.Ast.is(ast, Kind.Expr_Var, d) and Flixlint.Ast.attr(ast, d, Attr.Sym) == Some(sym))
        case _ => Nil
    }

    /// The calls a lambda is passed to (directly, or as a let-bound variable), as `(callee, call)`.
    pub def lambdaPassedTo(ast: Ast, lam: Node): List[(String, Node)] =
        let direct = passedAt(ast, lam);
        let viaLet = Flixlint.Ast.parent(ast, lam) |> Option.toList
            |> List.filter(p -> Flixlint.Ast.is(ast, Kind.Expr_Let, p) and Flixlint.Ast.slotOf(ast, lam) == Some(Slot.Exp1))
            |> List.flatMap(l -> usesOf(ast, l)) |> List.flatMap(u -> passedAt(ast, u));
        direct ::: viaLet

    /// The call `n` is an argument of, when it is one (through ascriptions).
    def passedAt(ast: Ast, n: Node): List[(String, Node)] = match Flixlint.Ast.parent(ast, n) {
        case Some(p) if isAscription(ast, p) => passedAt(ast, p)
        case Some(p) if isCall(ast, p) and Flixlint.Ast.slotOf(ast, n) == Some(Slot.Exps) => (callee(ast, p), p) :: Nil
        case _ => Nil
    }

    /// The function an expression stands for when it is a call, or a lambda / let around one.
    pub def denoted(ast: Ast, e: Node): Option[String] =
        let r = resolve(ast, e);
        if (isCall(ast, r) and not isPipe(ast, r)) Some(callee(ast, r))
        else if (Flixlint.Ast.is(ast, Kind.Expr_Let, r)) Flixlint.Ast.child(ast, r, Slot.Exp2) |> Option.flatMap(denoted(ast))
        else if (Flixlint.Ast.is(ast, Kind.Expr_Lambda, r)) Flixlint.Ast.child(ast, r, Slot.Exp) |> Option.flatMap(denoted(ast))
        else None

    /// Whether `n` is `a |> f`.
    pub def isPipe(ast: Ast, n: Node): Bool =
        Flixlint.Ast.is(ast, Kind.Expr_ApplyDef, n) and callee(ast, n) == "|>" and List.length(args(ast, n)) == 2

    /// The stages of a `|>` chain in order, as (function, the call node it stands for).
    pub def pipeStages(ast: Ast, e: Node): List[(String, Node)] =
        let r = resolve(ast, e);
        if (isPipe(ast, r)) match args(ast, r) {
            case a :: b :: _ => pipeStages(ast, a) ::: (denoted(ast, b) |> Option.toList |> List.map(f -> (f, resolve(ast, b))))
            case _ => Nil
        } else denoted(ast, r) |> Option.toList |> List.map(f -> (f, r))

    /// The nearest parents of `n` described (`arg:<callee>:<index>`, `field:<label>`, `tag:<case>`, `tuple`, `vector`,
    /// `array`, `let`, `op:<operator>`, else the node's kind without its group), with the line each starts on; `not`
    /// and ascriptions are seen through.
    pub def placement(ast: Ast, n: Node): List[(String, Int32)] =
        Flixlint.Ast.ancestors(ast, n) |> List.zip(n :: Flixlint.Ast.ancestors(ast, n))
            |> List.filter(match (_, p) -> not (Flixlint.Ast.is(ast, Kind.Expr_Unary, p) or isAscription(ast, p)))
            |> List.map(match (below, p) -> (describe(ast, p, below), Flixlint.Ast.line(ast, p)))

    def describe(ast: Ast, p: Node, below: Node): String =
        let kindName = Flixlint.AstKinds.kindName(Flixlint.Ast.kind(ast, p));
        let short = match String.indexOfRight(substr = ".", kindName) {
            case Some(i) => String.dropLeft(i + 1, kindName)
            case None    => kindName
        };
        let slot = Flixlint.Ast.slotOf(ast, below);
        if (isCall(ast, p) and slot == Some(Slot.Exps)) "arg:${callee(ast, p)}:${Flixlint.Ast.indexOf(ast, below)}"
        else if (Flixlint.Ast.is(ast, Kind.Expr_RecordExtend, p) and slot == Some(Slot.Exp1)) "field:${Flixlint.Ast.attr(ast, p, Attr.Label) |> Option.getWithDefault("?")}"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Tag, p)) "tag:${tagCase(ast, p)}"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Tuple, p)) "tuple"
        else if (Flixlint.Ast.is(ast, Kind.Expr_VectorLit, p)) "vector"
        else if (Flixlint.Ast.is(ast, Kind.Expr_ArrayLit, p)) "array"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Let, p) and slot == Some(Slot.Exp1)) "let"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Binary, p)) "op:${Flixlint.Ast.attr(ast, p, Attr.Sop) |> Option.getWithDefault("?")}"
        else short

    /// The shape of an expression: `bool`, `unary:<op>`, `op:<op>`, `call:<callee>`, `var`, else its kind without `Expr.`.
    pub def shapeOf(ast: Ast, e: Node): String =
        let s = seeThrough(ast, e);
        let op = Flixlint.Ast.attr(ast, s, Attr.Sop) |> Option.getWithDefault("?");
        if (isBool(ast, s)) "bool"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Unary, s)) "unary:${op}"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Binary, s)) "op:${op}"
        else if (isCall(ast, s)) "call:${callee(ast, s)}"
        else if (Flixlint.Ast.is(ast, Kind.Expr_Var, s)) "var"
        else String.stripPrefix(substr = "Expr.", Flixlint.AstKinds.kindName(Flixlint.Ast.kind(ast, s))) |> Option.getWithDefault(Flixlint.AstKinds.kindName(Flixlint.Ast.kind(ast, s)))

    /// The branches of the sources (`if`, `match` and a `match` lambda, `extmatch`, and each guard of a rule) as
    /// (kind, the node at the line to report). A `let (a, b) = e` and a `forM` generator are not branches: the compiler
    /// makes each a match of one rule.
    pub def branches(ast: Ast): List[(String, Node)] =
        let sameSpan = (a, b) -> {
            let pa = Flixlint.Ast.pos(ast, a);
            let pb = Flixlint.Ast.pos(ast, b);
            pa#line == pb#line and pa#col == pb#col and pa#endLine == pb#endLine and pa#endCol == pb#endCol
        };
        let own = Flixlint.Ast.ofKinds(ast, List#{Kind.Expr_IfThenElse, Kind.Expr_Match, Kind.Expr_ExtMatch}) |> List.filterMap(m -> {
            let isMatch = Flixlint.Ast.is(ast, Kind.Expr_Match, m);
            let synthetic = Flixlint.Ast.pos(ast, m)#synthetic;
            let rules = if (isMatch) Flixlint.Ast.childrenIn(ast, m, Slot.Rules) else Nil;
            let destructuring = match rules {
                case r :: Nil => not synthetic and sameSpan(r, m) and Option.isEmpty(Flixlint.Ast.child(ast, r, Slot.Guard))
                case _ => false
            };
            let generator = match rules {
                case r :: Nil => synthetic and (Flixlint.Ast.child(ast, r, Slot.Pat)
                    |> Option.exists(p -> Flixlint.Ast.is(ast, Kind.Pattern_Var, p) or Flixlint.Ast.is(ast, Kind.Pattern_Wild, p)))
                case _ => false
            };
            let kind = if (Flixlint.Ast.is(ast, Kind.Expr_IfThenElse, m)) "if" else if (isMatch) "match" else "extmatch";
            if (destructuring or generator) None else Some((kind, m))
        });
        let guards = Flixlint.Ast.ofKind(ast, Kind.MatchRule) |> List.filterMap(r -> Flixlint.Ast.child(ast, r, Slot.Guard) |> Option.map(g -> ("guard", g)));
        own ::: guards

    // ---- use and import ----

    /// A `use` or a Java `import` of the sources: the name it brings in (`Auth.Permit`, `java.lang.System`), the name it
    /// is known by in the module, and the module it is written in.
    pub type alias Use = { node = Node, name = String, localName = String, module = String, file = String, line = Int32, isImport = Bool }

    /// Every `use` and `import` of the sources, in file and line order.
    pub def uses(ast: Ast): List[Use] =
        Flixlint.Ast.ofKinds(ast, List#{Kind.UseOrImport_Use, Kind.UseOrImport_Import}) |> List.map(u -> {
            let isImport = Flixlint.Ast.is(ast, Kind.UseOrImport_Import, u);
            { node = u, name = Flixlint.Ast.attr(ast, u, if (isImport) Attr.Clazz else Attr.Sym) |> Option.getWithDefault("?"),
              localName = Flixlint.Ast.attr(ast, u, Attr.Alias) |> Option.getWithDefault(""),
              module = Flixlint.Ast.attr(ast, u, Attr.Mod) |> Option.getWithDefault(""),
              file = Flixlint.Ast.file(ast, u), line = Flixlint.Ast.line(ast, u), isImport = isImport }
        })

    /// The names the declarations of each module write, by (file, module): the functions they call, the cases they build
    /// and match, the Java classes they name, and the names in the types they write (parameters, results, effects, cases,
    /// aliases, ascriptions and casts, constraints). A `use` of a name is used when one of these is the name or a name inside
    /// it (`Auth.Permit` for `Auth.Permit.Permit`).
    /// WhyNot: the types the typed stage infers for expressions are not read. A name that only an inferred type mentions is
    /// not written, so a `use` of it is still unused; reading them made the typed stage count fewer unused uses than the
    /// resolved one.
    pub def namesUsed(ast: Ast): Map[(String, String), Set[String]] =
        let named = Set#{Attr.Sym, Attr.SymUse, Attr.Clazz, Attr.Owner};
        // the fields a type is written in (both names where the stages name them differently); a parameter of the typed
        // stage gets a type inferred when none is written, which its `src` tells
        let written = Set#{(Kind.Case, Attr.Tpes), (Kind.TypeAlias, Attr.Tpe), (Kind.Spec, Attr.RetTpe), (Kind.Spec, Attr.Tpe),
            (Kind.Spec, Attr.Eff), (Kind.FormalParam, Attr.Tpe), (Kind.TraitConstraint, Attr.Arg), (Kind.TraitConstraint, Attr.Tpe),
            (Kind.EqualityConstraint, Attr.Tpe1), (Kind.EqualityConstraint, Attr.Tpe2), (Kind.Expr_Ascribe, Attr.ExpectedType),
            (Kind.Expr_Ascribe, Attr.ExpectedEff), (Kind.Expr_UncheckedCast, Attr.DeclaredType), (Kind.Expr_UncheckedCast, Attr.DeclaredEff),
            (Kind.Expr_Unsafe, Attr.AsEff), (Kind.Expr_Unsafe, Attr.Eff)};
        let isUse = r -> Flixlint.Ast.is(ast, Kind.UseOrImport_Use, r) or Flixlint.Ast.is(ast, Kind.UseOrImport_Import, r);
        Flixlint.Ast.nodes(ast) |> List.filter(n -> not isUse(Flixlint.Ast.root(ast, n))) |> List.foldLeft((acc, n) -> {
            let kind = Flixlint.Ast.kind(ast, n);
            let leaves = Flixlint.Ast.leaves(ast, n);
            let inferred = Flixlint.Ast.attr(ast, n, Attr.Src) == Some("Inferred");
            let fromValues = leaves |> List.filter(l -> Set.memberOf(l#attr, named)) |> List.filterMap(l -> l#value)
                |> List.filter(v -> not String.contains(substr = "#", v));
            let fromTypes = if (inferred) Nil else leaves |> List.filter(l -> Set.memberOf((kind, l#attr), written))
                |> List.filterMap(l -> l#tpe) |> List.flatMap(t -> Flixlint.Ast.typeNames(ast, t, Flixlint.Ast.AliasMode.Closed));
            let names = fromValues ::: fromTypes;
            if (List.isEmpty(names)) acc
            else Map.insertWith(Set.union, (Flixlint.Ast.file(ast, n), moduleOf(nameOf(ast, Flixlint.Ast.root(ast, n)))), List.toSet(names), acc)
        }, Map.empty())

    /// Whether a `use` brings in a name its module never uses.
    pub def isUnused(used: Map[(String, String), Set[String]], u: Use): Bool =
        let names = Map.getWithDefault((u#file, u#module), Set.empty(), used);
        not Set.exists(n -> n == u#name or String.startsWith(prefix = "${u#name}.", n), names)

    // ---- the targets a rule names (docs/design-generic.md 2.2: a rule names what it is about with a Names value, so a
    // name the sources no longer have fails to compile instead of quietly matching nothing) ----

    /// The calls of `fn`, in id order.
    pub def callsTo(ast: Ast, fn: Flixlint.Names.Fn): List[Node] =
        Flixlint.Ast.withLeaf(ast, Attr.SymUse, Flixlint.Names.fnName(fn)) |> List.filter(isCall(ast))

    /// Whether a call calls one of `fns`.
    pub def callsOneOf(ast: Ast, fns: Set[Flixlint.Names.Fn], call: Node): Bool =
        Set.memberOf(callee(ast, call), Set.map(Flixlint.Names.fnName, fns))

    /// The tags that build `c` (`Option.Some`), in id order.
    pub def tagsOf(ast: Ast, c: Flixlint.Names.Case): List[Node] =
        Flixlint.Ast.withLeaf(ast, Attr.SymUse, Flixlint.Names.caseName(c)) |> List.filter(Flixlint.Ast.is(ast, Kind.Expr_Tag))

    /// Whether a tag builds one of `cs`.
    pub def buildsOneOf(ast: Ast, cs: Set[Flixlint.Names.Case], tag: Node): Bool =
        Set.memberOf(tagCase(ast, tag), Set.map(Flixlint.Names.caseName, cs))

    /// Whether a declaration is in the module `m` itself (not a module inside it).
    pub def isIn(ast: Ast, m: Flixlint.Names.Mod, decl: Node): Bool = moduleOf(nameOf(ast, decl)) == Flixlint.Names.modName(m)

    /// Whether the head of `t` is the type `ty` (an alias is its own head; `expand` it first to see what it stands for).
    pub def headIs(ast: Ast, ty: Flixlint.Names.Type, t: TypeRef): Bool = Flixlint.Ast.head(ast, t) == Some(Flixlint.Names.typeName(ty))

    /// Whether the type `ty` appears anywhere in `t` (aliases closed).
    pub def mentions(ast: Ast, ty: Flixlint.Names.Type, t: TypeRef): Bool =
        Flixlint.Ast.typeNames(ast, t, Flixlint.Ast.AliasMode.Closed) |> List.memberOf(Flixlint.Names.typeName(ty))

    /// Whether a def declares the effect `e` (aliases opened).
    pub def hasEffect(ast: Ast, e: Flixlint.Names.Eff, def0: Node): Bool = Set.memberOf(Flixlint.Names.effName(e), effects(ast, def0))

    // ---- violations ----

    /// A violation at `line` in the declaration `n` is in: its file, its name as the subject, and the def an `allowIn`
    /// names (none for an enum, an alias, an effect).
    pub def violation(ast: Ast, id: String, n: Node, line: Int32, message: String, reason: String): Violation =
        let r = Flixlint.Ast.root(ast, n);
        // a `use` has no name of its own; it is told by the module it is written in
        let isUse = Flixlint.Ast.is(ast, Kind.UseOrImport_Use, r) or Flixlint.Ast.is(ast, Kind.UseOrImport_Import, r);
        let name = if (isUse) Flixlint.Ast.attr(ast, r, Attr.Mod) |> Option.getWithDefault("?") else nameOf(ast, r);
        { file = Flixlint.Ast.file(ast, n), line = line, id = id, subject = name, message = message, reason = reason, path = Nil, notes = Nil,
          inFn = if (Flixlint.Ast.is(ast, Kind.Def, r)) Some(Flixlint.Names.fnOf(name)) else None }
}
