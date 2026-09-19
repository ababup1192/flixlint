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
    use Sys.Env.Env
    use Sys.Exit.Exit

    /// The entry point of the generated engine `main`: the facts directory and today's date come from the environment.
    pub def lint(rules: RuleSet): Unit \ IO =
        Sys.Exit.runWithIO(() -> Sys.Env.runWithIO(() -> Fs.FileRead.runWithIO(() -> lint0(rules))))

    def lint0(rules: RuleSet): Unit \ IO + Env + FileRead + Exit =
        let factsDir = Sys.Env.getVar("FLIXLINT_FACTS") |> Option.getWithDefault("build/flixlint/facts");
        let today = Sys.Env.getVar("FLIXLINT_TODAY") |> Option.getWithDefault("0000-00-00");
        let facts = Flixlint.Facts.load(factsDir);
        let (violations, errors) = judgeAll(facts, today, rules);
        violations |> List.sortBy(Flixlint.Violation.key) |> List.forEach(v -> println(Flixlint.Violation.render(facts, v)));
        List.forEach(println, errors);
        if (not List.isEmpty(errors)) Sys.Exit.exit(2)
        else if (not List.isEmpty(violations)) Sys.Exit.exit(1)
        else ()

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

    /// CaseTypeAll(ofEnum, case, argType), nested type constructors included; reported at the enum's declaration,
    /// so only `allowInFile` can allow it.
    def caseArgTypeRule(facts: Facts, r: DisallowedCaseArgType): List[Violation] =
        let declared = Flixlint.Facts.enums(facts) |> List.find(e -> e#ofEnum == r#ofEnum);
        Flixlint.Facts.caseTypesAll(facts)
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
