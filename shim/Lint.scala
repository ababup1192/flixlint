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
    val (engine, key, rest) = split(argv)
    val code = Facts.guarded(rest)
    if (code != 0) sys.exit(code)
    val names = engine.resolve("src").resolve("Flixlint").resolve("Names.flix")
    val hash = hashOf(key, Files.readAllBytes(names))
    val jar = engine.resolve("artifact").resolve("engine.jar")
    val built = engine.resolve("built-hash")
    if (Files.isRegularFile(jar) && Files.isRegularFile(built) && Files.readString(built).trim == hash) sys.exit(runEngine(jar))
    Files.writeString(engine.resolve("wanted-hash"), hash + "\n")
    sys.exit(NeedsBuild)
  }

  private def split(argv: Array[String]): (Path, String, Array[String]) = {
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
    (engine.getOrElse(usage("--engine DIR")), key.getOrElse(usage("--engine-key KEY")), rest.result())
  }

  private def usage(what: String): Nothing = {
    System.err.println(s"flixlint: Lint needs $what")
    sys.exit(4)
  }

  /** The first 16 hex digits of the SHA-1 of the key, a newline, and the names. */
  def hashOf(key: String, names: Array[Byte]): String = {
    val md = MessageDigest.getInstance("SHA-1")
    md.update((key + "\n").getBytes(StandardCharsets.UTF_8))
    md.update(names)
    md.digest().map(b => f"${b & 0xff}%02x").mkString.take(16)
  }

  /** Runs the engine's `main` and returns its exit code (the engine leaves through `System.exit` when it is not 0).
    *
    * WhyNot: the engine is not put on this JVM's class path. Its jar carries the Flix runtime it was compiled
    * against, and the compiler jar here has classes of the same names, so it gets a loader of its own over the
    * platform's.
    */
  private def runEngine(jar: Path): Int = {
    val loader = new URLClassLoader(Array(jar.toUri.toURL), ClassLoader.getPlatformClassLoader)
    val mainClass = {
      val jf = new java.util.jar.JarFile(jar.toFile)
      try jf.getManifest.getMainAttributes.getValue("Main-Class") finally jf.close()
    }
    Thread.currentThread.setContextClassLoader(loader)
    try {
      loader.loadClass(mainClass).getMethod("main", classOf[Array[String]]).invoke(null, Array.empty[String])
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
