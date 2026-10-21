package flixlint

import ca.uwaterloo.flix.api.Flix
import ca.uwaterloo.flix.language.ast.shared.SecurityContext

import java.io.{BufferedOutputStream, DataInputStream, DataOutputStream, IOException, OutputStream, PrintStream}
import java.net.{StandardProtocolFamily, UnixDomainSocketAddress, URLClassLoader}
import java.nio.channels.{Channels, SelectionKey, Selector, ServerSocketChannel, SocketChannel}
import java.nio.file.{Files, Path, Paths}
import java.util.Arrays

/** A resident `Lint` (`bin/flixlint --resident`): one JVM per project that keeps the compiler with its last ASTs and
  * the loaded rule engine between runs, so a run after the first compiles only what changed since (the compiler's own
  * incremental `check`) and runs the engine on warm code.
  *
  *   Resident server --socket FILE --identity ID [--idle-minutes N]
  *   Resident client --socket FILE --identity ID [--wait SECONDS] <the arguments of Lint>
  *
  * The client sends its arguments and the engine's settings (`FLIXLINT_FACTS`, `FLIXLINT_TODAY`, `FLIXLINT_LIMITS`,
  * `FLIXLINT_LIMITS_BASE`, read from its environment) to the server, writes what the run prints to its own stdout and
  * stderr, and leaves with the run's exit code: the same output and code as `Lint` in a JVM of its own. Exit code 11
  * when no server answers or the server is not the one for this call (another compiler or shim jar, another
  * directory): `bin/flixlint` then starts one, or runs `Lint` on its own.
  *
  * The identity is what `bin/flixlint` knows of the compiler jar, the shim jar and the working directory; a server
  * given another identity stops, so a rebuilt shim or another compiler never serves a run with the old code. The
  * server serves one run at a time and stops after `--idle-minutes` (default 30) without one.
  *
  * WhyNot: not a TCP port. A Unix domain socket is a file only this user can reach, with no port to choose or to
  * collide on.
  * WhyNot: the files are not all added again on every run. The compiler marks every file it is given as changed, and
  * a changed file sends its dependents back through the typer; only a file whose bytes differ from the last run's (or
  * one added or removed) is given to it.
  */
object Resident {
  val NoServer = 11
  val Protocol = 1
  private val Settings = List("FLIXLINT_FACTS", "FLIXLINT_TODAY", "FLIXLINT_LIMITS", "FLIXLINT_LIMITS_BASE")

  def main(argv: Array[String]): Unit = argv.toList match {
    case "server" :: rest => server(rest)
    case "client" :: rest => sys.exit(client(rest, name => Option(System.getenv(name))))
    case _ =>
      System.err.println("flixlint: Resident server|client --socket FILE --identity ID ...")
      sys.exit(4)
  }

  /** `--socket FILE --identity ID` and the options of each side, in front of the rest. */
  private final case class Opts(socket: Path, identity: String, idleMinutes: Long, waitSeconds: Long, rest: List[String])

  private def opts(argv: List[String]): Opts = {
    def go(a: List[String], o: Opts): Opts = a match {
      case "--socket" :: v :: t => go(t, o.copy(socket = Paths.get(v)))
      case "--identity" :: v :: t => go(t, o.copy(identity = v))
      case "--idle-minutes" :: v :: t => go(t, o.copy(idleMinutes = v.toLong))
      case "--wait" :: v :: t => go(t, o.copy(waitSeconds = v.toLong))
      case rest => o.copy(rest = rest)
    }
    val o = go(argv, Opts(null, null, 30, 0, Nil))
    if (o.socket == null || o.identity == null) throw new Facts.UsageError("Resident needs --socket FILE and --identity ID")
    o
  }

  // ---- the client ----

  /** Sends the run to the server and relays its output; the run's exit code, or `NoServer`. */
  def client(argv: List[String], env: String => Option[String]): Int = {
    val o = opts(argv)
    val deadline = System.nanoTime() + o.waitSeconds * 1000000000L
    connect(o.socket, deadline) match {
      case None => NoServer
      case Some(ch) =>
        try {
          val out = new DataOutputStream(new BufferedOutputStream(Channels.newOutputStream(ch)))
          out.writeInt(Protocol)
          out.writeUTF(o.identity)
          val settings = Settings.flatMap(n => env(n).map(v => s"$n=$v"))
          out.writeInt(settings.length); settings.foreach(out.writeUTF)
          out.writeInt(o.rest.length); o.rest.foreach(out.writeUTF)
          out.flush()
          val in = new DataInputStream(Channels.newInputStream(ch))
          relay(in)
        } catch {
          case _: IOException =>
            System.err.println("flixlint: the resident server stopped during the run; run again (or without --resident)")
            4
        } finally ch.close()
    }
  }

  private def connect(socket: Path, deadline: Long): Option[SocketChannel] = {
    val ch = SocketChannel.open(StandardProtocolFamily.UNIX)
    try { ch.connect(UnixDomainSocketAddress.of(socket)); Some(ch) }
    catch {
      case _: IOException =>
        ch.close()
        if (System.nanoTime() >= deadline) None
        else { Thread.sleep(100); connect(socket, deadline) }
    }
  }

  /** Writes the frames of the reply to stdout and stderr until the exit code. */
  private def relay(in: DataInputStream): Int = {
    val buf = new Array[Byte](1 << 16)
    var code = -1
    while (code < 0) {
      val tag = in.readByte().toInt
      if (tag == 'X') code = in.readInt()
      else {
        val n = in.readInt()
        in.readFully(buf, 0, n)
        (if (tag == 'O') System.out else System.err).write(buf, 0, n)
      }
    }
    System.out.flush(); System.err.flush()
    code
  }

  // ---- the server ----

  private def server(argv: List[String]): Unit = {
    val o = opts(argv)
    Files.deleteIfExists(o.socket)
    val ch = ServerSocketChannel.open(StandardProtocolFamily.UNIX)
    ch.bind(UnixDomainSocketAddress.of(o.socket))
    o.socket.toFile.setReadable(false, false); o.socket.toFile.setReadable(true, true)
    o.socket.toFile.setWritable(false, false); o.socket.toFile.setWritable(true, true)
    ch.configureBlocking(false)
    val selector = Selector.open()
    ch.register(selector, SelectionKey.OP_ACCEPT)
    val state = new State
    val realOut = System.out
    val realErr = System.err
    var serving = true
    val idle = o.idleMinutes * 60000000000L
    var last = System.nanoTime()
    System.err.println(s"flixlint resident: serving ${o.socket} (${o.identity})")
    while (serving) {
      if (selector.select(o.idleMinutes * 60000L) == 0) serving = System.nanoTime() - last < idle
      else {
        last = System.nanoTime()
        selector.selectedKeys().clear()
        Option(ch.accept()).foreach { conn =>
          conn.configureBlocking(true)
          try serving = serve(conn, o, state, realErr)
          catch { case e: IOException => realErr.println(s"flixlint resident: a client left: ${e.getMessage}") }
          finally { System.setOut(realOut); System.setErr(realErr); conn.close() }
        }
      }
    }
    ch.close()
    Files.deleteIfExists(o.socket)
    realErr.println("flixlint resident: stopped")
    sys.exit(0)
  }

  /** One run; whether to keep serving (not after a call meant for another server). */
  private def serve(conn: SocketChannel, o: Opts, state: State, realErr: PrintStream): Boolean = {
    val in = new DataInputStream(Channels.newInputStream(conn))
    val raw = new DataOutputStream(new BufferedOutputStream(Channels.newOutputStream(conn), 1 << 16))
    val protocol = in.readInt()
    val theirs = in.readUTF()
    val settings = List.fill(in.readInt())(in.readUTF())
    val argv = Array.fill(in.readInt())(in.readUTF())
    if (protocol != Protocol || theirs != o.identity) {
      realErr.println(s"flixlint resident: stopping for a call with another identity ($theirs)")
      // The socket goes before the reply: the caller may start the next server on the same path right after it.
      Files.deleteIfExists(o.socket)
      raw.writeByte('X'); raw.writeInt(NoServer); raw.flush()
      false
    } else {
      val out = new PrintStream(new Frames(raw, 'O'), false, "UTF-8")
      val err = new PrintStream(new Frames(raw, 'E'), false, "UTF-8")
      System.setOut(out); System.setErr(err)
      val t0 = System.nanoTime()
      var tEngine = 0L
      val code =
        try Lint.run(argv, rest => Facts.guardedWith(rest)(state.facts), jar => { tEngine = System.nanoTime(); state.engine(jar, settings) })
        catch {
          case e: Throwable =>
            err.println(s"flixlint: the resident run failed: ${e.getClass.getName}: ${e.getMessage}")
            e.printStackTrace(err)
            4
        }
      out.flush(); err.flush()
      val t1 = System.nanoTime()
      realErr.println(f"flixlint resident: exit $code in ${(t1 - t0) / 1e9}%.2fs (engine ${if (tEngine == 0) 0.0 else (t1 - tEngine) / 1e9}%.2fs)")
      raw.writeByte('X'); raw.writeInt(code); raw.flush()
      true
    }
  }

  /** What the server keeps between runs: the compiler with the files it was last given, and the loaded engine. */
  private final class State {
    private var deps: Option[Facts.Deps] = None
    private var flix: Flix = _
    private var given = Map.empty[Path, Array[Byte]]
    private var engineAt: Option[(Path, String, URLClassLoader)] = None

    /** `Facts.run` on the kept compiler: a new one only when the dependencies change. */
    def facts(argv: Array[String], spans: Option[Path]): Int = {
      val args = Facts.parseArgs(argv)
      val t0 = System.nanoTime()
      val d = Facts.depsOf(args)
      if (!deps.contains(d)) {
        deps = Some(d)
        flix = Facts.compiler(d)
        given = Map.empty
      }
      val files = args.srcs.flatMap(Facts.listFlix)
      val now = files.map(f => f -> Files.readAllBytes(f)).toMap
      given.keys.filterNot(now.contains).foreach(f => flix.remFile(f))
      files.foreach(f => if (!given.get(f).exists(b => Arrays.equals(b, now(f)))) flix.addFile(f, SecurityContext.Unrestricted))
      given = now
      Facts.write(flix, args, files, spans, t0)
    }

    /** Runs the engine jar, loaded once per build of it (`built-hash` next to `artifact/`).
      *
      * WhyNot: the jar is not loaded where `flix build-jar` writes it. A rebuild writes the next engine over the same
      * file while this JVM still has the old one open and cached, and the loader then reads the new bytes through the
      * old index; each build is loaded from a copy of its own (`resident/engine-<hash>.jar`).
      */
    def engine(jar: Path, settings: List[String]): Int = {
      val dir = jar.getParent.getParent
      val built = Files.readString(dir.resolve("built-hash")).trim
      val copy = dir.resolve("resident").resolve(s"engine-$built.jar")
      val loader = engineAt match {
        case Some((p, h, l)) if p == jar && h == built => l
        case other =>
          other.foreach { case (_, h, l) => l.close(); Files.deleteIfExists(dir.resolve("resident").resolve(s"engine-$h.jar")) }
          Files.createDirectories(copy.getParent)
          Files.copy(jar, copy, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
          val l = Lint.newLoader(copy)
          engineAt = Some((jar, built, l))
          l
      }
      System.clearProperty("flixlint.exit")
      val context = Thread.currentThread.getContextClassLoader
      val code = try Lint.runEngine(loader, copy, ("--resident" :: settings).toArray)
        finally Thread.currentThread.setContextClassLoader(context)
      if (code != 0) code else Option(System.getProperty("flixlint.exit")).map(_.toInt).getOrElse(0)
    }
  }

  /** An output stream that writes what it is given as frames of one tag: the tag, the length, the bytes. */
  private final class Frames(to: DataOutputStream, tag: Char) extends OutputStream {
    override def write(b: Int): Unit = write(Array(b.toByte), 0, 1)
    override def write(b: Array[Byte], off: Int, len: Int): Unit = to.synchronized {
      if (len > 0) { to.writeByte(tag); to.writeInt(len); to.write(b, off, len) }
    }
    override def flush(): Unit = to.synchronized(to.flush())
  }
}
