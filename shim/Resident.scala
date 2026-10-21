package flixlint

import ca.uwaterloo.flix.api.Flix
import ca.uwaterloo.flix.language.ast.shared.SecurityContext

import java.io.{BufferedOutputStream, DataInputStream, DataOutputStream, IOException, OutputStream, PrintStream}
import java.net.{StandardProtocolFamily, UnixDomainSocketAddress, URLClassLoader}
import java.nio.channels.{Channels, ClosedChannelException, FileChannel, ServerSocketChannel, SocketChannel}
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths, StandardOpenOption}
import java.util.Arrays
import java.util.concurrent.atomic.{AtomicBoolean, AtomicInteger, AtomicLong}

/** The resident server (`bin/flixlint --resident`): one JVM per project root and identity that keeps the compiler with
  * its last ASTs and the loaded rule engines between runs, so a run after the first compiles only what changed since
  * (the compiler's own incremental `check`) and runs the engine on warm code. Every kind of run on that project (a lint
  * at either stage, the name index `--spans`, and later the `check` of `make check`) shares the one compiler.
  *
  *   Resident server --socket FILE --root DIR --identity ID [--idle-minutes N] [--run-limit SECONDS]
  *   Resident client --socket FILE --root DIR --identity ID --kind KIND [--wait SECONDS] [--timeout SECONDS] [--setting NAME=VALUE]... <the arguments of Lint>
  *   Resident fixture DIR   (checks the encoder and the decoder against DIR/request.hex and DIR/reply.hex)
  *
  * The wire (protocol 2, README "Resident server") is Java's `DataOutputStream`: `writeInt` big endian, `writeUTF` a
  * 2-byte length and modified UTF-8. A request is the protocol number, the kind (`check` `lint` `spans` `test-jar`
  * `stop`), the root, the identity, the settings (`FLIXLINT_FACTS=...`, the client's `--setting`s) and the
  * arguments. The reply is frames: `O`/`E` bytes for stdout/stderr, `Q` (runs ahead of this one, the kind running and
  * for how many seconds; `0` ahead: this run starts now), `V` the version of the sources checked (the `check` kind),
  * and `X` the exit code, last.
  *
  * The client writes what the run prints to its own stdout and stderr and leaves with the run's exit code: the same
  * output and code as `Lint` in a JVM of its own. Exit code 11 when no server answers or it is not the one for this
  * call; 12 when the server went away during the run; 13 when the run took longer than `--timeout`, counted from when
  * it started (not from when it was queued).
  *
  * Order: the server reads every request as it comes and runs one at a time. A `check` goes first, but a request
  * overtaken once runs next whatever comes after it (a stream of checks never starves a lint). A run that takes longer
  * than `--run-limit` (900 s by default) is answered with exit code 4 and the server stops: it cannot stop the run's
  * thread, and a compiler or rule engine left in a loop must not keep the project's one server.
  *
  * WhyNot: not a TCP port. A Unix domain socket is a file only this user can reach, with no port to choose or to
  * collide on.
  * WhyNot: a call with another identity does not stop the server. Each identity has a socket of its own (`bin/flixlint`
  * names it after the root and the identity), so two compilers on one project are two servers rather than one that
  * stops for the other and pays its cold start on every call.
  * WhyNot: the files are not all added again on every run. The compiler marks every file it is given as changed, and
  * a changed file sends its dependents back through the typer; only a file whose bytes differ from the last run's (or
  * one added or removed) is given to it.
  */
object Resident {
  val NoServer = 11
  val Lost = 12
  val TimedOut = 13
  val Protocol = 2
  val Kinds = List("check", "lint", "spans", "test-jar", "stop")

  def main(argv: Array[String]): Unit = argv.toList match {
    case "server" :: rest => server(rest)
    case "client" :: rest => sys.exit(client(rest))
    case "fixture" :: dir :: Nil => sys.exit(Wire.fixture(Paths.get(dir)))
    case _ =>
      System.err.println("flixlint: Resident server|client --socket FILE --root DIR --identity ID ... | Resident fixture DIR")
      sys.exit(4)
  }

  // ---- the wire ----

  final case class Request(kind: String, root: String, identity: String, settings: List[String], args: List[String])

  sealed trait Frame
  object Frame {
    final case class Out(bytes: Vector[Byte]) extends Frame
    final case class Err(bytes: Vector[Byte]) extends Frame
    final case class Queued(ahead: Int, running: String, seconds: Int) extends Frame
    final case class Version(version: String) extends Frame
    final case class Exit(code: Int) extends Frame
  }

  object Wire {
    def writeRequest(out: DataOutputStream, r: Request): Unit = {
      out.writeInt(Protocol)
      out.writeUTF(r.kind); out.writeUTF(r.root); out.writeUTF(r.identity)
      out.writeInt(r.settings.length); r.settings.foreach(out.writeUTF)
      out.writeInt(r.args.length); r.args.foreach(out.writeUTF)
    }

    /** None for a caller of another protocol: the rest of its bytes cannot be read. */
    def readRequest(in: DataInputStream): Option[Request] =
      if (in.readInt() != Protocol) None
      else {
        val kind = in.readUTF(); val root = in.readUTF(); val identity = in.readUTF()
        val settings = List.fill(in.readInt())(in.readUTF())
        Some(Request(kind, root, identity, settings, List.fill(in.readInt())(in.readUTF())))
      }

    def writeFrame(out: DataOutputStream, f: Frame): Unit = f match {
      case Frame.Out(b) => out.writeByte('O'); out.writeInt(b.length); out.write(b.toArray)
      case Frame.Err(b) => out.writeByte('E'); out.writeInt(b.length); out.write(b.toArray)
      case Frame.Queued(a, k, s) => out.writeByte('Q'); out.writeInt(a); out.writeUTF(k); out.writeInt(s)
      case Frame.Version(v) => out.writeByte('V'); out.writeUTF(v)
      case Frame.Exit(c) => out.writeByte('X'); out.writeInt(c)
    }

    def readFrame(in: DataInputStream): Frame = in.readByte().toChar match {
      case 'O' => Frame.Out(bytes(in))
      case 'E' => Frame.Err(bytes(in))
      case 'Q' => val a = in.readInt(); val k = in.readUTF(); Frame.Queued(a, k, in.readInt())
      case 'V' => Frame.Version(in.readUTF())
      case 'X' => Frame.Exit(in.readInt())
      case t => throw new IOException(s"unknown frame '$t'")
    }

    private def bytes(in: DataInputStream): Vector[Byte] = {
      val b = new Array[Byte](in.readInt()); in.readFully(b); b.toVector
    }

    /** What `DIR/request.hex` and `DIR/reply.hex` hold (README "Resident server"; a client in another language reads
      * and writes the same bytes in its own tests).
      */
    val FixtureRequest = Request("lint", "/p/game", "id-1", List("FLIXLINT_TODAY=2026-10-21"), List("--stage", "src/日🎮.flix"))
    val FixtureReply = List[Frame](
      Frame.Queued(1, "check", 12), Frame.Queued(0, "lint", 0),
      Frame.Out("ok\n".getBytes(StandardCharsets.UTF_8).toVector), Frame.Err("e\n".getBytes(StandardCharsets.UTF_8).toVector),
      Frame.Version("abc"), Frame.Exit(1))

    /** 0 when the encoder writes the fixture's bytes and the decoder reads them back; 1 with what differs. */
    def fixture(dir: Path): Int = {
      def hex(name: String): Array[Byte] = {
        val text = Files.readAllLines(dir.resolve(name)).toArray.map(_.toString.takeWhile(_ != '#')).mkString.filterNot(_.isWhitespace)
        text.grouped(2).map(Integer.parseInt(_, 16).toByte).toArray
      }
      def encoded(write: DataOutputStream => Unit): Array[Byte] = {
        val b = new java.io.ByteArrayOutputStream(); val d = new DataOutputStream(b); write(d); d.flush(); b.toByteArray
      }
      val req = hex("request.hex")
      val rep = hex("reply.hex")
      val problems = List(
        Option.when(!Arrays.equals(encoded(writeRequest(_, FixtureRequest)), req))("the request is not encoded as request.hex"),
        Option.when(scala.util.Try(readRequest(new DataInputStream(new java.io.ByteArrayInputStream(req)))).toOption.flatten != Some(FixtureRequest))("request.hex does not decode to the request"),
        Option.when(!Arrays.equals(encoded(d => FixtureReply.foreach(writeFrame(d, _))), rep))("the reply is not encoded as reply.hex"),
        Option.when(scala.util.Try { val in = new DataInputStream(new java.io.ByteArrayInputStream(rep)); FixtureReply.map(_ => readFrame(in)) }.toOption != Some(FixtureReply))("reply.hex does not decode to the reply")
      ).flatten ++ Order.fixtureProblems
      problems.foreach(p => System.err.println(s"flixlint resident fixture: $p"))
      if (problems.isEmpty) 0 else 1
    }
  }

  /** Which waiting request runs next. */
  object Order {
    final case class Waiting(kind: String, overtaken: Boolean)

    /** The index, in arrival order, of the one to run next: the first one overtaken before, else the first `check`,
      * else the first.
      */
    def next(w: IndexedSeq[Waiting]): Int = {
      val owed = w.indexWhere(_.overtaken)
      if (owed >= 0) owed else math.max(0, w.indexWhere(_.kind == "check"))
    }

    /** The queue after the one at `i` leaves it: those that came before it have been overtaken. */
    def after(w: IndexedSeq[Waiting], i: Int): IndexedSeq[Waiting] =
      w.zipWithIndex.collect { case (x, j) if j != i => if (j < i) x.copy(overtaken = true) else x }

    /** The order the queue runs in when nothing more comes (indices in arrival order). */
    def order(w: IndexedSeq[Waiting]): List[Int] = {
      def go(q: IndexedSeq[(Waiting, Int)]): List[Int] =
        if (q.isEmpty) Nil
        else {
          val i = next(q.map(_._1))
          val rest = after(q.map(_._1), i).zip(q.zipWithIndex.filter(_._2 != i).map(_._1._2))
          q(i)._2 :: go(rest)
        }
      go(w.zipWithIndex)
    }

    /** The orders `Wire.fixture` checks: what README "Resident server" says of a check and of a run overtaken. */
    private[Resident] def fixtureProblems: List[String] = {
      def q(kinds: String*) = kinds.toVector.map(Waiting(_, overtaken = false))
      List(
        (q("lint", "spans"), List(0, 1)),
        (q("lint", "check"), List(1, 0)),
        // a lint overtaken once runs before a check that came after it
        (q("lint", "check", "check"), List(1, 0, 2)),
        (q("spans", "lint", "check", "check"), List(2, 0, 1, 3)),
        (Vector(Waiting("lint", overtaken = true), Waiting("check", overtaken = false)), List(0, 1))
      ).collect { case (w, want) if order(w) != want => s"the order of ${w.map(_.kind).mkString(",")} is ${order(w)}, not $want" }
    }
  }

  /** `--socket FILE --root DIR --identity ID` and the options of each side, in front of the rest. */
  private final case class Opts(socket: Path, root: String, identity: String, kind: String, idleMinutes: Long, runLimit: Long,
                                waitSeconds: Long, timeout: Long, settings: List[String], rest: List[String])

  private def opts(argv: List[String]): Opts = {
    def go(a: List[String], o: Opts): Opts = a match {
      case "--socket" :: v :: t => go(t, o.copy(socket = Paths.get(v)))
      case "--root" :: v :: t => go(t, o.copy(root = v))
      case "--identity" :: v :: t => go(t, o.copy(identity = v))
      case "--kind" :: v :: t => go(t, o.copy(kind = v))
      case "--idle-minutes" :: v :: t => go(t, o.copy(idleMinutes = v.toLong))
      case "--run-limit" :: v :: t => go(t, o.copy(runLimit = v.toLong))
      case "--wait" :: v :: t => go(t, o.copy(waitSeconds = v.toLong))
      case "--timeout" :: v :: t => go(t, o.copy(timeout = v.toLong))
      case "--setting" :: v :: t => go(t, o.copy(settings = o.settings :+ v))
      case rest => o.copy(rest = rest)
    }
    val o = go(argv, Opts(null, null, null, "lint", 30, 900, 0, 0, Nil, Nil))
    if (o.socket == null || o.root == null || o.identity == null) throw new Facts.UsageError("Resident needs --socket FILE, --root DIR and --identity ID")
    o
  }

  // ---- the client ----

  /** Sends the run to the server and relays its output; the run's exit code, or `NoServer`, `Lost`, `TimedOut`.
    *
    * WhyNot: the settings are not read from the client's environment by a list of names kept here. The caller
    * (`bin/flixlint`) has the one list the engine reads (`Flixlint.Engine.settingsOf`) and hands it over as `--setting`;
    * a second list here went out of step with it once (FLIXLINT_TIMING worked on its own and not on the server).
    */
  def client(argv: List[String]): Int = {
    val o = opts(argv)
    val deadline = System.nanoTime() + o.waitSeconds * 1000000000L
    connect(o.socket, deadline) match {
      case None => NoServer
      case Some(ch) =>
        val started = new AtomicLong(0L)
        val timedOut = new AtomicBoolean(false)
        if (o.timeout > 0) {
          val watch = new Thread(() => {
            while (ch.isOpen) {
              val s = started.get
              if (s != 0 && System.nanoTime() - s > o.timeout * 1000000000L) { timedOut.set(true); ch.close() }
              Thread.sleep(200)
            }
          })
          watch.setDaemon(true); watch.start()
        }
        try {
          val out = new DataOutputStream(new BufferedOutputStream(Channels.newOutputStream(ch)))
          Wire.writeRequest(out, Request(o.kind, o.root, o.identity, o.settings, o.rest))
          out.flush()
          relay(new DataInputStream(Channels.newInputStream(ch)), () => started.set(System.nanoTime()))
        } catch {
          case _: IOException if timedOut.get =>
            System.out.flush()
            System.err.println(s"flixlint: the run took longer than ${o.timeout}s on the resident server (counted from when it started); stopped waiting")
            TimedOut
          case _: IOException => Lost
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

  /** Writes the frames of the reply to stdout and stderr until the exit code. A `Q` frame is said once per change of
    * the number ahead; the one with none ahead marks the start of the run (`started`).
    */
  private def relay(in: DataInputStream, started: () => Unit): Int = {
    var ahead = -1
    var code = -1
    while (code < 0) Wire.readFrame(in) match {
      case Frame.Exit(c) => code = c
      case Frame.Out(b) => System.out.write(b.toArray)
      case Frame.Err(b) => System.err.write(b.toArray)
      case Frame.Version(_) => ()
      case Frame.Queued(0, _, _) => started()
      case Frame.Queued(a, k, s) =>
        if (a != ahead) System.err.println(s"flixlint: the resident server is busy; $a run(s) ahead of this one (running: $k, for ${s}s)")
        ahead = a
    }
    System.out.flush(); System.err.flush()
    code
  }

  // ---- the server ----

  /** A request read off a connection, waiting for its turn. */
  private final class Waiting(val conn: SocketChannel, val req: Request, val out: DataOutputStream) {
    val arrived: Long = System.nanoTime()
    var overtaken = false
    var said: (Int, Long) = (-1, 0L) // the last `Q` sent: how many were ahead, and when
  }

  private def server(argv: List[String]): Unit = {
    val o = opts(argv)
    val realOut = System.out
    val realErr = System.err
    // WhyNot: the socket is not simply taken over. Two callers that found no server may start two at once; the lock
    // lets one serve and the other leave, so the project never has a second JVM behind an unlinked socket.
    Files.createDirectories(o.socket.toAbsolutePath.getParent)
    val lockFile = o.socket.resolveSibling(o.socket.getFileName.toString.stripSuffix(".sock") + ".lock")
    val lock = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE).tryLock()
    if (lock == null) {
      realErr.println(s"flixlint resident: another server holds ${lockFile}; leaving")
      sys.exit(0)
    }
    val cwd = Paths.get("").toAbsolutePath.toRealPath()
    if (cwd != Paths.get(o.root).toRealPath()) {
      realErr.println(s"flixlint resident: started in $cwd, not in the root ${o.root}; leaving")
      sys.exit(4)
    }
    Files.deleteIfExists(o.socket)
    val ch = ServerSocketChannel.open(StandardProtocolFamily.UNIX)
    ch.bind(UnixDomainSocketAddress.of(o.socket))
    o.socket.toFile.setReadable(false, false); o.socket.toFile.setReadable(true, true)
    o.socket.toFile.setWritable(false, false); o.socket.toFile.setWritable(true, true)

    val queue = scala.collection.mutable.ArrayBuffer.empty[Waiting]
    val turn = new Object
    var running: Option[(String, Long)] = None // the kind running, and since when (under `turn`)

    def reject(conn: SocketChannel, out: DataOutputStream): Unit =
      try { Wire.writeFrame(out, Frame.Exit(NoServer)); out.flush() } finally conn.close()

    /** Sends `Q` to each waiting caller whose place changed, and again every 10 s (under `turn`). */
    def tell(): Unit = {
      val order = Order.order(queue.toVector.map(w => Order.Waiting(w.req.kind, w.overtaken)))
      val now = System.nanoTime()
      order.zipWithIndex.foreach { case (i, place) =>
        val w = queue(i)
        val ahead = place + (if (running.isDefined) 1 else 0)
        if (ahead > 0 && (w.said._1 != ahead || now - w.said._2 > 10000000000L)) {
          val (kind, since) = running.getOrElse((queue(order.head).req.kind, now))
          try { Wire.writeFrame(w.out, Frame.Queued(ahead, kind, ((now - since) / 1000000000L).toInt)); w.out.flush() }
          catch { case _: IOException => () } // the caller left; its run fails to write and is skipped then
          w.said = (ahead, now)
        }
      }
    }

    val acceptor = new Thread(() => {
      try while (true) {
        val conn = ch.accept()
        val reader = new Thread(() => {
          val out = new DataOutputStream(new BufferedOutputStream(Channels.newOutputStream(conn), 1 << 16))
          try Wire.readRequest(new DataInputStream(Channels.newInputStream(conn))) match {
            case Some(r) if r.root == o.root && r.identity == o.identity && Kinds.contains(r.kind) =>
              turn.synchronized { queue += new Waiting(conn, r, out); tell(); turn.notifyAll() }
            case other =>
              realErr.println(s"flixlint resident: refused a call (${other.map(r => s"kind ${r.kind}, root ${r.root}, identity ${r.identity}").getOrElse("another protocol")})")
              reject(conn, out)
          } catch { case e: IOException => realErr.println(s"flixlint resident: a caller left before its request: ${e.getMessage}"); conn.close() }
        })
        reader.setDaemon(true); reader.start()
      } catch { case _: ClosedChannelException => () }
    })
    acceptor.setDaemon(true); acceptor.start()

    /** Closes the socket, answers the waiting callers that there is no server, and leaves. */
    def stop(why: String): Nothing = {
      ch.close()
      Files.deleteIfExists(o.socket)
      turn.synchronized { queue.foreach(w => try reject(w.conn, w.out) catch { case _: IOException => () }); queue.clear() }
      realErr.println(s"flixlint resident: stopped ($why)")
      sys.exit(0)
    }

    val state = new State
    val idle = o.idleMinutes * 60000000000L
    var last = System.nanoTime()
    var n = 0
    realErr.println(s"flixlint resident: serving ${o.socket} for ${o.root} (${o.identity}; run limit ${o.runLimit}s, idle ${o.idleMinutes} min)")
    while (true) {
      val next = turn.synchronized {
        while (queue.isEmpty && System.nanoTime() - last < idle) turn.wait(math.max(1L, (idle - (System.nanoTime() - last)) / 1000000L))
        if (queue.isEmpty) None
        else {
          val i = Order.next(queue.toVector.map(w => Order.Waiting(w.req.kind, w.overtaken)))
          (0 until i).foreach(j => queue(j).overtaken = true)
          val w = queue.remove(i)
          running = Some((w.req.kind, System.nanoTime()))
          Some(w)
        }
      }
      next match {
        case None => stop(s"idle for ${o.idleMinutes} min")
        case Some(w) if w.req.kind == "stop" =>
          try { Wire.writeFrame(w.out, Frame.Exit(0)); w.out.flush(); w.conn.close() } catch { case _: IOException => () }
          stop("asked to")
        case Some(w) =>
          n += 1
          val waited = (System.nanoTime() - w.arrived) / 1e9
          val t0 = System.nanoTime()
          val code = new AtomicInteger(-1)
          val tEngine = new AtomicLong(0L)
          val run = new Thread(() => {
            val out = new PrintStream(new Frames(w.out, 'O'), false, "UTF-8")
            val err = new PrintStream(new Frames(w.out, 'E'), false, "UTF-8")
            System.setOut(out); System.setErr(err)
            code.set(
              try {
                w.out.synchronized { Wire.writeFrame(w.out, Frame.Queued(0, w.req.kind, 0)); w.out.flush() }
                runOne(w.req, state, () => tEngine.set(System.nanoTime()))
              } catch {
                case e: IOException => realErr.println(s"flixlint resident: a caller left during its run: ${e.getMessage}"); 4
                case e: Throwable =>
                  err.println(s"flixlint: the resident run failed: ${e.getClass.getName}: ${e.getMessage}")
                  e.printStackTrace(err)
                  4
              })
            out.flush(); err.flush()
            System.setOut(realOut); System.setErr(realErr)
          })
          run.start()
          val limit = o.runLimit * 1000000000L
          while (run.isAlive && System.nanoTime() - t0 < limit) {
            run.join(1000)
            turn.synchronized(tell())
          }
          val t1 = System.nanoTime()
          if (run.isAlive) {
            realErr.println(f"flixlint resident: #$n ${w.req.kind} passed the run limit of ${o.runLimit}s (waited $waited%.2fs)")
            try {
              w.out.synchronized {
                Wire.writeFrame(w.out, Frame.Err(s"flixlint: the run passed the resident server's limit of ${o.runLimit}s; the server stops\n".getBytes(StandardCharsets.UTF_8).toVector))
                Wire.writeFrame(w.out, Frame.Exit(4)); w.out.flush()
              }
            } catch { case _: IOException => () }
            stop("a run passed the run limit")
          }
          val te = tEngine.get
          realErr.println(f"flixlint resident: #$n ${w.req.kind} exit ${code.get} in ${(t1 - t0) / 1e9}%.2fs (waited $waited%.2fs, engine ${if (te == 0) 0.0 else (t1 - te) / 1e9}%.2fs)")
          try { w.out.synchronized { Wire.writeFrame(w.out, Frame.Exit(code.get)); w.out.flush() } } catch { case _: IOException => () }
          try w.conn.close() catch { case _: IOException => () }
          turn.synchronized { running = None; last = System.nanoTime(); tell() }
      }
    }
  }

  /** One run of `req` on the kept state; its exit code. `engineStarts` marks when the rule engine starts. */
  private def runOne(req: Request, state: State, engineStarts: () => Unit): Int = {
    val argv = req.args.toArray
    val hasEngine = argv.contains("--engine")
    req.kind match {
      case "lint" | "spans" if hasEngine != (req.kind == "lint") =>
        System.err.println(s"flixlint: a ${req.kind} run ${if (hasEngine) "with" else "without"} --engine")
        4
      case "lint" | "spans" =>
        Lint.run(argv, rest => Facts.guardedWith(rest)(state.facts), state.build, jar => { engineStarts(); state.engine(jar, req.settings) })
      case other =>
        System.err.println(s"flixlint: this resident server does not serve the kind $other yet")
        4
    }
  }

  /** What the server keeps between runs: the compiler with the sources it was last given, and the loaded engines. */
  private final class State {
    private var deps: Option[Facts.Deps] = None
    private var flix: Flix = _
    private var sent = Map.empty[Path, Array[Byte]]

    /** `Facts.run` on the kept compiler: a new one only when the dependencies change. */
    def facts(argv: Array[String], spans: Option[Path]): Int = {
      val args = Facts.parseArgs(argv)
      val t0 = System.nanoTime()
      val project = Facts.projectOf(args)
      if (!deps.contains(project.deps)) {
        deps = Some(project.deps)
        flix = Facts.compiler(project.deps)
        sent = Map.empty
      }
      val sources = Facts.sourcesOf(args, project)
      sent = Resident.give(flix, sent, sources.compiled)
      Facts.write(flix, args, sources, spans, t0)
    }

    private var engineFlix = Map.empty[Path, (Flix, Map[Path, Array[Byte]])]

    /** Builds `artifact/engine.jar` of the engine directory with a compiler kept for it (only the changed sources are
      * compiled again); false when they do not compile, and `bin/flixlint` builds it and reports the errors as before.
      *
      * The jar is what `flix build-jar` writes: the generated classes and a manifest naming `Main`. Each engine
      * directory (a lint at each stage has its own, with its own `Names.flix`) keeps its compiler.
      * WhyNot: not `flix build-jar` in a JVM of its own. Its start and the cold compiler cost most of the build (about
      * 8 s against 1 s on a warm compiler); a rule changed while the server runs builds in that second.
      */
    def build(dir: Path): Boolean = try {
      val (flix, before) = engineFlix.getOrElse(dir, {
        val f = new Flix()
        f.setOptions(ca.uwaterloo.flix.util.Options.Default.copy(lib = ca.uwaterloo.flix.util.LibLevel.All, progress = false))
        (f, Map.empty[Path, Array[Byte]])
      })
      engineFlix += dir -> (flix, Resident.give(flix, before, Facts.listFlix(dir.resolve("src"))))
      flix.compile() match {
        case ca.uwaterloo.flix.util.Result.Ok(result) =>
          val jar = dir.resolve("artifact").resolve("engine.jar")
          Files.createDirectories(jar.getParent)
          val part = jar.resolveSibling("engine.jar.part")
          val manifest = new java.util.jar.Manifest()
          manifest.getMainAttributes.put(java.util.jar.Attributes.Name.MANIFEST_VERSION, "1.0")
          manifest.getMainAttributes.put(java.util.jar.Attributes.Name.MAIN_CLASS, "Main")
          val out = new java.util.jar.JarOutputStream(Files.newOutputStream(part), manifest)
          try result.getClasses.values.toList.sortBy(_.name.descriptorString).foreach { c =>
            out.putNextEntry(new java.util.jar.JarEntry(c.name.descriptorString.drop(1).dropRight(1) + ".class"))
            out.write(c.bytecode)
            out.closeEntry()
          } finally out.close()
          Files.move(part, jar, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
          true
        case _ => false
      }
    } catch {
      case e: Exception =>
        System.err.println(s"flixlint resident: the engine did not build here (${e.getClass.getName}: ${e.getMessage}); building it apart")
        false
    }

    private var engineAt = Map.empty[Path, (String, URLClassLoader)]

    /** Runs the engine jar, loaded once per build of it (`built-hash` next to `artifact/`); one loader per engine
      * directory, so lints at both stages alternate without loading their engines again.
      *
      * WhyNot: the jar is not loaded where `flix build-jar` writes it. A rebuild writes the next engine over the same
      * file while this JVM still has the old one open and cached, and the loader then reads the new bytes through the
      * old index; each build is loaded from a copy of its own (`resident/engine-<hash>.jar`).
      */
    def engine(jar: Path, settings: List[String]): Int = {
      val dir = jar.getParent.getParent
      val built = Files.readString(dir.resolve("built-hash")).trim
      val copy = dir.resolve("resident").resolve(s"engine-$built.jar")
      val loader = engineAt.get(jar) match {
        // The copy is checked too: the build directory may have been removed (make clean) while the server ran.
        case Some((h, l)) if h == built && Files.isRegularFile(copy) => l
        case other =>
          other.foreach { case (h, l) => l.close(); Files.deleteIfExists(dir.resolve("resident").resolve(s"engine-$h.jar")) }
          Files.createDirectories(copy.getParent)
          Files.copy(jar, copy, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
          val l = Lint.newLoader(copy)
          engineAt += jar -> (built, l)
          l
      }
      System.clearProperty("flixlint.exit")
      val context = Thread.currentThread.getContextClassLoader
      val code = try Lint.runEngine(loader, copy, ("--resident" :: settings).toArray)
        finally Thread.currentThread.setContextClassLoader(context)
      if (code != 0) code else Option(System.getProperty("flixlint.exit")).map(_.toInt).getOrElse(0)
    }
  }

  /** Gives `flix` the sources `files` as they are on disk now, and returns what it was given (path -> bytes): each file
    * is read once, and the bytes compared are the bytes given (`addSource`), so a file written between the comparison
    * and the compiler's own read cannot be checked in a version other than the one compared. Files gone since `before`
    * are removed; a file whose bytes did not change is not given again.
    *
    * The path is the one `addFile` would key it by (`normalize`), and the text is decoded as `addFile` does, so the
    * compiler's messages and the facts name the files as before.
    */
  private def give(flix: Flix, before: Map[Path, Array[Byte]], files: List[Path]): Map[Path, Array[Byte]] = {
    val now = files.map(f => f.normalize -> Files.readAllBytes(f)).toMap
    before.keys.filterNot(now.contains).foreach(flix.remSource)
    now.foreach { case (f, b) =>
      if (!before.get(f).exists(Arrays.equals(_, b))) flix.addSource(f, new String(b, flix.defaultCharset), SecurityContext.Unrestricted)
    }
    now
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
