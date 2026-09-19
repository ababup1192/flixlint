/// Allows that cover nothing: an allowIn of a function without a violation, an allowInFile of a file that is not
/// there, and an allowIn on a custom rule whose check finds nothing there.
mod StaleRules {
    use Flixlint.{RuleSet, disallowEffectsTogether, customRule, allowIn, allowInFile}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Eff}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.effectsTogether(List#{
            disallowEffectsTogether({ id = "io-in-tx", effects = Set#{Eff.Db}, withEffects = Set#{Eff.Http},
                reason = "DB and outbound I/O in one signature: split into read Tx -> I/O -> write Tx" })
                |> allowIn(Fn.Entries_createAndFetch, "the fetch is a health probe of a few ms")
                |> allowIn(Fn.Entries_create, "a stale allow: create has no Http")
                |> allowInFile("src/cms/Removed.flix", "a file that is gone")
        }),
        Flixlint.customs(List#{
            customRule({ id = "nothing", check = nothing })
                |> allowIn(Fn.Entries_create, "a stale allow: the check finds nothing")
        })
    })

    def nothing(_facts: Facts): List[Violation] = Nil
}
