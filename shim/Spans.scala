package flixlint

import ca.uwaterloo.flix.language.ast.{ResolvedAst, SourceLocation, Symbol, Type, TypeConstructor, TypedAst, UnkindedType}
import ca.uwaterloo.flix.language.ast.shared.SymUse

import java.io.PrintWriter
import java.nio.file.{Files, Path}

/** `--spans FILE`: the position of every name the sources write, one line per occurrence, for tools that rewrite code
  * (a refactoring tool looks a name up here and edits exactly those characters).
  *
  * Columns (tab separated): `kind file sl sc el ec sym owner extra`. Lines and columns are the compiler's: 1-based,
  * `ec` one past the last character, counted in UTF-16 code units. The first line is a `#` header with the format
  * version and the stage. Kinds:
  *
  *  - `def-decl` the name of a `def`; extra `pub` when public, `inst` for a def of an instance, `ann=a,b` its annotations
  *    (lower case: `test`, `skip`, ...), `ext=sl:sc:el:ec` the whole definition as the compiler places it;
  *    `def-use` a call or a reference to a def
  *  - `def-use`, `case-construct`, `case-pattern` have extra `sugar` when the span is not the written name but syntax that
  *    stands for it (`a :: b` is `List.Cons` over the whole expression, `a % b` is `Int32.remainder`)
  *  - `enum-decl` the name of an `enum`; `case-decl` a case of it (owner: the enum; extra `arity=N`, the number of its fields)
  *  - `case-construct` a case built in an expression; `case-pattern` a case matched in a pattern
  *  - `match-site` a `match` (the whole expression): extra `arms=N wild=N var=N guard=N enum=E`, where `wild` / `var` count
  *    the arms whose top-level pattern is `_` / a variable and `enum` is the enum of the first top-level case pattern
  *    (`-` when there is none); the typed stage adds `scrut=T`, the head of the scrutinee's type
  *  - `match-arm` one arm of a match (the span is the arm as the compiler places it; `sym` the case of a top-level case
  *    pattern): extra `match=L:C` (the match it is in), `pat=wild|var|tag|other`, `at=sl:sc:el:ec` the top-level pattern,
  *    `guard=0|1`, `full=1` for a case pattern whose fields are all `_` or variables (it takes every value of the case),
  *    and for `pat=var` `name=x uses=0|1` (whether the body or the guard reads the variable)
  *  - typed stage only: `label-select` (`e#x`, the span is `x`) and `label-update` (`{ x = v | e }`, the span is `x`),
  *    extra `recv=A via=V`: `A` the type alias the receiver `e` is declared with, `via` how it was known: `decl` (the
  *    declared type of a parameter, an ascribed `let`, an ascription or the return type of the def called), `row` (the
  *    receiver's closed record type has exactly the fields of one alias; `recv=A|B via=ambiguous` when several have them), or `recv=? via=open|none`
  *  - resolved stage only (the header says `adds=use,type-use,alias-decl`):
  *    - `use` a `use` declaration (owner: the module it is in; sym: what it brings in): extra `alias=x` the name it
  *      brings in and `what=def|enum|case|alias|module|effect|op|trait|sig|struct|other`
  *    - `type-use` an enum, a type alias or a struct named in a type (a signature, an ascription, a case's fields, an
  *      alias's body; owner: the def, enum, alias, effect or trait it is in): extra `what=enum|alias|struct`. The span
  *      is the name as written (`World.Scene` or, after a `use`, `Scene`)
  *    - `alias-decl` the name of a `type alias`
  *
  * `owner` is the top-level def the occurrence is in (lambdas and local defs count as their enclosing def).
  *
  * WhyNot: the spans are not facts. The rule engine loads every TSV it is given into Flix, and the spans are an
  * order of magnitude more rows than all facts together (75k on a 200-file project); they would slow every lint for
  * the sake of a tool that runs on demand. Nothing in `Names.flix` comes from here either.
  */
object Spans {
  /** Bumped when a column or a kind changes meaning, so that a cached index of an older shim is not reused. */
  val FormatVersion = 2

  /** Takes `--spans FILE` out of the arguments (the rest goes to the fact walker unchanged). */
  def split(argv: Array[String]): (Option[Path], Array[String]) = {
    val i = argv.indexOf("--spans")
    if (i < 0) (None, argv)
    else if (i + 1 >= argv.length) throw new Facts.UsageError("--spans needs a value")
    else (Some(java.nio.file.Paths.get(argv(i + 1))), argv.take(i) ++ argv.drop(i + 2))
  }

  private final case class Row(kind: String, file: String, sl: Int, sc: Int, el: Int, ec: Int, sym: String, owner: String, extra: String)

  private final class Out(stage: String, adds: String = "") {
    private val rows = scala.collection.mutable.LinkedHashMap.empty[(String, String, Int, Int, Int, Int, String), Row]

    /** WhyNot: an occurrence is kept once per (kind, place, symbol). The desugarer walks some expressions twice (a
      * partial application is a lambda around the call), and the second copy carries the same location.
      */
    def add(kind: String, sym: String, loc: SourceLocation, owner: String, extra: String = ""): Unit =
      Facts.sourceFile(loc).foreach { f =>
        val key = (kind, f, loc.startLine, loc.startCol, loc.endLine, loc.endCol, sym)
        if (!rows.contains(key)) rows(key) = Row(kind, f, loc.startLine, loc.startCol, loc.endLine, loc.endCol, sym, owner, extra)
      }

    def write(path: Path): Int = {
      Option(path.toAbsolutePath.getParent).foreach(Files.createDirectories(_))
      val sorted = rows.values.toVector.sortBy(r => (r.file, r.sl, r.sc, r.el, r.ec, r.kind, r.sym))
      val w = new PrintWriter(Files.newBufferedWriter(path))
      try {
        w.println(s"# flixlint-spans $FormatVersion stage=$stage columns=kind,file,sl,sc,el,ec,sym,owner,extra$adds")
        sorted.foreach(r => w.println(Seq(r.kind, r.file, r.sl, r.sc, r.el, r.ec, clean(r.sym), clean(r.owner), clean(r.extra)).mkString("\t")))
      } finally w.close()
      sorted.length
    }

    private def clean(s: String): String = s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')
  }

  import Facts.{field, hasField, symName, synthetic}

  private def isExpr(cls: String): Boolean = cls.contains("$Expr$")

  private def isPattern(cls: String): Boolean = cls.contains("$Pattern$")

  /** `arms=N wild=N var=N guard=N enum=E`, read off the rules of a match (both stages share these node names). */
  private def matchShape(rules: List[Any]): String = {
    val pats = rules.map(r => field[Any](r, "pat"))
    val wild = pats.count(_.getClass.getName.endsWith("$Pattern$Wild"))
    val vars = pats.count(_.getClass.getName.endsWith("$Pattern$Var"))
    val guards = rules.count(r => field[Option[Any]](r, "guard").nonEmpty)
    val enum0 = pats.collectFirst {
      case p: Product if p.productPrefix == "Tag" => symName(field[SymUse.CaseSymUse](p, "symUse").sym.enumSym)
    }.getOrElse("-")
    s"arms=${rules.length} wild=$wild var=$vars guard=$guards enum=$enum0"
  }

  /** The generic walk over a definition body. `hook` sees every node first and may add rows of its own. */
  private def walk(out: Out, node: Any, owner: String, parentCls: String, hook: (Product, String) => Unit): Unit = node match {
    case t: UnkindedType => typesIn(out, t, owner)
    case null | _: Type | _: SourceLocation | _: String | _: java.lang.Number | _: java.lang.Boolean => ()
    case u: SymUse.DefSymUse => out.add("def-use", symName(u.sym), u.loc, owner, sugar(u.loc, u.sym.name))
    case u: SymUse.CaseSymUse => out.add(if (isPattern(parentCls)) "case-pattern" else "case-construct", symName(u.sym), u.loc, owner, sugar(u.loc, u.sym.name))
    case _: Symbol => ()
    case p: Product =>
      val cls = p.getClass.getName
      hook(p, cls)
      p.productIterator.foreach(x => walk(out, x, owner, cls, hook))
    case xs: Iterable[_] => xs.foreach(x => walk(out, x, owner, parentCls, hook))
    case _ => ()
  }

  /** The enums, aliases and structs a type names (`type-use`). Only the resolved stage has these nodes: the typed
    * stage's types are inferred, and their locations are the expressions', not names the sources wrote.
    *
    * WhyNot: the body of an applied alias (`Alias.tpe`) is not walked. It is the alias already expanded, so its
    * names belong to the alias's declaration, not to this place.
    */
  private def typesIn(out: Out, node: Any, owner: String): Unit = node match {
    case t: UnkindedType.Enum => out.add("type-use", symName(t.sym), t.loc, owner, "what=enum")
    case t: UnkindedType.Struct => out.add("type-use", symName(t.sym), t.loc, owner, "what=struct")
    case t: UnkindedType.UnappliedAlias => out.add("type-use", symName(t.sym), t.loc, owner, "what=alias")
    case t: UnkindedType.Alias =>
      out.add("type-use", symName(t.symUse.sym), t.symUse.loc, owner, "what=alias")
      t.args.foreach(typesIn(out, _, owner))
    case null | _: Type | _: SourceLocation | _: String | _: java.lang.Number | _: java.lang.Boolean | _: Symbol => ()
    case p: Product => p.productIterator.foreach(typesIn(out, _, owner))
    case xs: Iterable[_] => xs.foreach(typesIn(out, _, owner))
    case _ => ()
  }

  private def symKind(sym: Symbol): String = sym match {
    case _: Symbol.DefnSym => "def"
    case _: Symbol.EnumSym => "enum"
    case _: Symbol.CaseSym => "case"
    case _: Symbol.TypeAliasSym => "alias"
    case _: Symbol.ModuleSym => "module"
    case _: Symbol.EffSym => "effect"
    case _: Symbol.OpSym => "op"
    case _: Symbol.TraitSym => "trait"
    case _: Symbol.SigSym => "sig"
    case _: Symbol.StructSym => "struct"
    case _ => "other"
  }

  /** `sugar` when the name is not what the sources wrote there: `a :: b` builds `List.Cons` and the span is the whole
    * expression, `a % b` calls `Int32.remainder`, `Vector#{..}` calls `Vector.toList`. A rewrite leaves these alone.
    */
  private def sugar(loc: SourceLocation, name: String): String =
    if (loc.startLine == loc.endLine && loc.text.forall(_.endsWith(name))) "" else "sugar" // a name never spans lines

  private def matchRow(out: Out, p: Product, owner: String, more: String): Unit = {
    val loc = field[SourceLocation](p, "loc")
    val rules = field[List[Any]](p, "rules")
    out.add("match-site", "", loc, owner, matchShape(rules) + more)
    rules.foreach(r => armRow(out, r, s"${loc.startLine}:${loc.startCol}", owner))
  }

  private def span(loc: SourceLocation): String = s"${loc.startLine}:${loc.startCol}:${loc.endLine}:${loc.endCol}"

  /** `pub inst ann=test ext=sl:sc:el:ec`. */
  private def declExtra(pub: Boolean, inst: Boolean, ann: ca.uwaterloo.flix.language.ast.shared.Annotations, loc: SourceLocation): String = {
    val anns = ann.annotations.map(a => a.getClass.getSimpleName.stripSuffix("$").toLowerCase)
    (Seq("pub").filter(_ => pub) ++ Seq("inst").filter(_ => inst) ++ (if (anns.isEmpty) Nil else Seq("ann=" + anns.mkString(","))) ++ Seq("ext=" + span(loc))).mkString(" ")
  }

  private def varSym(pat: Any): Symbol.VarSym =
    if (hasField(pat, "bnd")) field[Symbol.VarSym](field[Any](pat, "bnd"), "sym") else field[Symbol.VarSym](pat, "sym")

  /** Whether the expression reads the variable. */
  private def reads(node: Any, v: Symbol.VarSym): Boolean = node match {
    case null | _: Type | _: UnkindedType | _: SourceLocation | _: String | _: java.lang.Number | _: java.lang.Boolean | _: Symbol => false
    case p: Product if p.productPrefix == "Var" && p.getClass.getName.contains("$Expr$") => field[Symbol.VarSym](p, "sym") == v
    case p: Product => p.productIterator.exists(reads(_, v))
    case xs: Iterable[_] => xs.exists(reads(_, v))
    case _ => false
  }

  private def armRow(out: Out, rule: Any, matchAt: String, owner: String): Unit = {
    val pat = field[Any](rule, "pat")
    val cls = pat.getClass.getName
    val guard = field[Option[Any]](rule, "guard")
    val body = field[Any](rule, "exp")
    val g = if (guard.nonEmpty) 1 else 0
    val patLoc = field[SourceLocation](pat, "loc")
    def irrefutable(x: Any): Boolean = { val n = x.getClass.getName; n.endsWith("$Pattern$Wild") || n.endsWith("$Pattern$Var") }
    val (kind, sym, more) =
      if (cls.endsWith("$Pattern$Wild")) ("wild", "", "")
      else if (cls.endsWith("$Pattern$Var")) {
        val v = varSym(pat)
        val uses = if (reads(body, v) || guard.exists(reads(_, v))) 1 else 0
        ("var", "", s" name=${v.text} uses=$uses")
      } else pat match {
        case t: Product if t.productPrefix == "Tag" =>
          val full = if (field[List[Any]](t, "pats").forall(irrefutable)) 1 else 0
          ("tag", symName(field[SymUse.CaseSymUse](t, "symUse").sym), s" full=$full")
        case _ => ("other", "", "")
      }
    out.add("match-arm", sym, field[SourceLocation](rule, "loc"), owner, s"match=$matchAt pat=$kind at=${span(patLoc)} guard=$g$more")
  }

  def resolved(root: ResolvedAst.Root, path: Path): Int = {
    val out = new Out("resolved", " adds=use,type-use,alias-decl")
    val allDefs: Iterable[ResolvedAst.Declaration.Def] = root.defs.values ++ root.instances.values.flatMap(_.defs)
    val instDefs: Set[Any] = root.instances.values.flatMap(_.defs).toSet
    def insts(d: Any): Boolean = instDefs.contains(d)
    for (d <- allDefs if !synthetic(d)) {
      val fn = symName(d.sym)
      out.add("def-decl", fn, d.sym.loc, fn, declExtra(d.spec.mod.isPublic, insts(d), d.spec.ann, d.loc))
      typesIn(out, d.spec, fn)
      walk(out, d.exp, fn, "", (p, cls) => if (p.productPrefix == "Match" && isExpr(cls)) matchRow(out, p, fn, ""))
    }
    for ((sym, e) <- root.enums) {
      out.add("enum-decl", symName(sym), sym.loc, symName(sym))
      e.cases.foreach { c =>
        out.add("case-decl", symName(c.sym), c.sym.loc, symName(sym), s"arity=${c.tpes.length}")
        typesIn(out, c.tpes, symName(sym))
      }
    }
    for ((sym, a) <- root.typeAliases) {
      out.add("alias-decl", symName(sym), sym.loc, symName(sym))
      typesIn(out, a.tpe, symName(sym))
    }
    // An instance has no name of its own: its type is owned by `<the module it is in>.<the trait>`.
    for (i <- root.instances.values) typesIn(out, i.tpe, Facts.qname(i.ns.parts, i.symUse.sym.name))
    for ((sym, e) <- root.effects) typesIn(out, e.ops, symName(sym))
    for ((sym, t) <- root.traits) typesIn(out, t.sigs.values, symName(sym))
    for ((mod, u) <- root.uses.m.toList.flatMap { case (k, vs) => vs.map(k -> _) }) u match {
      case use: ca.uwaterloo.flix.language.ast.shared.UseOrImport.Use =>
        out.add("use", symName(use.sym), use.loc, mod.toString, s"alias=${use.alias.name} what=${symKind(use.sym)}")
      case _ => ()
    }
    out.write(path)
  }

  def typed(root: TypedAst.Root, path: Path): Int = {
    val out = new Out("typed")
    val receivers = new Receivers(root)
    val allDefs: Iterable[TypedAst.Def] = root.defs.values ++ root.instances.values.flatMap(_.defs)
    val instDefs: Set[Any] = root.instances.values.flatMap(_.defs).toSet
    for (d <- allDefs if !synthetic(d)) {
      val fn = symName(d.sym)
      out.add("def-decl", fn, d.sym.loc, fn, declExtra(d.spec.mod.isPublic, instDefs.contains(d), d.spec.ann, d.loc))
      d.spec.fparams.toList.foreach(receivers.declare)
      walk(out, d.exp, fn, "", (p, cls) => if (isExpr(cls)) p.productPrefix match {
        case "Match" => matchRow(out, p, fn, " scrut=" + Typed.headName(field[TypedAst.Expr](p, "exp").tpe))
        case "Let" => receivers.let(p)
        case "Lambda" => receivers.declare(field[TypedAst.FormalParam](p, "fparam"))
        case "LocalDef" => field[ca.uwaterloo.flix.util.collection.Nel[TypedAst.FormalParam]](p, "fparams").toList.foreach(receivers.declare)
        case "RecordSelect" =>
          val label = field[Any](p, "label")
          out.add("label-select", field[String](label, "name"), field[SourceLocation](label, "loc"), fn, receivers.of(field[TypedAst.Expr](p, "exp")))
        case "RecordExtend" =>
          // `{ x = v | e }` is `RecordExtend(x, v, RecordRestrict(x, e))`; a bare extension `{ +x = v | e }` is not an update.
          val label = field[Any](p, "label")
          field[Any](p, "exp2") match {
            case r: Product if r.productPrefix == "RecordRestrict" && field[String](field[Any](r, "label"), "name") == field[String](label, "name") =>
              out.add("label-update", field[String](label, "name"), field[SourceLocation](label, "loc"), fn, receivers.of(field[TypedAst.Expr](r, "exp")))
            case _ => ()
          }
        case _ => ()
      })
    }
    for ((sym, e) <- root.enums) {
      out.add("enum-decl", symName(sym), sym.loc, symName(sym))
      e.cases.foreach { case (cs, c) => out.add("case-decl", symName(cs), cs.loc, symName(sym), s"arity=${c.tpes.length}") }
    }
    out.write(path)
  }

  /** Which type alias a record receiver is declared with.
    *
    * WhyNot: the receiver's own type is not enough. Inference expands aliases, so `w#scene` on a `w: World` sees the
    * bare record; the alias survives only where a type was written (a parameter, an ascription, a def's return type),
    * so the declared types of the variables are tracked, and the record's closed field set is the fallback.
    */
  private final class Receivers(root: TypedAst.Root) {
    private val declared = scala.collection.mutable.HashMap.empty[Symbol.VarSym, Type]

    private val aliasFields: Map[String, Set[String]] = root.typeAliases.toList.flatMap { case (sym, a) =>
      closedLabels(unalias(a.tpe)).map(ls => symName(sym) -> ls)
    }.toMap

    private val byFields: Map[Set[String], List[String]] = aliasFields.toList.groupBy(_._2).map { case (k, v) => k -> v.map(_._1).sorted }

    def declare(fp: TypedAst.FormalParam): Unit = declared(fp.bnd.sym) = fp.tpe

    def let(p: Product): Unit = declaredType(field[TypedAst.Expr](p, "exp1")).foreach(t => declared(field[TypedAst.Binder](p, "bnd").sym) = t)

    private def declaredType(e: TypedAst.Expr): Option[Type] = e match {
      case TypedAst.Expr.Var(sym, _, _) => declared.get(sym)
      case a: TypedAst.Expr.Ascribe => a.expectedType.orElse(declaredType(a.exp))
      case a: TypedAst.Expr.ApplyDef => root.defs.get(a.symUse.sym).map(_.spec.retTpe)
      case _ => None
    }

    def of(recv: TypedAst.Expr): String = {
      val fromDecl = declaredType(recv).orElse(Some(recv.tpe)).collect { case Type.Alias(symUse, _, _, _) => symName(symUse.sym) }
      fromDecl match {
        case Some(a) => s"recv=$a via=decl"
        case None => closedLabels(recv.tpe) match {
          case None => if (isRecord(recv.tpe)) "recv=? via=open" else "recv=? via=none"
          case Some(ls) => byFields.getOrElse(ls, Nil) match {
            case List(a) => s"recv=$a via=row"
            case Nil => "recv=? via=none"
            case many => s"recv=${many.mkString("|")} via=ambiguous"
          }
        }
      }
    }

    private def unalias(t: Type): Type = t match {
      case Type.Alias(_, _, tpe, _) => unalias(tpe)
      case _ => t
    }

    private def isRecord(t: Type): Boolean = unalias(t) match {
      case Type.Apply(Type.Cst(TypeConstructor.Record, _), _, _) => true
      case _ => false
    }

    /** The labels of a closed record type; None for anything else (an open row, a non-record). */
    private def closedLabels(t: Type): Option[Set[String]] = unalias(t) match {
      case Type.Apply(Type.Cst(TypeConstructor.Record, _), row, _) => rowLabels(unalias(row), Set.empty)
      case _ => None
    }

    private def rowLabels(row: Type, acc: Set[String]): Option[Set[String]] = row match {
      case Type.Apply(Type.Apply(Type.Cst(TypeConstructor.RecordRowExtend(label), _), _, _), rest, _) => rowLabels(unalias(rest), acc + label.name)
      case Type.Cst(TypeConstructor.RecordRowEmpty, _) => Some(acc)
      case _ => None
    }
  }
}
