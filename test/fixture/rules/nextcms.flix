/// The shapes in which nextcms's rule file writes the families, on the fixture's sources: entries that share an id built
/// with a helper, a list joined with `:::`, an effect that shows only as one a signature removes (`ef - Db`), a handler
/// reached through a module, the case of an enum inside a module, a lambda set of several functions over a glob, a value
/// set that is empty but for the literals of a function, and a custom rule over the argument and string literals.
mod NextcmsShapes {
    use Flixlint.{RuleSet, disallowFunction, disallowCallsTogether, disallowEffectsTogether, disallowHandler,
                  disallowConstructor, disallowCallInLambdaOf, disallowCallWithArg, disallowCaseArgType, disallowDependency,
                  transitivelyIn, valuesFromLiteralsIn, allowIn, allowInFile}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Eff, Mod, Case, Enum, Type}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.functions(generated() ::: clock()),
        Flixlint.callsTogether(grantTarget()),
        Flixlint.effectsTogether(authInTx()),
        Flixlint.handlers(handlerSite()),
        Flixlint.constructors(roles() ::: proofs()),
        Flixlint.callsInLambda(findMany()),
        Flixlint.callsWithArg(logText()),
        Flixlint.caseArgTypes(List#{
            disallowCaseArgType({ id = "visible", ofEnum = Enum.Predicate, argType = Type.ColumnName, reason = "a predicate names a column through Column, never a raw ColumnName (nor a List of them)" })
        }),
        Flixlint.dependencies(domainIsolation()),
        Flixlint.custom("log-text", logTextUnused)
    })

    def generated(): List[Flixlint.DisallowedFunction] =
        let reason = "the generated API is called from the mapping only";
        let entry = path -> disallowFunction({ id = "generated", path = path, reason = reason });
        List#{
            entry(Fn.Generated_findOrders),
            entry(Fn.Generated_limitOf),
            entry(Fn.Scope_currentId) |> allowInFile("src/domain/Orders.flix", "the scope of the query is the domain's own")
        }

    def clock(): List[Flixlint.DisallowedFunction] = List#{
        disallowFunction({ id = "clock", path = Fn.Clock_now, reason = "the clock is read by the runner only" })
            |> transitivelyIn(Mod.Runner)
            |> allowInFile("src/app/Runner.flix", "the runner reads it once per request")
    }

    def grantTarget(): List[Flixlint.DisallowedCallsTogether] = List#{
        disallowCallsTogether({ id = "grant-target", functions = Set#{Fn.Mapping_orderId}, withFunctions = Set#{Fn.Auth_permit},
            reason = "an order id and its proof are taken together (permitOn)" })
            |> allowIn(Fn.Endpoints_pairedPermit, "an allow on a pair"),
        disallowCallsTogether({ id = "grant-leak", functions = Set#{Fn.Auth_permitOn}, withFunctions = Set#{Fn.Auth_permit},
            reason = "an id proved with permitOn is not checked again with a target-less permit" })
    }

    def authInTx(): List[Flixlint.DisallowedEffectsTogether] = List#{
        disallowEffectsTogether({ id = "auth-in-tx", effects = Set#{Eff.Db}, withEffects = Set#{Eff.Auth, Eff.Http},
            reason = "the proof is asked for before the Tx" })
    }

    def handlerSite(): List[Flixlint.DisallowedHandler] = List#{
        disallowHandler({ id = "handler-site", effect = Eff.Db, reason = "the Db handler is installed by the runner only" })
            |> transitivelyIn(Mod.Runner)
    }

    def roles(): List[Flixlint.DisallowedConstructor] = List#{
        disallowConstructor({ id = "role", constructor = Case.Generated_Role_Owner, reason = "a role comes from the generated API's answer" })
    }

    def proofs(): List[Flixlint.DisallowedConstructor] = List#{
        disallowConstructor({ id = "handler-site", constructor = Case.Auth_Permit_Permit, reason = "Permit is built inside Auth only" })
            |> allowInFile("src/domain/Auth.flix", "the grant functions seal the proof")
    }

    def findMany(): List[Flixlint.DisallowedCallInLambda] =
        let lists = Set#{Fn.List_map, Fn.List_filterMap, Fn.List_filter};
        let entry = fn -> disallowCallInLambdaOf({ id = "find-many", function = fn, inLambdaOf = lists, files = "src/api/**",
            reason = "one read per id over a list of ids is N+1" });
        List#{ entry(Fn.Orders_find) }

    def logText(): List[Flixlint.DisallowedCallWithArg] =
        let entry = fn -> disallowCallWithArg({ id = "log-text", function = fn, argIndex = 0, values = Set#{},
            reason = "a key that carries a sentence is written with Log.text only" })
            |> valuesFromLiteralsIn(Fn.Log_freeTextKeys);
        List#{ entry(Fn.Log_str) }

    def domainIsolation(): List[Flixlint.DisallowedDependency] =
        let reason = "the domain does not know the generated API";
        List#{
            disallowDependency({ id = "domain-isolation", files = "src/domain/**", module = Mod.Generated, reason = reason }),
            disallowDependency({ id = "domain-isolation", files = "src/domain/**", module = Mod.Scope, reason = reason })
        }

    /// A key of Log.freeTextKeys that no call of Log.text writes.
    def logTextUnused(facts: Facts): List[Violation] =
        let written = Flixlint.Facts.argLits(facts)
            |> List.filter(a -> a#callee == Fn.Log_text and a#index == 0)
            |> List.map(a -> a#text)
            |> List.toSet;
        match Flixlint.Facts.defOf(facts, Fn.Log_freeTextKeys) {
            case None => Nil
            case Some(d) => Flixlint.Facts.strLitsIn(facts, Fn.Log_freeTextKeys)
                |> List.filter(key -> not Set.memberOf(key, written))
                |> List.map(key -> Flixlint.Violation.atDef(facts, "log-text", d, "lists \"${key}\", which no Log.text call writes",
                    "a key that is not written anywhere is stale; remove it from the list"))
        }
}
