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

    /// An argument of a case built in the body of `fn` (`Some(x)`): its `shape` (`bool` for a literal, `unary:Not`,
    /// `op:And`, `call:Eq.eq` for `a == b`, `var`, or the node's name) and the head of its type `tycon` (`Bool`; `?` at the
    /// resolved stage, which has no types yet).
    pub type alias TagArg = { fn = Fn, constructor = Case, index = Int32, shape = String, tycon = String, line = Int32 }

    /// A `true` / `false` literal in the body of `fn` (not in a pattern): `placement` names its nearest parents, closest first
    /// and up to three, joined by ` < ` (`field:expected < arg:Assert.assertEq:0` for `assertEq(expected = true, x)`;
    /// a parent is `arg:<callee>:<index>`, `field:<label>`, `tag:<case>`, `tuple`, `vector`, `array`, `let` or
    /// `op:<operator>`, `not` and ascriptions seen through). `parentLine` is the line the nearest parent starts on.
    pub type alias BoolLit = { fn = Fn, value = Bool, placement = String, line = Int32, parentLine = Int32 }

    /// A branch in the body of `fn`: `kind` is `if`, `match` (a `match` lambda too), `typematch`, `extmatch` or `guard`
    /// (the `if` of a `case … if …` rule, one row per rule). A `let (a, b) = e` and a `forM` generator are not branches.
    pub type alias Branch = { fn = Fn, kind = String, line = Int32 }

    /// A string literal in the body of `fn`.
    pub type alias StrLit = { fn = Fn, text = String, line = Int32 }

    /// A type constructor of the `index`-th parameter of `fn`: the head one (`argTypes`), or any one in the
    /// type, nested ones included (`argTypesAll`: `List[ColumnName]` gives `List` and `ColumnName`), or any one with
    /// type aliases opened as well (`argTypesDeep`: `type alias Ctx = { w = World }` gives `Ctx` and `World`).
    pub type alias ArgType = { fn = Fn, index = Int32, tycon = Type }

    /// A type constructor of the `index`-th field of an enum case: the head one (`caseTypes`), any one (`caseTypesAll`),
    /// or any one with type aliases opened as well (`caseTypesDeep`).
    pub type alias CaseType = { ofEnum = Enum, constructor = Case, index = Int32, tycon = Type }

    /// A type alias of the linted sources: where it is declared, and the number of its record fields (`fields`; -1 when
    /// it does not stand for a record). `aliasTypesAllOf` gives the type constructors it stands for (as `argTypesAll`).
    pub type alias AliasDef = { typeAlias = Type, module = Mod, file = String, line = Int32, fields = Int32 }

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
        branches = List[Branch],
        boolLits = List[BoolLit],
        tagArgs = List[TagArg],
        argTypes = List[ArgType],
        argTypesAll = List[ArgType],
        argTypesDeep = Lazy[List[ArgType]],
        caseTypes = List[CaseType],
        caseTypesAll = List[CaseType],
        caseTypesDeep = List[CaseType],
        enums = List[EnumDef],
        typeAliases = List[AliasDef],
        effects = List[EffDef],
        defOf = Map[Fn, Def],
        callsFrom = Map[Fn, List[Call]],
        effectOf = Map[Fn, Set[Eff]],
        argTypesOf = Map[Fn, List[ArgType]],
        argTypesAllOf = Map[Fn, List[ArgType]],
        argTypesDeepOf = Lazy[Map[Fn, List[ArgType]]],
        retTypeOf = Map[Fn, Type],
        retTypesAllOf = Map[Fn, Set[Type]],
        retTypesDeepOf = Lazy[Map[Fn, Set[Type]]],
        aliasTypesAllOf = Map[Type, Set[Type]],
        strLitsOf = Map[Fn, List[String]],
        effAliases = Map[Eff, Set[Eff]],
        files = Set[String],
        fnCases = Map[String, String],
        ast = Flixlint.Ast.Ast
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
    pub def branches(facts: Facts): List[Branch] = data(facts)#branches
    pub def boolLits(facts: Facts): List[BoolLit] = data(facts)#boolLits
    pub def tagArgs(facts: Facts): List[TagArg] = data(facts)#tagArgs
    pub def argTypes(facts: Facts): List[ArgType] = data(facts)#argTypes
    pub def argTypesAll(facts: Facts): List[ArgType] = data(facts)#argTypesAll
    pub def argTypesDeep(facts: Facts): List[ArgType] = force data(facts)#argTypesDeep
    pub def caseTypes(facts: Facts): List[CaseType] = data(facts)#caseTypes
    pub def caseTypesAll(facts: Facts): List[CaseType] = data(facts)#caseTypesAll
    pub def caseTypesDeep(facts: Facts): List[CaseType] = data(facts)#caseTypesDeep
    pub def enums(facts: Facts): List[EnumDef] = data(facts)#enums
    pub def typeAliases(facts: Facts): List[AliasDef] = data(facts)#typeAliases
    pub def effects(facts: Facts): List[EffDef] = data(facts)#effects
    /// Every file the walk was given, whether or not it holds a definition an `allowInFile` could name.
    pub def files(facts: Facts): Set[String] = data(facts)#files

    /// The generic AST of the sources (Flixlint.Ast and Flixlint.Flix read it); empty when the shim did not write it.
    pub def ast(facts: Facts): Flixlint.Ast.Ast = data(facts)#ast

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

    /// Every type constructor in the parameters of `fn`, with type aliases opened at any depth.
    pub def argTypesDeepOf(facts: Facts, fn: Fn): List[ArgType] = Map.getWithDefault(fn, Nil, force data(facts)#argTypesDeepOf)

    /// Every type constructor in the return type of `fn`, with type aliases opened at any depth.
    pub def retTypesDeepOf(facts: Facts, fn: Fn): Set[Type] = Map.getWithDefault(fn, Set.empty(), force data(facts)#retTypesDeepOf)

    /// Every type constructor a type alias stands for, nested ones included (aliases inside it by their own name).
    pub def aliasTypesAllOf(facts: Facts, aliasType: Type): Set[Type] = Map.getWithDefault(aliasType, Set.empty(), data(facts)#aliasTypesAllOf)

    /// The string literals in the body of `fn`, in source order.
    pub def strLitsIn(facts: Facts, fn: Fn): List[String] = Map.getWithDefault(fn, Nil, data(facts)#strLitsOf)

    /// The members of an effect type alias, or the effect itself when it is not an alias.
    pub def expandEffect(facts: Facts, effect: Eff): Set[Eff] =
        Map.getWithDefault(effect, Set#{effect}, data(facts)#effAliases)

    /// The members of every effect in the set, aliases expanded.
    pub def expandEffects(facts: Facts, effects: Set[Eff]): Set[Eff] =
        Set.foldLeft((acc, e) -> Set.union(acc, expandEffect(facts, e)), Set.empty(), effects)

    /// The qualified name of a function as the compiler prints it (`Auth.permit`).
    pub def fnName(_facts: Facts, fn: Fn): String = Flixlint.Names.fnName(fn)

    /// The spelling of the enum case of a function (`Auth_permit`), for the hint that names `Fn.Auth_permit`.
    pub def fnCase(facts: Facts, fn: Fn): String = Map.getWithDefault(Flixlint.Names.fnName(fn), "?", data(facts)#fnCases)

    pub def effName(_facts: Facts, effect: Eff): String = Flixlint.Names.effName(effect)
    pub def modName(_facts: Facts, module: Mod): String = Flixlint.Names.modName(module)
    pub def caseName(_facts: Facts, constructor: Case): String = Flixlint.Names.caseName(constructor)
    pub def enumName(_facts: Facts, ofEnum: Enum): String = Flixlint.Names.enumName(ofEnum)
    pub def typeName(_facts: Facts, tycon: Type): String = Flixlint.Names.typeName(tycon)

    /// The module part of a qualified name (`Generated.Types.Foo` -> `Generated.Types`; a bare name has none).
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

    /// The facts of the generic AST `ast` (its relations, `Flixlint.Rel`), with the names of `names.tsv` in `dir`. A row whose
    /// name is not among the names (operators such as `++` are not) is skipped.
    pub def load(dir: String, ast: Flixlint.Ast.Ast): Facts \ FileRead =
        let names = cells(lines(dir, "names"));
        let tableOf = Flixlint.Rel.tableOf(ast);
        let src = rel -> tableOf(rel) |> List.map(r -> List.map(Flixlint.Rel.clean, r) |> List.toVector);
        let fnOf = known(names, "Fn", Flixlint.Names.fnOf);
        let effOf = known(names, "Eff", Flixlint.Names.effOf);
        let modOf = known(names, "Mod", Flixlint.Names.modOf);
        let caseOf = known(names, "Case", Flixlint.Names.caseOf);
        let enumOf = known(names, "Enum", Flixlint.Names.enumOf);
        let typeOf = known(names, "Type", Flixlint.Names.typeOf);
        let defs = src("def") |> List.filterMap(c -> forM (
                fn <- fnOf(col(0, c));
                module <- modOf(col(2, c))
            ) yield { fn = fn, name = col(1, c), module = module, file = col(3, c), line = int(4, c), isPub = col(5, c) == "true" });
        let calls = src("calls") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                callee <- fnOf(col(1, c))
            ) yield { caller = caller, callee = callee, line = int(2, c) });
        let effectRows = src("effect_of") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); e <- effOf(col(1, c))) yield (fn, e));
        let handles = src("handles") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); e <- effOf(col(1, c))) yield { fn = fn, effect = e, line = int(2, c) });
        let constructs = src("constructs") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); k <- caseOf(col(1, c))) yield { fn = fn, constructor = k, line = int(2, c) });
        let callsInLambda = src("calls_in_lambda") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                callee <- fnOf(col(1, c));
                outer <- fnOf(col(2, c))
            ) yield { caller = caller, callee = callee, outer = outer, line = int(3, c) });
        let argLits = src("arg_lit") |> List.filterMap(c -> forM (caller <- fnOf(col(0, c)); callee <- fnOf(col(1, c)))
            yield { caller = caller, callee = callee, index = int(2, c), text = col(3, c), line = int(4, c) });
        let argCalls = src("arg_call") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                callee <- fnOf(col(1, c));
                argCallee <- fnOf(col(3, c))
            ) yield { caller = caller, callee = callee, index = int(2, c), argCallee = argCallee, line = int(4, c) });
        let pipedInto = src("piped_into") |> List.filterMap(c -> forM (
                caller <- fnOf(col(0, c));
                source <- fnOf(col(1, c));
                target <- fnOf(col(2, c))
            ) yield { caller = caller, source = source, target = target, line = int(3, c) });
        let strLits = src("str_lit") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c))) yield { fn = fn, text = col(1, c), line = int(2, c) });
        let types = loadTypes(src, fnOf, typeOf, enumOf, caseOf);
        let aliasRows = src("eff_alias") |> List.filterMap(c -> forM (a <- effOf(col(0, c)); e <- effOf(col(1, c))) yield (a, e));
        let enums = src("enum") |> List.filterMap(c -> forM (e <- enumOf(col(0, c)); m <- modOf(col(1, c))) yield { ofEnum = e, module = m, file = col(2, c), line = int(3, c) });
        let (typeAliases, aliasTypesAll) = loadAliases(src, typeOf, modOf);
        let branches = loadBranches(src, fnOf);
        let boolLits = loadBoolLits(src, fnOf);
        let tagArgs = loadTagArgs(src, fnOf, caseOf);
        let effects = src("eff") |> List.filterMap(c -> forM (e <- effOf(col(0, c)); m <- modOf(col(1, c))) yield { effect = e, module = m, file = col(2, c), line = int(3, c) });
        let sourceFiles = src("source_file") |> List.map(c -> col(0, c));
        let callsFrom = groupSorted(c -> c#caller, c -> (c#line, c#callee), calls);
        let sortedCalls = callsFrom |> Map.valuesOf |> List.flatten;
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
            branches = branches,
            boolLits = boolLits,
            tagArgs = tagArgs,
            argTypes = types#argTypes,
            argTypesAll = types#argTypesAll,
            argTypesDeep = types#argTypesDeep,
            caseTypes = types#caseTypes,
            caseTypesAll = types#caseTypesAll,
            caseTypesDeep = types#caseTypesDeep,
            enums = enums,
            typeAliases = typeAliases,
            effects = effects,
            defOf = defs |> List.map(d -> (d#fn, d)) |> List.toMap,
            callsFrom = callsFrom,
            effectOf = setsBy(effectRows),
            argTypesOf = groupSorted(a -> a#fn, a -> a#index, types#argTypes),
            argTypesAllOf = groupSorted(a -> a#fn, a -> a#index, types#argTypesAll),
            argTypesDeepOf = lazy groupSorted(a -> a#fn, a -> a#index, force types#argTypesDeep),
            retTypeOf = List.toMap(types#retTypes),
            retTypesAllOf = setsBy(types#retTypesAll),
            retTypesDeepOf = lazy setsBy(force types#retTypesDeep),
            aliasTypesAllOf = aliasTypesAll,
            strLitsOf = groupSorted(s -> s#fn, s -> s#line, strLits) |> Map.map(List.map(s -> s#text)),
            effAliases = setsBy(aliasRows),
            files = List.foldLeft((acc, f) -> Set.insert(f, acc), Set.empty(), sourceFiles)
                |> (acc -> List.foldLeft((s, d) -> Set.insert(d#file, s), acc, defs))
                |> (acc -> List.foldLeft((s, e) -> Set.insert(e#file, s), acc, enums))
                |> (acc -> List.foldLeft((s, e) -> Set.insert(e#file, s), acc, effects)),
            fnCases = names |> List.filter(c -> col(0, c) == "Fn") |> List.map(c -> (col(1, c), col(2, c))) |> List.toMap,
            ast = ast
        })

    /// A lookup from the qualified name to its value, for the names of one kind in `names.tsv` (kind, name, case).
    /// The root module is the empty name.
    def known(names: List[Vector[String]], kind: String, valueOf: String -> a): String -> Option[a] =
        let m = names |> List.filter(c -> col(0, c) == kind) |> List.map(c -> (col(1, c), valueOf(col(1, c)))) |> List.toMap;
        (n -> Map.get(n, m))

    /// The type relations read by `loadTypes`.
    type alias TypeRows = {
        argTypes = List[ArgType], argTypesAll = List[ArgType], argTypesDeep = Lazy[List[ArgType]],
        retTypes = List[(Fn, Type)], retTypesAll = List[(Fn, Type)], retTypesDeep = Lazy[List[(Fn, Type)]],
        caseTypes = List[CaseType], caseTypesAll = List[CaseType], caseTypesDeep = List[CaseType]
    }

    /// The types of parameters, return values and case fields: the head one, all of them, and through aliases.
    /// WhyNot: not inline in `load`. The JVM caps a method at 64 KB, and `load` reaches it as relations are added
    /// (on a project with ten thousand names the compiler would inline these back into `load`, hence @DontInline).
    /// WhyNot: the Deep rows of parameters and return values are not parsed here. They are most of the facts (every
    /// alias opened at every depth) and only a custom rule reads them, so they are parsed when one first does.
    @DontInline
    def loadTypes(src: String -> List[Vector[String]], fnOf: String -> Option[Fn], typeOf: String -> Option[Type],
                  enumOf: String -> Option[Enum], caseOf: String -> Option[Case]): TypeRows =
        let argType = c -> forM (fn <- fnOf(col(0, c)); t <- typeOf(col(2, c))) yield { fn = fn, index = int(1, c), tycon = t };
        let retType = c -> forM (fn <- fnOf(col(0, c)); t <- typeOf(col(1, c))) yield (fn, t);
        let argTypes = src("arg_type") |> List.filterMap(argType);
        let argTypesAll = src("arg_type_all") |> List.filterMap(argType);
        let argTypesDeep = lazy (src("arg_type_deep") |> List.filterMap(argType));
        let retTypes = src("ret_type") |> List.filterMap(retType);
        let retTypesAll = src("ret_type_all") |> List.filterMap(retType);
        let retTypesDeep = lazy (src("ret_type_deep") |> List.filterMap(retType));
        let caseTypeRows = rel -> src(rel) |> List.filterMap(c -> forM (e <- enumOf(col(0, c)); k <- caseOf(col(1, c)); t <- typeOf(col(3, c))) yield { ofEnum = e, constructor = k, index = int(2, c), tycon = t });
        let caseTypes = caseTypeRows("case_type");
        let caseTypesAll = caseTypeRows("case_type_all");
        let caseTypesDeep = caseTypeRows("case_type_deep");
        { argTypes = argTypes, argTypesAll = argTypesAll, argTypesDeep = argTypesDeep,
          retTypes = retTypes, retTypesAll = retTypesAll, retTypesDeep = retTypesDeep,
          caseTypes = caseTypes, caseTypesAll = caseTypesAll, caseTypesDeep = caseTypesDeep }

    /// The case arguments. WhyNot: not inline in `load`, for the same reason as `loadTypes`.
    @DontInline
    def loadTagArgs(src: String -> List[Vector[String]], fnOf: String -> Option[Fn], caseOf: String -> Option[Case]): List[TagArg] =
        src("tag_arg") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)); k <- caseOf(col(1, c)))
            yield { fn = fn, constructor = k, index = int(2, c), shape = col(3, c), tycon = col(4, c), line = int(5, c) })

    /// The Bool literals. WhyNot: not inline in `load`, for the same reason as `loadTypes`.
    @DontInline
    def loadBoolLits(src: String -> List[Vector[String]], fnOf: String -> Option[Fn]): List[BoolLit] =
        src("bool_lit") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c)))
            yield { fn = fn, value = col(1, c) == "true", placement = col(2, c), line = int(3, c), parentLine = int(4, c) })

    /// The branches. WhyNot: not inline in `load`, for the same reason as `loadTypes`.
    @DontInline
    def loadBranches(src: String -> List[Vector[String]], fnOf: String -> Option[Fn]): List[Branch] =
        src("branch") |> List.filterMap(c -> forM (fn <- fnOf(col(0, c))) yield { fn = fn, kind = col(1, c), line = int(2, c) })

    /// The type aliases and what each stands for.
    /// WhyNot: not inline in `load`, for the same reason as `loadTypes`.
    @DontInline
    def loadAliases(src: String -> List[Vector[String]], typeOf: String -> Option[Type], modOf: String -> Option[Mod]): (List[AliasDef], Map[Type, Set[Type]]) =
        let defs = src("type_alias") |> List.filterMap(c -> forM (a <- typeOf(col(0, c)); m <- modOf(col(1, c)))
            yield { typeAlias = a, module = m, file = col(2, c), line = int(3, c), fields = int(5, c) });
        let stands = src("alias_type_all") |> List.filterMap(c -> forM (a <- typeOf(col(0, c)); t <- typeOf(col(1, c))) yield (a, t));
        (defs, setsBy(stands))

    /// `xs` grouped by `key`, each group sorted by `within` (stable). The groups are short, so this sorts far less than
    /// sorting the whole list by both keys, and `Map.valuesOf` of it is that sorted list.
    def groupSorted(key: a -> k, within: a -> j, xs: List[a]): Map[k, List[a]] with Order[k], Order[j] =
        grouped(key, xs) |> Map.map(g -> g |> List.map(x -> (within(x), x)) |> List.sortBy(fst) |> List.map(snd))

    /// `xs` grouped by `key`, keeping the order inside each group.
    def grouped(key: a -> k, xs: List[a]): Map[k, List[a]] with Order[k] =
        List.foldRight((x, m) -> Map.insertWith((newer, older) -> newer ::: older, key(x), x :: Nil, m), Map.empty(), xs)

    def setsBy(pairs: List[(k, v)]): Map[k, Set[v]] with Order[k], Order[v] =
        List.foldLeft((m, p) -> Map.insertWith((newer, older) -> Set.union(newer, older), fst(p), Set#{snd(p)}, m), Map.empty(), pairs)

    /// The non-empty lines of a relation's file. A missing file is an empty relation.
    def lines(dir: String, rel: String): List[String] \ FileRead =
        match Fs.FileRead.readLines("${dir}/${rel}.tsv") {
            case Ok(ls) => List.filter(l -> not String.isEmpty(l), ls)
            case Err(_) => Nil
        }

    /// The columns of each line.
    def cells(ls: List[String]): List[Vector[String]] =
        List.map(l -> String.splitOn(substr = "\t", l) |> List.toVector, ls)

    def col(i: Int32, c: Vector[String]): String = Vector.get(i, c)

    def int(i: Int32, c: Vector[String]): Int32 = Int32.parse(10, Vector.get(i, c)) |> Result.getWithDefault(0)
}
