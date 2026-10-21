///
/// Runs a `RuleSet` against the facts: one judgment per family, then the entry's allows, then the report.
///
/// Exit codes: 0 no violation, 1 violations, 2 the rules are wrong (an allow that matches nothing, an
/// `allowInFile` of a file that is not among the sources).
///
pub mod Flixlint.Engine {
    use Flixlint.Names.{Fn, Eff, Mod}
    use Flixlint.{Allow, RuleSet, DisallowedFunction, DisallowedCallsTogether, DisallowedEffectsTogether,
                  DisallowedOtherEffectsWith, DisallowedEffectsIn, DisallowedHandler, DisallowedConstructor,
                  DisallowedCallInLambda, DisallowedCallWithArg, DisallowedCaseArgType, DisallowedDependency}
    use Flixlint.Facts.{Facts, Call}
    use Flixlint.Violation.Violation
    use Fs.FileRead.FileRead
    use Fs.DirList.DirList

    import java.io.File
    import java.io.FileWriter
    import java.io.IOException
    import java.lang.System

    /// What a run is told: the facts directory, today's date and the limits (`--limits`, `--limits-base`, each a file or a directory).
    type alias Settings = { factsDir = String, today = String, limits = Option[String], limitsBase = Option[String], timing = Bool, dumpRel = Option[String], held = Bool }

    /// The entry point of the generated engine `main`: the settings come from the environment (`FLIXLINT_FACTS`,
    /// `FLIXLINT_TODAY`, `FLIXLINT_LIMITS`, `FLIXLINT_LIMITS_BASE`, `FLIXLINT_TIMING`) and the exit code ends the JVM.
    /// The caller, `bin/flixlint`, has the one list of them (`settings`) for both ways in.
    ///
    /// Under the resident server (`bin/flixlint --resident`, shim/Resident.scala) one JVM serves many runs, so `main`
    /// is called with `--resident NAME=VALUE...` instead: the settings come from those arguments and the exit code is
    /// left in the system property `flixlint.exit`.
    /// WhyNot: the server does not hand the settings over through its environment. A JVM cannot change its own, and
    /// `System.exit` would end the server with the run.
    pub def lint(rules: RuleSet): Unit \ IO =
        match Sys.Env.runWithIO(() -> Sys.Env.getArgs()) {
            case "--resident" :: vars =>
                let code = Fs.FileRead.runWithIO(() -> Fs.DirList.runWithIO(() -> judgeAndReport(rules, settingsOf(name -> argOf(name, vars)))));
                let _ = System.setProperty("flixlint.exit", Int32.toString(code));
                ()
            case _ =>
                let settings = Sys.Env.runWithIO(() -> settingsOf(Sys.Env.getVar));
                let code = Fs.FileRead.runWithIO(() -> Fs.DirList.runWithIO(() -> judgeAndReport(rules, settings)));
                if (code == 0) () else Sys.Exit.runWithIO(() -> Sys.Exit.exit(code))
        }

    /// The settings, each read by its variable's name (a new one also goes into `settings` of `bin/flixlint`, which
    /// hands the list to the resident server).
    def settingsOf(get: String -> Option[String] \ ef): Settings \ ef =
        let nonEmpty = name -> get(name) |> Option.filter(p -> not String.isEmpty(p));
        { factsDir = get("FLIXLINT_FACTS") |> Option.getWithDefault("build/flixlint/facts"),
          today = get("FLIXLINT_TODAY") |> Option.getWithDefault("0000-00-00"),
          limits = nonEmpty("FLIXLINT_LIMITS"),
          limitsBase = nonEmpty("FLIXLINT_LIMITS_BASE"),
          timing = Option.nonEmpty(nonEmpty("FLIXLINT_TIMING")),
          dumpRel = nonEmpty("FLIXLINT_DUMP_REL"),
          held = Option.nonEmpty(nonEmpty("FLIXLINT_HELD")) }

    /// The value of `NAME=VALUE` among the arguments.
    def argOf(name: String, vars: List[String]): Option[String] =
        vars |> List.find(String.startsWith(prefix = "${name}=")) |> Option.map(String.dropLeft(String.length(name) + 1))

    /// Judges the facts, prints the report and returns the exit code (0 no violation, 1 violations, 2 the rules are wrong,
    /// 4 the generic AST beside the facts is of another format or schema than this flixlint's).
    def judgeAndReport(rules: RuleSet, settings: Settings): Int32 \ IO + FileRead + DirList =
        let t0 = System.nanoTime();
        match loadAst(settings#factsDir) {
            case Err(e) =>
                System.err.println("flixlint: ${e}");
                4
            case Ok(ast) =>
                let facts = Flixlint.Facts.load(settings#factsDir, ast);
                settings#dumpRel |> Option.forEach(dir -> Flixlint.Rel.dump(dir, ast));
                let t1 = System.nanoTime();
                let code = report(rules, settings, facts);
                let t2 = nanoTimeAfter(code);
                List.forEach(n -> System.err.println(notice(Flixlint.Ast.stage(ast), n)), Flixlint.Ast.ruleNames(ast) |> List.filter(isNoticed));
                if (settings#timing) timings(rules, facts, t1 - t0, t2 - t1) else ();
                code
        }

    /// The generic AST the shim wrote beside the facts (`<facts>/generic`), or an empty one when it wrote none.
    def loadAst(factsDir: String): Result[String, Flixlint.Ast.Ast] \ IO =
        let dir = "${factsDir}/generic";
        if ((new File("${dir}/meta.txt")).exists()) Flixlint.Ast.load(dir) else Ok(Flixlint.Ast.empty())

    /// Whether a name the rule file writes is worth a line: this stage does not have it, these sources never have it, or it
    /// is an `Unnamed(`.
    /// WhyNot: not a violation, and not exit 2. A rule file run at both stages may name a kind only one stage has, and a
    /// kind the sources happen not to use is no mistake; the line only makes a rule that quietly finds nothing visible.
    def isNoticed(n: Flixlint.Ast.RuleName): Bool = n#table == "Unnamed" or not n#inStage or n#count == 0

    def notice(stage: Flixlint.Ast.Stage, n: Flixlint.Ast.RuleName): String =
        let stageName = if (stage == Flixlint.Ast.Stage.Typed) "typed" else "resolved";
        let what =
            if (n#table == "Unnamed") "writes a name as a string (${n#name}): it does not stop compiling when the name goes; write the Names case"
            else if (not n#inStage) "${n#table}.${n#name} is not in the ${stageName} stage's AST, so what is written with it finds nothing at this stage"
            else "${n#table}.${n#name} is in no node of these sources (0 at the ${stageName} stage)";
        "flixlint: note: ${n#file}:${n#line}: ${what}"

    /// The report of the judged facts; the exit code.
    def report(rules: RuleSet, settings: Settings, facts: Facts): Int32 \ IO + FileRead + DirList =
        let (judged, ruleErrors) = judgeAll(facts, settings#today, rules);
        let outcome = match settings#limits {
            case None => { violations = judged, failures = Nil, hints = Nil, errors = Nil, held = Nil }
            case Some(path) =>
                match Flixlint.Ratchet.read(path) {
                    case Ok(limits) => Flixlint.Ratchet.apply(limits, ruleIds(rules), judged) |> againstBase(limits, settings#limitsBase)
                    case Err(e) => { violations = judged, failures = Nil, hints = Nil, errors = List#{"flixlint: ${e}"}, held = Nil }
                }
        };
        let violations = outcome#violations;
        let errors = ruleErrors ::: outcome#errors;
        violations |> List.sortBy(Flixlint.Violation.key) |> List.forEach(v -> println(Flixlint.Violation.render(facts, v)));
        reportHeld(settings, facts, outcome#held);
        List.forEach(println, outcome#failures);
        List.forEach(println, outcome#hints);
        List.forEach(println, errors);
        if (not List.isEmpty(errors)) 2
        else if (not List.isEmpty(violations) or not List.isEmpty(outcome#failures)) 1
        else 0

    /// The violations held within their limits: one line on stderr with how many there are of each rule, and every one of
    /// them in `held.txt` beside the facts directory; `FLIXLINT_HELD=1` (`--held`) also lists them on stdout like the others.
    /// WhyNot: not listed by default. A ratchet at its limit is a pass, and a lint that lists the same old violations on
    /// every run buries the new ones; but a run that says nothing of them sends the reader to a second, full run to see
    /// what is left to fix.
    def reportHeld(settings: Settings, facts: Facts, held: List[Violation]): Unit \ IO =
        if (List.isEmpty(held)) () else {
            let sorted = held |> List.sortBy(Flixlint.Violation.key);
            let dir = match String.indexOfRight(substr = "/", settings#factsDir) {
                case Some(i) => String.takeLeft(i, settings#factsDir)
                case None    => "."
            };
            let file = "${dir}/held.txt";
            let written = writeText(file, (sorted |> List.map(v -> Flixlint.Violation.render(facts, v)) |> String.intercalate("\n")) + "\n");
            if (settings#held) List.forEach(v -> println(Flixlint.Violation.render(facts, v)), sorted) else ();
            let counts = List.foldLeft((acc, v) -> Map.insertWith(Add.add, v#id, 1, acc), Map.empty(), held) |> Map.toList
                |> List.sortBy(match (id, n) -> (0 - n, id));
            let shown = counts |> List.take(5) |> List.map(match (id, n) -> "${id} ${n}") |> String.intercalate(", ");
            let more = if (List.length(counts) > 5) ", ..." else "";
            let place = if (written) "all of them in ${file}" else "${file} could not be written";
            System.err.println("flixlint: ratchet: ${List.length(held)} violations within their limits (${shown}${more}); ${place}, or --held to list them")
        }

    /// Writes `text` to `path`; whether it could.
    def writeText(path: String, text: String): Bool \ IO =
        try {
            let w: FileWriter = new FileWriter(path);
            w.write(text);
            w.close();
            true
        } catch {
            case _: IOException => false
        }

    /// `FLIXLINT_TIMING=1`: how long reading the facts and judging took, and each custom rule on its own (to find a slow one).
    /// WhyNot: the custom rules are not timed inside `judgeAll`. It is pure, so it cannot read the clock; they are run once more
    /// here, one by one, only when the timing is asked for.
    def timings(rules: RuleSet, facts: Facts, loadNs: Int64, judgeNs: Int64): Unit \ IO =
        System.err.println("flixlint timing: load=${loadNs / 1_000_000i64}ms judge=${judgeNs / 1_000_000i64}ms");
        rules#customs |> List.forEach(r -> {
            let t0 = System.nanoTime();
            // the rule runs after the first reading of the clock and before the second, which needs its result
            let found = if (t0 >= 0i64) List.length(r#check(facts)) else 0;
            let t1 = nanoTimeAfter(found);
            System.err.println("flixlint timing: judge ${r#id}=${(t1 - t0) / 1_000_000i64}ms (${found} before the allows)")
        })

    /// The clock, read once `x` is known (so that a pure computation of `x` is not moved past it).
    def nanoTimeAfter(x: Int32): Int64 \ IO = if (x < Int32.minValue()) 0i64 else System.nanoTime()

    /// The ratchet's outcome with the limits checked against the base limits (`--limits-base`, a file or a
    /// directory): a limit may not go up without a reason. Without a base the outcome is as it was.
    def againstBase(limits: List[Flixlint.Ratchet.Limit], basePath: Option[String], outcome: Flixlint.Ratchet.Outcome): Flixlint.Ratchet.Outcome \ FileRead + DirList =
        match basePath {
            case None => outcome
            case Some(base0) =>
                match Flixlint.Ratchet.read(base0) {
                    case Ok(base) =>
                        let (failures, hints) = Flixlint.Ratchet.raised(base0, limits, base);
                        { failures = outcome#failures ::: failures, hints = outcome#hints ::: hints | outcome }
                    case Err(e) => { errors = outcome#errors ::: List#{"flixlint: ${e}"} | outcome }
                }
        }

    /// The id of every entry of the rule set.
    def ruleIds(rules: RuleSet): Set[String] =
        (List.map(r -> r#id, rules#functions)
            ::: List.map(r -> r#id, rules#callsTogether)
            ::: List.map(r -> r#id, rules#effectsTogether)
            ::: List.map(r -> r#id, rules#otherEffectsWith)
            ::: List.map(r -> r#id, rules#effectsIn)
            ::: List.map(r -> r#id, rules#handlers)
            ::: List.map(r -> r#id, rules#constructors)
            ::: List.map(r -> r#id, rules#callsInLambda)
            ::: List.map(r -> r#id, rules#callsWithArg)
            ::: List.map(r -> r#id, rules#caseArgTypes)
            ::: List.map(r -> r#id, rules#dependencies)
            ::: List.map(r -> r#id, rules#customs))
            |> List.toSet

    /// Every family's violations after the allows, and the errors of the rules themselves.
    pub def judgeAll(facts: Facts, today: String, rules: RuleSet): (List[Violation], List[String]) =
        let judged =
            List.map(r -> allowed(facts, today, r#id, r#allows, functionRule(facts, r)), rules#functions)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, callsTogetherRule(facts, r)), rules#callsTogether)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, effectsTogetherRule(facts, r)), rules#effectsTogether)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, otherEffectsWithRule(facts, r)), rules#otherEffectsWith)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, effectsInRule(facts, r)), rules#effectsIn)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, handlerRule(facts, r)), rules#handlers)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, constructorRule(facts, r)), rules#constructors)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, callInLambdaRule(facts, r)), rules#callsInLambda)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, callWithArgRule(facts, r)), rules#callsWithArg)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, caseArgTypeRule(facts, r)), rules#caseArgTypes)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, dependencyRule(facts, r)), rules#dependencies)
            ::: List.map(r -> allowed(facts, today, r#id, r#allows, (r#check)(facts)), rules#customs);
        (List.flatMap(fst, judged), List.flatMap(snd, judged))

    // ---- the families (section 5 of the design: one sentence each) ----

    /// Calls(caller, callee) with callee = path, or callee a pub function of the `transitively` modules that reaches
    /// path (the caller itself not being on the way to path).
    def functionRule(facts: Facts, r: DisallowedFunction): List[Violation] =
        let reach = reachable(facts, Set#{r#path}, r#transitively);
        let wrappers = entries(facts, reach, Set.empty(), r#transitively);
        Flixlint.Facts.calls(facts) |> List.filterMap(c ->
            if (c#callee == r#path)
                Some(Flixlint.Violation.atCall(facts, r#id, c, r#reason))
            else if (Set.memberOf(c#callee, wrappers) and not Map.memberOf(c#caller, reach))
                Some(Flixlint.Violation.atCall(facts, r#id, c, r#reason) |> Flixlint.Violation.withPath(chain(facts, reach, c#callee)))
            else None)

    /// A caller that calls one of `functions` and one of `withFunctions`; reported at the `withFunctions` call.
    def callsTogetherRule(facts: Facts, r: DisallowedCallsTogether): List[Violation] =
        callers(facts) |> List.filterMap(caller ->
            let cs = Flixlint.Facts.callsFrom(facts, caller);
            forM (
                first <- List.find(c -> Set.memberOf(c#callee, r#functions), cs);
                second <- List.find(c -> Set.memberOf(c#callee, r#withFunctions), cs)
            ) yield togetherViolation(facts, r, first, second))

    def togetherViolation(facts: Facts, r: DisallowedCallsTogether, first: Call, second: Call): Violation =
        let v = Flixlint.Violation.atCall(facts, r#id, second, r#reason);
        { message = "calls ${Flixlint.Facts.fnName(facts, first#callee)} and ${Flixlint.Facts.fnName(facts, second#callee)}" | v }

    /// EffectOf(fn) meets `effects` and meets `withEffects` (aliases expanded on both sides).
    def effectsTogetherRule(facts: Facts, r: DisallowedEffectsTogether): List[Violation] =
        let effects = Flixlint.Facts.expandEffects(facts, r#effects);
        let withEffects = Flixlint.Facts.expandEffects(facts, r#withEffects);
        Flixlint.Facts.defs(facts) |> List.filterMap(d ->
            let effs = Flixlint.Facts.effectOf(facts, d#fn);
            let a = Set.intersection(effs, effects);
            let b = Set.intersection(effs, withEffects);
            if (Set.isEmpty(a) or Set.isEmpty(b)) None
            else Some(Flixlint.Violation.atDef(facts, r#id, d,
                "has ${effNames(facts, a)} and ${effNames(facts, b)} in its signature", r#reason)))

    /// `effect` is in EffectOf(fn) and EffectOf(fn) is not exactly {effect}.
    def otherEffectsWithRule(facts: Facts, r: DisallowedOtherEffectsWith): List[Violation] =
        Flixlint.Facts.defs(facts) |> List.filterMap(d ->
            let effs = Flixlint.Facts.effectOf(facts, d#fn);
            let others = Set.remove(r#effect, effs);
            if (Set.memberOf(r#effect, effs) and not Set.isEmpty(others))
                Some(Flixlint.Violation.atDef(facts, r#id, d,
                    "has ${Flixlint.Facts.effName(facts, r#effect)} with ${effNames(facts, others)}", r#reason))
            else None)

    /// Def(fn).file matches `files` and EffectOf(fn) meets `effects` (or is not empty, when `effects` is empty).
    def effectsInRule(facts: Facts, r: DisallowedEffectsIn): List[Violation] =
        let effects = Flixlint.Facts.expandEffects(facts, r#effects);
        Flixlint.Facts.defs(facts) |> List.filter(d -> Flixlint.Glob.matches(r#files, d#file)) |> List.filterMap(d ->
            let effs = Flixlint.Facts.effectOf(facts, d#fn);
            let hit = if (Set.isEmpty(effects)) effs else Set.intersection(effs, effects);
            if (Set.isEmpty(hit)) None
            else Some(Flixlint.Violation.atDef(facts, r#id, d, "has ${effNames(facts, hit)}", r#reason)))

    /// Handles(fn, effect), or a call to a pub function of the `transitively` modules that reaches such a handler.
    def handlerRule(facts: Facts, r: DisallowedHandler): List[Violation] =
        let rows = Flixlint.Facts.handles(facts) |> List.filter(h -> h#effect == r#effect);
        let effName = Flixlint.Facts.effName(facts, r#effect);
        let direct = rows |> List.map(h -> Flixlint.Violation.inBody(facts, r#id, h#fn, h#line,
            "installs a handler for ${effName}", r#reason));
        let seeds = rows |> List.map(h -> h#fn) |> List.toSet;
        direct ::: viaEntries(facts, r#id, r#reason, seeds, r#transitively, "handler ${effName}")

    /// Constructs(fn, constructor), or a call to a pub function of the `transitively` modules that reaches one.
    def constructorRule(facts: Facts, r: DisallowedConstructor): List[Violation] =
        let rows = Flixlint.Facts.constructs(facts) |> List.filter(c -> c#constructor == r#constructor);
        let caseName = Flixlint.Facts.caseName(facts, r#constructor);
        let direct = rows |> List.map(c -> Flixlint.Violation.inBody(facts, r#id, c#fn, c#line,
            "builds ${caseName}", r#reason));
        let seeds = rows |> List.map(c -> c#fn) |> List.toSet;
        direct ::: viaEntries(facts, r#id, r#reason, seeds, r#transitively, caseName)

    /// CallsInLambdaArgOf(caller, function, outer) with outer in `inLambdaOf` and Def(caller).file matching `files`.
    def callInLambdaRule(facts: Facts, r: DisallowedCallInLambda): List[Violation] =
        Flixlint.Facts.callsInLambda(facts)
            |> List.filter(c -> c#callee == r#function and Set.memberOf(c#outer, r#inLambdaOf))
            |> List.filter(c -> Flixlint.Facts.defOf(facts, c#caller) |> Option.exists(d -> Flixlint.Glob.matches(r#files, d#file)))
            |> List.map(c -> Flixlint.Violation.inBody(facts, r#id, c#caller, c#line,
                "calls ${Flixlint.Facts.fnName(facts, c#callee)} inside a lambda passed to ${Flixlint.Facts.fnName(facts, c#outer)}", r#reason))

    /// ArgLit(caller, function, argIndex, text) with text in `values` or among the string literals of `valuesFrom`.
    def callWithArgRule(facts: Facts, r: DisallowedCallWithArg): List[Violation] =
        let values = List.foldLeft((acc, fn) -> Set.union(acc, List.toSet(Flixlint.Facts.strLitsIn(facts, fn))), r#values, r#valuesFrom);
        Flixlint.Facts.argLits(facts)
            |> List.filter(a -> a#callee == r#function and a#index == r#argIndex and Set.memberOf(a#text, values))
            |> List.map(a -> Flixlint.Violation.inBody(facts, r#id, a#caller, a#line,
                "calls ${Flixlint.Facts.fnName(facts, a#callee)} with \"${a#text}\"", r#reason))

    /// CaseTypeDeep(ofEnum, case, argType), nested type constructors and what type aliases stand for included (a field
    /// typed `Keys` with `type alias Keys = List[ColumnName]` takes `ColumnName`); reported at the enum's declaration,
    /// so only `allowInFile` can allow it.
    def caseArgTypeRule(facts: Facts, r: DisallowedCaseArgType): List[Violation] =
        let declared = Flixlint.Facts.enums(facts) |> List.find(e -> e#ofEnum == r#ofEnum);
        Flixlint.Facts.caseTypesDeep(facts)
            |> List.filter(ct -> ct#ofEnum == r#ofEnum and ct#tycon == r#argType)
            |> List.map(ct ->
                let (file, line) = declared |> Option.map(e -> (e#file, e#line)) |> Option.getWithDefault(("?", 0));
                let subject = Flixlint.Facts.caseName(facts, ct#constructor);
                Flixlint.Violation.atDeclaration(r#id, file, line, subject, "takes ${Flixlint.Facts.typeName(facts, ct#tycon)}", r#reason))

    /// Def(caller).file matches `files`, and the callee, a built case, a type in a parameter or in the return type
    /// (nested ones included) belongs to `module` (or a submodule); or an enum declared in `files` has such a type in a case.
    def dependencyRule(facts: Facts, r: DisallowedDependency): List[Violation] =
        let inModule = name -> Flixlint.Facts.isIn(facts, r#module, name);
        let inFiles = Flixlint.Facts.defs(facts) |> List.filter(d -> Flixlint.Glob.matches(r#files, d#file));
        let inFilesSet = inFiles |> List.map(d -> d#fn) |> List.toSet;
        let byCall = inFiles |> List.flatMap(d -> Flixlint.Facts.callsFrom(facts, d#fn)
            |> List.filter(c -> inModule(Flixlint.Facts.fnName(facts, c#callee)))
            |> List.map(c -> Flixlint.Violation.atCall(facts, r#id, c, r#reason)));
        let byConstruct = Flixlint.Facts.constructs(facts)
            |> List.filter(c -> Set.memberOf(c#fn, inFilesSet) and inModule(Flixlint.Facts.caseName(facts, c#constructor)))
            |> List.map(c -> Flixlint.Violation.inBody(facts, r#id, c#fn, c#line,
                "builds ${Flixlint.Facts.caseName(facts, c#constructor)}", r#reason));
        let byArgType = inFiles |> List.filterMap(d ->
            Flixlint.Facts.argTypesAllOf(facts, d#fn)
                |> List.find(a -> inModule(Flixlint.Facts.typeName(facts, a#tycon)))
                |> Option.map(a -> Flixlint.Violation.atDef(facts, r#id, d,
                    "takes ${Flixlint.Facts.typeName(facts, a#tycon)}", r#reason)));
        let byRetType = inFiles |> List.filterMap(d ->
            Flixlint.Facts.retTypesAllOf(facts, d#fn)
                |> Set.find(t -> inModule(Flixlint.Facts.typeName(facts, t)))
                |> Option.map(t -> Flixlint.Violation.atDef(facts, r#id, d,
                    "returns ${Flixlint.Facts.typeName(facts, t)}", r#reason)));
        let byEnum = Flixlint.Facts.enums(facts)
            |> List.filter(e -> Flixlint.Glob.matches(r#files, e#file))
            |> List.flatMap(e -> Flixlint.Facts.caseTypesAll(facts)
                |> List.filter(ct -> ct#ofEnum == e#ofEnum and inModule(Flixlint.Facts.typeName(facts, ct#tycon)))
                |> List.map(ct -> Flixlint.Violation.atDeclaration(r#id, e#file, e#line, Flixlint.Facts.caseName(facts, ct#constructor),
                    "takes ${Flixlint.Facts.typeName(facts, ct#tycon)}", r#reason)));
        byCall ::: byConstruct ::: byArgType ::: byRetType ::: byEnum

    // ---- transitivelyIn: the fixpoint over the calls ----

    ///
    /// For every function of the `modules` that reaches one of the `seeds` through calls, the next hop toward the seed.
    /// Repeats until no function is added (the fixpoint); empty when there are no modules.
    ///
    def reachable(facts: Facts, seeds: Set[Fn], modules: List[Mod]): Map[Fn, Fn] =
        if (List.isEmpty(modules)) Map.empty()
        else reachLoop(facts, seeds, List.toSet(modules), Map.empty())

    def reachLoop(facts: Facts, seeds: Set[Fn], modules: Set[Mod], known: Map[Fn, Fn]): Map[Fn, Fn] =
        let reached = fn -> Set.memberOf(fn, seeds) or Map.memberOf(fn, known);
        let added = Flixlint.Facts.defs(facts)
            |> List.filter(d -> Set.memberOf(d#module, modules) and not reached(d#fn))
            |> List.filterMap(d -> Flixlint.Facts.callsFrom(facts, d#fn) |> List.find(c -> reached(c#callee)) |> Option.map(c -> (d#fn, c#callee)));
        if (List.isEmpty(added)) known
        else reachLoop(facts, seeds, modules, List.foldLeft((m, p) -> Map.insert(fst(p), snd(p), m), known, added))

    /// The pub functions of the `modules` that are seeds or reach one: calling them is calling the disallowed thing.
    def entries(facts: Facts, reach: Map[Fn, Fn], seeds: Set[Fn], modules: List[Mod]): Set[Fn] =
        let mods = List.toSet(modules);
        Set.union(Map.keysOf(reach), seeds)
            |> Set.filter(fn -> Flixlint.Facts.defOf(facts, fn) |> Option.exists(d -> d#isPub and Set.memberOf(d#module, mods)))

    /// Violations for calls to the entries from outside the way to the seeds, with the path to the seed.
    def viaEntries(facts: Facts, id: String, reason: String, seeds: Set[Fn], modules: List[Mod], target: String): List[Violation] =
        let reach = reachable(facts, seeds, modules);
        let ents = entries(facts, reach, seeds, modules);
        Flixlint.Facts.calls(facts) |> List.filterMap(c ->
            if (Set.memberOf(c#callee, ents) and not Map.memberOf(c#caller, reach) and not Set.memberOf(c#caller, seeds))
                Some(Flixlint.Violation.atCall(facts, id, c, reason) |> Flixlint.Violation.withPath(chain(facts, reach, c#callee) ::: (target :: Nil)))
            else None)

    /// `fn -> next -> ... -> seed`, following the next hops.
    def chain(facts: Facts, reach: Map[Fn, Fn], fn: Fn): List[String] =
        Flixlint.Facts.fnName(facts, fn) :: (match Map.get(fn, reach) {
            case Some(next) => chain(facts, reach, next)
            case None => Nil
        })

    // ---- allows ----

    ///
    /// Drops the violations an allow of the entry covers. An allow that covers nothing is an error (the code it was
    /// written for is gone); an `allowUntil` past its date covers nothing but is noted on the violation it would have
    /// covered; an `allowInFile` of a file that is not among the sources is an error.
    ///
    def allowed(facts: Facts, today: String, id: String, allows: List[Allow], violations: List[Violation]): (List[Violation], List[String]) =
        let errors = allows |> List.filterMap(a -> match a {
            case Allow.InFile(path, _) if not Set.memberOf(path, Flixlint.Facts.files(facts)) =>
                Some("flixlint: rule ${id}: ${describe(facts, a)}: no such file among the sources")
            case _ if not List.exists(v -> covers(a, v), violations) =>
                Some("flixlint: rule ${id}: ${describe(facts, a)} matches nothing (remove it)")
            case _ => None
        });
        let kept = violations
            |> List.filter(v -> not List.exists(a -> covers(a, v) and not expired(today, a), allows))
            |> List.map(v -> List.foldLeft((acc, a) -> match a {
                case Allow.Until(_, date, reason) if covers(a, v) and expired(today, a) =>
                    Flixlint.Violation.withNote("allowUntil ${date} has expired (${reason})", acc)
                case _ => acc
            }, v, allows));
        (kept, errors)

    def covers(a: Allow, v: Violation): Bool = match a {
        case Allow.InFn(fn, _) => v#inFn == Some(fn)
        case Allow.InFile(path, _) => v#file == path
        case Allow.Until(fn, _, _) => v#inFn == Some(fn)
    }

    /// Dates are `YYYY-MM-DD`, so the string order is the date order.
    def expired(today: String, a: Allow): Bool = match a {
        case Allow.Until(_, date, _) => today > date
        case _ => false
    }

    def describe(facts: Facts, a: Allow): String = match a {
        case Allow.InFn(fn, _) => "allowIn(Fn.${Flixlint.Facts.fnCase(facts, fn)})"
        case Allow.InFile(path, _) => "allowInFile(\"${path}\")"
        case Allow.Until(fn, date, _) => "allowUntil(Fn.${Flixlint.Facts.fnCase(facts, fn)}, \"${date}\")"
    }

    // ---- helpers ----

    def callers(facts: Facts): List[Fn] = Flixlint.Facts.defs(facts) |> List.map(d -> d#fn)

    def effNames(facts: Facts, effs: Set[Eff]): String =
        effs |> Set.toList |> List.map(e -> Flixlint.Facts.effName(facts, e)) |> List.sort |> String.intercalate(", ")
}
