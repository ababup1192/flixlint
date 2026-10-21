package flixlint

import ca.uwaterloo.flix.api.{Bootstrap, Flix}
import ca.uwaterloo.flix.util.{Formatter, Result}

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths}
import java.security.MessageDigest
import scala.jdk.CollectionConverters._

/** The `check` of the resident server: `flix check` on the project's kept compiler, answered with the version of the
  * sources it checked (checkd-freshness §2.1, §3).
  *
  *   Check version DIR   (prints the version of the project at DIR: the fixture test/resident/version)
  *
  * A check runs what the CLI's `flix check` runs, in its order and with its streams: `Bootstrap.bootstrap` on the root
  * (its progress on stderr, installing what is missing), then the check of the project's sources, the compiler's
  * messages on stdout; exit 0 when they compile, 1 when not. The compiler and the sources it was given are kept between
  * runs (`Resident.State`), so a check after a lint of the same sources compiles nothing again.
  */
object Check {

  def main(argv: Array[String]): Unit = argv.toList match {
    case "version" :: dir :: Nil =>
      val root = Paths.get(dir).toAbsolutePath.normalize
      println(version(root, VersionFiles.under(root).map(f => f -> Files.readAllBytes(f)).toMap))
    case _ =>
      System.err.println("flixlint: Check version DIR")
      sys.exit(4)
  }

  /** The version of the sources: which bytes a check was about (§3.1). The callers compute it from what they read, the
    * server from the bytes it gave the compiler and a client from the disk after the answer; an answer is used only
    * when the two are the same.
    *
    * The files are the project's `.flix` files under `src/` and `test/` (what `Bootstrap` finds) and its `flix.toml`
    * and `packages.lock` when they are there. Each is one entry: its path relative to the root with `/` between the
    * names, a NUL, the SHA-256 of its bytes in lower-case hex, a NUL. The entries are sorted by the path's UTF-8
    * bytes and the version is the SHA-256 of all of them, in lower-case hex (64 characters).
    *
    * WhyNot: no modification time, size or file count of its own. The bytes alone decide, so a write that keeps the
    * time (`cp -p`, `touch -r`) or the size still changes the version.
    * WhyNot: not the version of `flix.jar` and the shim. They are the server's identity, and another identity is
    * another server (Resident); `lib/` follows `flix.toml` and `packages.lock`, which are in.
    */
  def version(root: Path, files: Map[Path, Array[Byte]]): String = {
    val entries = files.toList.map { case (f, bytes) =>
      val rel = root.relativize(f.toAbsolutePath.normalize).iterator().asScala.map(_.toString).mkString("/")
      rel.getBytes(StandardCharsets.UTF_8) -> hex(sha256(bytes))
    }.sortWith((a, b) => compareBytes(a._1, b._1) < 0)
    val all = MessageDigest.getInstance("SHA-256")
    entries.foreach { case (rel, sum) =>
      all.update(rel); all.update(0.toByte); all.update(sum.getBytes(StandardCharsets.US_ASCII)); all.update(0.toByte)
    }
    hex(all.digest())
  }

  /** The files besides the sources that are part of the version. */
  object VersionFiles {
    val Extra = List("flix.toml", "packages.lock")

    /** The `.flix` files under `src/` and `test/` and the extra files, for a project read from disk (the fixture). */
    def under(root: Path): List[Path] =
      List("src", "test").map(root.resolve).filter(Files.isDirectory(_)).flatMap(Facts.listFlix) ++ extras(root)

    def extras(root: Path): List[Path] = Extra.map(root.resolve).filter(Files.isRegularFile(_))
  }

  private def sha256(b: Array[Byte]): Array[Byte] = MessageDigest.getInstance("SHA-256").digest(b)

  private def hex(b: Array[Byte]): String = b.map(x => f"${x & 0xff}%02x").mkString

  private def compareBytes(a: Array[Byte], b: Array[Byte]): Int = {
    val n = math.min(a.length, b.length)
    var i = 0
    while (i < n && a(i) == b(i)) i += 1
    if (i < n) (a(i) & 0xff) - (b(i) & 0xff) else a.length - b.length
  }

  /** One check of the project at `root` on the kept compiler: the exit code, and the version of what was checked.
    * `compilerFor` gives the compiler for the dependencies (a new one when they changed) and `give` hands it the
    * sources' bytes as read once, returning what it was given.
    */
  def run(root: Path, compilerFor: Facts.Deps => Flix, give: (Flix, List[Path]) => Map[Path, Array[Byte]]): (Int, Option[String]) = {
    val formatter = Formatter.getDefault
    Bootstrap.bootstrap(root, sys.env.get("GITHUB_TOKEN").filter(_.nonEmpty))(formatter, System.err) match {
      case Result.Err(e) =>
        System.out.println(e.message(formatter))
        (1, None)
      case Result.Ok(b) =>
        val pf = b.projectFiles
        val flix = compilerFor(Facts.Deps(pf.pkgs, pf.jars, Facts.Deps.mountsOf(root)))
        val given = give(flix, pf.sources)
        val extras = VersionFiles.extras(root).map(f => f -> Files.readAllBytes(f))
        val v = version(root, given ++ extras)
        val before = flix.getFormatter
        flix.setFormatter(formatter)
        val code = try b.check(flix) match {
          case Result.Ok(_) => 0
          case Result.Err(e) =>
            System.out.println(e.message(formatter))
            1
        } finally flix.setFormatter(before)
        (code, Some(v))
    }
  }
}
