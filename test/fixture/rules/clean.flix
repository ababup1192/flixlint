/// A rule set the fixture satisfies: the handler for Db is installed by the runner only.
mod CleanRules {
    use Flixlint.{RuleSet, disallowHandler, allowIn}
    use Flixlint.Names.{Fn, Eff}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.handlers(List#{
            disallowHandler({ id = "db-handler", effect = Eff.Db, reason = "the Db handler is installed by the runner only" })
                |> allowIn(Fn.Runner_transact, "the runner")
        })
    })
}
