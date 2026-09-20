/// A rule that names a function the sources do not have: it must not compile.
mod BrokenRules {
    use Flixlint.{RuleSet, disallowFunction}
    use Flixlint.Names.Fn

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.functions(List#{
            disallowFunction({ id = "gone", path = Fn.Orders_removedLongAgo, reason = "removed" })
        })
    })
}
