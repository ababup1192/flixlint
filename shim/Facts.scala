package flixlint

import ca.uwaterloo.flix.api.Flix
import ca.uwaterloo.flix.language.ast.shared.{Input, SecurityContext}
import ca.uwaterloo.flix.language.ast.{ChangeSet, ResolvedAst, SourceLocation, Symbol, Type, TypeConstructor, TypedAst, UnkindedType}
import ca.uwaterloo.flix.language.phase
import ca.uwaterloo.flix.tools.pkg.{Dependency, Manifest, ManifestParser}
import ca.uwaterloo.flix.util.{Formatter, LibLevel, Options, Result, Subeffecting}

import java.io.PrintWriter
import java.nio.file.{Files, Path, Paths}
import scala.jdk.CollectionConverters._

/** Extracts language-level facts from the Flix compiler's AST and writes them as TSV, one file per relation, plus
  * `Flixlint/Names.flix`: one Flix enum per kind of name (Fn / Eff / Mod / Case / Enum / Type) with every name the facts mention,
  * so that rules refer to functions, effects and types as enum cases and a stale name fails to compile.
  *
  * Usage: Facts --out DIR [--names-out FILE] [--stage typed|resolved] [--pkg FPKG]... [--jar JAR]...
  *               [--project-root DIR] SRC...
  *
  * WhyNot: the walker dispatches on `productPrefix` and reads fields by name instead of pattern matching on the
  * TypedAst / ResolvedAst case classes. The two ASTs share the node names and field names that matter here, so one
  * walker serves both stages, and a compiler upgrade that renames a node breaks in one place with a clear message.
  */
object Facts {

  final case class Args(out: Path, namesOut: Option[Path], stage: String, pkgs: List[Path], jars: List[Path], srcs: List[Path], projectRoot: Option[Path], subeffecting: Boolean)

  /** Thrown for anything the caller can fix: a bad option, a missing file, an unreadable flix.toml. Exit code 4. */
  final class UsageError(msg: String) extends RuntimeException(msg)

  def parseArgs(argv: Array[String]): Args = {
    var out: Path = null
    var namesOut: Option[Path] = None
    var stage = "typed"
    var pkgs = List.empty[Path]
    var jars = List.empty[Path]
    var srcs = List.empty[Path]
    var projectRoot: Option[Path] = None
    var sub = true
    var i = 0
    def value(opt: String): String =
      if (i + 1 < argv.length) argv(i + 1) else throw new UsageError(s"$opt needs a value")
    while (i < argv.length) {
      argv(i) match {
        case "--out" => out = Paths.get(value("--out")); i += 2
        case "--names-out" => namesOut = Some(Paths.get(value("--names-out"))); i += 2
        case "--stage" => stage = value("--stage"); i += 2
        case "--pkg" => pkgs = pkgs :+ Paths.get(value("--pkg")); i += 2
        case "--jar" => jars = jars :+ Paths.get(value("--jar")); i += 2
        case "--project-root" => projectRoot = Some(Paths.get(value("--project-root"))); i += 2
        case "--no-subeffecting" => sub = false; i += 1
        case opt if opt.startsWith("--") => throw new UsageError(s"unknown option $opt")
        case s => srcs = srcs :+ Paths.get(s); i += 1
      }
    }
    if (out == null) throw new UsageError("--out DIR is required")
    if (srcs.isEmpty) throw new UsageError("at least one source directory or file is required")
    if (stage != "typed" && stage != "resolved") throw new UsageError(s"unknown --stage $stage (typed or resolved)")
    Args(out, namesOut, stage, pkgs, jars, srcs, projectRoot, sub)
  }

  // Exit codes: 0 facts written, 3 the sources do not compile, 4 the caller or the environment is wrong.
  // WhyNot: a crash must not leave exit 1. bin/flixlint reserves 1 for "there are violations", so an
  // uncaught exception here would read to CI as a report of new violations.
  def main(argv: Array[String]): Unit =
    try run(argv)
    catch {
      case e: UsageError =>
        System.err.println(s"flixlint: ${e.getMessage}")
        sys.exit(4)
      case e: Throwable =>
        System.err.println(s"flixlint: the fact walker failed: ${e.getClass.getName}: ${e.getMessage}")
        e.printStackTrace()
        sys.exit(4)
    }

  def run(argv: Array[String]): Unit = {
    val args = parseArgs(argv)
    val t0 = System.nanoTime()
    val flix = new Flix()
    val base = Options.Default
    val opts = base.copy(
      lib = LibLevel.All,
      progress = false,
      xsubeffecting = if (args.subeffecting) Set[Subeffecting](Subeffecting.Lambdas) else Set.empty[Subeffecting]
    )
    flix.setOptions(opts)
    val files = args.srcs.flatMap(listFlix)
    files.foreach(f => flix.addFile(f)(SecurityContext.Unrestricted))
    val deps = if (args.pkgs.nonEmpty || args.jars.nonEmpty) Deps(args.pkgs, args.jars) else Deps.ofProject(args.projectRoot, args.srcs)
    deps.pkgs.foreach(p => flix.addPkg(p)(SecurityContext.Unrestricted))
    deps.jars.foreach(j => flix.addJar(j))
    val t1 = System.nanoTime()

    val sink = new Sink(args.out)
    val (nErrors, phaseNs) = args.stage match {
      case "typed" =>
        val (optRoot, errors) = flix.check()
        val t2 = System.nanoTime()
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(optRoot)))
        optRoot match {
          case Some(root) => Typed.emit(root, sink)
          case None => System.err.println("flixlint: no typed AST (compilation errors above)")
        }
        (errors.length, t2 - t1)
      case "resolved" =>
        val (root, errors) = Resolved.run(flix)
        val t2 = System.nanoTime()
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(None)))
        Resolved.emit(root, sink)
        (errors.length, t2 - t1)
      case other => throw new UsageError(s"unknown --stage $other (typed or resolved)")
    }
    sink.close()
    Names.write(args.namesOut.getOrElse(args.out.resolve("Names.flix")), sink)
    val t3 = System.nanoTime()
    System.err.println(f"flixlint facts: stage=${args.stage} files=${files.length} compile=${phaseNs / 1e9}%.1fs walk=${(t3 - t1 - phaseNs) / 1e9}%.2fs total=${(t3 - t0) / 1e9}%.1fs")
    if (nErrors > 0) sys.exit(3)
  }

  def listFlix(p: Path): List[Path] =
    if (Files.isDirectory(p)) Files.walk(p).iterator().asScala.filter(f => f.toString.endsWith(".flix") && Files.isRegularFile(f)).toList.sorted
    else if (Files.isRegularFile(p)) List(p)
    else throw new UsageError(s"$p: no such source file or directory")

  /** The packages and jars to put on the compiler's path. */
  final case class Deps(pkgs: List[Path], jars: List[Path])

  /** Reads the project's `flix.toml` with the compiler's own `ManifestParser` and turns the dependencies it names
    * into the paths the compiler has already unpacked them to (`lib/github`, `lib/cache`, `lib/external`).
    *
    * WhyNot: `FlixPackageManager.findTransitiveDependencies` is not used. It reaches GitHub, and a linter must not
    * need the network; the manifest of every installed package sits next to its fpkg, so the closure is taken from
    * disk. Nothing is downloaded: a package that is not there is an error telling the caller to run `flix check`.
    *
    * WhyNot: `lib/**/*.fpkg` is not passed wholesale. lib/ keeps every version ever resolved, and two versions of
    * one package bring the same definitions in twice. Jars are passed whole: two versions of one artifact on the
    * classpath is first-wins, not a redefinition.
    */
  object Deps {
    def ofProject(explicitRoot: Option[Path], srcs: List[Path]): Deps = findRoot(explicitRoot, srcs) match {
      case None => Deps(Nil, Nil)
      case Some(root) => ofRoot(root)
    }

    /** WhyNot: the search upwards does not run to `/`. Above the current directory sits whatever the machine
      * happens to have, and a `flix.toml` found there describes another project.
      */
    private def findRoot(explicitRoot: Option[Path], srcs: List[Path]): Option[Path] = {
      val cwd = Paths.get("").toAbsolutePath.normalize
      explicitRoot match {
        case Some(r) =>
          val root = r.toAbsolutePath.normalize
          if (!Files.isRegularFile(root.resolve("flix.toml"))) throw new UsageError(s"--project-root $root has no flix.toml")
          Some(root)
        case None =>
          var p = Option(srcs.head.toAbsolutePath.normalize.getParent).getOrElse(cwd)
          var found: Option[Path] = None
          while (found.isEmpty && p != null && p.startsWith(cwd)) {
            if (Files.isRegularFile(p.resolve("flix.toml"))) found = Some(p) else p = p.getParent
          }
          found.orElse(Some(cwd).filter(c => Files.isRegularFile(c.resolve("flix.toml"))))
      }
    }

    private def ofRoot(root: Path): Deps = {
      val lib = root.resolve("lib")
      val fpkgs = scala.collection.mutable.LinkedHashMap.empty[String, Path]
      val externals = scala.collection.mutable.LinkedHashMap.empty[String, Path]
      def walk(manifest: Manifest): Unit = {
        manifest.jarDependencies.foreach { d =>
          externals.getOrElseUpdate(d.fileName, need(lib.resolve("external").resolve(d.fileName), root))
        }
        manifest.flixDependencies.foreach { d =>
          val version = d.version.toString
          val dir = lib.resolve("github").resolve(d.username).resolve(d.projectName).resolve(version)
          val key = s"${d.username}/${d.projectName}/$version"
          if (!fpkgs.contains(key)) {
            fpkgs += (key -> need(dir.resolve(s"${d.projectName}-$version.fpkg"), root))
            val nested = dir.resolve(s"${d.projectName}-$version.toml")
            if (Files.isRegularFile(nested)) walk(parse(nested))
          }
        }
      }
      walk(parse(root.resolve("flix.toml")))
      Deps(fpkgs.values.toList, listJars(lib.resolve("cache")) ++ externals.values.toList)
    }

    private def parse(toml: Path): Manifest = ManifestParser.parse(toml) match {
      case Result.Ok(m) => m
      case Result.Err(e) => throw new UsageError(s"$toml: ${e.message(Formatter.NoFormatter)}")
    }

    private def need(p: Path, root: Path): Path =
      if (Files.isRegularFile(p)) p
      else throw new UsageError(
        s"$p is missing; run 'flix check' once in $root so that the compiler unpacks the dependencies of its " +
          "flix.toml into lib/, or pass --pkg / --jar yourself")

    private def listJars(dir: Path): List[Path] =
      if (!Files.isDirectory(dir)) Nil
      else {
        val entries = Files.walk(dir)
        try entries.iterator().asScala.filter(f => f.toString.endsWith(".jar") && Files.isRegularFile(f)).toList.sorted
        finally entries.close()
      }
  }

  // ---- generic helpers over the AST (both stages) ----

  def field[A](node: Any, name: String): A = node.getClass.getMethod(name).invoke(node).asInstanceOf[A]

  def sourceFile(loc: SourceLocation): Option[String] = loc.source.input match {
    case Input.RealFile(p, _) => Some(p.toString)
    case _ => None
  }

  def qname(ns: List[String], name: String): String = (ns :+ name).mkString(".")

  /** A def the compiler made up (a derived `Eq.eq$1234`): its name is a fresh number, so it is left out of the facts
    * and of `Names.flix`, or the names would change with every edit and the engine would be rebuilt every run.
    */
  def synthetic(d: Any): Boolean = symName(field[Any](d, "sym")).contains("$")

  def symName(sym: Any): String = sym match {
    case s: Symbol.DefnSym => qname(s.namespace, s.name)
    case s: Symbol.SigSym => qname(s.namespace, s.name)
    case s: Symbol.OpSym => qname(s.namespace, s.name)
    case s: Symbol.CaseSym => qname(s.namespace, s.name)
    case s: Symbol.EffSym => qname(s.namespace, s.name)
    case s: Symbol.EnumSym => qname(s.namespace, s.name)
    case s: Symbol.TypeAliasSym => qname(s.namespace, s.name)
    case s: Symbol.StructSym => qname(s.namespace, s.name)
    case s: Symbol.TraitSym => qname(s.namespace, s.name)
    case other => other.toString
  }

  /** Walks a definition body, attributing every call / handler / constructor to the enclosing top-level def
    * (lambdas and local defs count as their enclosing def). On the way it records the shape of each call: the
    * functions whose lambda arguments the call sits in (`CallsInLambdaArgOf`), the string literals and the calls
    * among its arguments (`ArgLit` / `ArgCall`), the stages of a `|>` chain (`PipedInto`) and every string literal
    * (`StrLit`).
    *
    * WhyNot: the walker does not read the arguments of a call off the call node alone. The desugarer turns a partial
    * application `f(a)` into `let t = a; x -> f(t, x)` and a function passed by name `List.map(g, xs)` into
    * `let t = x -> g(x); List.map(t, xs)`, so an argument is often a variable bound just outside the call. The
    * let-bound expressions are carried along (`env`) and an argument that is such a variable is read as the
    * expression it stands for, walked where it is used (a lambda: inside the call's lambda context) and once.
    */
  def walkBody(fn: String, body: Any, sink: Sink): Unit = {
    /** A let-bound expression and the lambda context of the `let` (its value is computed there, not where it is used). */
    final case class Bound(expr: Any, outers: List[String])
    type Env = Map[Symbol.VarSym, Bound]

    def isApply(p: Product): Boolean = p.productPrefix == "ApplyDef" || p.productPrefix == "ApplySig" || p.productPrefix == "ApplyOp"

    def calleeOf(p: Product): String = symName(field[Any](field[Any](p, "symUse"), "sym"))

    def lineOf(p: Product): Int = field[SourceLocation](p, "loc").startLine

    def isPipe(p: Product): Boolean = p.productPrefix == "ApplyDef" && calleeOf(p) == "|>" && field[List[Any]](p, "exps").length == 2

    def binderOf(let: Product): Symbol.VarSym =
      if (let.getClass.getMethods.exists(_.getName == "bnd")) field[Symbol.VarSym](field[Any](let, "bnd"), "sym") else field[Symbol.VarSym](let, "sym")

    /** The expression a variable stands for, when it is let-bound in `env`. */
    def resolve(e: Any, env: Env): Any = e match {
      case p: Product if p.productPrefix == "Var" => env.get(field[Symbol.VarSym](p, "sym")).map(b => resolve(b.expr, env)).getOrElse(e)
      case _ => e
    }

    /** The lambda an expression is, seen through the lets and ascriptions around it. */
    def lambdaOf(e: Any, env: Env): Option[Product] = resolve(e, env) match {
      case p: Product if p.productPrefix == "Lambda" => Some(p)
      case p: Product if p.productPrefix == "Let" => lambdaOf(field[Any](p, "exp2"), env + (binderOf(p) -> Bound(field[Any](p, "exp1"), Nil)))
      case p: Product if p.productPrefix == "Ascribe" || p.productPrefix == "CheckedCast" || p.productPrefix == "UncheckedCast" => lambdaOf(field[Any](p, "exp"), env)
      case _ => None
    }

    /** The function an expression stands for when it is a call: the call itself, or the lambda (the eta-expansion of
      * a partial application or of a function passed by name) around one.
      */
    def denoted(e: Any, env: Env): Option[(String, Int)] = resolve(e, env) match {
      case p: Product if isApply(p) && !isPipe(p) => Some((calleeOf(p), lineOf(p)))
      case p: Product if p.productPrefix == "Let" => denoted(field[Any](p, "exp2"), env + (binderOf(p) -> Bound(field[Any](p, "exp1"), Nil)))
      case p: Product if p.productPrefix == "Lambda" || p.productPrefix == "Ascribe" || p.productPrefix == "CheckedCast" || p.productPrefix == "UncheckedCast" =>
        denoted(field[Any](p, "exp"), env)
      case _ => None
    }

    /** The stages of a `|>` chain in order: the call that produces the leftmost value, then each function piped into. */
    def stages(e: Any, env: Env): List[(String, Int)] = resolve(e, env) match {
      case p: Product if isPipe(p) =>
        val exps = field[List[Any]](p, "exps")
        stages(exps.head, env) ++ denoted(exps(1), env).toList
      case r => denoted(r, env).toList
    }

    def strLit(e: Any): Option[String] = e match {
      case p: Product if p.productPrefix == "Cst" =>
        field[Any](p, "cst") match {
          case c: Product if c.productPrefix == "Str" => Some(field[String](c, "lit"))
          case _ => None
        }
      case _ => None
    }

    // a let-bound expression is walked once: where its variable is first used as an argument, else at the `let`
    val consumed = scala.collection.mutable.Set.empty[Symbol.VarSym]

    // outers: the functions whose lambda arguments enclose the node, innermost first;
    // inPipe: the node is the left operand of a `|>` whose chain has already been recorded
    def go(node: Any, outers: List[String], env: Env, inPipe: Boolean): Unit = node match {
      case null | _: Type | _: UnkindedType | _: SourceLocation | _: Symbol | _: String | _: java.lang.Number | _: java.lang.Boolean => ()
      case p: Product =>
        p.productPrefix match {
          case "ApplyDef" if isPipe(p) =>
            if (!inPipe) {
              val chain = stages(p, env)
              for (((from, _), i) <- chain.zipWithIndex; (into, intoLine) <- chain.drop(i + 1)) sink.pipedInto(fn, from, into, intoLine)
            }
            val exps = field[List[Any]](p, "exps")
            go(exps.head, outers, env, inPipe = true)
            go(exps(1), outers, env, inPipe = false)
          case "ApplyDef" | "ApplySig" | "ApplyOp" =>
            val callee = calleeOf(p)
            val loc = lineOf(p)
            sink.calls(fn, callee, loc)
            outers.distinct.foreach(outer => sink.callsInLambdaArgOf(fn, callee, outer, loc))
            val exps = field[List[Any]](p, "exps")
            exps.zipWithIndex.foreach { case (e, i) =>
              val arg = resolve(e, env)
              strLit(arg).foreach(s => sink.argLit(fn, callee, i, s, loc))
              denoted(arg, env).foreach { case (g, _) => sink.argCall(fn, callee, i, g, loc) }
              val inLambda = lambdaOf(arg, env).nonEmpty
              e match {
                case v: Product if v.productPrefix == "Var" && env.contains(field[Symbol.VarSym](v, "sym")) =>
                  val sym = field[Symbol.VarSym](v, "sym")
                  if (!consumed(sym)) {
                    consumed += sym
                    val bound = env(sym)
                    go(bound.expr, if (inLambda) callee :: bound.outers else bound.outers, env, inPipe = false)
                  }
                case _ =>
                  go(e, if (inLambda) callee :: outers else outers, env, inPipe = false)
              }
            }
            p.productIterator.filter(x => !(x.asInstanceOf[AnyRef] eq exps)).foreach(x => go(x, outers, env, inPipe = false))
          case "Let" =>
            val sym = binderOf(p)
            val bound = field[Any](p, "exp1")
            go(field[Any](p, "exp2"), outers, env + (sym -> Bound(bound, outers)), inPipe = false)
            if (!consumed(sym)) go(bound, outers, env, inPipe = false)
          case "Cst" =>
            strLit(p).foreach(s => sink.strLit(fn, s, lineOf(p)))
          case "InvokeStaticMethod" | "InvokeMethod" | "InvokeConstructor" =>
            // Java interop: the callee is `package.Class.method` (constructors: `package.Class.<init>`).
            // The typed AST carries the resolved method for all three; the resolved AST knows the class only for
            // static methods and constructors, so instance methods are skipped at that stage.
            val methods = p.getClass.getMethods
            val loc = lineOf(p)
            def className(owner: java.lang.constant.ClassDesc): String = {
              val pkg = owner.packageName()
              if (pkg.isEmpty) owner.displayName() else pkg + "." + owner.displayName()
            }
            methods.find(m => m.getName == "method" || m.getName == "constructor").map(_.invoke(p)) match {
              case Some(jm) =>
                val ref = field[Any](jm, "ref")
                sink.calls(fn, className(field[java.lang.constant.ClassDesc](ref, "owner")) + "." + field[String](ref, "name"), loc)
              case None if methods.exists(_.getName == "clazz") =>
                val clazz = field[java.lang.constant.ClassDesc](p, "clazz")
                val name = if (methods.exists(_.getName == "methodName")) field[Any](field[Any](p, "methodName"), "name").toString else "<init>"
                sink.calls(fn, className(clazz) + "." + name, loc)
              case None => ()
            }
            p.productIterator.foreach(x => go(x, outers, env, inPipe = false))
          case "Handler" =>
            val symUse = field[Any](p, "symUse")
            sink.handles(fn, symName(field[Any](symUse, "sym")), lineOf(p))
            p.productIterator.foreach(x => go(x, outers, env, inPipe = false))
          case "Tag" if p.getClass.getName.contains("Expr") =>
            // an expression that builds the case; a `Tag` pattern (a match, a let with a pattern) is not a construction
            val symUse = field[Any](p, "symUse")
            sink.constructs(fn, symName(field[Any](symUse, "sym")), lineOf(p))
            p.productIterator.foreach(x => go(x, outers, env, inPipe = false))
          case _ =>
            p.productIterator.foreach(x => go(x, outers, env, inPipe = false))
        }
      case xs: Iterable[_] => xs.foreach(x => go(x, outers, env, inPipe))
      case _ => ()
    }
    go(body, Nil, Map.empty, inPipe = false)
  }
}

/** One TSV file per relation. Columns are tab-separated; text columns have tabs and newlines replaced by spaces.
  * Every name that goes into a row is also remembered by kind, for `Names.flix`.
  */
final class Sink(dir: Path) {
  // WhyNot: 既存の TSV を残さない。row が 1 件も出ない relation はファイルを開かないので、前回の走行で
  // 出ていた違反がそのまま残り、直した物を報告し続ける。
  Files.createDirectories(dir)
  Sink.deleteStaleTsv(dir)
  private val writers = scala.collection.mutable.Map.empty[String, PrintWriter]
  private def w(rel: String): PrintWriter = writers.getOrElseUpdate(rel, new PrintWriter(Files.newBufferedWriter(dir.resolve(rel + ".tsv"))))
  private def clean(s: String): String = s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')
  private def row(rel: String, cols: Any*): Unit = w(rel).println(cols.map(c => clean(c.toString)).mkString("\t"))

  val fnNames = scala.collection.mutable.TreeSet.empty[String]
  val effNames = scala.collection.mutable.TreeSet.empty[String]
  val modNames = scala.collection.mutable.TreeSet.empty[String]
  val caseNames = scala.collection.mutable.TreeSet.empty[String]
  val enumNames = scala.collection.mutable.TreeSet.empty[String]
  val typeNames = scala.collection.mutable.TreeSet.empty[String]
  private def modOf(qualified: String): Unit = {
    val i = qualified.lastIndexOf('.')
    if (i > 0) modNames += qualified.substring(0, i)
  }

  def defn(fn: String, name: String, mod: String, file: String, line: Int, isPub: Boolean): Unit = { fnNames += fn; modNames += mod; row("def", fn, name, mod, file, line, isPub) }
  def calls(caller: String, callee: String, line: Int): Unit = { fnNames += caller; fnNames += callee; modOf(callee); row("calls", caller, callee, line) }
  def effectOf(fn: String, eff: String): Unit = { fnNames += fn; effNames += eff; row("effect_of", fn, eff) }
  def handles(fn: String, eff: String, line: Int): Unit = { fnNames += fn; effNames += eff; row("handles", fn, eff, line) }
  def constructs(fn: String, enumCase: String, line: Int): Unit = { fnNames += fn; caseNames += enumCase; row("constructs", fn, enumCase, line) }
  def callsInLambdaArgOf(caller: String, callee: String, outer: String, line: Int): Unit = { fnNames += caller; fnNames += callee; fnNames += outer; row("calls_in_lambda", caller, callee, outer, line) }
  def argLit(caller: String, callee: String, i: Int, text: String, line: Int): Unit = { fnNames += caller; fnNames += callee; row("arg_lit", caller, callee, i, text, line) }
  def argCall(caller: String, callee: String, i: Int, argCallee: String, line: Int): Unit = { fnNames += caller; fnNames += callee; fnNames += argCallee; row("arg_call", caller, callee, i, argCallee, line) }
  def pipedInto(caller: String, from: String, into: String, line: Int): Unit = { fnNames += caller; fnNames += from; fnNames += into; row("piped_into", caller, from, into, line) }
  def strLit(fn: String, text: String, line: Int): Unit = { fnNames += fn; row("str_lit", fn, text, line) }
  def argTypeAll(fn: String, i: Int, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("arg_type_all", fn, i, tycon) }
  def retTypeAll(fn: String, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("ret_type_all", fn, tycon) }
  def caseTypeAll(enum0: String, enumCase: String, i: Int, tycon: String): Unit = { enumNames += enum0; caseNames += enumCase; typeNames += tycon; row("case_type_all", enum0, enumCase, i, tycon) }
  def argType(fn: String, i: Int, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("arg_type", fn, i, tycon) }
  def retType(fn: String, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("ret_type", fn, tycon) }
  def caseType(enum0: String, enumCase: String, i: Int, tycon: String): Unit = { enumNames += enum0; caseNames += enumCase; typeNames += tycon; row("case_type", enum0, enumCase, i, tycon) }
  def effAlias(alias: String, eff: String): Unit = { effNames += alias; effNames += eff; row("eff_alias", alias, eff) }
  def enumDef(enum0: String, mod: String, file: String, line: Int, isPub: Boolean): Unit = { enumNames += enum0; modNames += mod; row("enum", enum0, mod, file, line, isPub) }
  def effDef(eff: String, mod: String, file: String, line: Int, isPub: Boolean): Unit = { effNames += eff; modNames += mod; row("eff", eff, mod, file, line, isPub) }
  def close(): Unit = writers.values.foreach(_.close())
}

object Sink {
  private def deleteStaleTsv(dir: Path): Unit = {
    val entries = Files.list(dir)
    try entries.iterator().asScala.filter(_.toString.endsWith(".tsv")).toList.foreach(Files.delete)
    finally entries.close()
  }
}

/** `Names.flix`: the names of the facts as Flix enums (`Fn` / `Eff` / `Mod` / `Case` / `Enum` / `Type`).
  *
  * A case is the qualified name with every character that is not an ASCII letter or digit replaced by `_` and the
  * first letter upper-cased (`Auth.permit` -> `Auth_permit`, `java.lang.System.currentTimeMillis` ->
  * `Java_lang_System_currentTimeMillis`); a name that would collide gets a trailing `_`. Names that do not start with a
  * letter (`++`, `|>`, `bug!`) are left out: no rule needs them and they cannot be enum cases. The root module (the empty
  * name) is `Mod.Root`.
  *
  * WhyNot: the enums derive `Eq, Order` but not `ToString`. Deriving `ToString` on an enum of a few thousand cases
  * takes the compiler minutes (measured: 80 s at 3,000 cases, 6 s without); the qualified name comes from the table.
  */
object Names {
  /** Upper-case words the parser does not accept as a case name (`case Static`). */
  val reserved: Set[String] = Set("Static", "Pure", "Univ", "Impure")

  def caseOf(name: String): String = {
    if (name.isEmpty) "Root"
    else {
      val s = name.map(c => if (c < 128 && c.isLetterOrDigit) c else '_')
      val c = s.head.toUpper + s.tail
      if (reserved(c)) c + "_" else c
    }
  }

  /** The root module (the empty name) is the case `Root`. */
  def cases(names: Iterable[String]): List[(String, String)] = {
    val taken = scala.collection.mutable.Set.empty[String]
    names.filter(n => n.isEmpty || (n.head < 128 && n.head.isLetter)).toList.map { n =>
      var c = caseOf(n)
      while (taken(c)) c += "_"
      taken += c
      (n, c)
    }
  }

  private def quoted(s: String): String = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$") + "\""

  /** The table is split into chunks: one list literal of ten thousand tuples is a JVM method too large to compile. */
  val chunkSize = 400

  def enumSource(kind: String, names: Iterable[String]): String = {
    val cs = cases(names)
    val body = if (cs.isEmpty) "        case NoNames\n" else cs.map { case (_, c) => s"        case $c\n" }.mkString
    val fnName = kind.head.toLower + kind.tail + "Table"
    val chunks = cs.grouped(chunkSize).toList
    val parts = chunks.indices.map(i => s"$fnName$i()").mkString(" ::: ")
    val chunkDefs = chunks.zipWithIndex.map { case (chunk, i) =>
      val table = chunk.map { case (n, c) => s"        (${quoted(n)}, ${quoted(c)}, $kind.$c)" }.mkString(",\n")
      s"""    def $fnName$i(): List[(String, String, $kind)] = List#{
$table
    }
"""
    }.mkString("\n")
    s"""    pub enum $kind with Eq, Order {
$body    }

    /// Every $kind: (qualified name as the compiler prints it, the spelling of the case, the case).
    pub def $fnName(): List[(String, String, $kind)] = ${if (chunks.isEmpty) "Nil" else parts}

$chunkDefs"""
  }

  def write(path: Path, sink: Sink): Unit = {
    val src = "/// Generated by flixlint from the facts of the linted sources. Do not edit.\n" +
      "pub mod Flixlint.Names {\n" +
      enumSource("Fn", sink.fnNames) + "\n" +
      enumSource("Eff", sink.effNames) + "\n" +
      enumSource("Mod", sink.modNames) + "\n" +
      enumSource("Case", sink.caseNames) + "\n" +
      enumSource("Enum", sink.enumNames) + "\n" +
      enumSource("Type", sink.typeNames) +
      "}\n"
    Option(path.getParent).foreach(Files.createDirectories(_))
    Files.writeString(path, src)
  }
}

/** Stage 1: facts from the typed AST returned by `Flix.check()`. */
object Typed {
  import Facts._

  /** The effects of a signature, with type aliases expanded to their members (`Db = DbRead + DbWrite` gives both). */
  def effNames(t: Type): List[String] = t match {
    case Type.Alias(_, _, tpe, _) => effNames(tpe)
    case Type.Cst(TypeConstructor.Effect(sym, _), _) => List(symName(sym))
    case Type.Apply(t1, t2, _) if isSetOp(t.typeConstructor) => effNames(t1) ++ effNames(t2)
    case _ => Nil
  }

  def isSetOp(tc: Option[TypeConstructor]): Boolean = tc match {
    case Some(TypeConstructor.Union | TypeConstructor.Intersection | TypeConstructor.Difference | TypeConstructor.Complement | TypeConstructor.SymmetricDiff) => true
    case _ => false
  }

  def headName(t: Type): String = t match {
    case Type.Alias(symUse, _, _, _) => symName(symUse.sym)
    case _ => t.typeConstructor match {
      case Some(TypeConstructor.Enum(sym, _)) => symName(sym)
      case Some(TypeConstructor.Struct(sym, _)) => symName(sym)
      case Some(TypeConstructor.Effect(sym, _)) => symName(sym)
      case Some(tc) => tc.toString
      case None => "?"
    }
  }

  /** Every named type constructor in a type, outermost first (`List[ColumnName]` gives `List`, `ColumnName`). An alias is
    * listed by its own name and its arguments (its target is not); type variables and record / schema rows are left out.
    */
  def allNames(t: Type): List[String] = t match {
    case Type.Alias(symUse, args, _, _) => symName(symUse.sym) :: args.flatMap(allNames)
    case Type.Apply(t1, t2, _) => allNames(t1) ++ allNames(t2)
    case Type.Var(_, _) => Nil
    case Type.Cst(TypeConstructor.RecordRowExtend(_) | TypeConstructor.SchemaRowExtend(_), _) => Nil
    case _ => List(headName(t))
  }

  def emit(root: TypedAst.Root, sink: Sink): Unit = {
    val allDefs: Iterable[TypedAst.Def] = root.defs.values ++ root.instances.values.flatMap(_.defs)
    // every function the sources could call is a name, so a rule can disallow one that is not called yet
    allDefs.filterNot(synthetic).foreach(d => sink.fnNames += symName(d.sym))
    root.sigs.keys.foreach(s => sink.fnNames += symName(s))
    root.effects.values.flatMap(_.ops).foreach(op => sink.fnNames += symName(op.sym))
    root.effects.keys.foreach(e => sink.effNames += symName(e))
    for (d <- allDefs if !synthetic(d); file <- sourceFile(d.loc)) {
      val fn = symName(d.sym)
      sink.defn(fn, d.sym.name, d.sym.namespace.mkString("."), file, d.loc.startLine, d.spec.mod.isPublic)
      effNames(d.spec.eff).distinct.foreach(e => sink.effectOf(fn, e))
      d.spec.fparams.toList.zipWithIndex.foreach { case (fp, i) =>
        sink.argType(fn, i, headName(fp.tpe))
        allNames(fp.tpe).distinct.foreach(n => sink.argTypeAll(fn, i, n))
      }
      sink.retType(fn, headName(d.spec.retTpe))
      allNames(d.spec.retTpe).distinct.foreach(n => sink.retTypeAll(fn, n))
      walkBody(fn, d.exp, sink)
    }
    for ((sym, e) <- root.enums; file <- sourceFile(e.loc)) {
      sink.enumDef(symName(sym), sym.namespace.mkString("."), file, e.loc.startLine, e.mod.isPublic)
      for ((cs, c) <- e.cases; (t, i) <- c.tpes.zipWithIndex) {
        sink.caseType(symName(sym), symName(cs), i, headName(t))
        allNames(t).distinct.foreach(n => sink.caseTypeAll(symName(sym), symName(cs), i, n))
      }
    }
    for ((sym, e) <- root.effects; file <- sourceFile(e.loc))
      sink.effDef(symName(sym), sym.namespace.mkString("."), file, e.loc.startLine, e.mod.isPublic)
    // aliases of packages and the standard library are listed too: a rule that names `Db` means its members
    for ((sym, a) <- root.typeAliases; e <- effNames(a.tpe).distinct)
      sink.effAlias(symName(sym), e)
  }
}

/** Stage 2: facts from the resolved AST, stopping before the kinder and the typer.
  *
  * WhyNot: `Flix.check()` has no public way to stop early, so the phases are called directly in the same order the
  * compiler does. Inputs and the JVM class list live in private fields of `Flix`; they are read by reflection because
  * building them by hand would duplicate the library-loading logic of the compiler.
  */
object Resolved {
  import Facts._

  def run(flix: Flix): (ResolvedAst.Root, List[ca.uwaterloo.flix.language.CompilationMessage]) = {
    implicit val f: Flix = flix
    val initThreadPool = flix.getClass.getDeclaredMethod("initThreadPool")
    initThreadPool.setAccessible(true)
    initThreadPool.invoke(flix)
    flix.phaseTimers = scala.collection.mutable.ArrayBuffer.empty
    val getInputs = flix.getClass.getDeclaredMethod("getInputs")
    getInputs.setAccessible(true)
    val inputs = getInputs.invoke(flix).asInstanceOf[List[Input]]
    val getClasses = flix.getClass.getDeclaredMethod("availableClasses")
    getClasses.setAccessible(true)
    val availableClasses = getClasses.invoke(flix).asInstanceOf[ca.uwaterloo.flix.language.ast.shared.AvailableClasses]
    val cs = ChangeSet.Everything
    val (readAst, e1) = phase.Reader.run(inputs, availableClasses)
    val (tokens, e2) = phase.Lexer.run(readAst, Map.empty, cs)
    val (cst, e3) = phase.Parser2.run(tokens, ca.uwaterloo.flix.language.ast.SyntaxTree.empty, cs)
    val (optWeeded, e4) = phase.Weeder2.run(readAst, None, cst, ca.uwaterloo.flix.language.ast.WeededAst.empty, cs)
    val weeded = optWeeded.getOrElse(sys.error("flixlint: weeder produced no AST"))
    val desugared = phase.Desugar.run(weeded, ca.uwaterloo.flix.language.ast.DesugaredAst.empty, cs)
    val (named, e5) = phase.Namer.run(desugared)
    val (resolved, e6) = phase.Resolver.run(named, ResolvedAst.empty, cs)
    val shutdown = flix.getClass.getDeclaredMethod("shutdownThreadPool")
    shutdown.setAccessible(true)
    shutdown.invoke(flix)
    (resolved, e1 ++ e2 ++ e3 ++ e4 ++ e5 ++ e6)
  }

  /** The effects of a signature, with type aliases expanded to their members. */
  def effNames(t: UnkindedType): List[String] = t match {
    case UnkindedType.Alias(_, _, tpe, _) => effNames(tpe)
    case UnkindedType.Effect(sym, _) => List(symName(sym))
    case UnkindedType.Apply(t1, t2, _) if isSetOp(t) => effNames(t1) ++ effNames(t2)
    case _ => Nil
  }

  def isSetOp(t: UnkindedType): Boolean = t match {
    case UnkindedType.Apply(t1, _, _) => isSetOp(t1)
    case UnkindedType.Cst(tc, _) => Typed.isSetOp(Some(tc))
    case _ => false
  }

  def headName(t: UnkindedType): String = t match {
    case UnkindedType.Alias(symUse, _, _, _) => symName(symUse.sym)
    case UnkindedType.Enum(sym, _) => symName(sym)
    case UnkindedType.Struct(sym, _) => symName(sym)
    case UnkindedType.Effect(sym, _) => symName(sym)
    case UnkindedType.Cst(tc, _) => tc.toString
    case UnkindedType.Apply(t1, _, _) => headName(t1)
    case UnkindedType.Arrow(_, _, _) => "Arrow"
    case UnkindedType.Var(_, _) => "?"
    case other => other.getClass.getSimpleName
  }

  /** Every named type constructor in a type, outermost first (see `Typed.allNames`). */
  def allNames(t: UnkindedType): List[String] = t match {
    case UnkindedType.Alias(symUse, args, _, _) => symName(symUse.sym) :: args.flatMap(allNames)
    case UnkindedType.Apply(t1, t2, _) => allNames(t1) ++ allNames(t2)
    case UnkindedType.Arrow(eff, _, _) => "Arrow" :: eff.toList.flatMap(allNames)
    case UnkindedType.Var(_, _) => Nil
    case UnkindedType.Cst(TypeConstructor.RecordRowExtend(_) | TypeConstructor.SchemaRowExtend(_), _) => Nil
    case _ => List(headName(t))
  }

  def emit(root: ResolvedAst.Root, sink: Sink): Unit = {
    val allDefs: Iterable[ResolvedAst.Declaration.Def] = root.defs.values ++ root.instances.values.flatMap(_.defs)
    allDefs.filterNot(synthetic).foreach(d => sink.fnNames += symName(d.sym))
    root.traits.values.flatMap(_.sigs.values).foreach(s => sink.fnNames += symName(s.sym))
    root.effects.values.flatMap(_.ops).foreach(op => sink.fnNames += symName(op.sym))
    root.effects.keys.foreach(e => sink.effNames += symName(e))
    for (d <- allDefs if !synthetic(d); file <- sourceFile(d.loc)) {
      val fn = symName(d.sym)
      sink.defn(fn, d.sym.name, d.sym.namespace.mkString("."), file, d.loc.startLine, d.spec.mod.isPublic)
      d.spec.eff.toList.flatMap(effNames).distinct.foreach(e => sink.effectOf(fn, e))
      d.spec.fparams.toList.zipWithIndex.foreach { case (fp, i) =>
        sink.argType(fn, i, fp.tpe.map(headName).getOrElse("?"))
        fp.tpe.toList.flatMap(allNames).distinct.foreach(n => sink.argTypeAll(fn, i, n))
      }
      sink.retType(fn, headName(d.spec.tpe))
      allNames(d.spec.tpe).distinct.foreach(n => sink.retTypeAll(fn, n))
      walkBody(fn, d.exp, sink)
    }
    for ((sym, e) <- root.enums; file <- sourceFile(e.loc)) {
      sink.enumDef(symName(sym), sym.namespace.mkString("."), file, e.loc.startLine, e.mod.isPublic)
      for (c <- e.cases; (t, i) <- c.tpes.zipWithIndex) {
        sink.caseType(symName(sym), symName(c.sym), i, headName(t))
        allNames(t).distinct.foreach(n => sink.caseTypeAll(symName(sym), symName(c.sym), i, n))
      }
    }
    for ((sym, e) <- root.effects; file <- sourceFile(e.loc))
      sink.effDef(symName(sym), sym.namespace.mkString("."), file, e.loc.startLine, e.mod.isPublic)
    for ((sym, a) <- root.typeAliases; e <- effNames(a.tpe).distinct)
      sink.effAlias(symName(sym), e)
  }
}
