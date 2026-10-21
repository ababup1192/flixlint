package flixlint

import java.net.URLClassLoader
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths}
import java.security.MessageDigest

/** The facts and the rule engine in one JVM: `Facts`, then the engine jar `bin/flixlint` built for the same sources,
  * loaded into this process.
  *
  * Usage: Lint --engine DIR --engine-key KEY <the arguments of Facts>
  *
  * The engine is reused when `DIR/built-hash` is the hash of KEY (what `bin/flixlint` hashed of the engine's other
  * sources and the compiler) and of the `Names.flix` the walk wrote. Otherwise the hash goes to `DIR/wanted-hash` and the
  * exit code is 10: `bin/flixlint` builds the engine and runs it on its own, as before.
  *
  * Exit codes: those of `Facts` (3, 4) when the facts cannot be written, those of the engine (0, 1, 2) when it ran, 10
  * when the engine has to be built first.
  *
  * WhyNot: the engine is not built here. A rebuild takes the compiler tens of seconds, so the start of one more JVM does
  * not count, and `flix build-jar` keeps its own working directory and log, which `bin/flixlint` already reports from.
  *
  * WhyNot: the engine is not handed the facts in memory. It reads the TSV the walk wrote (`--facts-out` is the same
  * files for the caller), so the two halves keep one contract whether they share a process or not.
  */
object Lint {
  val NeedsBuild = 10

  def main(argv: Array[String]): Unit = {
    val code = run(argv, Facts.guarded, _ => false, jar => runEngine(newLoader(jar), jar, Array.empty))
    if (code != 0) sys.exit(code)
  }

  /** The facts by `facts`, then the engine by `engine` when it is built for them, or once `build` built it (given the
    * engine directory; false when it did not, and `bin/flixlint` builds it); the exit code (see above).
    * `bin/flixlint` runs it in a JVM of its own (`main`), the resident server (`Resident`) with its warm compiler.
    */
  def run(argv: Array[String], facts: Array[String] => Int, build: Path => Boolean, engine: Path => Int): Int = {
    val (dirOpt, key, rest) =
      try split(argv)
      catch {
        case e: Facts.UsageError =>
          System.err.println(s"flixlint: ${e.getMessage}")
          return 4
      }
    val code = facts(rest)
    // No engine: a run for the index alone (`--spans` without `--rules`), so the facts are all there is to do.
    if (code != 0 || dirOpt.isEmpty) return code
    val dir = dirOpt.get
    val names = dir.resolve("src").resolve("Flixlint").resolve("Names.flix")
    val hash = hashOf(key, Files.readAllBytes(names))
    val jar = dir.resolve("artifact").resolve("engine.jar")
    val built = dir.resolve("built-hash")
    if (Files.isRegularFile(jar) && Files.isRegularFile(built) && Files.readString(built).trim == hash) engine(jar)
    else {
      Files.writeString(dir.resolve("wanted-hash"), hash + "\n")
      if (build(dir)) { Files.writeString(built, hash + "\n"); engine(jar) } else NeedsBuild
    }
  }

  /** `--engine DIR --engine-key KEY` and the rest. Neither: a run without the engine (the index alone). */
  private def split(argv: Array[String]): (Option[Path], String, Array[String]) = {
    var engine: Option[Path] = None
    var key: Option[String] = None
    val rest = Array.newBuilder[String]
    var i = 0
    while (i < argv.length) {
      argv(i) match {
        case "--engine" if i + 1 < argv.length => engine = Some(Paths.get(argv(i + 1))); i += 2
        case "--engine-key" if i + 1 < argv.length => key = Some(argv(i + 1)); i += 2
        case a => rest += a; i += 1
      }
    }
    if (engine.isDefined != key.isDefined) throw new Facts.UsageError("Lint needs both --engine DIR and --engine-key KEY, or neither")
    (engine, key.getOrElse(""), rest.result())
  }

  /** The first 16 hex digits of the SHA-1 of the key, a newline, and the names. */
  def hashOf(key: String, names: Array[Byte]): String = {
    val md = MessageDigest.getInstance("SHA-1")
    md.update((key + "\n").getBytes(StandardCharsets.UTF_8))
    md.update(names)
    md.digest().map(b => f"${b & 0xff}%02x").mkString.take(16)
  }

  /** A loader for the engine jar.
    *
    * WhyNot: the engine is not put on this JVM's class path. Its jar carries the Flix runtime it was compiled
    * against, and the compiler jar here has classes of the same names, so it gets a loader of its own over the
    * platform's.
    */
  def newLoader(jar: Path): URLClassLoader = new URLClassLoader(Array(jar.toUri.toURL), ClassLoader.getPlatformClassLoader)

  /** Runs the engine's `main` with `args` and returns its exit code: 0 when `main` returns (the engine leaves through
    * `System.exit` when it is not 0, unless it was given `--resident`, see `Resident`).
    */
  def runEngine(loader: ClassLoader, jar: Path, args: Array[String]): Int = {
    val mainClass = {
      val jf = new java.util.jar.JarFile(jar.toFile)
      try jf.getManifest.getMainAttributes.getValue("Main-Class") finally jf.close()
    }
    Thread.currentThread.setContextClassLoader(loader)
    try {
      loader.loadClass(mainClass).getMethod("main", classOf[Array[String]]).invoke(null, args)
      0
    } catch {
      // As the JVM does for an exception out of `main`: the trace, and exit code 1.
      case e: java.lang.reflect.InvocationTargetException =>
        System.err.print("Exception in thread \"main\" ")
        e.getCause.printStackTrace()
        1
    } finally System.out.flush()
  }
}
