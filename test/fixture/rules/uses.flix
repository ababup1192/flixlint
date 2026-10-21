/// A `use` or `import` the module never uses (Flixlint.Flix.uses and namesUsed): src/Tidy.flix brings in Auth.Permit and
/// never names it; its `use List.length` is used, and so are the fixture's other uses.
mod UseRules {
    use Flixlint.{RuleSet, customRule}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{ customRule({ id = "unused-use", check = unusedUse }) })
    })

    def unusedUse(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let used = Flixlint.Flix.namesUsed(ast);
        Flixlint.Flix.uses(ast) |> List.filter(Flixlint.Flix.isUnused(used))
            |> List.map(u -> Flixlint.Flix.violation(ast, "unused-use", u#node, u#line, "brings in ${u#name}, which the module never uses",
                "remove the use, or use the name"))
}
