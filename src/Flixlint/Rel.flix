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

    /// Every table built so far.
    pub def tables(ast: Ast): List[Table] = List#{
        { name = "source_file", rows = Flixlint.Ast.files(ast) |> List.map(f -> f :: Nil) },
        { name = "def", rows = defRows(ast) },
        { name = "enum", rows = declRows(ast, Kind.Enum) },
        { name = "eff", rows = declRows(ast, Kind.Effect) },
        { name = "type_alias", rows = aliasRows(ast) },
        { name = "alias_type_all", rows = aliasTypeAllRows(ast) },
        { name = "eff_alias", rows = effAliasRows(ast) },
        { name = "effect_of", rows = effectOfRows(ast) },
        { name = "arg_type", rows = argTypeRows(ast, TypeView.Head) },
        { name = "arg_type_all", rows = argTypeRows(ast, TypeView.All) },
        { name = "arg_type_deep", rows = argTypeRows(ast, TypeView.Deep) },
        { name = "ret_type", rows = retTypeRows(ast, TypeView.Head) },
        { name = "ret_type_all", rows = retTypeRows(ast, TypeView.All) },
        { name = "ret_type_deep", rows = retTypeRows(ast, TypeView.Deep) },
        { name = "case_type", rows = caseTypeRows(ast, TypeView.Head) },
        { name = "case_type_all", rows = caseTypeRows(ast, TypeView.All) },
        { name = "case_type_deep", rows = caseTypeRows(ast, TypeView.Deep) }
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
                |> List.map(n -> name :: n :: Nil)
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

    // ---- writing ----

    /// The tables as the old facts' TSV files (`<dir>/<name>.tsv`, one row per line, columns by tabs).
    pub def dump(dir: String, ast: Ast): Unit \ IO =
        discard (new File(dir)).mkdirs();
        tables(ast) |> List.forEach(t -> {
            let text = t#rows |> List.map(r -> String.intercalate("\t", List.map(clean, r)) + "\n") |> String.intercalate("");
            discard Files.write((new File("${dir}/${t#name}.tsv")).toPath(), text.getBytes())
        })

    /// A column as the old facts write it (a tab or a line break becomes a space).
    def clean(s: String): String = s |> String.map(c -> if (c == '\t' or c == '\n' or c == '\r') ' ' else c)
}
