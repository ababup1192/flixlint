/// Rules for the fixture project: every family and three custom rules, each with at least one violation.
mod FixtureRules {
    use Flixlint.{RuleSet, disallowFunction, disallowCallsTogether, disallowEffectsTogether, disallowOtherEffectsWith,
                  disallowEffectsIn, disallowHandler, disallowConstructor, disallowCallInLambdaOf, disallowCallWithArg,
                  disallowCaseArgType, disallowDependency, customRule,
                  transitivelyIn, valuesFromLiteralsIn, allowIn, allowInFile, allowUntil}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Eff, Mod, Case, Enum, Type}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.functions(List#{
            disallowFunction({ id = "clock", path = Fn.Java_lang_System_currentTimeMillis,
                reason = "the real clock is read where Main builds the clock; everything else takes the time as an argument" })
                |> transitivelyIn(Mod.Wall)
                |> allowIn(Fn.Wall_nowMillis, "the one place that reads the clock"),
            disallowFunction({ id = "clock", path = Fn.Clock_now, reason = "Clock.now is handled by the runner; use cases take the time as an argument" })
                |> allowIn(Fn.Runner_nowMillis, "the runner reads it once per request")
        }),
        Flixlint.callsTogether(List#{
            disallowCallsTogether({ id = "capability-target", functions = Set#{Fn.Mapping_orderId}, withFunctions = Set#{Fn.Auth_permit},
                reason = "an order id and the permit for it are obtained together (Mapping.orderId with Auth.permitOn)" }),
            disallowCallsTogether({ id = "capability-leak", functions = Set#{Fn.Auth_permitOn}, withFunctions = Set#{Fn.Auth_permit},
                reason = "an id received with permitOn is not re-checked with a target-less permit()" })
        }),
        Flixlint.effectsTogether(List#{
            disallowEffectsTogether({ id = "io-in-tx", effects = Set#{Eff.Db}, withEffects = Set#{Eff.Http},
                reason = "DB and outbound I/O in one signature: split into read Tx -> I/O -> write Tx" })
                |> allowIn(Fn.Orders_createAndFetch, "the fetch is a health probe of a few ms")
                |> allowUntil(Fn.Orders_confirm, "2026-01-01", "split into two transactions (#123)")
        }),
        Flixlint.otherEffectsWith(List#{
            disallowOtherEffectsWith({ id = "clock-alone", effect = Eff.Clock, reason = "a function that reads the clock does nothing else, so tests can fix the time" })
        }),
        Flixlint.effectsIn(List#{
            disallowEffectsIn({ id = "pure-rules", files = "src/domain/rules/**", effects = Set#{},
                reason = "rules are pure and table-tested; the time comes in as nowMillis" })
        }),
        Flixlint.handlers(List#{
            disallowHandler({ id = "handler-site", effect = Eff.Auth, reason = "the Auth handler is installed by the runner only; use cases receive Permit" })
                |> transitivelyIn(Mod.Auth)
                |> allowIn(Fn.Runner_transact, "the runner")
                |> allowInFile("src/domain/Auth.flix", "the effect's own module")
        }),
        Flixlint.constructors(List#{
            disallowConstructor({ id = "handler-site", constructor = Case.Auth_Permit_Permit, reason = "Permit is built inside Auth only" })
                |> allowInFile("src/domain/Auth.flix", "the effect's own module"),
            disallowConstructor({ id = "wrapped-key", constructor = Case.Column_Column, reason = "a Column comes from Column.ofDef, never built by hand" })
        }),
        Flixlint.callsInLambda(List#{
            // The glob is written with a nested group: it stands for src/api and src/app, and nothing else.
            disallowCallInLambdaOf({ id = "find-many", function = Fn.Orders_find, inLambdaOf = Set#{Fn.List_map, Fn.List_filterMap},
                files = "src/{api,{app}}/**",
                reason = "one read per id over a list of ids is N+1; a list of ids is read with findMany" })
        }),
        Flixlint.callsWithArg(List#{
            disallowCallWithArg({ id = "log-text", function = Fn.Log_str, argIndex = 0, values = Set#{"secret"},
                reason = "a key that carries a sentence or a secret is written with Log.text only" })
                |> valuesFromLiteralsIn(Fn.Log_freeTextKeys)
        }),
        Flixlint.caseArgTypes(List#{
            disallowCaseArgType({ id = "wrapped-key", ofEnum = Enum.Predicate, argType = Type.ColumnName, reason = "predicates name columns through Column, never a raw ColumnName" })
        }),
        Flixlint.dependencies(List#{
            disallowDependency({ id = "domain-isolation", files = "src/domain/**", module = Mod.Generated, reason = "the domain does not know the generated API; mappings live in Mapping" })
                |> allowIn(Fn.Orders_listMine, "the query is the domain's own")
        }),
        Flixlint.custom("guarded-write", guardedWrite),
        Flixlint.customs(List#{
            customRule({ id = "capability-site", check = capabilitySite })
                |> allowIn(Fn.Orders_permitsInLambda, "an allow on a custom rule"),
            customRule({ id = "silent-parse", check = silentParse })
        })
    })

    /// Calling an Inventory function that takes a Permit proof from src/api without Inventory.guarded in the same function.
    def guardedWrite(facts: Facts): List[Violation] =
        let mutating = Flixlint.Facts.defs(facts)
            |> List.filter(d -> d#module == Mod.Inventory and Flixlint.Facts.argType(facts, d#fn, 0) == Some(Type.Auth_Permit))
            |> List.map(d -> d#fn)
            |> List.toSet;
        Flixlint.Facts.calls(facts)
            |> List.filter(c -> Set.memberOf(c#callee, mutating))
            |> List.filter(c -> Flixlint.Facts.defOf(facts, c#caller) |> Option.exists(d -> Flixlint.Glob.matches("src/api/**", d#file)))
            |> List.filter(c -> not Flixlint.Facts.callsTo(facts, c#caller, Fn.Inventory_guarded))
            |> List.map(c -> Flixlint.Violation.atCall(facts, "guarded-write", c, "bulk writes from the API go through Inventory.guarded"))

    /// Calling an Auth function that asks Auth (has the effect) and returns a proof, from src/domain outside Auth itself.
    def capabilitySite(facts: Facts): List[Violation] =
        let judging = Flixlint.Facts.defs(facts)
            |> List.filter(d -> d#module == Mod.Auth and d#isPub
                and Set.memberOf(Eff.Auth, Flixlint.Facts.effectOf(facts, d#fn))
                and Flixlint.Facts.retType(facts, d#fn) == Some(Type.Auth_Permit))
            |> List.map(d -> d#fn)
            |> List.toSet;
        Flixlint.Facts.calls(facts)
            |> List.filter(c -> Set.memberOf(c#callee, judging))
            |> List.filter(c -> Flixlint.Facts.defOf(facts, c#caller)
                |> Option.exists(d -> Flixlint.Glob.matches("src/domain/**", d#file) and d#file != "src/domain/Auth.flix"))
            |> List.map(c -> Flixlint.Violation.atCall(facts, "capability-site", c, "use cases receive Permit as an argument; only the boundary asks Auth"))

    /// A value Ids.parse rejects that is dropped (List.filterMap) or replaced by a default (Option.getWithDefault, directly
    /// or through a pipe); a default that is Result.Err is a rejection and not reported.
    def silentParse(facts: Facts): List[Violation] =
        let reason = "a value that does not parse is rejected, not dropped or replaced by a default";
        let dropped = Flixlint.Facts.callsInLambda(facts)
            |> List.filter(c -> c#outer == Fn.List_filterMap and c#callee == Fn.Ids_parse)
            |> List.map(c -> Flixlint.Violation.inBody(facts, "silent-parse", c#caller, c#line, "drops the values Ids.parse rejects", reason));
        let viaPipe = Flixlint.Facts.pipedInto(facts)
            |> List.filter(p -> p#target == Fn.Option_getWithDefault and p#source == Fn.Ids_parse)
            |> List.map(p -> (p#caller, p#line));
        let viaArg = Flixlint.Facts.argCalls(facts)
            |> List.filter(a -> a#callee == Fn.Option_getWithDefault and a#index == 1 and a#argCallee == Fn.Ids_parse)
            |> List.map(a -> (a#caller, a#line));
        let rejecting = Flixlint.Facts.constructs(facts) |> List.filter(c -> c#constructor == Case.Result_Err) |> List.map(c -> (c#fn, c#line));
        let defaulted = List.distinct(viaPipe ::: viaArg)
            |> List.filter(at -> not List.memberOf(at, rejecting))
            |> List.map(match (caller, line) -> Flixlint.Violation.inBody(facts, "silent-parse", caller, line, "defaults the values Ids.parse rejects", reason));
        dropped ::: defaulted
}
