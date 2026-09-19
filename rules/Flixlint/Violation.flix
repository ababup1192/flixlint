///
/// One violation: the line it is reported at, the rule that produced it and the lines that explain it.
///
pub mod Flixlint.Violation {
    use Names.Fn
    use Flixlint.Facts.{Facts, Call, Def}

    ///
    /// `file:line: id: subject: message` is the first line of the report; `reason` (the rule's), `path` (how a
    /// wrapper reaches the disallowed thing, when `transitivelyIn` found it) and `notes` follow. `inFn` is the
    /// function the violation sits in and the target of `allowIn`; a violation on an enum declaration has none.
    ///
    pub type alias Violation = {
        file = String,
        line = Int32,
        id = String,
        subject = String,
        message = String,
        reason = String,
        path = List[String],
        notes = List[String],
        inFn = Option[Fn]
    }

    /// A violation at a call: `caller calls callee`, reported at the line of the call.
    pub def atCall(facts: Facts, id: String, call: Call, reason: String): Violation =
        let caller = Flixlint.Facts.fnName(facts, call#caller);
        let callee = Flixlint.Facts.fnName(facts, call#callee);
        { file = fileOf(facts, call#caller), line = call#line, id = id, subject = caller,
          message = "calls ${callee}", reason = reason, path = Nil, notes = Nil, inFn = Some(call#caller) }

    /// A violation at a definition, reported at its declaration line with the given message.
    pub def atDef(facts: Facts, id: String, def0: Def, message: String, reason: String): Violation =
        { file = def0#file, line = def0#line, id = id, subject = Flixlint.Facts.fnName(facts, def0#fn),
          message = message, reason = reason, path = Nil, notes = Nil, inFn = Some(def0#fn) }

    /// A violation inside the body of `fn` at `line` (a handler, a constructor).
    pub def inBody(facts: Facts, id: String, fn: Fn, line: Int32, message: String, reason: String): Violation =
        { file = fileOf(facts, fn), line = line, id = id, subject = Flixlint.Facts.fnName(facts, fn),
          message = message, reason = reason, path = Nil, notes = Nil, inFn = Some(fn) }

    /// A violation that is not inside a function (an enum case), so `allowIn` cannot name it; `allowInFile` can.
    pub def atDeclaration(id: String, file: String, line: Int32, subject: String, message: String, reason: String): Violation =
        { file = file, line = line, id = id, subject = subject, message = message, reason = reason, path = Nil, notes = Nil, inFn = None }

    pub def withPath(path: List[String], v: Violation): Violation = { path = path | v }

    pub def withNote(note: String, v: Violation): Violation = { notes = v#notes ::: (note :: Nil) | v }

    /// The report: the `file:line:` header, then the reason, the path, the notes and the hint, indented.
    pub def render(facts: Facts, v: Violation): String =
        let allow = match v#inFn {
            case Some(fn) => "allowIn(Fn.${Flixlint.Facts.fnCase(facts, fn)}, \"reason\")"
            case None => "allowInFile(\"${v#file}\", \"reason\")"
        };
        let lines = List#{"${v#file}:${v#line}: ${v#id}: ${v#subject}: ${v#message}", "    ${v#reason}"}
            ::: (if (List.isEmpty(v#path)) Nil else List#{"    ${String.intercalate(" -> ", v#path)}"})
            ::: List.map(n -> "    ${n}", v#notes)
            ::: List#{"    fix it, or add |> ${allow} to rule ${v#id}"};
        String.intercalate("\n", lines)

    /// The sort key: file, line, rule id, then the rest, so the report is the same on every run.
    pub def key(v: Violation): (String, Int32, String, String, String) = (v#file, v#line, v#id, v#subject, v#message)

    def fileOf(facts: Facts, fn: Fn): String =
        Flixlint.Facts.defOf(facts, fn) |> Option.map(d -> d#file) |> Option.getWithDefault("?")
}
