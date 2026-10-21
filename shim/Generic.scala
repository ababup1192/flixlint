package flixlint

import ca.uwaterloo.flix.api.Flix
import ca.uwaterloo.flix.language.ast.shared.SecurityContext
import ca.uwaterloo.flix.language.ast.{ResolvedAst, SourceLocation, Symbol, Type, TypeConstructor, TypedAst, UnkindedType}
import ca.uwaterloo.flix.util.{LibLevel, Options}

import java.io.{BufferedOutputStream, DataOutputStream}
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path}

/** The AST itself as generic relations, with no knowledge of what a rule wants (docs/design-generic.md, chapter 1).
  *
  * Usage: Generic --out DIR [--stage typed|resolved] [--pkg FPKG]... [--jar JAR]... [--project-root DIR] SRC...
  * (the arguments of `Facts`, `--names-out` unused).
  *
  * One node per AST node of the project's own declarations (defs, instance defs, enums, type aliases, effects), in
  * walk order: a parent before its children, the children in field order. Node `i` is row `i` of every column.
  *
  *  - `kind.i32`   the kind of each node, as its number in `Flixlint.AstKinds` (its position in `kinds.txt`)
  *  - `parent.i32` the id of each node's parent, -1 on a declaration
  *  - `kinds.txt`  every kind name of the `ast_schema` (AstSchema), one per line, sorted. A kind is the compiler's class
  *                 name without the stage prefix (`Expr.ApplyDef`, `Pattern.Tag`, `Type.Apply`, `Def`)
  *  - `schema_hash.txt` the hash of the `ast_schema` the numbers come from (`Flixlint.AstKinds.schemaHash`)
  *
  * A column is its Int32 values in big-endian order (Java's `DataOutputStream` and `ByteBuffer`) and nothing else; the row count is the file size / 4.
  *
  * WhyNot: the walker does not pattern match on the AST case classes; it reads `productElementNames`, so a compiler
  * upgrade that adds or renames a node changes the rows, not this file. The handful of leaf types it reads
  * (symbols, constants, type constructors) are the only places that name the compiler's classes.
  * WhyNot: not an option of `Facts`. The generic relations replace the per-purpose facts one rule at a time, and until
  * then the two walks run as separate commands, so the fact walker and its timing stay as they are.
  */
object Generic {

  def main(argv: Array[String]): Unit = {
    val code =
      try run(argv)
      catch {
        case e: Facts.UsageError =>
          System.err.println(s"flixlint: ${e.getMessage}")
          4
        case e: Throwable =>
          System.err.println(s"flixlint: the generic walker failed: ${e.getClass.getName}: ${e.getMessage}")
          e.printStackTrace()
          4
      }
    if (code != 0) sys.exit(code)
  }

  /** Writes the columns; 0, or 3 when the sources do not compile (the errors are on stderr). */
  def run(argv: Array[String]): Int = {
    val args = Facts.parseArgs(argv)
    val t0 = System.nanoTime()
    val deps =
      if (args.pkgs.nonEmpty || args.jars.nonEmpty) Facts.Deps.ofPaths(args.pkgs, args.jars, args.projectRoot, args.srcs)
      else Facts.Deps.ofProject(args.projectRoot, args.srcs)
    val flix = new Flix(deps.pkgs, deps.jars, deps.mounts)
    flix.setOptions(Options.Default.copy(lib = LibLevel.All, progress = false))
    args.srcs.flatMap(Facts.listFlix).foreach(f => flix.addFile(f, SecurityContext.Unrestricted))
    val t1 = System.nanoTime()
    val (nErrors, counts) = args.stage match {
      case "typed" =>
        val (optRoot, errors) = flix.check()
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(optRoot)))
        (errors.length, optRoot.map(typed(_, args.out)))
      case _ =>
        val (root, errors) = Resolved.run(flix)
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(None)))
        (errors.length, Some(resolved(root, args.out)))
    }
    val t2 = System.nanoTime()
    counts match {
      case Some(Counts(n, w)) =>
        System.err.println(f"flixlint generic: stage=${args.stage} nodes=$n compile=${(t2 - t1 - w) / 1e9}%.1fs walk+write=${w / 1e9}%.2fs total=${(t2 - t0) / 1e9}%.1fs")
      case None => System.err.println("flixlint: no typed AST (compilation errors above)")
    }
    if (nErrors > 0) 3 else 0
  }

  /** How many nodes the walk wrote, and how long the walk and the write took (ns). */
  final case class Counts(nodes: Int, ns: Long)

  /** The columns, held in memory until the walk ends (the kind numbers need every kind name first). */
  private final class Out {
    val kinds = new scala.collection.mutable.ArrayBuffer[String](1 << 16)
    val parents = new scala.collection.mutable.ArrayBuffer[Int](1 << 16)
    def next: Int = kinds.length

    def write(dir: Path): Unit = {
      Files.createDirectories(dir)
      val unknown = kinds.distinct.filterNot(AstSchema.kindNumbers.contains)
      // WhyNot: not written as a new number. A kind the schema does not have would make the numbers of the columns and of
      // AstKinds.flix name different things; it means the schema walk (AstSchema) misses a field the walker follows.
      if (unknown.nonEmpty) throw new IllegalStateException(s"kinds not in the ast_schema: ${unknown.sorted.mkString(", ")}")
      Files.write(dir.resolve("kinds.txt"), AstSchema.kindNames.mkString("", "\n", "\n").getBytes(StandardCharsets.UTF_8))
      column(dir.resolve("kind.i32"), kinds.iterator.map(AstSchema.kindNumbers))
      Files.write(dir.resolve("schema_hash.txt"), (AstSchema.hashOf(AstSchema.schemaText) + "\n").getBytes(StandardCharsets.UTF_8))
      column(dir.resolve("parent.i32"), parents.iterator)
    }

    private def column(file: Path, xs: Iterator[Int]): Unit = {
      val out = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(file), 1 << 16))
      try xs.foreach(x => out.writeInt(x))
      finally out.close()
    }
  }

  /** A position: line, col, endLine, endCol, synthetic. */
  private final case class Pos(l: Int, c: Int, el: Int, ec: Int, syn: Int)

  private def posOf(loc: SourceLocation): Pos = Pos(loc.startLine, loc.startCol, loc.endLine, loc.endCol, if (loc.isSynthetic) 1 else 0)

  private def locOf(p: Any): Option[SourceLocation] =
    p.getClass.getMethods.find(m => m.getName == "loc" && m.getParameterCount == 0 && classOf[SourceLocation].isAssignableFrom(m.getReturnType))
      .map(_.invoke(p).asInstanceOf[SourceLocation]).filter(l => l != null && l.startLine > 0)

  private def isSkipped(v: Any): Boolean = AstSchema.isSkippedClass(v.getClass)

  private def isLeaf(p: Product): Boolean = AstSchema.isLeafClass(p.getClass)

  // WhyNot: leaves and types are not written yet. Only the two columns the load is measured on are (design 3, step 1);
  // the walk still visits every field, so the node count is the full schema's.
  private final class Walker(out: Out) {
    /** A node and its subtree. */
    def node(p: Product, parent: Int, inherited: Pos, inBody: Boolean, top: Boolean): Int = {
      val id = out.next
      out.kinds += AstSchema.kindOfClass(p.getClass)
      out.parents += parent
      val pos = locOf(p).map(posOf).getOrElse(inherited)
      // WhyNot: the expansion an alias carries (`Alias.tpe`) is not walked. Every use of `World` would repeat the
      // whole record it stands for (5.7M nodes on the game instead of 0.4M); the alias declaration is a root of its
      // own, and the library opens an alias by its name.
      val alias = p.productPrefix == "Alias" && (p.isInstanceOf[Type] || p.isInstanceOf[UnkindedType])
      p.productElementNames.zip(p.productIterator).foreach { case (name, v) =>
        if (name != "loc" && !(alias && name == "tpe")) value(v, id, pos, name, inBody || (top && name == "exp"))
      }
      id
    }

    private def value(v: Any, owner: Int, pos: Pos, slot: String, inBody: Boolean): Unit = v match {
      case null | _: SourceLocation => ()
      case x if isSkipped(x) => ()
      case _: Type | _: UnkindedType if inBody => ()
      case _: String | _: java.lang.Number | _: java.lang.Boolean | _: java.lang.Character | _: Symbol | _: TypeConstructor => ()
      case p: Product if isLeaf(p) => ()
      case o: Option[_] => o.foreach(x => value(x, owner, pos, slot, inBody))
      case n: Product if n.getClass.getName.endsWith("collection.Nel") =>
        (Facts.field[Any](n, "head") :: Facts.field[List[Any]](n, "tail")).foreach(x => value(x, owner, pos, slot, inBody))
      case m: scala.collection.Map[_, _] => m.values.foreach(x => value(x, owner, pos, slot, inBody))
      case xs: Iterable[_] => xs.foreach(x => value(x, owner, pos, slot, inBody))
      case p: Product if p.productArity == 0 => ()
      case p: Product => node(p, owner, pos, inBody, top = false)
      case _ => ()
    }
  }

  private def emit(dir: Path, roots: Iterable[(Product, String)]): Counts = {
    val t0 = System.nanoTime()
    val out = new Out
    val w = new Walker(out)
    roots.foreach { case (p, _) => w.node(p, -1, Pos(0, 0, 0, 0, 0), inBody = false, top = true) }
    out.write(dir)
    Counts(out.next, System.nanoTime() - t0)
  }

  import Facts.{sourceFile, synthetic}

  def typed(root: TypedAst.Root, dir: Path): Counts = {
    val defs = (root.defs.values ++ root.instances.values.flatMap(_.defs)).filterNot(synthetic).flatMap(d => sourceFile(d.loc).map(f => (d: Product, f)))
    val enums = root.enums.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    val aliases = root.typeAliases.values.flatMap(a => sourceFile(a.loc).map(f => (a: Product, f)))
    val effects = root.effects.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    emit(dir, (defs ++ enums ++ aliases ++ effects).toList.sortBy(r => (r._2, locOf(r._1).map(_.startLine).getOrElse(0))))
  }

  def resolved(root: ResolvedAst.Root, dir: Path): Counts = {
    val defs = (root.defs.values ++ root.instances.values.flatMap(_.defs)).filterNot(synthetic).flatMap(d => sourceFile(d.loc).map(f => (d: Product, f)))
    val enums = root.enums.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    val aliases = root.typeAliases.values.flatMap(a => sourceFile(a.loc).map(f => (a: Product, f)))
    val effects = root.effects.values.flatMap(e => sourceFile(e.loc).map(f => (e: Product, f)))
    emit(dir, (defs ++ enums ++ aliases ++ effects).toList.sortBy(r => (r._2, locOf(r._1).map(_.startLine).getOrElse(0))))
  }
}
