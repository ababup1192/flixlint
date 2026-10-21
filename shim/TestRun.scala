package flixlint

import ca.uwaterloo.flix.api.{BootstrapError, Flix}
import ca.uwaterloo.flix.language.ast.{SourceLocation, SourcePosition, Symbol}
import ca.uwaterloo.flix.language.ast.shared.{Origin, SecurityContext, Source, SourceName}
import ca.uwaterloo.flix.runtime.{LoadedProgram, TestFn}
import ca.uwaterloo.flix.tools.Tester
import ca.uwaterloo.flix.util.{Formatter, Options, Result}

import java.lang.reflect.InvocationTargetException
import java.net.URLClassLoader
import java.nio.file.{Files, Path, Paths}
import scala.jdk.CollectionConverters._

/** Runs the tests `TestJar` wrote, in a JVM of its own (checkd-freshness §4.3, C-T):
  *
  *   TestRun FILE.tests
  *
  * The classes are loaded from the jar (the compiler's runtime and the dependencies' jars beside them), each test is
  * called as `JvmLoader` calls it for `flix test` (the static method with no argument; what it throws is the test's
  * failure) and `Tester` runs and reports them as `flix test` does. Exit 0 when they pass, 1 when one fails.
  */
object TestRun {
  final case class Entry(sym: Symbol.DefnSym, skip: Boolean, cls: String, method: String)

  def main(argv: Array[String]): Unit = argv match {
    case Array(list) => sys.exit(run(Paths.get(list)))
    case _ =>
      System.err.println("flixlint: TestRun FILE.tests")
      sys.exit(4)
  }

  def run(list: Path): Int = {
    val rows = Files.readAllLines(list).asScala.toList.map(_.split("\t", -1).toList)
    val jars = rows.collect { case "jar" :: p :: Nil => Paths.get(p); case "cp" :: p :: Nil => Paths.get(p) }
    val tests = rows.collect { case "test" :: ns :: name :: file :: l1 :: c1 :: l2 :: c2 :: skip :: cls :: method :: Nil =>
      val source = new Source(SourceName.PathName(Paths.get(file)), Origin.User, SecurityContext.Unrestricted, Array.emptyCharArray)
      val loc = SourceLocation(isReal = true, source, new SourcePosition(l1.toInt, c1.toShort), new SourcePosition(l2.toInt, c2.toShort))
      Entry(new Symbol.DefnSym(None, if (ns.isEmpty) Nil else ns.split('.').toList, name, loc), skip == "true", cls, method)
    }
    val loader = new URLClassLoader(jars.map(_.toUri.toURL).toArray, getClass.getClassLoader)
    Thread.currentThread.setContextClassLoader(loader)
    val fns = tests.map { t =>
      val sym = t.sym
      sym -> TestFn(sym, t.skip, () => {
        val m = Class.forName(t.cls, true, loader).getMethods.find(_.getName == t.method)
          .getOrElse(throw new NoSuchMethodException(s"${t.cls}.${t.method}"))
        try { m.invoke(null); () } catch { case e: InvocationTargetException => throw e.getTargetException }
      })
    }.toMap
    val formatter = Formatter.getDefault
    val flix = new Flix()
    flix.setOptions(Options.Default.copy(progress = false))
    flix.setFormatter(formatter)
    Tester.run(Nil, LoadedProgram(None, fns))(flix) match {
      case Result.Ok(_) => 0
      case Result.Err(_) =>
        System.out.println(BootstrapError.GeneralError("Tester Error").message(formatter))
        1
    }
  }
}
