/// Rules on the generic AST that name what a stage lacks: `Kind.Binder` is the typed stage's only (the resolved stage
/// binds a `let` with a `sym` of its own), `Kind.Expr_Spawn` is in no node of the fixture, and `Unnamed(` names a function
/// by a string. None of them is a violation: the run ends with exit 0 and the engine says each on stderr
/// (test/expected-notices-<stage>.txt).
mod NoticeRules {
    use Flixlint.{RuleSet, customRule}
    use Flixlint.AstKinds.Kind
    use Flixlint.Violation.Violation

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "binders", check = facts -> nothing(Flixlint.Ast.ofKind(Flixlint.Facts.ast(facts), Kind.Binder)) }),
            customRule({ id = "spawns", check = facts -> nothing(Flixlint.Ast.ofKind(Flixlint.Facts.ast(facts), Kind.Expr_Spawn)) }),
            customRule({ id = "by-string", check = facts ->
                nothing(Flixlint.Flix.callsTo(Flixlint.Facts.ast(facts), Flixlint.Names.Fn.Unnamed("Orders.find"))) })
        })
    })

    /// No violation, whatever was found: the rules are here for the lines the engine says about the names they write.
    def nothing(_found: List[Flixlint.Ast.Node]): List[Violation] = Nil
}
