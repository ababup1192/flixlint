///
/// What a rule file uses: one record per rule entry (`id` / what / `reason`), a builder per family, the functions
/// that are chained after an entry (`transitivelyIn`, `allowIn`, `allowInFile`, `allowUntil`), and the `RuleSet`
/// the engine runs. Names of functions, effects, modules, cases, enums and types are the enums of the generated
/// `Names` module, so a rule that names something the sources no longer have fails to compile.
///
pub mod Flixlint {
    use Names.{Fn, Eff, Mod, Case, Enum, Type}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation

    pub def version(): String = "0.3.0"

    /// A function or file whose violations of one entry are not reported, with the reason it is allowed.
    pub enum Allow with Eq, Order {
        /// `allowIn(Fn.X, reason)`
        case InFn(Fn, String)
        /// `allowInFile(path, reason)`: every violation in that file
        case InFile(String, String)
        /// `allowUntil(Fn.X, "YYYY-MM-DD", reason)`: like `InFn` until the date, ignored after it
        case Until(Fn, String, String)
    }

    /// Do not call `path`. With `transitivelyIn(Mod.X)`, the pub functions of `X` that reach `path` count as `path`.
    pub type alias DisallowedFunction = { id = String, reason = String, path = Fn, transitively = List[Mod], allows = List[Allow] }

    /// A function that calls one of `functions` must not call one of `withFunctions`.
    pub type alias DisallowedCallsTogether = { id = String, reason = String, functions = Set[Fn], withFunctions = Set[Fn], allows = List[Allow] }

    /// A signature must not have an effect of `effects` together with an effect of `withEffects` (aliases expanded).
    pub type alias DisallowedEffectsTogether = { id = String, reason = String, effects = Set[Eff], withEffects = Set[Eff], allows = List[Allow] }

    /// A signature that has `effect` must have no other effect.
    pub type alias DisallowedOtherEffectsWith = { id = String, reason = String, effect = Eff, allows = List[Allow] }

    /// The functions of the files matching the glob `files` must not have an effect of `effects`
    /// (an empty set means: must be pure).
    pub type alias DisallowedEffectsIn = { id = String, reason = String, files = String, effects = Set[Eff], allows = List[Allow] }

    /// Do not install a handler for `effect`. With `transitivelyIn(Mod.X)`, calling a pub function of `X` that
    /// installs one (`X.runWith`) counts too.
    pub type alias DisallowedHandler = { id = String, reason = String, effect = Eff, transitively = List[Mod], allows = List[Allow] }

    /// Do not build `constructor`. With `transitivelyIn(Mod.X)`, calling a pub function of `X` that builds it counts too.
    pub type alias DisallowedConstructor = { id = String, reason = String, constructor = Case, transitively = List[Mod], allows = List[Allow] }

    /// Do not call `function` inside a lambda passed to one of `inLambdaOf` (`List.map(x -> function(x), xs)`, or
    /// `List.map(function, xs)`). `files` (a glob, `**` by default; `inFiles`) limits where it is judged.
    pub type alias DisallowedCallInLambda = { id = String, reason = String, function = Fn, inLambdaOf = Set[Fn], files = String, allows = List[Allow] }

    /// Do not call `function` with one of `values` as the string literal at `argIndex`. With
    /// `valuesFromLiteralsIn(Fn.X)`, the string literals in the body of `X` are values too.
    pub type alias DisallowedCallWithArg = { id = String, reason = String, function = Fn, argIndex = Int32, values = Set[String], valuesFrom = List[Fn], allows = List[Allow] }

    /// No case of `ofEnum` may have a field whose type has `argType` in it (`ApiId` as well as `List[ApiId]`).
    pub type alias DisallowedCaseArgType = { id = String, reason = String, ofEnum = Enum, argType = Type, allows = List[Allow] }

    /// The functions of the files matching the glob `files` must neither call `module` (or its submodules), nor
    /// build one of its cases, nor have one of its types in a parameter or the return type (nested ones included);
    /// the enums declared there must not have one of its types in a case.
    pub type alias DisallowedDependency = { id = String, reason = String, files = String, module = Mod, allows = List[Allow] }

    /// A rule written against the facts directly, for what the families cannot say. Its violations carry their own
    /// reasons; `allowIn` / `allowInFile` / `allowUntil` apply to them like to any entry.
    pub type alias CustomRule = { id = String, check = Facts -> List[Violation], allows = List[Allow] }

    /// Every entry of every family. Built with `ruleSet` from the per-family lifters below.
    pub type alias RuleSet = {
        functions = List[DisallowedFunction],
        callsTogether = List[DisallowedCallsTogether],
        effectsTogether = List[DisallowedEffectsTogether],
        otherEffectsWith = List[DisallowedOtherEffectsWith],
        effectsIn = List[DisallowedEffectsIn],
        handlers = List[DisallowedHandler],
        constructors = List[DisallowedConstructor],
        callsInLambda = List[DisallowedCallInLambda],
        callsWithArg = List[DisallowedCallWithArg],
        caseArgTypes = List[DisallowedCaseArgType],
        dependencies = List[DisallowedDependency],
        customs = List[CustomRule]
    }

    // ---- builders: the writer gives id, what and reason; the rest starts empty ----

    pub def disallowFunction(r: { id = String, path = Fn, reason = String }): DisallowedFunction =
        { id = r#id, reason = r#reason, path = r#path, transitively = Nil, allows = Nil }

    pub def disallowCallsTogether(r: { id = String, functions = Set[Fn], withFunctions = Set[Fn], reason = String }): DisallowedCallsTogether =
        { id = r#id, reason = r#reason, functions = r#functions, withFunctions = r#withFunctions, allows = Nil }

    pub def disallowEffectsTogether(r: { id = String, effects = Set[Eff], withEffects = Set[Eff], reason = String }): DisallowedEffectsTogether =
        { id = r#id, reason = r#reason, effects = r#effects, withEffects = r#withEffects, allows = Nil }

    pub def disallowOtherEffectsWith(r: { id = String, effect = Eff, reason = String }): DisallowedOtherEffectsWith =
        { id = r#id, reason = r#reason, effect = r#effect, allows = Nil }

    pub def disallowEffectsIn(r: { id = String, files = String, effects = Set[Eff], reason = String }): DisallowedEffectsIn =
        { id = r#id, reason = r#reason, files = r#files, effects = r#effects, allows = Nil }

    pub def disallowHandler(r: { id = String, effect = Eff, reason = String }): DisallowedHandler =
        { id = r#id, reason = r#reason, effect = r#effect, transitively = Nil, allows = Nil }

    pub def disallowConstructor(r: { id = String, constructor = Case, reason = String }): DisallowedConstructor =
        { id = r#id, reason = r#reason, constructor = r#constructor, transitively = Nil, allows = Nil }

    pub def disallowCallInLambdaOf(r: { id = String, function = Fn, inLambdaOf = Set[Fn], reason = String }): DisallowedCallInLambda =
        { id = r#id, reason = r#reason, function = r#function, inLambdaOf = r#inLambdaOf, files = "**", allows = Nil }

    pub def disallowCallWithArg(r: { id = String, function = Fn, argIndex = Int32, values = Set[String], reason = String }): DisallowedCallWithArg =
        { id = r#id, reason = r#reason, function = r#function, argIndex = r#argIndex, values = r#values, valuesFrom = Nil, allows = Nil }

    pub def disallowCaseArgType(r: { id = String, ofEnum = Enum, argType = Type, reason = String }): DisallowedCaseArgType =
        { id = r#id, reason = r#reason, ofEnum = r#ofEnum, argType = r#argType, allows = Nil }

    pub def disallowDependency(r: { id = String, files = String, module = Mod, reason = String }): DisallowedDependency =
        { id = r#id, reason = r#reason, files = r#files, module = r#module, allows = Nil }

    // ---- chained after an entry ----

    /// The pub functions of `module` that reach the disallowed thing through calls count as the thing itself.
    pub def transitivelyIn(module: Mod, rule: { transitively = List[Mod] | r }): { transitively = List[Mod] | r } =
        { transitively = rule#transitively ::: (module :: Nil) | rule }

    /// Only the functions of the files matching the glob (`src/{admin,mcp}/**`) are judged.
    pub def inFiles(glob: String, rule: { files = String | r }): { files = String | r } =
        { files = glob | rule }

    /// The string literals in the body of `fn` count as `values` (a list the sources keep in one function).
    pub def valuesFromLiteralsIn(fn: Fn, rule: { valuesFrom = List[Fn] | r }): { valuesFrom = List[Fn] | r } =
        { valuesFrom = rule#valuesFrom ::: (fn :: Nil) | rule }

    /// Violations inside `fn` are not reported. An allow that matches no violation is an error.
    pub def allowIn(fn: Fn, reason: String, rule: { allows = List[Allow] | r }): { allows = List[Allow] | r } =
        { allows = rule#allows ::: (Allow.InFn(fn, reason) :: Nil) | rule }

    /// Violations in the file at `path` (as given to flixlint, e.g. `src/app/Now.flix`) are not reported.
    pub def allowInFile(path: String, reason: String, rule: { allows = List[Allow] | r }): { allows = List[Allow] | r } =
        { allows = rule#allows ::: (Allow.InFile(path, reason) :: Nil) | rule }

    /// Like `allowIn` until `date` (`YYYY-MM-DD`); after it the violations are reported again.
    pub def allowUntil(fn: Fn, date: String, reason: String, rule: { allows = List[Allow] | r }): { allows = List[Allow] | r } =
        { allows = rule#allows ::: (Allow.Until(fn, date, reason) :: Nil) | rule }

    // ---- the rule set ----

    pub def empty(): RuleSet =
        { functions = Nil, callsTogether = Nil, effectsTogether = Nil, otherEffectsWith = Nil, effectsIn = Nil,
          handlers = Nil, constructors = Nil, callsInLambda = Nil, callsWithArg = Nil, caseArgTypes = Nil, dependencies = Nil, customs = Nil }

    /// Merges the parts (`functions(...)`, `handlers(...)`, `custom(...)`, ...) into one rule set.
    pub def ruleSet(parts: List[RuleSet]): RuleSet = List.foldLeft(merge, empty(), parts)

    pub def functions(entries: List[DisallowedFunction]): RuleSet = { functions = entries | empty() }
    pub def callsTogether(entries: List[DisallowedCallsTogether]): RuleSet = { callsTogether = entries | empty() }
    pub def effectsTogether(entries: List[DisallowedEffectsTogether]): RuleSet = { effectsTogether = entries | empty() }
    pub def otherEffectsWith(entries: List[DisallowedOtherEffectsWith]): RuleSet = { otherEffectsWith = entries | empty() }
    pub def effectsIn(entries: List[DisallowedEffectsIn]): RuleSet = { effectsIn = entries | empty() }
    pub def handlers(entries: List[DisallowedHandler]): RuleSet = { handlers = entries | empty() }
    pub def constructors(entries: List[DisallowedConstructor]): RuleSet = { constructors = entries | empty() }
    pub def callsInLambda(entries: List[DisallowedCallInLambda]): RuleSet = { callsInLambda = entries | empty() }
    pub def callsWithArg(entries: List[DisallowedCallWithArg]): RuleSet = { callsWithArg = entries | empty() }
    pub def caseArgTypes(entries: List[DisallowedCaseArgType]): RuleSet = { caseArgTypes = entries | empty() }
    pub def dependencies(entries: List[DisallowedDependency]): RuleSet = { dependencies = entries | empty() }

    /// A rule that reads the facts itself and returns its violations (see `Flixlint.Violation` for building them);
    /// allows are chained after it and `customs` lifts it.
    pub def customRule(r: { id = String, check = Facts -> List[Violation] }): CustomRule =
        { id = r#id, check = r#check, allows = Nil }

    pub def customs(entries: List[CustomRule]): RuleSet = { customs = entries | empty() }

    /// A custom rule without allows: `customs(List#{customRule({ id = id, check = check })})`.
    pub def custom(id: String, check: Facts -> List[Violation]): RuleSet =
        customs(customRule({ id = id, check = check }) :: Nil)

    def merge(a: RuleSet, b: RuleSet): RuleSet =
        { functions = a#functions ::: b#functions,
          callsTogether = a#callsTogether ::: b#callsTogether,
          effectsTogether = a#effectsTogether ::: b#effectsTogether,
          otherEffectsWith = a#otherEffectsWith ::: b#otherEffectsWith,
          effectsIn = a#effectsIn ::: b#effectsIn,
          handlers = a#handlers ::: b#handlers,
          constructors = a#constructors ::: b#constructors,
          callsInLambda = a#callsInLambda ::: b#callsInLambda,
          callsWithArg = a#callsWithArg ::: b#callsWithArg,
          caseArgTypes = a#caseArgTypes ::: b#caseArgTypes,
          dependencies = a#dependencies ::: b#dependencies,
          customs = a#customs ::: b#customs }
}
