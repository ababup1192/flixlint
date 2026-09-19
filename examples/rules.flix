/// The rules for the example project in examples/src. Four rules: three families and one custom rule.
mod ExampleRules {
    use Flixlint.{RuleSet, disallowFunction, disallowEffectsTogether, disallowHandler, customRule,
                  transitivelyIn, allowIn, allowInFile, allowUntil}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Eff, Mod}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.functions(List#{
            disallowFunction({ id = "clock", path = Fn.Java_lang_System_currentTimeMillis,
                reason = "the time comes in as an argument; only Clock reads the wall clock" })
                |> transitivelyIn(Mod.Clock)
                |> allowIn(Fn.Clock_real, "the one place that reads the real clock")
        }),
        Flixlint.effectsTogether(List#{
            disallowEffectsTogether({ id = "io-in-tx", effects = Set#{Eff.Db}, withEffects = Set#{Eff.Http},
                reason = "waiting on the network inside a Tx keeps the connection borrowed: read Tx -> I/O -> write Tx" })
                |> allowUntil(Fn.Orders_syncInventory, "2026-12-31", "split into two transactions (#123)")
        }),
        Flixlint.handlers(List#{
            disallowHandler({ id = "db-handler", effect = Eff.Db,
                reason = "the Db handler is installed by the runner only" })
                |> allowInFile("src/Runner.flix", "the runner")
        }),
        Flixlint.customs(List#{
            customRule({ id = "find-reads-only", check = findReadsOnly })
        })
    })

    /// What the families cannot say: a function named find* reads, so its signature must not have Http.
    def findReadsOnly(facts: Facts): List[Violation] =
        Flixlint.Facts.defs(facts)
            |> List.filter(d -> String.startsWith(prefix = "find", d#name))
            |> List.filter(d -> Set.memberOf(Eff.Http, Flixlint.Facts.effectOf(facts, d#fn)))
            |> List.map(d -> Flixlint.Violation.atDef(facts, "find-reads-only", d, "has Http in its signature",
                "a find* function reads; reaching out over the network belongs in its own step"))
}
