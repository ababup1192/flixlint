/// A custom rule on the Deep type relations (ArgTypeDeep, RetTypeDeep), which the engine parses only when a rule reads them.
mod DeepRules {
    use Flixlint.{RuleSet, customRule}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Names.Type

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "int64-under-alias", check = int64UnderAlias })
        })
    })

    /// A function that takes or returns an Int64 seen only once its aliases are opened.
    def int64UnderAlias(facts: Facts): List[Violation] =
        let reason = "a number behind an alias is read through the alias's own functions";
        Flixlint.Facts.defs(facts) |> List.flatMap(d ->
            let takes = Flixlint.Facts.argTypesDeepOf(facts, d#fn) |> List.exists(a -> a#tycon == Type.Int64);
            let takesAll = Flixlint.Facts.argTypesAllOf(facts, d#fn) |> List.exists(a -> a#tycon == Type.Int64);
            let returns = Set.memberOf(Type.Int64, Flixlint.Facts.retTypesDeepOf(facts, d#fn));
            let returnsAll = Set.memberOf(Type.Int64, Flixlint.Facts.retTypesAllOf(facts, d#fn));
            List#{(takes and not takesAll, "takes Int64 through an alias"), (returns and not returnsAll, "returns Int64 through an alias")}
                |> List.filter(fst)
                |> List.map(p -> Flixlint.Violation.atDef(facts, "int64-under-alias", d, snd(p), reason)))
}
