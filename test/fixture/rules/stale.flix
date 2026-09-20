/// Allows that cover nothing: an allowIn of a function without a violation, an allowInFile of a file that is not
/// there, an allowInFile of a file that has only a type alias, and an allowIn on a custom rule whose check finds
/// nothing there.
mod StaleRules {
    use Flixlint.{RuleSet, disallowEffectsTogether, customRule, allowIn, allowInFile}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Eff}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.effectsTogether(List#{
            disallowEffectsTogether({ id = "io-in-tx", effects = Set#{Eff.Db}, withEffects = Set#{Eff.Http},
                reason = "DB and outbound I/O in one signature: split into read Tx -> I/O -> write Tx" })
                |> allowIn(Fn.Orders_createAndFetch, "the fetch is a health probe of a few ms")
                |> allowIn(Fn.Orders_create, "a stale allow: create has no Http")
                |> allowInFile("src/domain/Removed.flix", "a file that is gone")
                |> allowInFile("src/domain/Money.flix", "a file with only a type alias: it is among the sources, so this allow just covers nothing")
        }),
        Flixlint.customs(List#{
            customRule({ id = "nothing", check = nothing })
                |> allowIn(Fn.Orders_create, "a stale allow: the check finds nothing")
        })
    })

    def nothing(_facts: Facts): List[Violation] = Nil
}
