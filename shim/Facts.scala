package flixlint

import ca.uwaterloo.flix.api.{Bootstrap, Flix, InstalledPackage}
import ca.uwaterloo.flix.language.ast.shared.{Mountpoint, Origin, PackageId, Repository, SecurityContext, Source, SourceName}
import ca.uwaterloo.flix.language.ast.{ChangeSet, ReadAst, ResolvedAst, SourceLocation, Symbol, Type, TypeConstructor, TypedAst, UnkindedType}
import ca.uwaterloo.flix.language.phase
import ca.uwaterloo.flix.tools.pkg.{Dependency, Manifest, ManifestParser}
import ca.uwaterloo.flix.util.{Formatter, LibLevel, Options, Result}

import java.io.PrintWriter
import java.nio.file.{Files, Path, Paths}
import scala.jdk.CollectionConverters._

/** Extracts language-level facts from the Flix compiler's AST and writes them as TSV, one file per relation, plus
  * `Flixlint/Names.flix`: one Flix enum per kind of name (Fn / Eff / Mod / Case / Enum / Type) with every name the facts mention,
  * so that rules refer to functions, effects and types as enum cases and a stale name fails to compile.
  *
  * Usage: Facts --out DIR [--names-out FILE] [--names-of RULES] [--stage typed|resolved] [--spans FILE (see Spans)] [--pkg FPKG]... [--jar JAR]...
  *               [--project-root DIR] [--offline] SRC...
  *
  * WhyNot: the walker dispatches on `productPrefix` and reads fields by name instead of pattern matching on the
  * TypedAst / ResolvedAst case classes. The two ASTs share the node names and field names that matter here, so one
  * walker serves both stages, and a compiler upgrade that renames a node breaks in one place with a clear message.
  */
object Facts {

  final case class Args(out: Path, namesOut: Option[Path], stage: String, pkgs: List[Path], jars: List[Path], srcs: List[Path], projectRoot: Option[Path],
                        namesOf: Option[Path] = None, offline: Boolean = false)

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
    var namesOf: Option[Path] = None
    var offline = false
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
        case "--names-of" => namesOf = Some(Paths.get(value("--names-of"))); i += 2
        case "--offline" => offline = true; i += 1
        case opt if opt.startsWith("--") => throw new UsageError(s"unknown option $opt")
        case s => srcs = srcs :+ Paths.get(s); i += 1
      }
    }
    if (out == null) throw new UsageError("--out DIR is required")
    if (srcs.isEmpty) throw new UsageError("at least one source directory or file is required")
    if (stage != "typed" && stage != "resolved") throw new UsageError(s"unknown --stage $stage (typed or resolved)")
    Args(out, namesOut, stage, pkgs, jars, srcs, projectRoot, namesOf, offline)
  }

  // Exit codes: 0 facts written, 3 the sources do not compile, 4 the caller or the environment is wrong.
  // WhyNot: a crash must not leave exit 1. bin/flixlint reserves 1 for "there are violations", so an
  // uncaught exception here would read to CI as a report of new violations.
  def main(argv: Array[String]): Unit = {
    val code = guarded(argv)
    if (code != 0) sys.exit(code)
  }

  /** `run` with the spans option split off, and a usage error or a crash turned into exit code 4. */
  def guarded(argv: Array[String]): Int = guardedWith(argv)(run)

  /** `guarded` over another way of running the walk (the resident server keeps its compiler between runs). */
  def guardedWith(argv: Array[String])(run: (Array[String], Option[Path]) => Int): Int =
    try { val (spans, rest) = Spans.split(argv); run(rest, spans) }
    catch {
      case e: UsageError =>
        System.err.println(s"flixlint: ${e.getMessage}")
        4
      case e: Generic.LimitError =>
        System.err.println(s"flixlint: ${e.getMessage}")
        4
      case e: Throwable =>
        System.err.println(s"flixlint: the fact walker failed: ${e.getClass.getName}: ${e.getMessage}")
        e.printStackTrace()
        4
    }

  /** Writes the facts; 0, or 3 when the sources do not compile (the errors are on stderr). */
  def run(argv: Array[String], spans: Option[Path] = None): Int = {
    val args = parseArgs(argv)
    val t0 = System.nanoTime()
    val project = projectOf(args)
    val flix = compiler(project.deps)
    val sources = sourcesOf(args, project)
    sources.compiled.foreach(f => flix.addFile(f, SecurityContext.Unrestricted))
    write(flix, args, sources, spans, t0)
  }

  /** The packages and jars of the run and the project's own sources: the ones given by hand (`--pkg` / `--jar`), or
    * those Flix's `Bootstrap` sets up for the project's `flix.toml`, the way `flix check` does (it installs what is
    * missing, so it may reach the network; with `--offline` it stops there instead).
    */
  def projectOf(args: Args): Project =
    if (args.pkgs.nonEmpty || args.jars.nonEmpty) Project(Deps.ofPaths(args.pkgs, args.jars, args.projectRoot, args.srcs), None)
    else Deps.findRoot(args.projectRoot, args.srcs) match {
      case None => Project(Deps(Nil, Nil, Map.empty), None)
      case Some(root) => Deps.ofBootstrap(root, args.offline)
    }

  /** The dependencies of a run, and the sources `Bootstrap` found for the project (None when it was not used). */
  final case class Project(deps: Deps, sources: Option[List[Path]])

  /** What a run compiles, and which of those files its facts and index are about.
    *
    * `compiled` are the paths the compiler keys the sources by: in a project, every source `Bootstrap` found (the set
    * `flix check` compiles, by the same absolute paths, so a `check` and a lint share one compiler), and a SRC outside
    * the project. `files` are the `.flix` files under each SRC as the facts name them (the path as given on the command
    * line), and `shown` names each compiled path that is one of them; a compiled file under no SRC is compiled and left
    * out of the facts, the index and `Names.flix` (`sourceFile`).
    */
  final case class Sources(compiled: List[Path], files: List[Path], shown: Map[Path, Path])

  def sourcesOf(args: Args, project: Project): Sources = {
    val all = project.sources.getOrElse(Nil)
    val under = args.srcs.flatMap { s =>
      val abs = s.toAbsolutePath.normalize
      if (Files.isDirectory(abs) && all.exists(_.startsWith(abs)))
        all.filter(_.startsWith(abs)).sorted.map(f => f -> s.resolve(abs.relativize(f)))
      else listFlix(s).map(f => (if (all.isEmpty) f.normalize else f.toAbsolutePath.normalize) -> f)
    }
    Sources((all ++ under.map(_._1).filterNot(all.contains)).distinct, under.map(_._2), under.toMap)
  }

  /** A compiler over the dependencies, with no source added yet. */
  def compiler(deps: Deps): Flix = {
    // The packages, the jars and the mount table are fixed when the compiler is made (Flix 0.78).
    val flix = new Flix(deps.pkgs, deps.jars, deps.mounts)
    // The options of the CLI's `flix check` with its own defaults (`Options.Default` with `lib = All`, `installDeps`, the
    // GitHub token; subeffecting none), so the sources type the same way it types them. Only the progress bar is off.
    flix.setOptions(Options.Default.copy(lib = LibLevel.All, installDeps = true, githubToken = sys.env.get("GITHUB_TOKEN").filter(_.nonEmpty), progress = false))
    flix
  }

  /** Compiles `files` (already added to `flix`) to the stage of `args` and writes the facts; 0, or 3 when they do
    * not compile. `t0` is when the run started, for the timing line.
    */
  def write(flix: Flix, args: Args, sources: Sources, spans: Option[Path], t0: Long): Int = showing(sources) {
    val files = sources.files
    val t1 = System.nanoTime()
    var genericJob: Option[Background] = None

    val sink = new Sink(args.out)
    // WhyNot: the set of files is not left to be read off the definitions. A file that holds only type aliases, or
    // only a trait, has no `def`, `enum` or `eff` row, so an `allowInFile` naming it would be refused as a file the
    // sources do not have.
    files.foreach(f => sink.sourceFile(f.toString))
    val (nErrors, phaseNs) = args.stage match {
      case "typed" =>
        val (optRoot, errors) = flix.check()
        val t2 = System.nanoTime()
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(optRoot)))
        optRoot match {
          case Some(root) =>
            genericJob = Some(new Background(generic(root, args, files)))
            Typed.emit(root, sink); spans.foreach(Spans.typed(root, _))
          case None => Generic.clear(args.out.resolve("generic")); System.err.println("flixlint: no typed AST (compilation errors above)")
        }
        (errors.length, t2 - t1)
      case "resolved" =>
        val (root, errors) = Resolved.run(flix)
        val t2 = System.nanoTime()
        errors.foreach(e => System.err.println(e.messageWithLoc(flix.getFormatter)(None)))
        genericJob = Some(new Background(generic(root, args, files)))
        Resolved.emit(root, sink)
        spans.foreach(Spans.resolved(root, _))
        (errors.length, t2 - t1)
      case other => throw new UsageError(s"unknown --stage $other (typed or resolved)")
    }
    sink.close()
    Names.write(args.namesOut.getOrElse(args.out.resolve("Names.flix")), args.out, sink, args.namesOf.map(p => Names.usedIn(Files.readString(p))))
    val walked = System.nanoTime()
    val genericNs = genericJob.map(_.join()).getOrElse(0L)
    val t3 = System.nanoTime()
    System.err.println(f"flixlint facts: stage=${args.stage} files=${files.length} compile=${phaseNs / 1e9}%.1fs walk=${(walked - t1 - phaseNs) / 1e9}%.2fs generic=${genericNs / 1e9}%.2fs (alongside) total=${(t3 - t0) / 1e9}%.1fs")
    if (nErrors > 0) 3 else 0
  }

  /** A computation on a thread of its own; `join` waits for it and gives its result, or throws what it threw.
    * WhyNot: the generic walk is not run after the fact walker. Both only read the compiler's AST and write their own
    * tables, so running them side by side adds the longer of the two to a run instead of both. The thread's stack is as
    * deep as the main thread's (bin/flixlint runs the JVM with -Xss32m): the walk recurses down the AST.
    */
  final class Background(body: => Long) {
    @volatile private var result: Either[Throwable, Long] = Right(0L)
    private val thread = new Thread(null, () => result = (try Right(body) catch { case e: Throwable => Left(e) }), "flixlint-generic", 64L << 20)
    thread.start()
    def join(): Long = { thread.join(); result.fold(e => throw e, identity) }
  }

  /** The generic AST of `root` beside the facts (`<out>/generic`, read by Flixlint.Ast), with the names the rule file
    * (`--names-of`) writes; how long it took (ns).
    */
  private def generic(root: Product, args: Args, files: List[Path]): Long = {
    val t = System.nanoTime()
    Generic.emitTo(root, args.stage, files, args.out.resolve("generic"), args.namesOf)
    System.nanoTime() - t
  }

  def listFlix(p: Path): List[Path] =
    if (Files.isDirectory(p)) {
      // Closed: the resident server walks the sources on every run.
      val entries = Files.walk(p)
      try entries.iterator().asScala.filter(f => f.toString.endsWith(".flix") && Files.isRegularFile(f)).toList.sorted
      finally entries.close()
    }
    else if (Files.isRegularFile(p)) List(p)
    else throw new UsageError(s"$p: no such source file or directory")

  /** The packages and jars to put on the compiler's path, and the root project's mount table (`mount = "fge"` in
    * `flix.toml` makes `use fge::X` name the package's `X`).
    */
  final case class Deps(pkgs: List[InstalledPackage], jars: List[Path], mounts: Map[Mountpoint, PackageId])

  /** The dependencies of a project come from one place: the compiler's own `Bootstrap`, which `flix check` runs
    * (`ofBootstrap`). Only `--pkg` / `--jar` given by hand bypass it (`ofPaths`, for tools outside a project).
    *
    * WhyNot: flixlint does not read `flix.toml` and `lib/` itself (it did up to 0.8.0). A second reading of the manifest
    * and of lib/ had to follow every Flix upgrade, and stopped where `flix check` installs what is missing.
    */
  object Deps {
    /** `--pkg` / `--jar` given by hand. A package is named after where `flix check` unpacks it
      * (`lib/github/<owner>/<name>/<version>/<name>-<version>.fpkg`), its own mounts are read from the manifest next to
      * it, and the root mounts from the project's `flix.toml` when there is one.
      */
    def ofPaths(pkgs: List[Path], jars: List[Path], explicitRoot: Option[Path], srcs: List[Path]): Deps = {
      val installed = pkgs.map { p =>
        val abs = p.toAbsolutePath.normalize
        val parts = abs.iterator().asScala.map(_.toString).toVector
        val i = parts.lastIndexOf("github")
        // WhyNot: not just "enough segments after github/". A deeper path would shift owner and name by a segment and
        // give the package another id, so the shape is matched exactly, file name included.
        if (i < 0 || parts.length != i + 5 || parts(i + 4) != s"${parts(i + 2)}-${parts(i + 3)}.fpkg")
          throw new UsageError(s"--pkg $p: expected a path of the form .../github/<owner>/<name>/<version>/<name>-<version>.fpkg")
        val id = PackageId(Repository.GitHub, parts(i + 1), parts(i + 2))
        val nested = abs.resolveSibling(abs.getFileName.toString.stripSuffix(".fpkg") + ".toml")
        val mounts = if (Files.isRegularFile(nested)) parse(nested).mounts else Map.empty[Mountpoint, PackageId]
        InstalledPackage(abs, id, SecurityContext.Unrestricted, mounts)
      }
      val rootMounts = findRoot(explicitRoot, srcs).map(r => parse(r.resolve("flix.toml")).mounts).getOrElse(Map.empty[Mountpoint, PackageId])
      Deps(installed, jars, rootMounts)
    }

    /** WhyNot: the search upwards does not run to `/`. Above the current directory sits whatever the machine
      * happens to have, and a `flix.toml` found there describes another project.
      */
    def findRoot(explicitRoot: Option[Path], srcs: List[Path]): Option[Path] = {
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

    /** The packages and jars `Bootstrap` sets up for the project (installing what is missing into `lib/`, as
      * `flix check` does), and its sources. With `offline`, a run that would reach the network stops instead, naming
      * what it wanted. A failure is a usage error with Flix's message; what `Bootstrap` prints goes to stderr only then.
      * When `lib/` changed (something was installed) one line says what.
      *
      * WhyNot: `Bootstrap.mkFlix` is not used. Its options are the ones `flix check` builds with; the walk needs no
      * progress bar (`compiler`), and the packages, jars and mounts are the same.
      */
    def ofBootstrap(root: Path, offline: Boolean): Project = {
      val said = new java.io.ByteArrayOutputStream()
      val out = new java.io.PrintStream(said, true, "UTF-8")
      val before = libFiles(root)
      val wanted = scala.collection.mutable.ListBuffer.empty[String]
      val result = if (offline) withoutNetwork(wanted)(Bootstrap.bootstrap(root, githubToken)(Formatter.NoFormatter, out))
                   else Bootstrap.bootstrap(root, githubToken)(Formatter.NoFormatter, out)
      // the packages and jars, not the resolver's own files beside them (`.x.jar.checked`, `x.jar__sha1`)
      val added = libFiles(root).filterNot { case (p, size) => before.get(p).contains(size) }.keys
        .map(_.getFileName.toString).filter(n => !n.startsWith(".") && (n.endsWith(".jar") || n.endsWith(".fpkg"))).toList.sorted
      if (added.nonEmpty)
        System.err.println(s"flixlint: Flix installed ${added.length} into ${root.resolve("lib")}: ${added.take(3).mkString(", ")}${if (added.length > 3) ", ..." else ""}")
      result match {
        case Result.Ok(b) if wanted.isEmpty =>
          val pf = b.projectFiles
          val mounts = parse(root.resolve("flix.toml")).mounts
          Project(Deps(pf.pkgs, pf.jars, mounts), Some(pf.sources.map(_.toAbsolutePath.normalize)))
        case _ if wanted.nonEmpty =>
          throw new UsageError(s"$root: --offline, and Flix needed the network for ${wanted.head}; run 'flix check' there once")
        case Result.Err(e) =>
          System.err.print(said.toString("UTF-8"))
          throw new UsageError(s"$root: Flix could not set up the project's dependencies: ${e.message(Formatter.NoFormatter)}")
        case _ => throw new IllegalStateException("unreachable")
      }
    }

    /** The token `flix` uses for GitHub, from the same variable. */
    private def githubToken: Option[String] = sys.env.get("GITHUB_TOKEN").filter(_.nonEmpty)

    /** `run` with every connection through Java's proxy selector sent to a closed port, the URIs it wanted collected.
      * WhyNot: not a check of lib/ written here. That would be a second reading of the manifest beside `Bootstrap`.
      */
    private def withoutNetwork[A](wanted: scala.collection.mutable.ListBuffer[String])(run: => A): A = {
      val previous = java.net.ProxySelector.getDefault
      java.net.ProxySelector.setDefault(new java.net.ProxySelector {
        def select(uri: java.net.URI): java.util.List[java.net.Proxy] = {
          wanted.synchronized(wanted += uri.toString)
          java.util.List.of(new java.net.Proxy(java.net.Proxy.Type.HTTP, new java.net.InetSocketAddress("127.0.0.1", 9)))
        }
        def connectFailed(uri: java.net.URI, sa: java.net.SocketAddress, e: java.io.IOException): Unit = ()
      })
      try run finally java.net.ProxySelector.setDefault(previous)
    }

    /** The files under `lib/` and their sizes. */
    private def libFiles(root: Path): Map[Path, Long] = {
      val lib = root.resolve("lib")
      if (!Files.isDirectory(lib)) Map.empty
      else {
        val entries = Files.walk(lib)
        try entries.iterator().asScala.filter(Files.isRegularFile(_)).map(f => root.relativize(f) -> Files.size(f)).toMap
        finally entries.close()
      }
    }

    /** The mount table of the project's `flix.toml` (`mount = "fge"`). */
    def mountsOf(root: Path): Map[Mountpoint, PackageId] = parse(root.resolve("flix.toml")).mounts

    private def parse(toml: Path): Manifest = ManifestParser.parse(toml) match {
      case Result.Ok(m) => m
      case Result.Err(e) => throw new UsageError(s"$toml: ${e.message(Formatter.NoFormatter)}")
    }
  }

  // ---- generic helpers over the AST (both stages) ----

  def field[A](node: Any, name: String): A = Accessors.of(node.getClass, name) match {
    case Some(m) => m.invoke(node).asInstanceOf[A]
    case None => throw new NoSuchMethodException(s"${node.getClass.getName}.$name()")
  }

  /** Whether the node's class has a public accessor (a method without parameters) of that name. */
  def hasField(node: Any, name: String): Boolean = Accessors.of(node.getClass, name).nonEmpty

  /** The public accessors of a class by name, looked up once per class.
    *
    * WhyNot: not `getClass.getMethod` / `getMethods` at every node. The walkers visit hundreds of thousands of nodes,
    * and each of those calls searches the class and copies its methods; it was most of the time of the walk.
    */
  private object Accessors {
    private val table = new ClassValue[java.util.concurrent.ConcurrentHashMap[String, Option[java.lang.reflect.Method]]] {
      override def computeValue(c: Class[_]) = new java.util.concurrent.ConcurrentHashMap[String, Option[java.lang.reflect.Method]]()
    }
    def of(c: Class[_], name: String): Option[java.lang.reflect.Method] =
      table.get(c).computeIfAbsent(name, n => c.getMethods.find(m => m.getName == n && m.getParameterCount == 0))
  }

  /** The file a location is in, for the project's own sources only (the standard library is also a `PathName`,
    * under a virtual path, so the origin is what tells them apart). While a run writes its facts (`showing`), only the
    * files under its SRC, by the name the facts give them.
    */
  def sourceFile(loc: SourceLocation): Option[String] = (loc.source.origin, loc.source.sourceName) match {
    case (Origin.User, SourceName.PathName(p)) => shown match {
      case Some(names) => names.get(p.normalize).map(_.toString)
      case None => Some(p.toString)
    }
    case _ => None
  }

  /** Whether a location is in a project file that is compiled but under no SRC of the run (`sourcesOf`). */
  def hidden(loc: SourceLocation): Boolean = (loc.source.origin, loc.source.sourceName) match {
    case (Origin.User, SourceName.PathName(_)) => sourceFile(loc).isEmpty
    case _ => false
  }

  @volatile private var shown: Option[Map[Path, Path]] = None

  /** `body` with `sourceFile` naming the files of `sources` only. The walkers of one run (the facts, the generic AST on
    * its own thread, the index) all read it; runs never overlap (the resident server runs one at a time).
    */
  def showing[A](sources: Sources)(body: => A): A = {
    shown = Some(sources.shown.map { case (k, v) => k.normalize -> v })
    try body finally shown = None
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
      if (hasField(let, "bnd")) field[Symbol.VarSym](field[Any](let, "bnd"), "sym") else field[Symbol.VarSym](let, "sym")

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
            // The line of the callee's name, not of the call: a call's location starts at a comment written above it.
            val loc = field[SourceLocation](field[Any](p, "symUse"), "loc").startLine
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
            val loc = lineOf(p)
            def className(owner: java.lang.constant.ClassDesc): String = {
              val pkg = owner.packageName()
              if (pkg.isEmpty) owner.displayName() else pkg + "." + owner.displayName()
            }
            List("method", "constructor").find(hasField(p, _)).map(field[Any](p, _)) match {
              case Some(jm) =>
                val ref = field[Any](jm, "ref")
                sink.calls(fn, className(field[java.lang.constant.ClassDesc](ref, "owner")) + "." + field[String](ref, "name"), loc)
              case None if hasField(p, "clazz") =>
                val clazz = field[java.lang.constant.ClassDesc](p, "clazz")
                val name = if (hasField(p, "methodName")) field[Any](field[Any](p, "methodName"), "name").toString else "<init>"
                sink.calls(fn, className(clazz) + "." + name, loc)
              case None => ()
            }
            p.productIterator.foreach(x => go(x, outers, env, inPipe = false))
          case "Handler" =>
            val symUse = field[Any](p, "symUse")
            sink.handles(fn, symName(field[Any](symUse, "sym")), lineOf(p))
            p.productIterator.foreach(x => go(x, outers, env, inPipe = false))
          case "IfThenElse" | "Match" | "TypeMatch" | "ExtMatch" if p.getClass.getName.contains("Expr") =>
            // A branch in the body: `if`, `match` (a `match` lambda too: the compiler makes it a match on the argument,
            // and Python-era counts read the keyword), `typematch`, `extmatch`, and each guard of a match rule.
            // WhyNot: a `let (a, b) = e` is not counted. The compiler turns it into a match with one rule at the
            // let's own location, which no source `match` has (its rules sit at their `case`).
            val loc = field[SourceLocation](p, "loc")
            val rules = if (p.productPrefix == "Match") field[List[Any]](p, "rules") else Nil
            val destructuringLet = rules match {
              case List(rule) => loc.isReal && field[SourceLocation](rule, "loc") == loc && field[Option[Any]](rule, "guard").isEmpty
              case _ => false
            }
            // WhyNot: a generator of `forM` (`s <- xs`) is not counted either. The compiler makes it a lambda whose body is a
            // match with a single bare variable (or `_`) rule at a synthetic location; a `match` lambda the source wrote
            // has a pattern there (`match (a, b) -> …`).
            val generator = rules match {
              case List(rule) => loc.isSynthetic && Set("Var", "Wild").contains(field[Product](rule, "pat").productPrefix)
              case _ => false
            }
            val kind = p.productPrefix match {
              case "IfThenElse" => "if"
              case "Match" => "match"
              case "TypeMatch" => "typematch"
              case _ => "extmatch"
            }
            if (!destructuringLet && !generator) sink.branch(fn, kind, lineOf(p))
            rules.foreach(rule => field[Option[Any]](rule, "guard").foreach(g => sink.branch(fn, "guard", lineOf(g.asInstanceOf[Product]))))
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

  /** Every `true` / `false` literal in the body of `fn`, with where it is written and the line its parent starts on
    * (a tuple written over several lines starts on its first): the nearest parents (closest first,
    * up to three, joined by ` < `), e.g. `field:expected < arg:Assert.assertEq:0` for `assertEq(expected = true, x)`.
    * A parent is `arg:<callee>:<index>`, `field:<label>`, `tag:<case>`, `tuple`, `vector`, `array`, `let` (the bound
    * expression) or `op:<operator>`; anything else by its node name. `not` and type ascriptions are seen through, and a
    * literal in a pattern (`case true =>`) is not one.
    *
    * WhyNot: not a branch of `walkBody`. That walker follows let-bound expressions to where they are used, so a
    * literal there would be filed under the use; the place it is written is what a rule on literals needs.
    */
  def walkBools(fn: String, body: Any, sink: Sink): Unit = {
    def transparent(p: Product): Boolean = p.productPrefix match {
      case "Unary" | "Ascribe" | "CheckedCast" | "UncheckedCast" => true
      case _ => false
    }
    def parent(p: Product, fieldName: String, index: Int): String = p.productPrefix match {
      case "ApplyDef" | "ApplySig" | "ApplyOp" if fieldName == "exps" =>
        s"arg:${symName(field[Any](field[Any](p, "symUse"), "sym"))}:$index"
      case "RecordExtend" if fieldName == "exp1" => s"field:${field[Any](p, "label").toString}"
      case "Tag" if p.getClass.getName.contains("Expr") => s"tag:${symName(field[Any](field[Any](p, "symUse"), "sym"))}"
      case "Tuple" => "tuple"
      case "VectorLit" => "vector"
      case "ArrayLit" => "array"
      case "Let" if fieldName == "exp1" => "let"
      case "Binary" => s"op:${field[Any](p, "sop")}"
      case other => other
    }
    // The line a parent starts on (a node without a location, such as a match rule, takes its own parent's).
    def startOf(p: Product, ctx: List[(String, Int)]): Int =
      if (hasField(p, "loc")) field[SourceLocation](p, "loc").startLine
      else ctx.headOption.map(_._2).getOrElse(0)
    def go(node: Any, ctx: List[(String, Int)]): Unit = node match {
      case null | _: Type | _: UnkindedType | _: SourceLocation | _: Symbol | _: String | _: java.lang.Number | _: java.lang.Boolean => ()
      case p: Product if p.productPrefix == "Cst" && !p.getClass.getName.contains("Pattern") && field[Any](p, "cst").isInstanceOf[Product] &&
          field[Product](p, "cst").productPrefix == "Bool" =>
        val line = field[SourceLocation](p, "loc").startLine
        sink.boolLit(fn, field[Any](field[Any](p, "cst"), "lit").toString, ctx.take(3).map(_._1).mkString(" < "), line, ctx.headOption.map(_._2).getOrElse(line))
      case p: Product =>
        p.productElementNames.zip(p.productIterator).foreach {
          case (name, xs: List[_]) => xs.zipWithIndex.foreach { case (x, i) => go(x, if (transparent(p)) ctx else (parent(p, name, i), startOf(p, ctx)) :: ctx) }
          case (name, x) => go(x, if (transparent(p)) ctx else (parent(p, name, 0), startOf(p, ctx)) :: ctx)
        }
      case xs: Iterable[_] => xs.foreach(x => go(x, ctx))
      case _ => ()
    }
    go(body, Nil)
  }

  /** Every argument of a case built in the body of `fn` (`Some(x)`, `Ok((a, b))`, `Shape.Circle(r)`): its shape — `bool`
    * (a literal), `unary:<op>` (`not x`), `op:<op>` (`a and b`), `call:<callee>` (`a == b` is `call:Eq.eq`), `var` or the
    * node's name — and the head of its type (typed stage; `?` at the resolved stage, which has no types yet).
    * Ascriptions are seen through. WhyNot: not a branch of `walkBody`, for the reason given at `walkBools`.
    */
  def walkTagArgs(fn: String, body: Any, sink: Sink): Unit = {
    def shapeOf(e: Any): String = e match {
      case p: Product if p.productPrefix == "Ascribe" || p.productPrefix == "CheckedCast" || p.productPrefix == "UncheckedCast" =>
        shapeOf(field[Any](p, "exp"))
      case p: Product if p.productPrefix == "Cst" && field[Any](p, "cst").isInstanceOf[Product] &&
          field[Product](p, "cst").productPrefix == "Bool" => "bool"
      case p: Product if p.productPrefix == "Unary" => s"unary:${field[Any](p, "sop")}"
      case p: Product if p.productPrefix == "Binary" => s"op:${field[Any](p, "sop")}"
      case p: Product if p.productPrefix == "ApplyDef" || p.productPrefix == "ApplySig" || p.productPrefix == "ApplyOp" =>
        s"call:${symName(field[Any](field[Any](p, "symUse"), "sym"))}"
      case p: Product if p.productPrefix == "Var" => "var"
      case p: Product => p.productPrefix
      case _ => "?"
    }
    def typeOf(e: Any): String =
      if (e.getClass.getMethods.exists(m => m.getName == "tpe" && m.getParameterCount == 0)) field[Any](e, "tpe") match {
        case t: Type => Typed.headName(t)
        case _ => "?"
      } else "?"
    def go(node: Any): Unit = node match {
      case null | _: Type | _: UnkindedType | _: SourceLocation | _: Symbol | _: String | _: java.lang.Number | _: java.lang.Boolean => ()
      case p: Product if p.productPrefix == "Tag" && p.getClass.getName.contains("Expr") =>
        val kase = symName(field[Any](field[Any](p, "symUse"), "sym"))
        val line = field[SourceLocation](p, "loc").startLine
        field[List[Any]](p, "exps").zipWithIndex.foreach { case (e, i) => sink.tagArg(fn, kase, i, shapeOf(e), typeOf(e), line) }
        p.productIterator.foreach(go)
      case p: Product => p.productIterator.foreach(go)
      case xs: Iterable[_] => xs.foreach(go)
      case _ => ()
    }
    go(body)
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

  def sourceFile(file: String): Unit = row("source_file", file)
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
  def boolLit(fn: String, value: String, where: String, line: Int, parentLine: Int): Unit = { fnNames += fn; row("bool_lit", fn, value, where, line, parentLine) }
  def tagArg(fn: String, kase: String, index: Int, shape: String, tycon: String, line: Int): Unit = { fnNames += fn; caseNames += kase; row("tag_arg", fn, kase, index, shape, tycon, line) }
  def branch(fn: String, kind: String, line: Int): Unit = { fnNames += fn; row("branch", fn, kind, line) }
  def argTypeAll(fn: String, i: Int, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("arg_type_all", fn, i, tycon) }
  def retTypeAll(fn: String, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("ret_type_all", fn, tycon) }
  def caseTypeAll(enum0: String, enumCase: String, i: Int, tycon: String): Unit = { enumNames += enum0; caseNames += enumCase; typeNames += tycon; row("case_type_all", enum0, enumCase, i, tycon) }
  def argTypeDeep(fn: String, i: Int, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("arg_type_deep", fn, i, tycon) }
  def retTypeDeep(fn: String, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("ret_type_deep", fn, tycon) }
  def caseTypeDeep(enum0: String, enumCase: String, i: Int, tycon: String): Unit = { enumNames += enum0; caseNames += enumCase; typeNames += tycon; row("case_type_deep", enum0, enumCase, i, tycon) }
  def argType(fn: String, i: Int, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("arg_type", fn, i, tycon) }
  def retType(fn: String, tycon: String): Unit = { fnNames += fn; typeNames += tycon; modOf(tycon); row("ret_type", fn, tycon) }
  def caseType(enum0: String, enumCase: String, i: Int, tycon: String): Unit = { enumNames += enum0; caseNames += enumCase; typeNames += tycon; row("case_type", enum0, enumCase, i, tycon) }
  def effAlias(alias: String, eff: String): Unit = { effNames += alias; effNames += eff; row("eff_alias", alias, eff) }
  def enumDef(enum0: String, mod: String, file: String, line: Int, isPub: Boolean): Unit = { enumNames += enum0; modNames += mod; row("enum", enum0, mod, file, line, isPub) }
  def effDef(eff: String, mod: String, file: String, line: Int, isPub: Boolean): Unit = { effNames += eff; modNames += mod; row("eff", eff, mod, file, line, isPub) }
  def typeAliasDef(alias: String, mod: String, file: String, line: Int, isPub: Boolean, fields: Int): Unit = { typeNames += alias; modNames += mod; row("type_alias", alias, mod, file, line, isPub, fields) }
  def aliasTypeAll(alias: String, tycon: String): Unit = { typeNames += alias; typeNames += tycon; modOf(tycon); row("alias_type_all", alias, tycon) }
  def close(): Unit = writers.values.foreach(_.close())
}

object Sink {
  private def deleteStaleTsv(dir: Path): Unit = {
    val entries = Files.list(dir)
    try entries.iterator().asScala.filter(_.toString.endsWith(".tsv")).toList.foreach(Files.delete)
    finally entries.close()
  }
}

/** `Names.flix`: the names of the facts as Flix enums (`Fn` / `Eff` / `Mod` / `Case` / `Enum` / `Type`), and
  * `names.tsv` next to the facts: every name with the spelling of its case.
  *
  * A case is the qualified name with every character that is not an ASCII letter or digit replaced by `_` and the
  * first letter upper-cased (`Auth.permit` -> `Auth_permit`, `java.lang.System.currentTimeMillis` ->
  * `Java_lang_System_currentTimeMillis`); a name that would collide gets a trailing `_`. Names that do not start with a
  * letter (`++`, `|>`, `bug!`) are left out: no rule needs them and they cannot be enum cases. The root module (the empty
  * name) is `Mod.Root`.
  *
  * Only the names the rules write (`Fn.Auth_permit` in the rule file, `--names-of`) are cases of their own; every
  * other name is `Unnamed("its qualified name")`. A value is ordered by its qualified name, the order the cases had
  * when every name was one, so the report does not change with what the rules name.
  * WhyNot: not one case per name. The engine is compiled again whenever `Names.flix` changes, and a case per name
  * changed it with every function added or renamed in the sources (10,000 cases, a rebuild of seconds on a run that
  * otherwise takes one or two). A name the rules write that the sources no longer have is still left out, so the rule
  * fails to compile as before.
  * WhyNot: the enums derive `Eq` but not `ToString`. Deriving `ToString` on an enum of a few thousand cases took the
  * compiler minutes; the qualified name comes from `fnName` and its kin.
  */
object Names {
  /** Upper-case words the parser does not accept as a case name (`case Static`), and the case of the other names. */
  val reserved: Set[String] = Set("Static", "Pure", "Univ", "Impure", "Unnamed")

  val kinds: List[String] = List("Fn", "Eff", "Mod", "Case", "Enum", "Type")

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

  /** The cases a rule file writes, by kind (`Fn.Auth_permit` gives `Fn` -> `Auth_permit`). A word that only looks like
    * one (in a comment, `Type.X` of another module) only adds a case, when the sources have that name.
    */
  def usedIn(rules: String): Map[String, Set[String]] =
    """\b(Fn|Eff|Mod|Case|Enum|Type)\.([A-Z][A-Za-z0-9_]*)""".r.findAllMatchIn(rules).toList
      .groupBy(_.group(1)).map { case (k, ms) => k -> ms.map(_.group(2)).toSet }

  private def quoted(s: String): String = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$") + "\""

  /** The enum of one kind with the named cases (all of them when `used` is `None`), its order, and the functions
    * between a value and its qualified name.
    */
  def enumSource(kind: String, all: List[(String, String)], used: Option[Set[String]]): String = {
    val named = all.filter { case (_, c) => used.forall(_(c)) }
    val k = kind.head.toLower + kind.tail
    val body = named.map { case (_, c) => s"        case $c\n" }.mkString
    val toName = named.map { case (n, c) => s"            case $kind.$c => ${quoted(n)}\n" }.mkString
    val ofName = named.map { case (n, c) => s"            case ${quoted(n)} => $kind.$c\n" }.mkString
    s"""    pub enum $kind with Eq {
$body        case Unnamed(String)
    }

    instance Order[$kind] {
        pub def compare(x: $kind, y: $kind): Comparison = Order.compare(${k}Name(x), ${k}Name(y))
    }

    /// The qualified name as the compiler prints it.
    pub def ${k}Name(x: $kind): String = match x {
$toName            case $kind.Unnamed(n) => n
        }

    /// The value of a qualified name.
    pub def ${k}Of(n: String): $kind = match n {
$ofName            case _ => $kind.Unnamed(n)
        }
"""
  }

  /** Writes `Names.flix` to `path` and `names.tsv` (kind, name, case) to `factsDir`. */
  def write(path: Path, factsDir: Path, sink: Sink, used: Option[Map[String, Set[String]]]): Unit = {
    val byKind = List(sink.fnNames, sink.effNames, sink.modNames, sink.caseNames, sink.enumNames, sink.typeNames)
      .map(cases).zip(kinds)
    val src = "/// Generated by flixlint from the facts of the linted sources and the names the rules write. Do not edit.\n" +
      "pub mod Flixlint.Names {\n" +
      byKind.map { case (all, kind) => enumSource(kind, all, used.map(_.getOrElse(kind, Set.empty))) }.mkString("\n") +
      "}\n"
    Option(path.getParent).foreach(Files.createDirectories(_))
    Files.writeString(path, src)
    val tsv = new PrintWriter(Files.newBufferedWriter(factsDir.resolve("names.tsv")))
    try byKind.foreach { case (all, kind) => all.foreach { case (n, c) => tsv.println(s"$kind\t$n\t$c") } }
    finally tsv.close()
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

  /** The number of fields when `t` is a record type (`{ a = Int32, b = Bool }` gives 2), or -1 when it is not a record. */
  def recordFields(t: Type): Int = t match {
    case Type.Apply(Type.Cst(TypeConstructor.Record, _), row, _) => rowLabels(row)
    case _ => -1
  }

  private def rowLabels(row: Type): Int = row match {
    case Type.Apply(Type.Apply(Type.Cst(TypeConstructor.RecordRowExtend(_), _), _, _), rest, _) => 1 + rowLabels(rest)
    case _ => 0
  }

  /** Every named type constructor in a type, outermost first (`List[ColumnName]` gives `List`, `ColumnName`). An alias is
    * listed by its own name and its arguments (its target is not); type variables and record / schema rows are left out.
    */
  def allNames(t: Type): List[String] = namesIn(t, throughAliases = false)

  /** `allNames`, plus what each alias stands for, at any depth (`type alias Ctx = { w = World }` gives `Ctx` and `World`). */
  def deepNames(t: Type): List[String] = namesIn(t, throughAliases = true)

  private def namesIn(t: Type, throughAliases: Boolean): List[String] = t match {
    case Type.Alias(symUse, args, tpe, _) =>
      symName(symUse.sym) :: (args.flatMap(namesIn(_, throughAliases)) ++ (if (throughAliases) namesIn(tpe, throughAliases) else Nil))
    case Type.Apply(t1, t2, _) => namesIn(t1, throughAliases) ++ namesIn(t2, throughAliases)
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
      sink.defn(fn, d.sym.name, d.sym.namespace.mkString("."), file, d.sym.loc.startLine, d.spec.mod.isPublic)
      effNames(d.spec.eff).distinct.foreach(e => sink.effectOf(fn, e))
      d.spec.fparams.toList.zipWithIndex.foreach { case (fp, i) =>
        sink.argType(fn, i, headName(fp.tpe))
        allNames(fp.tpe).distinct.foreach(n => sink.argTypeAll(fn, i, n))
        deepNames(fp.tpe).distinct.foreach(n => sink.argTypeDeep(fn, i, n))
      }
      sink.retType(fn, headName(d.spec.retTpe))
      allNames(d.spec.retTpe).distinct.foreach(n => sink.retTypeAll(fn, n))
      deepNames(d.spec.retTpe).distinct.foreach(n => sink.retTypeDeep(fn, n))
      walkBody(fn, d.exp, sink)
      walkBools(fn, d.exp, sink)
      walkTagArgs(fn, d.exp, sink)
    }
    for ((sym, e) <- root.enums; file <- sourceFile(e.loc)) {
      sink.enumDef(symName(sym), sym.namespace.mkString("."), file, sym.loc.startLine, e.mod.isPublic)
      for ((cs, c) <- e.cases; (t, i) <- c.tpes.zipWithIndex) {
        sink.caseType(symName(sym), symName(cs), i, headName(t))
        allNames(t).distinct.foreach(n => sink.caseTypeAll(symName(sym), symName(cs), i, n))
        deepNames(t).distinct.foreach(n => sink.caseTypeDeep(symName(sym), symName(cs), i, n))
      }
    }
    for ((sym, e) <- root.effects; file <- sourceFile(e.loc))
      sink.effDef(symName(sym), sym.namespace.mkString("."), file, sym.loc.startLine, e.mod.isPublic)
    // aliases of packages and the standard library are listed too: a rule that names `Db` means its members
    for ((sym, a) <- root.typeAliases; file <- sourceFile(a.loc)) {
      sink.typeAliasDef(symName(sym), sym.namespace.mkString("."), file, sym.loc.startLine, a.mod.isPublic, recordFields(a.tpe))
      allNames(a.tpe).distinct.foreach(n => sink.aliasTypeAll(symName(sym), n))
    }
    for ((sym, a) <- root.typeAliases; e <- effNames(a.tpe).distinct)
      sink.effAlias(symName(sym), e)
  }
}

/** Stage 2: facts from the resolved AST, stopping before the kinder and the typer.
  *
  * WhyNot: `Flix.check()` has no public way to stop early, so the phases are called directly in the same order the
  * compiler does. The sources (the project's, the packages' and the bundled library's) come from a private method of
  * `Flix`; it is called by reflection because building them by hand would duplicate the library-loading logic of the
  * compiler.
  */
object Resolved {
  import Facts._

  def run(flix: Flix): (ResolvedAst.Root, List[ca.uwaterloo.flix.language.CompilationMessage]) = {
    implicit val f: Flix = flix
    val initThreadPool = flix.getClass.getDeclaredMethod("initThreadPool")
    initThreadPool.setAccessible(true)
    initThreadPool.invoke(flix)
    flix.phaseTimers = scala.collection.mutable.ArrayBuffer.empty
    val getSources = flix.getClass.getDeclaredMethod("getSources")
    getSources.setAccessible(true)
    val sources = getSources.invoke(flix).asInstanceOf[List[Source]]
    val cs = ChangeSet.Everything
    val readAst = ReadAst.Root(sources.map(src => src -> ()).toMap)
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
    (resolved, e2 ++ e3 ++ e4 ++ e5 ++ e6)
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

  /** The number of fields when `t` is a record type (`{ a = Int32, b = Bool }` gives 2), or -1 when it is not a record. */
  def recordFields(t: UnkindedType): Int = t match {
    case UnkindedType.Apply(UnkindedType.Cst(TypeConstructor.Record, _), row, _) => rowLabels(row)
    case _ => -1
  }

  private def rowLabels(row: UnkindedType): Int = row match {
    case UnkindedType.Apply(UnkindedType.Apply(UnkindedType.Cst(TypeConstructor.RecordRowExtend(_), _), _, _), rest, _) => 1 + rowLabels(rest)
    case _ => 0
  }

  /** Every named type constructor in a type, outermost first (see `Typed.allNames`). */
  def allNames(t: UnkindedType): List[String] = namesIn(t, throughAliases = false)

  /** `allNames`, plus what each alias stands for (see `Typed.deepNames`). */
  def deepNames(t: UnkindedType): List[String] = namesIn(t, throughAliases = true)

  private def namesIn(t: UnkindedType, throughAliases: Boolean): List[String] = t match {
    case UnkindedType.Alias(symUse, args, tpe, _) =>
      symName(symUse.sym) :: (args.flatMap(namesIn(_, throughAliases)) ++ (if (throughAliases) namesIn(tpe, throughAliases) else Nil))
    case UnkindedType.Apply(t1, t2, _) => namesIn(t1, throughAliases) ++ namesIn(t2, throughAliases)
    case UnkindedType.Arrow(eff, _, _) => "Arrow" :: eff.toList.flatMap(namesIn(_, throughAliases))
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
      sink.defn(fn, d.sym.name, d.sym.namespace.mkString("."), file, d.sym.loc.startLine, d.spec.mod.isPublic)
      d.spec.eff.toList.flatMap(effNames).distinct.foreach(e => sink.effectOf(fn, e))
      d.spec.fparams.toList.zipWithIndex.foreach { case (fp, i) =>
        sink.argType(fn, i, fp.tpe.map(headName).getOrElse("?"))
        fp.tpe.toList.flatMap(allNames).distinct.foreach(n => sink.argTypeAll(fn, i, n))
        fp.tpe.toList.flatMap(deepNames).distinct.foreach(n => sink.argTypeDeep(fn, i, n))
      }
      sink.retType(fn, headName(d.spec.tpe))
      allNames(d.spec.tpe).distinct.foreach(n => sink.retTypeAll(fn, n))
      deepNames(d.spec.tpe).distinct.foreach(n => sink.retTypeDeep(fn, n))
      walkBody(fn, d.exp, sink)
      walkBools(fn, d.exp, sink)
      walkTagArgs(fn, d.exp, sink)
    }
    for ((sym, e) <- root.enums; file <- sourceFile(e.loc)) {
      sink.enumDef(symName(sym), sym.namespace.mkString("."), file, sym.loc.startLine, e.mod.isPublic)
      for (c <- e.cases; (t, i) <- c.tpes.zipWithIndex) {
        sink.caseType(symName(sym), symName(c.sym), i, headName(t))
        allNames(t).distinct.foreach(n => sink.caseTypeAll(symName(sym), symName(c.sym), i, n))
        deepNames(t).distinct.foreach(n => sink.caseTypeDeep(symName(sym), symName(c.sym), i, n))
      }
    }
    for ((sym, e) <- root.effects; file <- sourceFile(e.loc))
      sink.effDef(symName(sym), sym.namespace.mkString("."), file, sym.loc.startLine, e.mod.isPublic)
    for ((sym, a) <- root.typeAliases; file <- sourceFile(a.loc)) {
      sink.typeAliasDef(symName(sym), sym.namespace.mkString("."), file, sym.loc.startLine, a.mod.isPublic, recordFields(a.tpe))
      allNames(a.tpe).distinct.foreach(n => sink.aliasTypeAll(symName(sym), n))
    }
    for ((sym, a) <- root.typeAliases; e <- effNames(a.tpe).distinct)
      sink.effAlias(symName(sym), e)
  }
}
