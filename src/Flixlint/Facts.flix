///
/// The facts of the linted sources, loaded from the TSV the shim writes, with the names turned into the enums of
/// the generated `Flixlint.Names` module. Custom rules read them through the functions of this module.
///
pub mod Flixlint.Facts {
    use Flixlint.Names.{Fn, Eff, Mod, Case, Enum, Type}
    use Fs.FileRead.FileRead

    ///
    /// WhyNot: the data is not passed around as the record itself. Flix expands a record type alias at every use, and
    /// a wide alias in every rule's signature made the engine's type check several times slower; behind the enum the
    /// alias is expanded in this module only.
    ///
    pub enum Facts(Data)

    /// A top-level or instance definition of the linted sources: where it is and whether it is `pub`.
    pub type alias Def = { fn = Fn, name = String, module = Mod, file = String, line = Int32, isPub = Bool }

    /// A call inside the body of `caller` (lambdas and local defs count as the enclosing def).
    pub type alias Call = { caller = Fn, callee = Fn, line = Int32 }

    /// `run ... with handler <effect>` inside the body of `fn`.
    pub type alias Handle = { fn = Fn, effect = Eff, line = Int32 }

    /// An enum case built inside the body of `fn`.
    pub type alias Construct = { fn = Fn, constructor = Case, line = Int32 }

    /// A call to `callee` inside a lambda passed as an argument to `outer` (`List.map(x -> callee(x), xs)`; a function
    /// passed by name counts too), in the body of `caller`. One row per enclosing `outer`.
    pub type alias CallInLambda = { caller = Fn, callee = Fn, outer = Fn, line = Int32 }

    /// A string literal as the `index`-th argument of a call to `callee`, in the body of `caller`.
    pub type alias ArgLit = { caller = Fn, callee = Fn, index = Int32, text = String, line = Int32 }

    /// A call to `argCallee` as the `index`-th argument of a call to `callee` (the argument is the call, or a
    /// partial application of it), in the body of `caller`.
    pub type alias ArgCall = { caller = Fn, callee = Fn, index = Int32, argCallee = Fn, line = Int32 }

    /// In a `|>` chain, the result of `source` reaches `target` (through any number of stages); `line` is the line of `target`.
    pub type alias PipedInto = { caller = Fn, source = Fn, target = Fn, line = Int32 }

    /// A string literal in the body of `fn`.
    pub type alias StrLit = { fn = Fn, text = String, line = Int32 }

    /// A type constructor of the `index`-th parameter of `fn`: the head one (`argTypes`), or any one in the
    /// type, nested ones included (`argTypesAll`: `List[ApiId]` gives `List` and `ApiId`).
    pub type alias ArgType = { fn = Fn, index = Int32, tycon = Type }

    /// A type constructor of the `index`-th field of an enum case: the head one (`caseTypes`) or any one (`caseTypesAll`).
    pub type alias CaseType = { ofEnum = Enum, constructor = Case, index = Int32, tycon = Type }

    /// Where an enum is declared.
    pub type alias EnumDef = { ofEnum = Enum, module = Mod, file = String, line = Int32 }

    /// Where an effect is declared.
    pub type alias EffDef = { effect = Eff, module = Mod, file = String, line = Int32 }

    /// The relations plus the indexes the rules look things up in, and the tables from enum case back to name.
    pub type alias Data = {
        defs = List[Def],
        calls = List[Call],
        handles = List[Handle],
        constructs = List[Construct],
        callsInLambda = List[CallInLambda],
        argLits = List[ArgLit],
        argCalls = List[ArgCall],
        pipedInto = List[PipedInto],
        strLits = List[StrLit],
        argTypes = List[ArgType],
        argTypesAll = List[ArgType],
        caseTypes = List[CaseType],
        caseTypesAll = List[CaseType],
        enums = List[EnumDef],
        effects = List[EffDef],
        defOf = Map[Fn, Def],
        callsFrom = Map[Fn, List[Call]],
        effectOf = Map[Fn, Set[Eff]],
        argTypesOf = Map[Fn, List[ArgType]],
        argTypesAllOf = Map[Fn, List[ArgType]],
        retTypeOf = Map[Fn, Type],
        retTypesAllOf = Map[Fn, Set[Type]],
        strLitsOf = Map[Fn, List[String]],
        effAliases = Map[Eff, Set[Eff]],
        files = Set[String],
        fnNames = Map[Fn, String],
        fnCases = Map[Fn, String],
        effNames = Map[Eff, String],
        modNames = Map[Mod, String],
        caseNames = Map[Case, String],
        enumNames = Map[Enum, String],
        typeNames = Map[Type, String]
    }

    pub def defs(facts: Facts): List[Def] = data(facts)#defs
    pub def calls(facts: Facts): List[Call] = data(facts)#calls
    pub def handles(facts: Facts): List[Handle] = data(facts)#handles
    pub def constructs(facts: Facts): List[Construct] = data(facts)#constructs
    pub def callsInLambda(facts: Facts): List[CallInLambda] = data(facts)#callsInLambda
    pub def argLits(facts: Facts): List[ArgLit] = data(facts)#argLits
    pub def argCalls(facts: Facts): List[ArgCall] = data(facts)#argCalls
    pub def pipedInto(facts: Facts): List[PipedInto] = data(facts)#pipedInto
    pub def strLits(facts: Facts): List[StrLit] = data(facts)#strLits
    pub def argTypes(facts: Facts): List[ArgType] = data(facts)#argTypes
    pub def argTypesAll(facts: Facts): List[ArgType] = data(facts)#argTypesAll
    pub def caseTypes(facts: Facts): List[CaseType] = data(facts)#caseTypes
    pub def caseTypesAll(facts: Facts): List[CaseType] = data(facts)#caseTypesAll
    pub def enums(facts: Facts): List[EnumDef] = data(facts)#enums
    pub def effects(facts: Facts): List[EffDef] = data(facts)#effects
    pub def files(facts: Facts): Set[String] = data(facts)#files

    /// The definition of `fn`, if it is one of the linted sources (package, stdlib and Java callees have none).
    pub def defOf(facts: Facts, fn: Fn): Option[Def] = Map.get(fn, data(facts)#defOf)

    /// The calls inside the body of `fn`, in source order.
    pub def callsFrom(facts: Facts, fn: Fn): List[Call] = Map.getWithDefault(fn, Nil, data(facts)#callsFrom)

    /// Whether the body of `caller` calls `callee`.
    pub def callsTo(facts: Facts, caller: Fn, callee: Fn): Bool =
        callsFrom(facts, caller) |> List.exists(c -> c#callee == callee)

    /// The effects of the signature of `fn`, with type aliases expanded (empty for a pure function).
    pub def effectOf(facts: Facts, fn: Fn): Set[Eff] = Map.getWithDefault(fn, Set.empty(), data(facts)#effectOf)

    /// The parameters of `fn` in order (their head type constructors).
    pub def argTypesOf(facts: Facts, fn: Fn): List[ArgType] = Map.getWithDefault(fn, Nil, data(facts)#argTypesOf)

    /// The head type constructor of the `index`-th parameter of `fn`.
    pub def argType(facts: Facts, fn: Fn, index: Int32): Option[Type] =
        argTypesOf(facts, fn) |> List.find(a -> a#index == index) |> Option.map(a -> a#tycon)

    /// The head type constructor of the return type of `fn`.
    pub def retType(facts: Facts, fn: Fn): Option[Type] = Map.get(fn, data(facts)#retTypeOf)

    /// Every type constructor in the parameters of `fn`, nested ones included (one row per constructor and parameter).
    pub def argTypesAllOf(facts: Facts, fn: Fn): List[ArgType] = Map.getWithDefault(fn, Nil, data(facts)#argTypesAllOf)

    /// Every type constructor in the return type of `fn`, nested ones included.
    pub def retTypesAllOf(facts: Facts, fn: Fn): Set[Type] = Map.getWithDefault(fn, Set.empty(), data(facts)#retTypesAllOf)

    /// The string literals in the body of `fn`, in source order.
    pub def strLitsIn(facts: Facts, fn: Fn): List[String] = Map.getWithDefault(fn, Nil, data(facts)#strLitsOf)

    /// The members of an effect type alias, or the effect itself when it is not an alias.
    pub def expandEffect(facts: Facts, effect: Eff): Set[Eff] =
        Map.getWithDefault(effect, Set#{effect}, data(facts)#effAliases)

    /// The members of every effect in the set, aliases expanded.
    pub def expandEffects(facts: Facts, effects: Set[Eff]): Set[Eff] =
        Set.foldLeft((acc, e) -> Set.union(acc, expandEffect(facts, e)), Set.empty(), effects)

    /// The qualified name of a function as the compiler prints it (`Session.grant`).
    pub def fnName(facts: Facts, fn: Fn): String = Map.getWithDefault(fn, "?", data(facts)#fnNames)

    /// The spelling of the enum case of a function (`Session_grant`), for the hint that names `Fn.Session_grant`.
    pub def fnCase(facts: Facts, fn: Fn): String = Map.getWithDefault(fn, "?", data(facts)#fnCases)

    pub def effName(facts: Facts, effect: Eff): String = Map.getWithDefault(effect, "?", data(facts)#effNames)
    pub def modName(facts: Facts, module: Mod): String = Map.getWithDefault(module, "?", data(facts)#modNames)
    pub def caseName(facts: Facts, constructor: Case): String = Map.getWithDefault(constructor, "?", data(facts)#caseNames)
    pub def enumName(facts: Facts, ofEnum: Enum): String = Map.getWithDefault(ofEnum, "?", data(facts)#enumNames)
    pub def typeName(facts: Facts, tycon: Type): String = Map.getWithDefault(tycon, "?", data(facts)#typeNames)

    /// The module part of a qualified name (`GeneratedAdmin.Types.Foo` -> `GeneratedAdmin.Types`; a bare name has none).
    pub def moduleOf(qualified: String): String =
        match String.indexOfRight(substr = ".", qualified) {
            case Some(i) => String.takeLeft(i, qualified)
            case None => ""
        }

    /// Whether `qualified` is declared in `module` or in one of its submodules.
    pub def isIn(facts: Facts, module: Mod, qualified: String): Bool =
        let m = modName(facts, module);
        let owner = moduleOf(qualified);
        owner == m or String.startsWith(prefix = "${m}.", owner)

    def data(facts: Facts): Data = match facts { case Facts.Facts(d) => d }

    // ---- loading ----

    /// Loads the TSV of `dir`. A row whose name is not in the generated enums (operators such as `++`) is skipped.
    pub def load(dir: String): Facts \ FileRead =
        let fnTable = Flixlint.Names.fnTable();
        let fnOf = table(fnTable);
        let effOf = table(Flixlint.Names.effTable());
        let modOf = table(Flixlint.Names.modTable());
        let caseOf = table(Flixlint.Names.caseTable());
        let enumOf = table(Flixlint.Names.enumTable());
        let typeOf = table(Flixlint.Names.typeTable());
        let defs = rows(dir, "def") |> List.filterMap(c -> forM (
                fn <- fnOf(col(0, c));
                module <- modOf(col(2, c))
            ) yield { fn = fn, name = col(1, c), module = module, file = col(3, c), line = int(4, c), isPub = col(5, c) == "true" });
        let calls = rows(dir, "calls") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                callee <- fnOf(col(1, c))
            ) yield { caller = caller, callee = callee, line = int(2, c) });
        let effectRows = rows(dir, "effect_of") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); e <- effOf(col(1, c))) yield (fn, e));
        let handles = rows(dir, "handles") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); e <- effOf(col(1, c))) yield { fn = fn, effect = e, line = int(2, c) });
        let constructs = rows(dir, "constructs") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); k <- caseOf(col(1, c))) yield { fn = fn, constructor = k, line = int(2, c) });
        let callsInLambda = rows(dir, "calls_in_lambda") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                callee <- fnOf(col(1, c));
                outer <- fnOf(col(2, c))
            ) yield { caller = caller, callee = callee, outer = outer, line = int(3, c) });
        let argLits = rows(dir, "arg_lit") |> List.filterMap(c -> forM (caller <- fnOf(col(0, c)); callee <- fnOf(col(1, c)))
            yield { caller = caller, callee = callee, index = int(2, c), text = col(3, c), line = int(4, c) });
        let argCalls = rows(dir, "arg_call") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                callee <- fnOf(col(1, c));
                argCallee <- fnOf(col(3, c))
            ) yield { caller = caller, callee = callee, index = int(2, c), argCallee = argCallee, line = int(4, c) });
        let pipedInto = rows(dir, "piped_into") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                source <- fnOf(col(1, c));
                target <- fnOf(col(2, c))
            ) yield { caller = caller, source = source, target = target, line = int(3, c) });
        let strLits = rows(dir, "str_lit") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c))) yield { fn = fn, text = col(1, c), line = int(2, c) });
        let argTypeRows = rel -> rows(dir, rel) |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); t <- typeOf(col(2, c))) yield { fn = fn, index = int(1, c), tycon = t });
        let argTypes = argTypeRows("arg_type");
        let argTypesAll = argTypeRows("arg_type_all");
        let retTypes = rows(dir, "ret_type") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); t <- typeOf(col(1, c))) yield (fn, t));
        let retTypesAll = rows(dir, "ret_type_all") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); t <- typeOf(col(1, c))) yield (fn, t));
        let caseTypeRows = rel -> rows(dir, rel) |> List.filterMap(c -> forM (e <- enumOf(col(0, c)); k <- caseOf(col(1, c)); t <- typeOf(col(3, c))) yield { ofEnum = e, constructor = k, index = int(2, c), tycon = t });
        let caseTypes = caseTypeRows("case_type");
        let caseTypesAll = caseTypeRows("case_type_all");
        let aliasRows = rows(dir, "eff_alias") |> List.filterMap(c -> forM (a <- effOf(col(0, c)); e <- effOf(col(1, c))) yield (a, e));
        let enums = rows(dir, "enum") |> List.filterMap(c -> forM (e <- enumOf(col(0, c)); m <- modOf(col(1, c))) yield { ofEnum = e, module = m, file = col(2, c), line = int(3, c) });
        let effects = rows(dir, "eff") |> List.filterMap(c -> forM (e <- effOf(col(0, c)); m <- modOf(col(1, c))) yield { effect = e, module = m, file = col(2, c), line = int(3, c) });
        let sortedCalls = calls |> List.sortBy(c -> (c#caller, c#line, c#callee));
        Facts.Facts({
            defs = defs,
            calls = sortedCalls,
            handles = handles,
            constructs = constructs,
            callsInLambda = callsInLambda,
            argLits = argLits,
            argCalls = argCalls,
            pipedInto = pipedInto,
            strLits = strLits,
            argTypes = argTypes,
            argTypesAll = argTypesAll,
            caseTypes = caseTypes,
            caseTypesAll = caseTypesAll,
            enums = enums,
            effects = effects,
            defOf = defs |> List.map(d -> (d#fn, d)) |> List.toMap,
            callsFrom = grouped(c -> c#caller, sortedCalls),
            effectOf = setsBy(effectRows),
            argTypesOf = grouped(a -> a#fn, argTypes |> List.sortBy(a -> (a#fn, a#index))),
            argTypesAllOf = grouped(a -> a#fn, argTypesAll |> List.sortBy(a -> (a#fn, a#index))),
            retTypeOf = List.toMap(retTypes),
            retTypesAllOf = setsBy(retTypesAll),
            strLitsOf = grouped(s -> s#fn, strLits |> List.sortBy(s -> (s#fn, s#line))) |> Map.map(List.map(s -> s#text)),
            effAliases = setsBy(aliasRows),
            files = List.foldLeft((acc, d) -> Set.insert(d#file, acc), Set.empty(), defs)
                |> (acc -> List.foldLeft((s, e) -> Set.insert(e#file, s), acc, enums))
                |> (acc -> List.foldLeft((s, e) -> Set.insert(e#file, s), acc, effects)),
            fnNames = fnTable |> List.map(match (n, _, k) -> (k, n)) |> List.toMap,
            fnCases = fnTable |> List.map(match (_, c, k) -> (k, c)) |> List.toMap,
            effNames = inverse(Flixlint.Names.effTable()),
            modNames = inverse(Flixlint.Names.modTable()),
            caseNames = inverse(Flixlint.Names.caseTable()),
            enumNames = inverse(Flixlint.Names.enumTable()),
            typeNames = inverse(Flixlint.Names.typeTable())
        })

    /// A lookup from the qualified name to the enum case. The root module is the empty name.
    def table(t: List[(String, String, a)]): String -> Option[a] with Order[a] =
        let m = t |> List.map(match (n, _, k) -> (n, k)) |> List.toMap;
        (n -> Map.get(n, m))

    def inverse(t: List[(String, String, a)]): Map[a, String] with Order[a] =
        t |> List.map(match (n, _, k) -> (k, n)) |> List.toMap

    /// Groups a list that is already sorted by the key, keeping the order inside each group.
    def grouped(key: a -> k, xs: List[a]): Map[k, List[a]] with Order[k] =
        List.foldRight((x, m) -> Map.insertWith((newer, older) -> newer ::: older, key(x), x :: Nil, m), Map.empty(), xs)

    def setsBy(pairs: List[(k, v)]): Map[k, Set[v]] with Order[k], Order[v] =
        List.foldLeft((m, p) -> Map.insertWith((newer, older) -> Set.union(newer, older), fst(p), Set#{snd(p)}, m), Map.empty(), pairs)

    /// A missing file is an empty relation (the shim writes a file only when the relation has a row).
    def rows(dir: String, rel: String): List[Vector[String]] \ FileRead =
        match Fs.FileRead.readLines("${dir}/${rel}.tsv") {
            case Ok(lines) => lines |> List.filter(l -> not String.isEmpty(l)) |> List.map(l -> String.splitOn(substr = "\t", l) |> List.toVector)
            case Err(_) => Nil
        }

    def col(i: Int32, c: Vector[String]): String = Vector.get(i, c)

    def int(i: Int32, c: Vector[String]): Int32 = Int32.parse(10, Vector.get(i, c)) |> Result.getWithDefault(0)
}
