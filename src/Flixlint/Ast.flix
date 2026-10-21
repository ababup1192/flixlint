///
/// Layer 1 of the generic AST (docs/design-generic.md 2.1): the tree, the leaves and the shared type table the shim's
/// `flixlint.Generic` writes, read as they are. It knows nodes, fields, attributes and types, not what a Flix construct
/// is; the Flix words live in `Flixlint.Flix` (layer 2). The kinds, slots and attributes are the generated
/// `Flixlint.AstKinds`.
///
pub mod Flixlint.Ast {
    use Flixlint.AstKinds.{Kind, Slot, Attr}
    import java.io.File
    import java.io.IOException
    import java.nio.ByteBuffer
    import java.nio.IntBuffer
    import java.nio.file.Files

    pub enum Ast(AstData)

    /// A node: its row in the columns.
    pub enum Node(Int32) with Eq, Order, Hash, ToString

    /// A type: its row in the shared type table.
    pub enum TypeRef(Int32) with Eq, Order, Hash, ToString

    pub enum Stage with Eq, ToString {
        case Resolved
        case Typed
    }

    /// The form of a type, the same at both stages (`Type.Cst` and `UnkindedType.Cst` are both `Cst`). A function type is
    /// `Arrow(n)` applied to its effect, its `n - 1` parameters and its result; a record is `Record` applied to a row of
    /// `RecordRow(label)`s; a type variable is `Var(i)`, `i` the order it first appears in the type it was written with.
    pub enum TypeForm with Eq, ToString {
        case Cst(String)
        case Apply
        case Alias(String)
        case Var(Int32)
        case Arrow(Int32)
        case Record
        case RecordRow(String)
        case Schema
        case Effect(String)
        case EffUnion(String)
        case Other(String)
    }

    /// Whether `typeNames` opens what an alias stands for.
    pub enum AliasMode with Eq {
        case Closed
        case Opened
    }

    /// A `Kind.X` / `Slot.Y` / `Attr.Z` (`table`) or an `Unnamed(` a rule file writes, at `file:line`: whether this stage has
    /// it and how many rows of these relations carry it (-1 for `Unnamed(`). Written by the shim from the rule file's text.
    pub type alias RuleName = { file = String, line = Int32, table = String, name = String, inStage = Bool, count = Int32 }

    /// A declaration outside the sources that the sources use (or an effect alias outside the sources).
    pub type alias External = { name = String, kind = String, tpe = Option[TypeRef], members = List[String] }

    type alias AstData = {
        stage = Stage,
        kind = Vector[Int32], parent = Vector[Int32], slot = Vector[Int32], index = Vector[Int32], root = Vector[Int32],
        line = Vector[Int32], col = Vector[Int32], endLine = Vector[Int32], endCol = Vector[Int32], synthetic = Vector[Int32],
        tpe = Vector[Int32], effects = Vector[Int32],
        attrNode = Vector[Int32], attrName = Vector[Int32], attrValue = Vector[Int32], attrType = Vector[Int32], attrLine = Vector[Int32],
        typeForm = Vector[Int32], typeName = Vector[Int32], typeArgStart = Vector[Int32], typeArgs = Vector[Int32], typeExpands = Vector[Int32],
        extSym = Vector[Int32], extKind = Vector[Int32], extType = Vector[Int32], extMemberStart = Vector[Int32], extMembers = Vector[Int32],
        strings = Vector[String],
        fileOfRoot = Map[Int32, String],
        files = Vector[String],
        // the indices, made the first time they are read: the children of each node and the nodes of each kind (CSR:
        // the ids of node `i` are `ids[start[i] .. start[i + 1])`), and where each node's attributes start
        childStart = Lazy[Vector[Int32]], childIds = Lazy[Vector[Int32]],
        kindStart = Lazy[Vector[Int32]], kindIds = Lazy[Vector[Int32]],
        attrStart = Lazy[Vector[Int32]],
        externals = Lazy[Map[String, External]],
        ruleNames = List[RuleName]
    }

    def data(ast: Ast): AstData = match ast { case Ast.Ast(d) => d }

    def id(n: Node): Int32 = match n { case Node.Node(i) => i }

    def tid(t: TypeRef): Int32 = match t { case TypeRef.TypeRef(i) => i }

    // ---- loading ----

    /// The relations under `dir`, or what could not be read. Relations written for another `ast_schema` than the one
    /// AstKinds.flix was made from, or in another format, are refused: their numbers would name other things.
    pub def load(dir: String): Result[String, Ast] \ IO =
        forM (
            meta <- readLines("${dir}/meta.txt") |> Result.map(metaOf);
            _ <- checkMeta(dir, meta);
            strings <- readLines("${dir}/strings.txt") |> Result.map(xs -> xs |> List.map(unescape) |> List.toVector);
            files <- readLines("${dir}/files.txt") |> Result.map(List.toVector);
            node <- columns(dir, "node", List#{"kind", "parent", "slot", "index", "root", "line", "col", "endLine", "endCol", "synthetic", "type", "effect"});
            attr <- columns(dir, "attr", List#{"node", "name", "value", "type", "line"});
            tpe <- columns(dir, "type", List#{"form", "name", "argStart", "args", "expands"});
            decl <- columns(dir, "decl", List#{"node", "file"});
            ext <- columns(dir, "ext", List#{"sym", "kind", "type", "memberStart", "members"});
            ruleNames <- readRuleNames("${dir}/rule_names.tsv")
        ) yield {
            let c = (m, k) -> Map.getWithDefault(k, Vector.empty(), m);
            let kind = c(node, "kind");
            let parent = c(node, "parent");
            let attrNode = c(attr, "node");
            let d = {
                stage = if (Map.get("stage", meta) == Some("resolved")) Stage.Resolved else Stage.Typed,
                kind = kind, parent = parent, slot = c(node, "slot"), index = c(node, "index"), root = c(node, "root"),
                line = c(node, "line"), col = c(node, "col"), endLine = c(node, "endLine"), endCol = c(node, "endCol"),
                synthetic = c(node, "synthetic"), tpe = c(node, "type"), effects = c(node, "effect"),
                attrNode = attrNode, attrName = c(attr, "name"), attrValue = c(attr, "value"), attrType = c(attr, "type"), attrLine = c(attr, "line"),
                typeForm = c(tpe, "form"), typeName = c(tpe, "name"), typeArgStart = c(tpe, "argStart"), typeArgs = c(tpe, "args"),
                typeExpands = c(tpe, "expands"),
                extSym = c(ext, "sym"), extKind = c(ext, "kind"), extType = c(ext, "type"), extMemberStart = c(ext, "memberStart"),
                extMembers = c(ext, "members"),
                strings = strings,
                fileOfRoot = Vector.zip(c(decl, "node"), c(decl, "file")) |> Vector.map(match (n, f) -> (n, Vector.nth(f, files) |> Option.getWithDefault("?"))) |> Vector.toMap,
                files = files,
                childStart = lazy fst(groups(Vector.length(kind), parent)),
                childIds = lazy snd(groups(Vector.length(kind), parent)),
                kindStart = lazy fst(groups(Vector.length(Flixlint.AstKinds.kinds()), kind)),
                kindIds = lazy snd(groups(Vector.length(Flixlint.AstKinds.kinds()), kind)),
                attrStart = lazy fst(groups(Vector.length(kind), attrNode)),
                externals = lazy Map.empty(),
                ruleNames = ruleNames
            };
            Ast.Ast({ externals = lazy externalsOf(d) | d })
        }

    /// No relations: what a rule sees when the shim did not write the generic AST.
    pub def empty(): Ast =
        let none = Vector.empty();
        Ast.Ast({
            stage = Stage.Typed, kind = none, parent = none, slot = none, index = none, root = none, line = none, col = none,
            endLine = none, endCol = none, synthetic = none, tpe = none, effects = none,
            attrNode = none, attrName = none, attrValue = none, attrType = none, attrLine = none,
            typeForm = none, typeName = none, typeArgStart = none, typeArgs = none, typeExpands = none,
            extSym = none, extKind = none, extType = none, extMemberStart = none, extMembers = none,
            strings = Vector.empty(), fileOfRoot = Map.empty(), files = Vector.empty(),
            childStart = lazy none, childIds = lazy none, kindStart = lazy none, kindIds = lazy none, attrStart = lazy none,
            externals = lazy Map.empty(), ruleNames = Nil
        })

    /// `rule_names.tsv`; none when the shim was not given the rule file.
    def readRuleNames(path: String): Result[String, List[RuleName]] \ IO =
        if (not (new File(path)).exists()) Ok(Nil)
        else readLines(path) |> Result.map(List.filterMap(l -> match String.splitOn(substr = "\t", l) {
            case file :: line :: table :: name :: inStage :: count :: Nil =>
                Some({ file = file, line = Int32.parse(10, line) |> Result.getWithDefault(0), table = table, name = unescape(name),
                       inStage = inStage == "1", count = Int32.parse(10, count) |> Result.getWithDefault(0) })
            case _ => None
        }))

    /// `key=value` lines.
    def metaOf(lines: List[String]): Map[String, String] =
        lines |> List.filterMap(l -> match String.indexOf(substr = "=", l) {
            case Some(i) => Some((String.takeLeft(i, l), String.dropLeft(i + 1, l)))
            case None => None
        }) |> List.toMap

    def checkMeta(dir: String, meta: Map[String, String]): Result[String, Unit] =
        let hash = Map.getWithDefault("schemaHash", "?", meta);
        if (Map.get("format", meta) != Some("1"))
            Err("${dir}: the relations are of format ${Map.getWithDefault("format", "?", meta)}, and this flixlint reads 1")
        else if (hash != Flixlint.AstKinds.schemaHash())
            Err("${dir}: the relations were written for the ast_schema ${hash}, and this flixlint has ${Flixlint.AstKinds.schemaHash()} (the shim and the library are of different versions)")
        else Ok(())

    /// The columns `<table>.<name>.i32` by name.
    def columns(dir: String, table: String, names: List[String]): Result[String, Map[String, Vector[Int32]]] \ IO =
        names |> List.map(n -> readColumn("${dir}/${table}.${n}.i32") |> Result.map(v -> (n, v))) |> Result.sequence |> Result.map(List.toMap)

    /// The ids `0 ..` grouped by `keys` (row `i` belongs to group `keys[i]`; a negative key belongs to none), as the start
    /// of each group and the ids in group order (within a group, in id order).
    def groups(n: Int32, keys: Vector[Int32]): (Vector[Int32], Vector[Int32]) = region rc {
        let start = Array.repeat(rc, n + 1, 0);
        Vector.forEach(k -> if (k >= 0) Array.put(Array.get(k + 1, start) + 1, k + 1, start) else (), keys);
        List.range(0, n) |> List.forEach(i -> Array.put(Array.get(i, start) + Array.get(i + 1, start), i + 1, start));
        let next = Array.copyOfRange(rc, 0, n + 1, start);
        let ids = Array.repeat(rc, Array.get(n, start), 0);
        Vector.forEachWithIndex((i, k) -> if (k >= 0) {
            let at = Array.get(k, next);
            Array.put(i, at, ids);
            Array.put(at + 1, k, next)
        } else (), keys);
        (Array.toVector(start), Array.toVector(ids))
    }

    def externalsOf(d: AstData): Map[String, External] =
        let str = i -> if (i < 0) "" else Vector.nth(i, d#strings) |> Option.getWithDefault("");
        Vector.range(0, Vector.length(d#extSym)) |> Vector.map(i -> {
            let tpe = Vector.get(i, d#extType);
            let members = Vector.range(Vector.get(i, d#extMemberStart), Vector.get(i + 1, d#extMemberStart))
                |> Vector.map(j -> str(Vector.get(j, d#extMembers))) |> Vector.toList;
            let e = { name = str(Vector.get(i, d#extSym)), kind = extKindName(Vector.get(i, d#extKind)),
                      tpe = if (tpe < 0) None else Some(TypeRef.TypeRef(tpe)), members = members };
            (e#name, e)
        }) |> Vector.toMap

    /// The kinds of an external declaration, in the shim's numbering (`Generic.ExtKinds`).
    def extKindName(i: Int32): String =
        Vector.nth(i, Vector#{"def", "sig", "op", "enum", "case", "struct", "alias", "effect", "java"}) |> Option.getWithDefault("?")

    /// A line of `strings.txt`: `\\`, `\n` and `\r` back to what they stand for.
    def unescape(s: String): String =
        if (not String.contains(substr = "\\", s)) s
        else unescapeFrom(String.toList(s), Nil) |> List.reverse |> List.toString

    def unescapeFrom(cs: List[Char], acc: List[Char]): List[Char] = match cs {
        case '\\' :: 'n' :: rest => unescapeFrom(rest, '\n' :: acc)
        case '\\' :: 'r' :: rest => unescapeFrom(rest, '\r' :: acc)
        case '\\' :: '\\' :: rest => unescapeFrom(rest, '\\' :: acc)
        case c :: rest => unescapeFrom(rest, c :: acc)
        case Nil => acc
    }

    def readLines(path: String): Result[String, List[String]] \ IO =
        try {
            let text = Files.readString((new File(path)).toPath());
            Ok(if (String.isEmpty(text)) Nil else String.splitOn(substr = "\n", String.stripSuffix(substr = "\n", text) |> Option.getWithDefault(text)))
        } catch {
            case e: IOException => Err("${path}: ${e.getMessage()}")
        }

    /// A column: big-endian Int32 values, the row count is the file size / 4.
    def readColumn(path: String): Result[String, Vector[Int32]] \ IO =
        let bytes = try {
            Ok(Files.readAllBytes((new File(path)).toPath()))
        } catch {
            case e: IOException => Err("${path}: ${e.getMessage()}")
        };
        Result.map(b -> toInts(ByteBuffer.wrap(b).asIntBuffer()), bytes)

    def toInts(ints: IntBuffer): Vector[Int32] \ IO = region rc {
        let arr: Array[Int32, rc] = Array.repeat(rc, ints.remaining(), 0);
        discard ints.get(arr);
        Array.toVector(arr)
    }

    // ---- the tree ----

    pub def stage(ast: Ast): Stage = data(ast)#stage

    /// How many nodes there are.
    pub def size(ast: Ast): Int32 = Vector.length(data(ast)#kind)

    /// Every node, in id order (a parent before its children).
    pub def nodes(ast: Ast): List[Node] = List.range(0, size(ast)) |> List.map(Node.Node)

    /// The nodes of kind `k`, in id order.
    pub def ofKind(ast: Ast, k: Kind): List[Node] =
        let d = data(ast);
        let i = Flixlint.AstKinds.kindIndex(k);
        slice(force d#kindStart, force d#kindIds, i) |> List.map(Node.Node)

    /// The nodes of any of `ks`, in id order.
    pub def ofKinds(ast: Ast, ks: List[Kind]): List[Node] = ks |> List.flatMap(ofKind(ast)) |> List.sort

    def slice(start: Vector[Int32], ids: Vector[Int32], i: Int32): List[Int32] =
        if (i < 0 or i + 1 >= Vector.length(start)) Nil
        else List.range(Vector.get(i, start), Vector.get(i + 1, start)) |> List.map(j -> Vector.get(j, ids))

    pub def kind(ast: Ast, n: Node): Kind =
        let i = Vector.get(id(n), data(ast)#kind);
        match Flixlint.AstKinds.kindOfIndex(i) {
            case Some(k) => k
            case None    => bug!("Flixlint.Ast: kind number ${i} of node ${id(n)} is not in AstKinds (load checks the schema hash)")
        }

    /// Whether `n` is of kind `k`.
    pub def is(ast: Ast, k: Kind, n: Node): Bool = Vector.get(id(n), data(ast)#kind) == Flixlint.AstKinds.kindIndex(k)

    /// The node `n` sits in; none for a declaration.
    pub def parent(ast: Ast, n: Node): Option[Node] =
        let p = Vector.get(id(n), data(ast)#parent);
        if (p < 0) None else Some(Node.Node(p))

    /// The nodes `n` sits in, closest first.
    pub def ancestors(ast: Ast, n: Node): List[Node] = match parent(ast, n) {
        case Some(p) => p :: ancestors(ast, p)
        case None    => Nil
    }

    /// The nodes in `n`'s fields, in field order.
    pub def children(ast: Ast, n: Node): List[Node] =
        let d = data(ast);
        slice(force d#childStart, force d#childIds, id(n)) |> List.map(Node.Node)

    /// The nodes in the field `s` of `n`, in order.
    pub def childrenIn(ast: Ast, n: Node, s: Slot): List[Node] =
        let i = Flixlint.AstKinds.slotIndex(s);
        children(ast, n) |> List.filter(c -> Vector.get(id(c), data(ast)#slot) == i)

    /// The (first) node in the field `s` of `n`.
    pub def child(ast: Ast, n: Node, s: Slot): Option[Node] = childrenIn(ast, n, s) |> List.head

    /// Every node under `n` (not `n` itself), parents before children: the ids after `n` up to its last descendant.
    pub def descendants(ast: Ast, n: Node): List[Node] = children(ast, n) |> List.flatMap(c -> c :: descendants(ast, c))

    /// Whether `n` lies inside `outer`.
    pub def isUnder(ast: Ast, outer: Node, n: Node): Bool = ancestors(ast, n) |> List.memberOf(outer)

    /// The field of its parent `n` sits in; none for a declaration.
    pub def slotOf(ast: Ast, n: Node): Option[Slot] = Flixlint.AstKinds.slotOfIndex(Vector.get(id(n), data(ast)#slot))

    /// The position of `n` in its field when the field is a list.
    pub def indexOf(ast: Ast, n: Node): Int32 = Vector.get(id(n), data(ast)#index)

    /// Where `n` is. A node the compiler gave no location has its parent's.
    pub def pos(ast: Ast, n: Node): { line = Int32, col = Int32, endLine = Int32, endCol = Int32, synthetic = Bool } =
        let d = data(ast);
        let i = id(n);
        { line = Vector.get(i, d#line), col = Vector.get(i, d#col), endLine = Vector.get(i, d#endLine), endCol = Vector.get(i, d#endCol),
          synthetic = Vector.get(i, d#synthetic) == 1 }

    pub def line(ast: Ast, n: Node): Int32 = Vector.get(id(n), data(ast)#line)

    /// The declaration `n` is in.
    pub def root(ast: Ast, n: Node): Node = Node.Node(Vector.get(id(n), data(ast)#root))

    /// The file of the declaration `n` is in.
    pub def file(ast: Ast, n: Node): String = Map.getWithDefault(Vector.get(id(n), data(ast)#root), "?", data(ast)#fileOfRoot)

    /// Every file the walk was given, whether or not it declares anything.
    pub def files(ast: Ast): List[String] = Vector.toList(data(ast)#files)

    // ---- the leaves ----

    /// The attribute rows of `n`, in field order.
    def attrRows(ast: Ast, n: Node): List[Int32] =
        let start = force data(ast)#attrStart;
        let i = id(n);
        if (i + 1 >= Vector.length(start)) Nil else List.range(Vector.get(i, start), Vector.get(i + 1, start))

    def rowsOf(ast: Ast, n: Node, a: Attr): List[Int32] =
        let k = Flixlint.AstKinds.attrIndex(a);
        attrRows(ast, n) |> List.filter(r -> Vector.get(r, data(ast)#attrName) == k)

    def string(ast: Ast, i: Int32): String = if (i < 0) "" else Vector.nth(i, data(ast)#strings) |> Option.getWithDefault("")

    /// Every leaf of `n`, in field order: its attribute, and its value or its type.
    pub def leaves(ast: Ast, n: Node): List[{ attr = Attr, value = Option[String], tpe = Option[TypeRef] }] =
        let d = data(ast);
        attrRows(ast, n) |> List.filterMap(r -> Flixlint.AstKinds.attrOfIndex(Vector.get(r, d#attrName)) |> Option.map(a -> {
            let v = Vector.get(r, d#attrValue);
            let t = Vector.get(r, d#attrType);
            { attr = a, value = if (v < 0) None else Some(string(ast, v)), tpe = if (t < 0) None else Some(TypeRef.TypeRef(t)) }
        }))

    /// The (first) value of the leaf `a` of `n`: a symbol's qualified name (`List.map`), a variable (`x#3`), a constant's
    /// kind (`Str`) and text (`Attr.Cst_lit`), an operator, a label, a modifier.
    pub def attr(ast: Ast, n: Node, a: Attr): Option[String] = attrs(ast, n, a) |> List.head

    /// Every value of the leaf `a` of `n`, in order (a field that is a list).
    pub def attrs(ast: Ast, n: Node, a: Attr): List[String] =
        rowsOf(ast, n, a) |> List.filter(r -> Vector.get(r, data(ast)#attrValue) >= 0) |> List.map(r -> string(ast, Vector.get(r, data(ast)#attrValue)))

    /// The line of the value of `a`, when it is written on a line of its own (the name of a call); else `n`'s line.
    pub def attrLine(ast: Ast, n: Node, a: Attr): Int32 =
        match rowsOf(ast, n, a) |> List.head |> Option.map(r -> Vector.get(r, data(ast)#attrLine)) {
            case Some(l) if l >= 0 => l
            case _ => line(ast, n)
        }

    /// The type in the field `a` of `n` (a declared type: `retTpe`, `tpe` of a parameter, an alias's `tpe`).
    pub def attrType(ast: Ast, n: Node, a: Attr): Option[TypeRef] = attrTypes(ast, n, a) |> List.head

    /// Every type in the field `a` of `n` (a field that is a list of types: `tpes` of a case, `targs`).
    pub def attrTypes(ast: Ast, n: Node, a: Attr): List[TypeRef] =
        rowsOf(ast, n, a) |> List.map(r -> Vector.get(r, data(ast)#attrType)) |> List.filter(t -> t >= 0) |> List.map(TypeRef.TypeRef)

    /// The type of an expression or a pattern (the typed stage; the resolved stage has none).
    pub def typeOf(ast: Ast, n: Node): Option[TypeRef] =
        let t = Vector.get(id(n), data(ast)#tpe);
        if (t < 0) None else Some(TypeRef.TypeRef(t))

    /// The effect of an expression (the typed stage).
    pub def effectOf(ast: Ast, n: Node): Option[TypeRef] =
        let t = Vector.get(id(n), data(ast)#effects);
        if (t < 0) None else Some(TypeRef.TypeRef(t))

    // ---- the types ----

    pub def form(ast: Ast, t: TypeRef): TypeForm =
        let d = data(ast);
        let name = string(ast, Vector.get(tid(t), d#typeName));
        match Vector.get(tid(t), d#typeForm) {
            case 0 => TypeForm.Cst(name)
            case 1 => TypeForm.Apply
            case 2 => TypeForm.Alias(name)
            case 3 => TypeForm.Var(Int32.parse(10, name) |> Result.getWithDefault(0))
            case 4 => TypeForm.Arrow(Int32.parse(10, name) |> Result.getWithDefault(0))
            case 5 => TypeForm.Record
            case 6 => TypeForm.RecordRow(name)
            case 7 => TypeForm.Schema
            case 8 => TypeForm.Effect(name)
            case 9 => TypeForm.EffUnion(name)
            case _ => TypeForm.Other(name)
        }

    /// The parts of a type: an application's function and argument, an alias's arguments.
    pub def typeArgs(ast: Ast, t: TypeRef): List[TypeRef] =
        let d = data(ast);
        List.range(Vector.get(tid(t), d#typeArgStart), Vector.get(tid(t) + 1, d#typeArgStart))
            |> List.map(j -> TypeRef.TypeRef(Vector.get(j, d#typeArgs)))

    /// What an alias stands for (the standard library's and the packages' aliases too); none for another type.
    pub def expansion(ast: Ast, t: TypeRef): Option[TypeRef] =
        let e = Vector.get(tid(t), data(ast)#typeExpands);
        if (e < 0) None else Some(TypeRef.TypeRef(e))

    /// `t` with the aliases at its head opened.
    pub def expand(ast: Ast, t: TypeRef): TypeRef = match expansion(ast, t) {
        case Some(e) => expand(ast, e)
        case None    => t
    }

    /// The head of a type (`List[Int32]` gives `List`; an alias gives its own name; a function `Arrow(n)`).
    pub def head(ast: Ast, t: TypeRef): Option[String] = match form(ast, t) {
        case TypeForm.Apply => typeArgs(ast, t) |> List.head |> Option.flatMap(head(ast))
        case f => nameOf(f)
    }

    /// The name a type form stands for by itself, as the old facts spell it (`Arrow(2)`, `Record`, `Union`); none for
    /// structure (an application, a variable, a record row).
    def nameOf(f: TypeForm): Option[String] = match f {
        case TypeForm.Cst(n) => Some(n)
        case TypeForm.Alias(n) => Some(n)
        case TypeForm.Arrow(n) => Some("Arrow(${n})")
        case TypeForm.Record => Some("Record")
        case TypeForm.Schema => Some("Schema")
        case TypeForm.Effect(n) => Some(n)
        case TypeForm.EffUnion(n) => Some(n)
        case TypeForm.Other(n) => Some(n)
        case _ => None
    }

    /// Every name in a type, outermost first: an alias by its own name and its arguments, and with `Opened` also what it
    /// stands for, at any depth (`type alias Ctx = { w = World }` gives `Ctx` and `World`). Variables and record rows give none.
    pub def typeNames(ast: Ast, t: TypeRef, mode: AliasMode): List[String] =
        let own = nameOf(form(ast, t)) |> Option.toList;
        let expanded = if (mode == AliasMode.Opened) expansion(ast, t) |> Option.toList else Nil;
        own ::: List.flatMap(a -> typeNames(ast, a, mode), typeArgs(ast, t) ::: expanded)

    /// A type written out (`List[Int32]`, `Int32 -> Bool \ IO`), for messages.
    pub def show(ast: Ast, t: TypeRef): String = match form(ast, t) {
        case TypeForm.Apply =>
            let (h, args) = spine(ast, t, Nil);
            match form(ast, h) {
                case TypeForm.Arrow(_) => match args {
                    case effect :: rest =>
                        let shown = List.map(show(ast), rest);
                        let ps = List.take(List.length(shown) - 1, shown);
                        let r = List.last(shown) |> Option.getWithDefault("?");
                        let e = show(ast, effect);
                        "${String.intercalate(" -> ", ps ::: (r :: Nil))}${if (e == "Pure") "" else " \\ ${e}"}"
                    case Nil => "?"
                }
                case TypeForm.Record => "{ ${args |> List.map(show(ast)) |> String.intercalate(", ")} }"
                case TypeForm.RecordRow(label) => match args {
                    case v :: rest :: Nil => "${label} = ${show(ast, v)}, ${show(ast, rest)}"
                    case _ => label
                }
                case _ => "${show(ast, h)}[${args |> List.map(show(ast)) |> String.intercalate(", ")}]"
            }
        case TypeForm.Var(i) => "t${i}"
        case TypeForm.Alias(n) => match typeArgs(ast, t) {
            case Nil => n
            case args => "${n}[${args |> List.map(show(ast)) |> String.intercalate(", ")}]"
        }
        case f => nameOf(f) |> Option.getWithDefault("?")
    }

    /// An application taken apart: its head and its arguments in order.
    def spine(ast: Ast, t: TypeRef, args: List[TypeRef]): (TypeRef, List[TypeRef]) = match (form(ast, t), typeArgs(ast, t)) {
        case (TypeForm.Apply, f :: a :: Nil) => spine(ast, f, a :: args)
        case _ => (t, args)
    }

    // ---- outside the sources ----

    /// The declaration outside the sources of a qualified name (`List.map`, `Option.Some`, `java.lang.String.length`),
    /// when the sources use it.
    pub def external(ast: Ast, name: String): Option[External] = Map.get(name, force data(ast)#externals)

    /// Every declaration outside the sources that the sources use, and every effect alias outside the sources.
    pub def externals(ast: Ast): List[External] = Map.valuesOf(force data(ast)#externals)

    /// The `Kind.X` / `Slot.Y` / `Attr.Z` and `Unnamed(` the rule file writes, with whether this stage has them and how many
    /// rows carry them (empty when the shim was not given the rule file).
    pub def ruleNames(ast: Ast): List[RuleName] = data(ast)#ruleNames
}
