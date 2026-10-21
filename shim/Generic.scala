package flixlint

import ca.uwaterloo.flix.language.ast.{ResolvedAst, SourceLocation, Symbol, Type, TypeConstructor, TypedAst, UnkindedType}

import java.io.{BufferedWriter, PrintWriter}
import java.nio.file.{Files, Path}

/** `--generic DIR` (spike): the AST itself as three relations, with no knowledge of what a rule wants.
  *
  *  - `node.tsv`   `id kind parent slot index root line col endLine endCol synthetic file`
  *    one row per AST node of the project's own declarations (defs, enums, type aliases, effects). `kind` is the
  *    compiler's class name without the stage prefix (`Expr.ApplyDef`, `Pattern.Tag`, `Type.Apply`, `Def`); `slot` and
  *    `index` are the field of the parent the node sits in (`exps`, 1); `root` is the declaration the node is in; `file`
  *    is written on the roots only. A node without a location takes its parent's.
  *  - `node_attr.tsv` `id name value` every leaf field of a node: a symbol (`symUse` -> `List.map`, a variable
  *    `sym` -> `x#123`), a string, a number, a constant (`cst` -> `Str`, `cst.lit` -> the text), an operator (`sop` ->
  *    `And`), a type constructor (`tc` -> `Int32`, `tc.kind` -> `Effect`), a label. `<name>.line` when the leaf's own
  *    line is not the node's.
  *  - `node_type.tsv` `id slot head` (inside a body only) the head of the type in the field `slot` of a node: at the
  *    typed stage `tpe` of every expression and pattern (`Bool`); at the resolved stage only the types that were
  *    written (ascriptions, annotated parameters). Declared types (signatures, case fields, aliases) are nodes instead.
  *
  * WhyNot: the walker does not pattern match on the AST case classes; it reads `productElementNames`, so a compiler
  * upgrade that adds or renames a node changes the rows, not this file. The handful of leaf types it prints
  * (symbols, constants, type constructors) are the only places that name the compiler's classes.
  */
object Generic {

  def split(argv: Array[String]): (Option[Path], Array[String]) = {
    val i = argv.indexOf("--generic")
    if (i < 0) (None, argv)
    else if (i + 1 >= argv.length) throw new Facts.UsageError("--generic needs a value")
    else (Some(java.nio.file.Paths.get(argv(i + 1))), argv.take(i) ++ argv.drop(i + 2))
  }

  private final class Out(dir: Path) {
    Files.createDirectories(dir)
    private def open(name: String) = new PrintWriter(new BufferedWriter(Files.newBufferedWriter(dir.resolve(name)), 1 << 16))
    val nodes: PrintWriter = open("node.tsv")
    val attrs: PrintWriter = open("node_attr.tsv")
    val types: PrintWriter = open("node_type.tsv")
    var next = 0
    var nNodes, nAttrs, nTypes = 0
    def clean(s: String): String = s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')
    def close(): Unit = { nodes.close(); attrs.close(); types.close() }
  }

  /** A position: line, col, endLine, endCol, synthetic. */
  private final case class Pos(l: Int, c: Int, el: Int, ec: Int, syn: Int)

  private def posOf(loc: SourceLocation): Pos = Pos(loc.startLine, loc.startCol, loc.endLine, loc.endCol, if (loc.isSynthetic) 1 else 0)

  private def locOf(p: Any): Option[SourceLocation] =
    p.getClass.getMethods.find(m => m.getName == "loc" && m.getParameterCount == 0 && classOf[SourceLocation].isAssignableFrom(m.getReturnType))
      .map(_.invoke(p).asInstanceOf[SourceLocation]).filter(l => l != null && l.startLine > 0)

  /** `ca.uwaterloo.flix.language.ast.TypedAst$Expr$ApplyDef` -> `Expr.ApplyDef`; the stage prefix and `Declaration.` go. */
  def kindOf(p: Product): String = {
    val n = p.getClass.getName
    val i = n.indexOf("language.ast.")
    val tail = if (i < 0) p.productPrefix else n.substring(i + "language.ast.".length)
    tail.stripPrefix("TypedAst$").stripPrefix("ResolvedAst$").stripPrefix("Declaration$").stripPrefix("shared.").stripSuffix("$").replace('$', '.')
  }

  private def isSkipped(v: Any): Boolean = {
    val n = v.getClass.getName
    n.endsWith("shared.Doc") || n.endsWith("ast.Scheme") || n.contains("ast.Kind") || n.contains("shared.SecurityContext")
  }

  private def symText(s: Symbol): String = s match {
    case v: Symbol.VarSym => s"${v.text}#${v.id}"
    case _ => Facts.symName(s)
  }

  private def tcName(tc: TypeConstructor): String = tc match {
    case TypeConstructor.Enum(sym, _) => Facts.symName(sym)
    case TypeConstructor.Struct(sym, _) => Facts.symName(sym)
    case TypeConstructor.Effect(sym, _) => Facts.symName(sym)
    case other => other.toString
  }

  private def headOf(t: Any): String = t match {
    case t: Type => Typed.headName(t)
    case t: UnkindedType => Resolved.headName(t)
    case _ => "?"
  }

  private final class Walker(out: Out) {
    private def attr(id: Int, name: String, value: String): Unit = {
      out.attrs.print(id); out.attrs.print('\t'); out.attrs.print(name); out.attrs.print('\t'); out.attrs.println(out.clean(value))
      out.nAttrs += 1
    }

    private def lineAttr(id: Int, pos: Pos, name: String, loc: SourceLocation): Unit =
      if (loc != null && loc.startLine > 0 && loc.startLine != pos.l) attr(id, name + ".line", loc.startLine.toString)

    /** A node and its subtree. */
    def node(p: Product, parent: Int, slot: String, index: Int, root: Int, inherited: Pos, inBody: Boolean, file: String): Int = {
      val id = out.next
      out.next += 1
      val r = if (root < 0) id else root
      val pos = locOf(p).map(posOf).getOrElse(inherited)
      val w = out.nodes
      w.print(id); w.print('\t'); w.print(kindOf(p)); w.print('\t'); w.print(parent); w.print('\t'); w.print(slot); w.print('\t')
      w.print(index); w.print('\t'); w.print(r); w.print('\t'); w.print(pos.l); w.print('\t'); w.print(pos.c); w.print('\t')
      w.print(pos.el); w.print('\t'); w.print(pos.ec); w.print('\t'); w.print(pos.syn); w.print('\t'); w.println(file)
      out.nNodes += 1
      // WhyNot: the expansion an alias carries (`Alias.tpe`) is not walked. Every use of `World` would repeat the
      // whole record it stands for (5.7M nodes on the game instead of 0.4M); the alias declaration is a root of its
      // own, and the library opens an alias by its name.
      val alias = p.productPrefix == "Alias" && (p.isInstanceOf[Type] || p.isInstanceOf[UnkindedType])
      p.productElementNames.zip(p.productIterator).foreach { case (name, v) =>
        if (name != "loc" && !(alias && name == "tpe")) value(v, id, pos, name, 0, r, inBody || (root < 0 && name == "exp"))
      }
      id
    }

    private def value(v: Any, owner: Int, pos: Pos, slot: String, index: Int, root: Int, inBody: Boolean): Unit = v match {
      case null | _: SourceLocation => ()
      case x if isSkipped(x) => ()
      case t @ (_: Type | _: UnkindedType) if inBody =>
        if (!slot.toLowerCase.contains("eff")) {
          val w = out.types
          w.print(owner); w.print('\t'); w.print(slot); w.print('\t'); w.println(out.clean(headOf(t)))
          out.nTypes += 1
        }
      case s: String => attr(owner, slot, s)
      case n: java.lang.Number => attr(owner, slot, n.toString)
      case b: java.lang.Boolean => attr(owner, slot, b.toString)
      case c: java.lang.Character => attr(owner, slot, c.toString)
      case s: Symbol =>
        attr(owner, slot, symText(s))
        s match { case _: Symbol.VarSym => (); case _ => locOf(s).foreach(lineAttr(owner, pos, slot, _)) }
      case u: Product if u.getClass.getName.contains("SymUse$") =>
        attr(owner, slot, symText(Facts.field[Symbol](u, "sym")))
        locOf(u).foreach(lineAttr(owner, pos, slot, _))
      case tc: TypeConstructor =>
        attr(owner, slot, tcName(tc))
        attr(owner, slot + ".kind", tc.getClass.getSimpleName.stripSuffix("$"))
      case c: Product if c.getClass.getName.contains("Constant$") =>
        attr(owner, slot, c.productPrefix)
        if (c.productArity == 1) attr(owner, slot + ".lit", String.valueOf(c.productElement(0)))
      case n: Product if n.getClass.getName.contains("ast.Name$") =>
        attr(owner, slot, scala.util.Try(Facts.field[Any](n, "name").toString).getOrElse(n.toString))
      case o: Option[_] => o.foreach(x => value(x, owner, pos, slot, index, root, inBody))
      case n: Product if n.getClass.getName.endsWith("collection.Nel") =>
        val xs = Facts.field[Any](n, "head") :: Facts.field[List[Any]](n, "tail")
        xs.zipWithIndex.foreach { case (x, i) => value(x, owner, pos, slot, i, root, inBody) }
      case m: scala.collection.Map[_, _] => m.values.zipWithIndex.foreach { case (x, i) => value(x, owner, pos, slot, i, root, inBody) }
      case xs: Iterable[_] => xs.zipWithIndex.foreach { case (x, i) => value(x, owner, pos, slot, i, root, inBody) }
      case p: Product if p.productArity == 0 => attr(owner, slot, p.toString)
      case p: Product => node(p, owner, slot, index, root, pos, inBody, "")
      case other => attr(owner, slot, other.toString)
    }
  }

  private def emit(dir: Path, roots: Iterable[(Product, String)]): (Int, Int, Int) = {
    val out = new Out(dir)
    val w = new Walker(out)
    try roots.foreach { case (p, file) => w.node(p, -1, "", 0, -1, Pos(0, 0, 0, 0, 0), inBody = false, file) }
    finally out.close()
    (out.nNodes, out.nAttrs, out.nTypes)
  }

  import Facts.{sourceFile, synthetic}

  def typed(root: TypedAst.Root, dir: Path): (Int, Int, Int) = {
    val defs = (root.defs.values ++ root.instances.values.flatMap(_.defs)).filterNot(synthetic).flatMap(d => sourceFile(d.loc).map(f => (d: Product, f)))
    val enums = root.enums.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    val aliases = root.typeAliases.values.flatMap(a => sourceFile(a.loc).map(f => (a: Product, f)))
    val effects = root.effects.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    emit(dir, (defs ++ enums ++ aliases ++ effects).toList.sortBy(r => (r._2, locOf(r._1).map(_.startLine).getOrElse(0))))
  }

  def resolved(root: ResolvedAst.Root, dir: Path): (Int, Int, Int) = {
    val defs = (root.defs.values ++ root.instances.values.flatMap(_.defs)).filterNot(synthetic).flatMap(d => sourceFile(d.loc).map(f => (d: Product, f)))
    val enums = root.enums.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    val aliases = root.typeAliases.values.flatMap(a => sourceFile(a.loc).map(f => (a: Product, f)))
    val effects = root.effects.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    emit(dir, (defs ++ enums ++ aliases ++ effects).toList.sortBy(r => (r._2, locOf(r._1).map(_.startLine).getOrElse(0))))
  }
}
