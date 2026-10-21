package flixlint

import ca.uwaterloo.flix.language.ast.shared.SecurityContext
import ca.uwaterloo.flix.language.ast.{SourceLocation, Symbol, Type, TypeConstructor, UnkindedType}

import java.io.{BufferedOutputStream, DataOutputStream, PrintWriter}
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths}
import scala.collection.mutable
import scala.jdk.CollectionConverters._

/** The AST itself as generic relations, with no knowledge of what a rule wants (docs/design-generic.md, chapter 1).
  *
  * Usage: Generic --out DIR [--facts-tsv DIR] [--node-ratio N] [--rules FILE] [--stage typed|resolved] [--pkg FPKG]... [--jar JAR]...
  *                [--project-root DIR] SRC...
  * (the arguments of `Facts`, `--names-out` unused).
  *
  * Every file under `--out` is a column of big-endian Int32 values (`<table>.<column>.i32`, the row count is the file
  * size / 4) or a text file of one value per line. Row `i` of the columns of a table is its row `i`.
  *
  *  - `node.*` one row per AST node of the project's own declarations (defs, instance defs, enums, type aliases,
  *    effects), in walk order: a parent before its children, the children in field order.
  *    `kind` (`Flixlint.AstKinds.Kind` number), `parent` (-1 on a declaration), `slot` (`Slot` number of the field of the
  *    parent, -1 on a declaration), `index` (the position in that field when it is a list), `root` (the declaration),
  *    `line` `col` `endLine` `endCol` (a node without a location has its parent's), `synthetic` (1 when the compiler made
  *    it), `type` and `effect` (the type id of an expression's or a pattern's `tpe` and an expression's `eff`, -1 if none)
  *  - `attr.*` the leaves of the nodes, grouped by node and in field order: `node`, `name` (`Attr` number), `value`
  *    (string id, -1 for a type), `type` (type id, -1 for a value), `line` (the value's own line when it is not the
  *    node's, else -1: the name of a call)
  *  - `type.*` the types, shared: one row per distinct type (1.3). `form` (`Generic.Form` number), `name` (string id or
  *    -1), `argStart` (row count + 1 offsets into `type.args`), `args` (type ids), `expands` (an alias's expansion, -1)
  *  - `decl.*` one row per declaration: `node`, `file` (line of `files.txt`)
  *  - `ext.*` the declarations of packages, the standard library and Java that the sources use (1.4): `sym` (string
  *    id), `kind` (`Generic.ExtKind` number), `type` (the signature as a function type, an alias's expansion, -1),
  *    `memberStart` / `members` (string ids: the effects an effect alias stands for). Every effect alias outside the
  *    sources is listed, used or not
  *  - `strings.txt` the strings, one per line, with `\` `\n` `\r` written `\\` `\n` `\r`
  *  - `files.txt` every file the walk was given; `kinds.txt` every kind name of the `ast_schema`
  *  - `meta.txt` `key=value`: `format`, `stage`, `flixVersion`, `schemaHash`, and `rows.<table>` / `bytes`
  *  - `rule_names.tsv` with `--rules FILE`: each `Kind.X` / `Slot.Y` / `Attr.Z` and `Unnamed(` the rule file writes, `file line
  *    table name inStage count` (design 1.5: the engine says which of them this stage lacks or these sources never have)
  *
  * `--facts-tsv DIR` also writes the same rows as TSV with the numbers turned back into names, for reading.
  *
  * The walk stops with exit 4 when it grows past `--node-ratio` (20) nodes per source line or 200MB, naming the table
  * and the declaration with the most nodes: the walker follows every field it finds, so a field a compiler upgrade adds
  * could grow it without bound.
  *
  * WhyNot: the walker does not pattern match on the AST case classes; it reads `productElementNames`, so a compiler
  * upgrade that adds or renames a node changes the rows, not this file. The leaves (symbols, constants, type
  * constructors, names, Java class descriptors) and the types are the only places that name the compiler's classes.
  * WhyNot: not an option of `Facts`. The generic relations replace the per-purpose facts one rule at a time, and until
  * then the two walks run as separate commands, so the fact walker and its timing stay as they are.
  */
object Generic {

  val Format = 1

  /** The forms of a type, a name of flixlint's that does not depend on the stage (`Type.Cst` and `UnkindedType.Cst` are both `Cst`). */
  val Forms: Vector[String] = Vector("Cst", "Apply", "Alias", "Var", "Arrow", "Record", "RecordRow", "Schema", "Effect", "EffUnion", "Other")
  private val form: Map[String, Int] = Forms.zipWithIndex.toMap

  /** The kinds of an external declaration. */
  val ExtKinds: Vector[String] = Vector("def", "sig", "op", "enum", "case", "struct", "alias", "effect", "java")
  private val extKindNumber: Map[String, Int] = ExtKinds.zipWithIndex.toMap

  final class LimitError(msg: String) extends RuntimeException(msg)

  def main(argv: Array[String]): Unit = {
    val code =
      try run(argv)
      catch {
        case e: Facts.UsageError =>
          System.err.println(s"flixlint: ${e.getMessage}")
          4
        case e: LimitError =>
          System.err.println(s"flixlint: ${e.getMessage}")
          4
        case e: Throwable =>
          System.err.println(s"flixlint: the generic walker failed: ${e.getClass.getName}: ${e.getMessage}")
          e.printStackTrace()
          4
      }
    if (code != 0) sys.exit(code)
  }

  /** `--name VALUE` taken out of the arguments. */
  private def option(argv: Array[String], name: String): (Option[String], Array[String]) = {
    val i = argv.indexOf(name)
    if (i < 0) (None, argv)
    else if (i + 1 >= argv.length) throw new Facts.UsageError(s"$name needs a value")
    else (Some(argv(i + 1)), argv.take(i) ++ argv.drop(i + 2))
  }

  /** Writes the relations; 0, or 3 when the sources do not compile (the errors are on stderr). */
  def run(argv0: Array[String]): Int = {
    val (tsv, argv1) = option(argv0, "--facts-tsv")
    val (ratio, argv2) = option(argv1, "--node-ratio")
    val (rules, argv) = option(argv2, "--rules")
    val args = Facts.parseArgs(argv)
    val nodeRatio = ratio.map(r => scala.util.Try(r.toInt).getOrElse(throw new Facts.UsageError(s"--node-ratio $r is not a number"))).getOrElse(20)
    val t0 = System.nanoTime()
    val flix = Facts.compiler(Facts.depsOf(args))
    val files = args.srcs.flatMap(Facts.listFlix)
    files.foreach(f => flix.addFile(f, SecurityContext.Unrestricted))
    val t1 = System.nanoTime()
    val (nErrors, root) = args.stage match {
      case "typed" =>
        val (optRoot, errors) = flix.check()
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(optRoot)))
        (errors.length, optRoot)
      case _ =>
        val (root, errors) = Resolved.run(flix)
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(None)))
        (errors.length, Some(root))
    }
    val t2 = System.nanoTime()
    root match {
      case Some(r) =>
        val out = emitTo(r.asInstanceOf[Product], args.stage, files, args.out, rules.map(Paths.get(_)), nodeRatio)
        tsv.foreach(d => out.writeTsv(Paths.get(d)))
        val t3 = System.nanoTime()
        System.err.println(f"flixlint generic: stage=${args.stage} ${out.counts.map { case (k, v) => s"$k=$v" }.mkString(" ")} compile=${(t2 - t1) / 1e9}%.1fs walk+write=${(t3 - t2) / 1e9}%.2fs (walk=${out.walkNs / 1e9}%.2fs cpu=${out.walkCpuNs / 1e9}%.2fs external=${out.extNs / 1e9}%.2fs write=${out.writeNs / 1e9}%.2fs) total=${(t3 - t0) / 1e9}%.1fs")
      case None => System.err.println("flixlint: no typed AST (compilation errors above)")
    }
    if (nErrors > 0) 3 else 0
  }

  final case class Limits(nodeRatio: Int, sourceLines: Long, maxBytes: Long)

  /** Walks `root` and writes its generic relations into `dir` (what was there goes first, so that a run that stops
    * leaves none behind), with the names `rules` writes; the tables written. `Facts.write` calls it with `<facts>/generic`.
    */
  def emitTo(root: Product, stage: String, files: List[Path], dir: Path, rules: Option[Path], nodeRatio: Int = 20): Out = {
    clear(dir)
    // The stream is closed: on the resident server one JVM runs this on every lint, and an unclosed one keeps the file open.
    val limits = Limits(nodeRatio, files.map(f => { val ls = Files.lines(f); try ls.count() finally ls.close() }).sum, 200L * 1000 * 1000)
    val out = emit(root, stage, files.map(_.toString), limits)
    val tw = System.nanoTime()
    out.write(dir)
    writeRuleNames(dir, rules.map(ruleNames(_, out)).getOrElse(Nil))
    out.writeNs = System.nanoTime() - tw
    out
  }

  /** Removes the files of `dir` (the relations are files only; a directory in it is left alone). */
  def clear(dir: Path): Unit =
    if (Files.isDirectory(dir)) {
      val listing = Files.list(dir)
      try listing.iterator().asScala.filter(Files.isRegularFile(_)).foreach(Files.delete) finally listing.close()
    }

  // ---- the tables, held in memory until the walk ends ----

  /** A growable column of Int32. */
  final class IntBuf {
    private var a = new Array[Int](1 << 12)
    var size = 0
    def +=(x: Int): Unit = { if (size == a.length) a = java.util.Arrays.copyOf(a, size * 2); a(size) = x; size += 1 }
    def apply(i: Int): Int = a(i)
    def update(i: Int, x: Int): Unit = a(i) = x
    def toArray: Array[Int] = java.util.Arrays.copyOf(a, size)
  }

  final class Strings {
    private val ids = mutable.HashMap.empty[String, Int]
    val all = mutable.ArrayBuffer.empty[String]
    /** The UTF-16 length of all the strings, each with its line end: the size of `strings.txt`, near enough. */
    var chars = 0L
    def id(s: String): Int = ids.getOrElseUpdate(s, { all += s; chars += s.length + 1; all.length - 1 })
  }

  /** A field of a product by name, through `productElement` (the position of each name is found once per class).
    * WhyNot: not `Facts.field`. That calls the accessor by reflection, which is the larger part of the walk when every
    * node's location and every type's parts are read.
    */
  private object Elem {
    private val positions = new java.util.HashMap[Class[_], Map[String, Int]]()
    def get[A](p: Any, name: String): A = {
      val q = p.asInstanceOf[Product]
      var m = positions.get(q.getClass)
      if (m == null) { m = q.productElementNames.zipWithIndex.toMap; positions.put(q.getClass, m) }
      q.productElement(m(name)).asInstanceOf[A]
    }
    def has(p: Any, name: String): Boolean = p match {
      case q: Product =>
        var m = positions.get(q.getClass)
        if (m == null) { m = q.productElementNames.zipWithIndex.toMap; positions.put(q.getClass, m) }
        m.contains(name)
      case _ => false
    }
  }

  /** The key of a type row; its hash is worked out once. */
  private final class Key(val form: Int, val name: Int, val args: Array[Int], val exp: Int) {
    override val hashCode: Int = ((form * 31 + name) * 31 + java.util.Arrays.hashCode(args)) * 31 + exp
    override def equals(o: Any): Boolean = o match {
      case k: Key => k.form == form && k.name == name && k.exp == exp && java.util.Arrays.equals(k.args, args)
      case _ => false
    }
  }

  /** The shared type table: a type of the same structure is one row (hash-consing). A type variable is keyed by the
    * order it first appears in the type being added (`a -> a` is one row in every def).
    */
  final class Types(strings: Strings) {
    val form, name, expands = new IntBuf
    val argStart = new IntBuf
    val args = new IntBuf
    argStart += 0
    private val ids = new java.util.HashMap[Key, Integer](1 << 16)
    private var vars = mutable.HashMap.empty[Any, Int]
    // WhyNot: not walked again for every expression. The typed stage gives every expression its type, and a type such as
    // a record of the whole game state has hundreds of nodes, so the rows of a subtree without type variables are kept by
    // the identity of the compiler's object (a subtree with variables is numbered by where it sits, so it is not kept).
    private val seen = new java.util.IdentityHashMap[AnyRef, Integer](1 << 20)
    private var varRows = 0
    private val tcRows = new java.util.HashMap[TypeConstructor, Integer]()
    private val symNames = new java.util.HashMap[Symbol, String]()
    /** The named things the types mention (enums, aliases, effects), for the external declarations. */
    val mentioned = mutable.LinkedHashSet.empty[Symbol]
    private val NoArgs = new Array[Int](0)

    def size: Int = form.size

    private def rowOf(f: Int, n: Int, as: Array[Int], exp: Int): Int = {
      val key = new Key(f, n, as, exp)
      val known = ids.get(key)
      if (known != null) known.intValue
      else {
        form += f; name += n; expands += exp
        as.foreach(args += _); argStart += args.size
        ids.put(key, form.size - 1)
        form.size - 1
      }
    }

    def row(f: String, n: Option[String], as: List[Int], exp: Int): Int =
      rowOf(Generic.form(f), n.map(strings.id).getOrElse(-1), if (as.isEmpty) NoArgs else as.toArray, exp)

    private val ApplyForm = Generic.form("Apply")
    private def apply(a: Int, b: Int): Int = rowOf(ApplyForm, -1, Array(a, b), -1)

    /** The id of `t` (a `Type` or an `UnkindedType`), its type variables numbered afresh. */
    def add(t: Any): Int = { vars = mutable.HashMap.empty; go(t) }

    /** The ids of `ts`, their type variables numbered across all of them (the parameters and result of one signature). */
    def addAll(ts: List[Any]): List[Int] = { vars = mutable.HashMap.empty; ts.map(go) }

    /** A function type the way the typed stage writes one: `Arrow(n)` applied to the effect, the parameters, the result. */
    def arrow(eff: Int, params: List[Int], ret: Int): Int =
      (eff :: params ::: List(ret)).foldLeft(row("Arrow", Some((params.length + 1).toString), Nil, -1))(apply)

    private def sym(s: Symbol): String = {
      val known = symNames.get(s)
      if (known != null) known
      else { mentioned += s; val n = Facts.symName(s); symNames.put(s, n); n }
    }

    private def tc(c: TypeConstructor): Int = {
      val known = tcRows.get(c)
      if (known != null) known.intValue
      else {
        val id = c match {
          case TypeConstructor.Arrow(n) => row("Arrow", Some(n.toString), Nil, -1)
          case TypeConstructor.Record => row("Record", None, Nil, -1)
          case TypeConstructor.RecordRowExtend(label) => row("RecordRow", Some(label.name), Nil, -1)
          case TypeConstructor.Schema => row("Schema", None, Nil, -1)
          case TypeConstructor.SchemaRowExtend(pred) => row("RecordRow", Some(pred.name), Nil, -1)
          case TypeConstructor.Effect(s, _) => row("Effect", Some(sym(s)), Nil, -1)
          case TypeConstructor.Union | TypeConstructor.Intersection | TypeConstructor.Difference | TypeConstructor.Complement | TypeConstructor.SymmetricDiff =>
            row("EffUnion", Some(c.toString), Nil, -1)
          case TypeConstructor.Enum(s, _) => row("Cst", Some(sym(s)), Nil, -1)
          case TypeConstructor.Struct(s, _) => row("Cst", Some(sym(s)), Nil, -1)
          // the region's symbol has the compiler's id, which changes from compile to compile
          case TypeConstructor.Region(_) => row("Cst", Some("Region"), Nil, -1)
          case other => row("Cst", Some(other.toString), Nil, -1)
        }
        tcRows.put(c, id)
        id
      }
    }

    private def go(t: Any): Int = {
      val known = seen.get(t)
      if (known != null) known.intValue
      else {
        val before = varRows
        val id = goNew(t)
        if (varRows == before) seen.put(t.asInstanceOf[AnyRef], id)
        id
      }
    }

    // WhyNot: dispatched on `productPrefix` and the fields by name, like the walker. `Type` and `UnkindedType` name their
    // cases alike, so one function serves both stages, and a case it does not know is still a row (`Other`).
    private def goNew(t: Any): Int = {
      val p = t.asInstanceOf[Product]
      def f[A](n: String): A = Elem.get[A](p, n)
      p.productPrefix match {
        case "Apply" => apply(go(f[Any]("tpe1")), go(f[Any]("tpe2")))
        case "Cst" => tc(f[TypeConstructor]("tc"))
        case "Var" =>
          varRows += 1
          row("Var", Some(vars.getOrElseUpdate(f[Any]("sym"), vars.size).toString), Nil, -1)
        case "Alias" =>
          val s = Elem.get[Symbol](f[Any]("symUse"), "sym")
          row("Alias", Some(sym(s)), f[List[Any]]("args").map(go), go(f[Any]("tpe")))
        case "UnappliedAlias" => row("Alias", Some(sym(f[Symbol]("sym"))), Nil, -1)
        // the resolved stage writes the effect inside the arrow; the typed stage applies the arrow to it
        case "Arrow" =>
          val eff = f[Option[Any]]("eff").map(go).getOrElse(row("Cst", Some("Pure"), Nil, -1))
          apply(row("Arrow", Some(f[Int]("arity").toString), Nil, -1), eff)
        case "Enum" | "Struct" | "RestrictableEnum" => row("Cst", Some(sym(f[Symbol]("sym"))), Nil, -1)
        case "Effect" => row("Effect", Some(sym(f[Symbol]("sym"))), Nil, -1)
        case "Ascribe" => go(f[Any]("tpe"))
        case other =>
          val inner = p.productIterator.flatMap {
            case x: Type => List(x)
            case x: UnkindedType => List(x)
            case xs: Iterable[_] => xs.collect { case x: Type => x; case x: UnkindedType => x }
            case _ => Nil
          }.toList
          row("Other", Some(other), inner.map(go), -1)
      }
    }
  }

  final class Out(val stage: String, val files: Vector[String], limits: Limits) {
    val strings = new Strings
    val types = new Types(strings)
    var walkNs, walkCpuNs, extNs, writeNs = 0L
    val kind, parent, slot, index, root, line, col, endLine, endCol, synthetic, tpe, eff = new IntBuf
    val aNode, aName, aValue, aType, aLine = new IntBuf
    val declNode, declFile = new IntBuf
    val extSym, extKind, extType, extMemberStart, extMembers = new IntBuf
    extMemberStart += 0
    /** The named things the leaves mention (callees, cases, aliases, effects), for the external declarations. */
    val mentioned = mutable.LinkedHashSet.empty[Symbol]
    val javaCallees = mutable.LinkedHashSet.empty[String]
    private val fileIds = files.zipWithIndex.toMap

    def next: Int = kind.size

    def decl(node: Int, file: String): Unit = { declNode += node; declFile += fileIds.getOrElse(file, -1) }

    def attr(node: Int, name: String, value: String, line: Int): Unit = {
      aNode += node; aName += number(AstNames.attrNumbers, "attr", name); aValue += strings.id(value); aType += -1; aLine += line
    }

    def attrType(node: Int, name: String, tid: Int): Unit = {
      aNode += node; aName += number(AstNames.attrNumbers, "attr", name); aValue += -1; aType += tid; aLine += -1
    }

    def ext(sym: String, k: String, tid: Int, members: List[String]): Unit = {
      extSym += strings.id(sym); extKind += extKindNumber(k); extType += tid
      members.foreach(m => extMembers += strings.id(m)); extMemberStart += extMembers.size
    }

    // WhyNot: a name the schema does not have is not given a number of its own. The numbers of the columns and of
    // AstKinds.flix would then name different things; it means the schema walk (AstSchema) misses a field the walker follows.
    def number(table: Map[String, Int], what: String, name: String): Int =
      table.getOrElse(name, throw new IllegalStateException(s"the $what $name is not in the ast_schema (make ast-kinds)"))

    def bytes: Long =
      4L * (12L * kind.size + 5L * aNode.size + 4L * types.size + types.args.size + 2L * declNode.size + 4L * extSym.size + extMembers.size) +
        strings.chars

    /** Stops the walk when it has grown past the limits, naming what grew. */
    def checkLimits(rootsByNodes: => List[(String, Int)]): Unit =
      if (kind.size > limits.nodeRatio * math.max(limits.sourceLines, 1L) || bytes > limits.maxBytes) {
        val (biggest, n) = rootsByNodes.maxBy(_._2)
        throw new LimitError(
          s"the generic AST grew past its limit (${kind.size} nodes for ${limits.sourceLines} source lines, at most ${limits.nodeRatio} per line; " +
            s"${bytes / 1000000}MB, at most ${limits.maxBytes / 1000000}MB). Tables: ${counts.map { case (k, v) => s"$k=$v" }.mkString(" ")}. " +
            s"The declaration with the most nodes is $biggest ($n nodes).")
      }

    def counts: List[(String, Int)] = List("node" -> kind.size, "attr" -> aNode.size, "type" -> types.size, "typeArg" -> types.args.size,
      "string" -> strings.all.size, "decl" -> declNode.size, "external" -> extSym.size)

    /** The attribute rows grouped by node, in the order they were written within a node (a counting sort). */
    private lazy val attrOrder: Array[Int] = {
      val start = new Array[Int](kind.size + 1)
      (0 until aNode.size).foreach(i => start(aNode(i) + 1) += 1)
      (0 until kind.size).foreach(i => start(i + 1) += start(i))
      val order = new Array[Int](aNode.size)
      (0 until aNode.size).foreach { i => val n = aNode(i); order(start(n)) = i; start(n) += 1 }
      order
    }

    private def reordered(b: IntBuf): Array[Int] = attrOrder.map(b(_))

    def write(dir: Path): Unit = {
      Files.createDirectories(dir)
      def column(name: String, xs: Array[Int]): Unit = {
        val out = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(dir.resolve(name + ".i32")), 1 << 16))
        try xs.foreach(out.writeInt) finally out.close()
      }
      def text(name: String, lines: Iterable[String]): Unit = {
        val w = new PrintWriter(Files.newBufferedWriter(dir.resolve(name), StandardCharsets.UTF_8))
        try lines.foreach(l => { w.print(l); w.print('\n') }) finally w.close()
      }
      List("kind" -> kind, "parent" -> parent, "slot" -> slot, "index" -> index, "root" -> root, "line" -> line, "col" -> col,
        "endLine" -> endLine, "endCol" -> endCol, "synthetic" -> synthetic, "type" -> tpe, "effect" -> eff)
        .foreach { case (n, b) => column("node." + n, b.toArray) }
      List("node" -> aNode, "name" -> aName, "value" -> aValue, "type" -> aType, "line" -> aLine).foreach { case (n, b) => column("attr." + n, reordered(b)) }
      List("form" -> types.form, "name" -> types.name, "argStart" -> types.argStart, "args" -> types.args, "expands" -> types.expands)
        .foreach { case (n, b) => column("type." + n, b.toArray) }
      column("decl.node", declNode.toArray); column("decl.file", declFile.toArray)
      List("sym" -> extSym, "kind" -> extKind, "type" -> extType, "memberStart" -> extMemberStart, "members" -> extMembers)
        .foreach { case (n, b) => column("ext." + n, b.toArray) }
      text("strings.txt", strings.all.map(escape))
      text("files.txt", files)
      text("kinds.txt", AstNames.kinds)
      text("meta.txt", List(s"format=$Format", s"stage=$stage", s"flixVersion=${ca.uwaterloo.flix.api.Version.CurrentVersion}",
        s"schemaHash=${AstNames.schemaHash}") ++ counts.map { case (k, v) => s"rows.$k=$v" } :+ s"bytes=$bytes")
    }

    /** The same rows as TSV, the numbers turned back into names. */
    def writeTsv(dir: Path): Unit = {
      Files.createDirectories(dir)
      def tsv(name: String, rows: Iterator[Seq[Any]]): Unit = {
        val w = new PrintWriter(Files.newBufferedWriter(dir.resolve(name + ".tsv"), StandardCharsets.UTF_8))
        try rows.foreach(r => w.println(r.map(x => escape(x.toString).replace('\t', ' ')).mkString("\t"))) finally w.close()
      }
      def str(i: Int): String = if (i < 0) "" else strings.all(i)
      tsv("node", (0 until kind.size).iterator.map(i => Seq(i, AstNames.kinds(kind(i)), parent(i), if (slot(i) < 0) "" else AstNames.slots(slot(i)),
        index(i), root(i), line(i), col(i), endLine(i), endCol(i), synthetic(i), tpe(i), eff(i))))
      tsv("node_attr", attrOrder.iterator.map(i => Seq(aNode(i), AstNames.attrs(aName(i)), str(aValue(i)), aType(i), aLine(i))))
      tsv("node_type", (0 until types.size).iterator.map(i => Seq(i, Forms(types.form(i)), str(types.name(i)),
        (types.argStart(i) until types.argStart(i + 1)).map(types.args(_)).mkString(","), types.expands(i))))
      tsv("decl", (0 until declNode.size).iterator.map(i => Seq(declNode(i), files.lift(declFile(i)).getOrElse(""))))
      tsv("external", (0 until extSym.size).iterator.map(i => Seq(str(extSym(i)), ExtKinds(extKind(i)), extType(i),
        (extMemberStart(i) until extMemberStart(i + 1)).map(j => str(extMembers(j))).mkString(","))))
    }
  }

  def escape(s: String): String =
    if (s.indexOf('\\') < 0 && s.indexOf('\n') < 0 && s.indexOf('\r') < 0) s
    else s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")

  // ---- the names a rule file writes (design 1.5) ----

  private val namePattern = """\b(Kind|Slot|Attr)\.([A-Z][A-Za-z0-9_]*)""".r

  private val unnamedPattern = """[A-Za-z0-9_.]*Unnamed\([^)]*\)""".r

  /** One name a rule file writes: where, which table, the name as the compiler spells it, whether this stage has it and
    * how many rows of these relations carry it (-1 for `Unnamed(`, which is not a table's name).
    */
  final case class RuleName(file: String, line: Int, table: String, written: String, inStage: Boolean, count: Int)

  /** `Kind.X` / `Slot.Y` / `Attr.Z` and `Unnamed(` in the text of a rule file, against what these relations have.
    * WhyNot: not read off the compiled rules. The engine is built from the rule file before the facts are read, and a
    * rule is a function, so the names it uses are only in its text; the same regex reading `Names` uses for `Fn.X`.
    */
  def ruleNames(rulesFile: Path, out: Out): List[RuleName] = {
    val shown = rulesFile.toString
    def byCase(names: Vector[String]): Map[String, String] = names.map(n => AstKindsFlix.caseName(n) -> n).toMap
    val tables = Map(
      "Kind" -> (byCase(AstNames.kinds), if (out.stage == "typed") AstNames.typedKinds else AstNames.resolvedKinds, counts(out.kind, AstNames.kinds.size)),
      "Slot" -> (byCase(AstNames.slots), if (out.stage == "typed") AstNames.typedSlots else AstNames.resolvedSlots, counts(out.slot, AstNames.slots.size)),
      "Attr" -> (byCase(AstNames.attrs), if (out.stage == "typed") AstNames.typedAttrs else AstNames.resolvedAttrs, counts(out.aName, AstNames.attrs.size)))
    val lines = Files.readAllLines(rulesFile, StandardCharsets.UTF_8).toArray(Array.empty[String]).toList.zipWithIndex
    lines.flatMap { case (text, i) =>
      val code = text.split("//", 2).head
      val written = namePattern.findAllMatchIn(code).toList.flatMap { m =>
        val (byName, inStage, count) = tables(m.group(1))
        // a case AstKinds does not have does not compile, so only the names it has are counted
        byName.get(m.group(2)).map(n => RuleName(shown, i + 1, m.group(1), m.group(2), inStage.contains(n), count(numberOf(m.group(1), n))))
      }
      val unnamed = unnamedPattern.findFirstIn(code).map(u => RuleName(shown, i + 1, "Unnamed", u, inStage = true, -1)).toList
      written ++ unnamed
    }.distinct
  }

  private def numberOf(table: String, name: String): Int = table match {
    case "Kind" => AstNames.kindNumbers(name)
    case "Slot" => AstNames.slotNumbers(name)
    case _ => AstNames.attrNumbers(name)
  }

  /** How many rows carry each number of a column. */
  private def counts(column: IntBuf, n: Int): Int => Int = {
    val c = new Array[Int](n)
    (0 until column.size).foreach { i => val v = column(i); if (v >= 0 && v < n) c(v) += 1 }
    i => c(i)
  }

  def writeRuleNames(dir: Path, names: List[RuleName]): Unit = {
    val w = new PrintWriter(Files.newBufferedWriter(dir.resolve("rule_names.tsv"), StandardCharsets.UTF_8))
    try names.foreach(r => w.println(List(r.file, r.line, r.table, escape(r.written).replace('\t', ' '), if (r.inStage) 1 else 0, r.count).mkString("\t")))
    finally w.close()
  }

  // ---- the walk ----

  /** A position: line, col, endLine, endCol, synthetic. */
  private final case class Pos(l: Int, c: Int, el: Int, ec: Int, syn: Int)

  private def posOf(loc: SourceLocation): Pos = Pos(loc.startLine, loc.startCol, loc.endLine, loc.endCol, if (loc.isSynthetic) 1 else 0)

  private def locOf(p: Any): Option[SourceLocation] = {
    val l = p match {
      case q: Product if Elem.has(q, "loc") => Elem.get[Any](q, "loc")
      case q: Product => null
      // a symbol is not a case class; its location is a method
      case _ => if (Facts.hasField(p, "loc")) Facts.field[Any](p, "loc") else null
    }
    l match {
      case s: SourceLocation if s.startLine > 0 => Some(s)
      case _ => None
    }
  }

  private def className(owner: java.lang.constant.ClassDesc): String = {
    val pkg = owner.packageName()
    if (pkg.isEmpty) owner.displayName() else pkg + "." + owner.displayName()
  }

  // WhyNot: a variable is not written with the compiler's id (`x#61332`). The ids come from a counter the compiler's
  // threads share, so they change from one compile of the same sources to the next; the walk numbers them in the order
  // it meets them instead (`x#0`), which is the same every time.
  private final class LocalNames {
    private val ids = new java.util.HashMap[Symbol, Integer]()
    private def number(s: Symbol): Int = { var n = ids.get(s); if (n == null) { n = ids.size; ids.put(s, n) }; n.intValue }
    private val compilerId = "\\$[0-9]+$".r
    private def local(s: Symbol, text: String): String = s"${compilerId.replaceFirstIn(text, "")}#${number(s)}"
    /** `x#0`; a name the compiler made carries its id as well (`arg$63098`, a type variable `a$13899`), which goes. */
    def text(s: Symbol): String = s match {
      case v: Symbol.VarSym => local(v, v.text)
      case r: Symbol.RegionSym => local(r, r.text)
      case l: Symbol.LabelSym => local(l, l.text)
      case _ =>
        val n = Facts.symName(s)
        if (compilerId.findFirstIn(n).isDefined) local(s, n) else n
    }
  }

  private def tcName(tc: TypeConstructor): String = tc match {
    case TypeConstructor.Enum(sym, _) => Facts.symName(sym)
    case TypeConstructor.Struct(sym, _) => Facts.symName(sym)
    case TypeConstructor.Effect(sym, _) => Facts.symName(sym)
    case other => other.toString
  }

  private final class Walker(out: Out) {
    private val locals = new LocalNames
    private def lineOf(pos: Pos, loc: Option[SourceLocation]): Int = loc.map(_.startLine).filter(_ != pos.l).getOrElse(-1)

    /** A node and its subtree; its id. */
    def node(p: Product, parent: Int, slot: Int, index: Int, root: Int, inherited: Pos): Int = {
      val id = out.next
      val r = if (root < 0) id else root
      val pos = locOf(p).map(posOf).getOrElse(inherited)
      val nc = nodeClass(p)
      out.kind += nc.kind
      out.parent += parent; out.slot += slot; out.index += index; out.root += r
      out.line += pos.l; out.col += pos.c; out.endLine += pos.el; out.endCol += pos.ec; out.synthetic += pos.syn
      out.tpe += -1; out.eff += -1
      if (nc.javaCall) javaCallee(p).foreach(out.javaCallees += _)
      var i = 0
      while (i < nc.fields.length) {
        val name = nc.fields(i)
        if (name != "loc") value(p.productElement(i), id, name, 0, r, pos, nc.exprLike)
        i += 1
      }
      id
    }

    /** The callee of a Java call, spelt as the fact walker spells it (`java.lang.String.length`, `<init>` for a constructor). */
    private def javaCallee(p: Product): Option[String] =
      List("method", "constructor").find(Facts.hasField(p, _)).map(Facts.field[Any](p, _)) match {
        case Some(jm) =>
          val ref = Facts.field[Any](jm, "ref")
          Some(className(Facts.field[java.lang.constant.ClassDesc](ref, "owner")) + "." + Facts.field[String](ref, "name"))
        case None if Facts.hasField(p, "clazz") =>
          val name = if (Facts.hasField(p, "methodName")) Facts.field[Any](Facts.field[Any](p, "methodName"), "name").toString else "<init>"
          Some(className(Facts.field[java.lang.constant.ClassDesc](p, "clazz")) + "." + name)
        case None => None
      }

    private def value(v: Any, owner: Int, name: String, index: Int, root: Int, pos: Pos, exprLike: Boolean): Unit =
      if (v != null) (Shape.of(v.getClass): @scala.annotation.switch) match {
        case Shape.Skip => ()
        case Shape.TypeV =>
          val tid = out.types.add(v)
          if (exprLike && name == "tpe") out.tpe(owner) = tid
          else if (exprLike && name == "eff") out.eff(owner) = tid
          else out.attrType(owner, name, tid)
        case Shape.Text => out.attr(owner, name, v.toString, -1)
        case Shape.Sym =>
          val s = v.asInstanceOf[Symbol]
          s match {
            case _: Symbol.VarSym | _: Symbol.RegionSym | _: Symbol.LabelSym => out.attr(owner, name, locals.text(s), -1)
            case _ => out.mentioned += s; out.attr(owner, name, locals.text(s), lineOf(pos, locOf(s)))
          }
        case Shape.SymUse =>
          val s = Elem.get[Symbol](v, "sym")
          s match { case _: Symbol.VarSym => (); case _ => out.mentioned += s }
          out.attr(owner, name, locals.text(s), lineOf(pos, locOf(v)))
        case Shape.TyCon =>
          val tc = v.asInstanceOf[TypeConstructor]
          out.attr(owner, name, tcName(tc), -1)
          out.attr(owner, name + ".kind", tc.getClass.getSimpleName.stripSuffix("$"), -1)
        case Shape.Constant =>
          val c = v.asInstanceOf[Product]
          out.attr(owner, name, c.productPrefix, -1)
          if (c.productArity == 1) out.attr(owner, name + ".lit", String.valueOf(c.productElement(0)), -1)
        case Shape.Name => out.attr(owner, name, scala.util.Try(Facts.field[Any](v, "name").toString).getOrElse(v.toString), -1)
        case Shape.Desc => out.attr(owner, name, className(v.asInstanceOf[java.lang.constant.ClassDesc]), -1)
        case Shape.Opt => v.asInstanceOf[Option[Any]].foreach(x => value(x, owner, name, index, root, pos, exprLike))
        case Shape.Nel =>
          var i = 0
          (Facts.field[Any](v, "head") :: Facts.field[List[Any]](v, "tail")).foreach { x => value(x, owner, name, i, root, pos, exprLike); i += 1 }
        case Shape.MapV =>
          var i = 0
          v.asInstanceOf[scala.collection.Map[Any, Any]].valuesIterator.foreach { x => value(x, owner, name, i, root, pos, exprLike); i += 1 }
        case Shape.Iter =>
          var i = 0
          v.asInstanceOf[Iterable[Any]].foreach { x => value(x, owner, name, i, root, pos, exprLike); i += 1 }
        case Shape.Node => node(v.asInstanceOf[Product], owner, out.number(AstNames.slotNumbers, "slot", name), index, root, pos)
        case _ => out.attr(owner, name, v.toString, -1)
      }
  }

  /** What the walker does with a value of a class, worked out once per class (the tests read the class's name). */
  private object Shape {
    final val Skip = 0; final val TypeV = 1; final val Text = 2; final val Sym = 3; final val SymUse = 4; final val TyCon = 5
    final val Constant = 6; final val Name = 7; final val Desc = 8; final val Opt = 9; final val Nel = 10; final val MapV = 11
    final val Iter = 12; final val Node = 13; final val Leaf = 14

    private val shapes = new ClassValue[Integer] {
      override def computeValue(c: Class[_]): Integer = {
        val n = c.getName
        if (classOf[SourceLocation].isAssignableFrom(c) || AstSchema.isSkippedClass(c)) Skip
        else if (classOf[Type].isAssignableFrom(c) || classOf[UnkindedType].isAssignableFrom(c)) TypeV
        else if (c == classOf[String] || classOf[java.lang.Number].isAssignableFrom(c) || c == classOf[java.lang.Boolean] || c == classOf[java.lang.Character]) Text
        else if (classOf[Symbol].isAssignableFrom(c)) Sym
        else if (n.contains("SymUse$")) SymUse
        else if (classOf[TypeConstructor].isAssignableFrom(c)) TyCon
        else if (n.contains("Constant$")) Constant
        else if (n.contains("ast.Name$")) Name
        else if (classOf[java.lang.constant.ClassDesc].isAssignableFrom(c)) Desc
        else if (classOf[Option[_]].isAssignableFrom(c)) Opt
        else if (n.endsWith("collection.Nel")) Nel
        else if (classOf[scala.collection.Map[_, _]].isAssignableFrom(c)) MapV
        else if (classOf[Iterable[_]].isAssignableFrom(c)) Iter
        // a product without fields (a case object) is a leaf
        else if (classOf[Product].isAssignableFrom(c) && AstSchema.fieldsOf(c).nonEmpty) Node
        else Leaf
      }
    }

    def of(c: Class[_]): Int = shapes.get(c).intValue
  }

  /** The kind number of a node class, whether it is an expression or a pattern, whether it calls Java, and its field names,
    * worked out once per class (from the first node of the class: the field names are its `productElementNames`). */
  private final case class NodeClass(kind: Int, exprLike: Boolean, javaCall: Boolean, fields: Array[String])

  private val nodeClasses = mutable.HashMap.empty[Class[_], NodeClass]

  private def nodeClass(p: Product): NodeClass = nodeClasses.getOrElseUpdate(p.getClass, {
    val kind = AstSchema.kindOfClass(p.getClass)
    val number = AstNames.kindNumbers.getOrElse(kind, throw new IllegalStateException(s"the kind $kind is not in the ast_schema (make ast-kinds)"))
    NodeClass(number, kind.startsWith("Expr.") || kind.startsWith("Pattern."), kind.startsWith("Expr.Invoke"), p.productElementNames.toArray)
  })

  // ---- the declarations, and the external ones ----

  private def values(root: Product, field: String): List[Any] =
    if (!Facts.hasField(root, field)) Nil
    else Facts.field[Any](root, field) match {
      case m: scala.collection.Map[_, _] => m.values.toList
      case xs: Iterable[_] => xs.toList
      case other => Facts.field[scala.collection.Map[Any, List[Any]]](other, "m").values.flatten.toList // ListMap: a key to its values
    }

  private def fileOf(d: Any): Option[String] = locOf(d).flatMap(Facts.sourceFile)

  private def emit(root: Product, stage: String, files: List[String], limits: Limits): Out = {
    val out = new Out(stage, files.toVector, limits)
    val tWalk = System.nanoTime()
    val cpu = java.lang.management.ManagementFactory.getThreadMXBean
    val cWalk = cpu.getCurrentThreadCpuTime
    val w = new Walker(out)
    val instanceDefs = values(root, "instances").flatMap(i => Facts.field[List[Any]](i, "defs"))
    val defs = (values(root, "defs") ++ instanceDefs).filterNot(Facts.synthetic)
    val roots = (defs ++ values(root, "enums") ++ values(root, "typeAliases") ++ values(root, "effects"))
      .flatMap(d => fileOf(d).map(f => (d.asInstanceOf[Product], f)))
      .sortBy { case (d, f) => (f, locOf(d).map(_.startLine).getOrElse(0), locOf(d).map(_.startCol).getOrElse(0)) }
    val sizes = mutable.ListBuffer.empty[(String, Int)]
    roots.foreach { case (d, f) =>
      val before = out.next
      val id = w.node(d, -1, -1, 0, -1, Pos(0, 0, 0, 0, 0))
      out.decl(id, f)
      sizes += ((s"${AstSchema.kindOfClass(d.getClass)} ${Facts.symName(Facts.field[Any](d, "sym"))} ($f:${out.line(id)})", out.next - before))
      out.checkLimits(sizes.toList)
    }
    out.walkNs = System.nanoTime() - tWalk
    out.walkCpuNs = cpu.getCurrentThreadCpuTime - cWalk
    val tExt = System.nanoTime()
    externals(root, out)
    out.extNs = System.nanoTime() - tExt
    out.checkLimits(sizes.toList)
    out
  }

  /** The declarations outside the sources that the walk mentioned, and every effect alias outside the sources. */
  private def externals(root: Product, out: Out): Unit = {
    val t = out.types
    def specType(spec: Any): Int = {
      val params = Facts.field[Any](spec, "fparams") match {
        case n: Product if n.getClass.getName.endsWith("collection.Nel") => Facts.field[Any](n, "head") :: Facts.field[List[Any]](n, "tail")
        case xs: Iterable[_] => xs.toList
      }
      def opt(x: Any): Option[Any] = x match { case o: Option[_] => o; case y => Some(y) }
      val paramTypes = params.map(p => opt(Facts.field[Any](p, "tpe")))
      val ret = opt(Facts.field[Any](spec, if (Facts.hasField(spec, "retTpe")) "retTpe" else "tpe"))
      val eff = opt(Facts.field[Any](spec, "eff"))
      // one variable numbering for the whole signature
      val all = t.addAll((eff :: ret :: paramTypes).flatten)
      val it = all.iterator
      lazy val unknown = t.row("Other", Some("Unwritten"), Nil, -1)
      val effId = eff.map(_ => it.next()).getOrElse(t.row("Cst", Some("Pure"), Nil, -1))
      val retId = ret.map(_ => it.next()).getOrElse(unknown)
      t.arrow(effId, paramTypes.map(p => p.map(_ => it.next()).getOrElse(unknown)), retId)
    }
    val defs = values(root, "defs").map(d => Facts.symName(Facts.field[Any](d, "sym")) -> d).toMap
    val sigs = (values(root, "sigs") ++ values(root, "traits").flatMap(tr => Facts.field[Any](tr, "sigs") match { case m: scala.collection.Map[_, _] => m.values.toList; case xs: Iterable[_] => xs.toList }))
      .map(s => Facts.symName(Facts.field[Any](s, "sym")) -> s).toMap
    val effects = values(root, "effects")
    val ops = effects.flatMap(e => Facts.field[List[Any]](e, "ops").map(o => Facts.symName(Facts.field[Any](o, "sym")) -> (o, e))).toMap
    val effectsByName = effects.map(e => Facts.symName(Facts.field[Any](e, "sym")) -> e).toMap
    val enums = values(root, "enums").map(e => Facts.symName(Facts.field[Any](e, "sym")) -> e).toMap
    val structs = values(root, "structs").map(e => Facts.symName(Facts.field[Any](e, "sym")) -> e).toMap
    val aliases = values(root, "typeAliases").map(a => Facts.symName(Facts.field[Any](a, "sym")) -> a).toMap
    def effMembers(a: Any): List[String] = effNames(Facts.field[Any](a, "tpe")).distinct

    val done = mutable.HashSet.empty[String]
    def ext(name: String, k: String, decl: Any, tid: => Int, members: => List[String]): Unit =
      if (fileOf(decl).isEmpty && done.add(k + " " + name)) out.ext(name, k, tid, members)
    val used = (out.mentioned ++ t.mentioned).toList.map(s => (s, Facts.symName(s))).sortBy(_._2)
    used.foreach {
      case (_: Symbol.DefnSym, n) => defs.get(n).foreach(d => ext(n, "def", d, specType(Facts.field[Any](d, "spec")), Nil))
      case (_: Symbol.SigSym, n) => sigs.get(n).foreach(s => ext(n, "sig", s, specType(Facts.field[Any](s, "spec")), Nil))
      case (_: Symbol.OpSym, n) => ops.get(n).foreach { case (o, e) => ext(n, "op", e, specType(Facts.field[Any](o, "spec")), Nil) }
      case (s: Symbol.CaseSym, n) => enums.get(Facts.symName(s.enumSym)).foreach(e => ext(n, "case", e, -1, Nil))
      case (_: Symbol.EnumSym, n) => enums.get(n).foreach(e => ext(n, "enum", e, -1, Nil))
      case (_: Symbol.StructSym, n) => structs.get(n).foreach(e => ext(n, "struct", e, -1, Nil))
      case (_: Symbol.TypeAliasSym, n) => aliases.get(n).foreach(a => ext(n, "alias", a, t.add(Facts.field[Any](a, "tpe")), effMembers(a)))
      case (_: Symbol.EffSym, n) => effectsByName.get(n).foreach(e => ext(n, "effect", e, -1, Nil))
      case _ => ()
    }
    // an effect alias is read by its members, so the ones outside the sources are listed even when unused
    aliases.toList.sortBy(_._1).foreach { case (n, a) =>
      val members = effMembers(a)
      if (members.nonEmpty) ext(n, "alias", a, t.add(Facts.field[Any](a, "tpe")), members)
    }
    out.javaCallees.toList.sorted.foreach(n => if (done.add("java " + n)) out.ext(n, "java", -1, Nil))
  }

  /** The effects a type stands for, aliases opened (`Db = DbRead + DbWrite` gives both); either stage. */
  private def effNames(t: Any): List[String] = t match {
    case p: Product => p.productPrefix match {
      case "Alias" => effNames(Facts.field[Any](p, "tpe"))
      case "Cst" => Facts.field[TypeConstructor](p, "tc") match {
        case TypeConstructor.Effect(sym, _) => List(Facts.symName(sym))
        case _ => Nil
      }
      case "Effect" => List(Facts.symName(Facts.field[Any](p, "sym")))
      case "Apply" if isSetOp(p) => effNames(Facts.field[Any](p, "tpe1")) ++ effNames(Facts.field[Any](p, "tpe2"))
      case _ => Nil
    }
    case _ => Nil
  }

  private def isSetOp(p: Product): Boolean = p.productPrefix match {
    case "Apply" => isSetOp(Facts.field[Product](p, "tpe1"))
    case "Cst" => Typed.isSetOp(Some(Facts.field[TypeConstructor](p, "tc")))
    case _ => false
  }
}
