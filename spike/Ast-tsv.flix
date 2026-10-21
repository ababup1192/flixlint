///
/// (spike) The AST as generic relations (`node` / `node_attr` / `node_type`, written by the shim with `--generic`) and
/// the small queries rules are built from: walk to the parent / ancestors / children, read a leaf attribute, the head of
/// a type, and the few shapes every rule needs (a call and its callee, a def and its parameters, a type and the names in
/// it). The shape helpers are the only place that knows the compiler's node names, so a Flix upgrade that renames a node
/// is fixed here, in the library, not in the shim and not in every rule.
///
pub mod Flixlint.Ast {
    use Fs.FileRead.FileRead

    pub enum Ast(AstData)

    /// One node: `kind` is the compiler's class without the stage (`Expr.ApplyDef`); `slot` / `index` the field of the
    /// parent it sits in; `root` the declaration it is in. A node without a location has its parent's.
    pub type alias Node = { id = Int32, kind = String, parent = Int32, slot = String, index = Int32, root = Int32,
                            line = Int32, col = Int32, endLine = Int32, endCol = Int32, synthetic = Bool }

    type alias AstData = {
        nodes = Vector[Node],
        children = Vector[List[Int32]],
        attrs = Vector[List[(String, String)]],
        types = Vector[List[(String, String)]],
        byKind = Map[String, List[Int32]],
        files = Map[Int32, String],
        aliases = Map[String, Int32]
    }

    def data(ast: Ast): AstData = match ast { case Ast.Ast(d) => d }

    // ---- loading ----

    /// The AST of `dir` (empty when the shim was not asked for it).
    pub def load(dir: String): Ast \ FileRead =
        let nodeRows = rows(dir, "node");
        let nodes = nodeRows |> List.map(c -> { id = int(0, c), kind = col(1, c), parent = int(2, c), slot = col(3, c),
            index = int(4, c), root = int(5, c), line = int(6, c), col = int(7, c), endLine = int(8, c), endCol = int(9, c),
            synthetic = col(10, c) == "1" }) |> List.toVector;
        let files = nodeRows |> List.filter(c -> Vector.length(c) > 11 and col(11, c) != "") |> List.map(c -> (int(0, c), col(11, c))) |> List.toMap;
        let attrRows = rows(dir, "node_attr") |> List.map(c -> (int(0, c), (col(1, c), if (Vector.length(c) > 2) col(2, c) else "")));
        let typeRows = rows(dir, "node_type") |> List.map(c -> (int(0, c), (col(1, c), col(2, c))));
        let n = Vector.length(nodes);
        let byKind = nodes |> Vector.foldRight((nd, m) -> Map.insertWith((a, b) -> a ::: b, nd#kind, nd#id :: Nil, m), Map.empty());
        Ast.Ast({
            nodes = nodes,
            children = childLists(n, nodes),
            attrs = bucket(n, attrRows),
            types = bucket(n, typeRows),
            byKind = byKind,
            files = files,
            aliases = aliasesOf(byKind, attrRows)
        })

    pub def empty(): Ast = Ast.Ast({ nodes = Vector.empty(), children = Vector.empty(), attrs = Vector.empty(), types = Vector.empty(), byKind = Map.empty(), files = Map.empty(), aliases = Map.empty() })

    /// The type aliases of the sources by name.
    def aliasesOf(byKind: Map[String, List[Int32]], attrRows: List[(Int32, (String, String))]): Map[String, Int32] =
        let ids = Map.getWithDefault("TypeAlias", Nil, byKind) |> List.toSet;
        attrRows |> List.filter(match (i, (k, _)) -> k == "sym" and Set.memberOf(i, ids)) |> List.map(match (i, (_, v)) -> (v, i)) |> List.toMap

    /// The children of every node, in id order (the shim writes a parent before its children, in field order).
    def childLists(n: Int32, nodes: Vector[Node]): Vector[List[Int32]] = region rc {
        let arr = Array.repeat(rc, n, Nil);
        nodes |> Vector.reverse |> Vector.forEach(nd -> if (nd#parent >= 0) Array.put(nd#id :: Array.get(nd#parent, arr), nd#parent, arr) else ());
        Array.toVector(arr)
    }

    def bucket(n: Int32, pairs: List[(Int32, a)]): Vector[List[a]] = region rc {
        let arr = Array.repeat(rc, n, Nil);
        pairs |> List.reverse |> List.forEach(match (i, x) -> Array.put(x :: Array.get(i, arr), i, arr));
        Array.toVector(arr)
    }

    def rows(dir: String, rel: String): List[Vector[String]] \ FileRead =
        match Fs.FileRead.readLines("${dir}/${rel}.tsv") {
            case Ok(lines) => lines |> List.filter(l -> not String.isEmpty(l)) |> List.map(l -> String.splitOn(substr = "\t", l) |> List.toVector)
            case Err(_) => Nil
        }

    def col(i: Int32, c: Vector[String]): String = if (i < Vector.length(c)) Vector.get(i, c) else ""

    def int(i: Int32, c: Vector[String]): Int32 = Int32.parse(10, col(i, c)) |> Result.getWithDefault(0)

    // ---- the generic queries ----

    pub def node(ast: Ast, id: Int32): Node = Vector.get(id, data(ast)#nodes)

    /// Every node of a kind, in source order.
    pub def ofKind(ast: Ast, kind: String): List[Node] = Map.getWithDefault(kind, Nil, data(ast)#byKind) |> List.map(node(ast))

    pub def ofKinds(ast: Ast, kinds: List[String]): List[Node] =
        kinds |> List.map(k -> Map.getWithDefault(k, Nil, data(ast)#byKind)) |> List.foldLeft(merge, Nil) |> List.map(node(ast))

    /// Two ascending lists of ids as one.
    def merge(xs: List[Int32], ys: List[Int32]): List[Int32] = mergeAcc(xs, ys, Nil)

    def mergeAcc(xs: List[Int32], ys: List[Int32], acc: List[Int32]): List[Int32] = match (xs, ys) {
        case (Nil, _) => List.reverse(acc) ::: ys
        case (_, Nil) => List.reverse(acc) ::: xs
        case (x :: xt, y :: yt) => if (x <= y) mergeAcc(xt, ys, x :: acc) else mergeAcc(xs, yt, y :: acc)
    }

    pub def parent(ast: Ast, n: Node): Option[Node] = if (n#parent >= 0) Some(node(ast, n#parent)) else None

    /// The parents of `n`, closest first.
    pub def ancestors(ast: Ast, n: Node): List[Node] = match parent(ast, n) {
        case Some(p) => p :: ancestors(ast, p)
        case None => Nil
    }

    pub def children(ast: Ast, n: Node): List[Node] = Vector.get(n#id, data(ast)#children) |> List.map(node(ast))

    /// The children in the field `slot`, by index.
    pub def childrenIn(ast: Ast, n: Node, slot: String): List[Node] = children(ast, n) |> List.filter(c -> c#slot == slot)

    pub def child(ast: Ast, n: Node, slot: String): Option[Node] = childrenIn(ast, n, slot) |> List.head

    /// Every node under `n` (not `n` itself), parents before children.
    pub def descendants(ast: Ast, n: Node): List[Node] = children(ast, n) |> List.flatMap(c -> c :: descendants(ast, c))

    pub def attr(ast: Ast, n: Node, name: String): Option[String] = attrs(ast, n, name) |> List.head

    pub def attrs(ast: Ast, n: Node, name: String): List[String] =
        Vector.get(n#id, data(ast)#attrs) |> List.filter(p -> fst(p) == name) |> List.map(snd)

    /// The head of the type of an expression or a pattern (typed stage; at the resolved stage only where one was written).
    pub def typeOf(ast: Ast, n: Node): Option[String] =
        Vector.get(n#id, data(ast)#types) |> List.find(p -> fst(p) == "tpe") |> Option.map(snd)

    /// The declaration `n` is in.
    pub def root(ast: Ast, n: Node): Node = node(ast, n#root)

    pub def file(ast: Ast, n: Node): String = Map.getWithDefault(n#root, "?", data(ast)#files)

    /// The line of the name a node carries in `slot` (the callee of a call, the name of a def), else the node's own.
    pub def lineOf(ast: Ast, n: Node, slot: String): Int32 =
        attr(ast, n, "${slot}.line") |> Option.flatMap(s -> Int32.parse(10, s) |> Result.toOption) |> Option.getWithDefault(n#line)

    /// Whether `n` lies inside `ancestor`.
    pub def isUnder(ast: Ast, ancestor: Node, n: Node): Bool = ancestors(ast, n) |> List.exists(a -> a#id == ancestor#id)

    /// A violation at `line` in the declaration `n` is in: its file, its name as the subject, and the def an
    /// `allowIn` names (none for an enum, an alias, an effect).
    pub def violation(facts: Flixlint.Facts.Facts, id: String, n: Node, line: Int32, message: String, reason: String): Flixlint.Violation.Violation =
        let ast = Flixlint.Facts.ast(facts);
        let r = root(ast, n);
        let name = nameOf(ast, r);
        { file = file(ast, n), line = line, id = id, subject = name, message = message, reason = reason, path = Nil, notes = Nil,
          inFn = if (r#kind == "Def") Flixlint.Facts.fnOfName(facts, name) else None }

    /// The line a declaration's name is on (`sym.line`), else where the declaration starts.
    pub def declLine(ast: Ast, decl: Node): Int32 = lineOf(ast, decl, "sym")

    // ---- declarations ----

    pub def defs(ast: Ast): List[Node] = ofKind(ast, "Def")

    /// The qualified name of a declaration (`Auth.permit`).
    pub def nameOf(ast: Ast, decl: Node): String = attr(ast, decl, "sym") |> Option.getWithDefault("?")

    /// The def `n` is in, by name (None for a node of an enum, an alias, an effect).
    pub def defOf(ast: Ast, n: Node): Option[String] =
        let r = root(ast, n);
        if (r#kind == "Def") attr(ast, r, "sym") else None

    /// The module part of a qualified name.
    pub def moduleOf(qualified: String): String = match String.indexOfRight(substr = ".", qualified) {
        case Some(i) => String.takeLeft(i, qualified)
        case None => ""
    }

    pub def isPub(ast: Ast, decl: Node): Bool =
        let mods = child(ast, decl, "spec") |> Option.flatMap(s -> child(ast, s, "mod")) |> Option.withDefault(default = child(ast, decl, "mod"));
        mods |> Option.exists(m -> attrs(ast, m, "mod") |> List.memberOf("Public"))

    /// The declared type of each parameter of a def, in order.
    pub def paramTypes(ast: Ast, def0: Node): List[Node] =
        child(ast, def0, "spec") |> Option.toList
            |> List.flatMap(s -> childrenIn(ast, s, "fparams"))
            |> List.flatMap(p -> child(ast, p, "tpe") |> Option.toList)

    /// The declared return type of a def (`retTpe` typed, `tpe` resolved).
    pub def returnType(ast: Ast, def0: Node): Option[Node] =
        child(ast, def0, "spec") |> Option.flatMap(s -> child(ast, s, "retTpe") |> Option.withDefault(default = child(ast, s, "tpe")))

    /// The effects a def declares, aliases opened (`Db = DbRead + DbWrite` gives both).
    pub def effectsOf(ast: Ast, def0: Node): Set[String] =
        child(ast, def0, "spec") |> Option.flatMap(s -> child(ast, s, "eff")) |> Option.toList
            |> List.flatMap(t -> typeNodes(ast, t, true))
            |> List.filterMap(t -> effectName(ast, t)) |> List.toSet

    def effectName(ast: Ast, t: Node): Option[String] =
        if (t#kind == "UnkindedType.Effect") attr(ast, t, "sym")
        else if (t#kind == "Type.Cst" and attr(ast, t, "tc.kind") == Some("Effect")) attr(ast, t, "tc")
        else None

    // ---- types (declared types are subtrees of Type.* (typed) or UnkindedType.* (resolved) nodes) ----

    /// The name a type node stands for by itself (`Int32`, `List`, an enum, an alias), None for structure (an
    /// application, a variable, a record row).
    pub def typeName(ast: Ast, t: Node): Option[String] = match t#kind {
        case "Type.Cst" => if (isRow(ast, t)) None else attr(ast, t, "tc")
        case "UnkindedType.Cst" => if (isRow(ast, t)) None else attr(ast, t, "tc")
        case "Type.Alias" => attr(ast, t, "symUse")
        case "UnkindedType.Alias" => attr(ast, t, "symUse")
        case "UnkindedType.Enum" => attr(ast, t, "sym")
        case "UnkindedType.Struct" => attr(ast, t, "sym")
        case "UnkindedType.Effect" => attr(ast, t, "sym")
        case "UnkindedType.Arrow" => Some("Arrow")
        case _ => None
    }

    def isRow(ast: Ast, t: Node): Bool = match attr(ast, t, "tc.kind") {
        case Some("RecordRowExtend") => true
        case Some("SchemaRowExtend") => true
        case _ => false
    }

    /// Every name in a type, outermost first; `throughAliases` also opens what each alias stands for.
    /// WhyNot: an alias node has no expansion under it (the shim writes each alias once, as its declaration), so
    /// `throughAliases` opens the declaration of the sources' aliases by name; a package's alias stays closed.
    pub def typeNames(ast: Ast, t: Node, throughAliases: Bool): List[String] =
        typeNodes(ast, t, throughAliases) |> List.filterMap(typeName(ast))

    /// Every node of a type, outermost first; `throughAliases` also walks the declarations of the aliases in it.
    pub def typeNodes(ast: Ast, t: Node, throughAliases: Bool): List[Node] = nodesIn(ast, t, throughAliases, Set.empty())

    def nodesIn(ast: Ast, t: Node, deep: Bool, opened: Set[String]): List[Node] =
        let isAlias = t#kind == "Type.Alias" or t#kind == "UnkindedType.Alias";
        let own = if (isAlias) typeName(ast, t) |> Option.toList else Nil;
        let expansion = if (deep) own |> List.filter(a -> not Set.memberOf(a, opened))
            |> List.filterMap(a -> Map.get(a, data(ast)#aliases)) |> List.map(node(ast))
            |> List.flatMap(decl -> child(ast, decl, "tpe") |> Option.toList)
            else Nil;
        let opened1 = Set.union(opened, List.toSet(own));
        t :: List.flatMap(c -> nodesIn(ast, c, deep, opened1), children(ast, t) ::: expansion)

    /// The type alias declaration of a name, when the sources declare it.
    pub def aliasDecl(ast: Ast, name: String): Option[Node] = Map.get(name, data(ast)#aliases) |> Option.map(node(ast))

    /// The head of a type (`List[Int32]` gives `List`; an alias gives its own name).
    pub def typeHead(ast: Ast, t: Node): Option[String] = match typeName(ast, t) {
        case Some(n) => Some(n)
        case None => children(ast, t) |> List.head |> Option.flatMap(c -> if (String.endsWith(suffix = "Apply", t#kind)) typeHead(ast, c) else None)
    }

    /// The number of record fields a type alias stands for, or -1 when it is not a record.
    pub def recordFields(ast: Ast, decl: Node): Int32 =
        match child(ast, decl, "tpe") {
            case Some(t) if isApply(t) and (nth(ast, 0, t) |> Option.flatMap(c -> attr(ast, c, "tc"))) == Some("Record") =>
                nth(ast, 1, t) |> Option.map(rowLength(ast)) |> Option.getWithDefault(0)
            case _ => -1
        }

    def isApply(t: Node): Bool = String.endsWith(suffix = ".Apply", t#kind)

    def nth(ast: Ast, i: Int32, t: Node): Option[Node] = children(ast, t) |> List.drop(i) |> List.head

    /// `Apply(Apply(Cst(RecordRowExtend), field), rest)` counted along `rest`.
    def rowLength(ast: Ast, row: Node): Int32 =
        let ext = isApply(row) and (nth(ast, 0, row) |> Option.filter(isApply) |> Option.flatMap(nth(ast, 0)) |> Option.exists(c -> isRow(ast, c)));
        if (ext) 1 + (nth(ast, 1, row) |> Option.map(rowLength(ast)) |> Option.getWithDefault(0)) else 0

    // ---- expressions ----

    pub def isCall(n: Node): Bool = n#kind == "Expr.ApplyDef" or n#kind == "Expr.ApplySig" or n#kind == "Expr.ApplyOp"

    /// Every call of a def, a trait signature or an effect operation.
    pub def calls(ast: Ast): List[Node] = ofKinds(ast, List#{"Expr.ApplyDef", "Expr.ApplySig", "Expr.ApplyOp"})

    pub def callee(ast: Ast, call: Node): String = attr(ast, call, "symUse") |> Option.getWithDefault("?")

    /// The line of the callee's name (a call's own location starts at a comment written above it).
    pub def callLine(ast: Ast, call: Node): Int32 = lineOf(ast, call, "symUse")

    pub def args(ast: Ast, call: Node): List[Node] = childrenIn(ast, call, "exps")

    pub def isBool(ast: Ast, n: Node): Bool = n#kind == "Expr.Cst" and attr(ast, n, "cst") == Some("Bool")

    pub def strLit(ast: Ast, n: Node): Option[String] =
        if (n#kind == "Expr.Cst" and attr(ast, n, "cst") == Some("Str")) attr(ast, n, "cst.lit") else None

    /// A node that only re-types its child (`e: T`, casts).
    pub def isAscription(n: Node): Bool = n#kind == "Expr.Ascribe" or n#kind == "Expr.CheckedCast" or n#kind == "Expr.UncheckedCast"

    /// `n` seen through ascriptions.
    pub def seeThrough(ast: Ast, n: Node): Node =
        if (isAscription(n)) child(ast, n, "exp") |> Option.map(seeThrough(ast)) |> Option.getWithDefault(n) else n

    /// The binder of a `let` (`bnd.sym` typed, `sym` resolved).
    pub def letBinder(ast: Ast, let0: Node): Option[String] =
        child(ast, let0, "bnd") |> Option.flatMap(b -> attr(ast, b, "sym")) |> Option.withDefault(default = attr(ast, let0, "sym"))

    /// The expression a variable is bound to by an enclosing `let` (the desugarer binds partial applications and
    /// functions passed by name this way).
    pub def boundTo(ast: Ast, v: Node): Option[Node] =
        if (v#kind != "Expr.Var") None
        else attr(ast, v, "sym") |> Option.flatMap(sym ->
            ancestors(ast, v) |> List.find(a -> a#kind == "Expr.Let" and letBinder(ast, a) == Some(sym))
                |> Option.flatMap(l -> child(ast, l, "exp1")))

    /// `n` seen through ascriptions and let-bound variables.
    pub def resolve(ast: Ast, n: Node): Node =
        let m = seeThrough(ast, n);
        match boundTo(ast, m) {
            case Some(b) => resolve(ast, b)
            case None => m
        }

    /// The uses of the variable a `let` binds, in its body.
    pub def usesOf(ast: Ast, let0: Node): List[Node] = match (letBinder(ast, let0), child(ast, let0, "exp2")) {
        case (Some(sym), Some(body)) => (body :: descendants(ast, body)) |> List.filter(d -> d#kind == "Expr.Var" and attr(ast, d, "sym") == Some(sym))
        case _ => Nil
    }

    /// The calls a lambda is passed to (directly, or as a let-bound variable), as `(callee, call)`.
    pub def lambdaPassedTo(ast: Ast, lam: Node): List[(String, Node)] =
        let direct = passedAt(ast, lam);
        let viaLet = parent(ast, lam) |> Option.toList
            |> List.filter(p -> p#kind == "Expr.Let" and lam#slot == "exp1") |> List.flatMap(l -> usesOf(ast, l)) |> List.flatMap(u -> passedAt(ast, u));
        direct ::: viaLet

    /// The call `n` is an argument of, when it is one (through ascriptions).
    def passedAt(ast: Ast, n: Node): List[(String, Node)] = match parent(ast, n) {
        case Some(p) if isAscription(p) => passedAt(ast, p)
        case Some(p) if isCall(p) and n#slot == "exps" => (callee(ast, p), p) :: Nil
        case _ => Nil
    }

    /// The function an expression stands for when it is a call, or a lambda / let around one.
    pub def denoted(ast: Ast, e: Node): Option[String] =
        let r = resolve(ast, e);
        if (isCall(r) and not isPipe(ast, r)) Some(callee(ast, r))
        else if (r#kind == "Expr.Let") child(ast, r, "exp2") |> Option.flatMap(denoted(ast))
        else if (r#kind == "Expr.Lambda") child(ast, r, "exp") |> Option.flatMap(denoted(ast))
        else None

    pub def isPipe(ast: Ast, n: Node): Bool = n#kind == "Expr.ApplyDef" and callee(ast, n) == "|>" and List.length(args(ast, n)) == 2

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
        ancestors(ast, n) |> List.zip(n :: ancestors(ast, n))
            |> List.filter(match (_, p) -> not (p#kind == "Expr.Unary" or isAscription(p)))
            |> List.map(match (below, p) -> (describe(ast, p, below), p#line))

    def describe(ast: Ast, p: Node, below: Node): String =
        let short = match String.indexOfRight(substr = ".", p#kind) {
            case Some(i) => String.dropLeft(i + 1, p#kind)
            case None => p#kind
        };
        if (isCall(p) and below#slot == "exps") "arg:${callee(ast, p)}:${below#index}"
        else if (p#kind == "Expr.RecordExtend" and below#slot == "exp1") "field:${attr(ast, p, "label") |> Option.getWithDefault("?")}"
        else if (p#kind == "Expr.Tag") "tag:${attr(ast, p, "symUse") |> Option.getWithDefault("?")}"
        else if (p#kind == "Expr.Tuple") "tuple"
        else if (p#kind == "Expr.VectorLit") "vector"
        else if (p#kind == "Expr.ArrayLit") "array"
        else if (p#kind == "Expr.Let" and below#slot == "exp1") "let"
        else if (p#kind == "Expr.Binary") "op:${attr(ast, p, "sop") |> Option.getWithDefault("?")}"
        else short

    /// The branches of the sources (`if`, `match` and a `match` lambda, `typematch`, `extmatch`, and each guard of a
    /// rule) as (kind, node at the line to report). A `let (a, b) = e` and a `forM` generator are not branches.
    pub def branches(ast: Ast): List[(String, Node)] =
        let sameSpan = (a, b) -> a#line == b#line and a#col == b#col and a#endLine == b#endLine and a#endCol == b#endCol;
        let own = ofKinds(ast, List#{"Expr.IfThenElse", "Expr.Match", "Expr.TypeMatch", "Expr.ExtMatch"}) |> List.filterMap(m -> {
            let rules = if (m#kind == "Expr.Match") childrenIn(ast, m, "rules") else Nil;
            let destructuring = match rules {
                case r :: Nil => not m#synthetic and sameSpan(r, m) and Option.isEmpty(child(ast, r, "guard"))
                case _ => false
            };
            let generator = match rules {
                case r :: Nil => m#synthetic and (child(ast, r, "pat") |> Option.exists(p -> p#kind == "Pattern.Var" or p#kind == "Pattern.Wild"))
                case _ => false
            };
            let kind = match m#kind {
                case "Expr.IfThenElse" => "if"
                case "Expr.Match" => "match"
                case "Expr.TypeMatch" => "typematch"
                case _ => "extmatch"
            };
            if (destructuring or generator) None else Some((kind, m))
        });
        let guards = ofKind(ast, "MatchRule") |> List.filterMap(r -> child(ast, r, "guard") |> Option.map(g -> ("guard", g)));
        own ::: guards
}
