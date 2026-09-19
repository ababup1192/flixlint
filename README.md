# flixlint

Architecture rules for [Flix](https://flix.dev) projects, checked on the compiler's AST instead of with `grep`.

The compiler already builds a typed AST of the whole project; flixlint asks it for a handful of language-level
**facts** (which function is defined where, who calls whom, which effects a signature has, where a handler is
installed, which enum case is built where, what the types of a signature are made of, which lambda a call sits in, which
literal or call is an argument, what a `|>` chain passes along) and writes them as TSV. Rules are written in
Flix, as records in the style of Clippy's `clippy.toml`: one entry says what is disallowed, why, and which functions
are allowed anyway. The names of functions, effects, modules, cases, enums and types are enums generated from the
facts, so a rule that names something the sources no longer have does not compile, and an allow that no longer covers
anything is an error.

flixlint knows nothing about any particular project: the names of effects, modules, files and enum cases are the
rules' business, not the linter's.

## Installing

flixlint is a **tool**, not a Flix library: it is delivered as this repository, and a project that wants to be linted
calls `bin/flixlint`. It is deliberately not something you put in your `flix.toml` `[dependencies]` — see
[Why it is not an fpkg](#why-it-is-not-an-fpkg).

```bash
# next to the project that will be linted, or anywhere else
git clone https://github.com/ababup1192/flixlint.git
# or, inside the project:
git submodule add https://github.com/ababup1192/flixlint.git flixlint
```

You need a JDK and the Flix compiler jar of the version in `flix.toml` (`flix = "0.76.0"`); pass it with
`--flix-jar` or `FLIX_JAR`, and with neither `bin/flix-jar` looks for the devbox profile of
`~/Desktop/flix_game_engine` (`FLIXLINT_ENGINE_ROOT` moves that).

The Scala shim is built once, on first use and whenever `shim/*.scala` changes, into `build/flixlint-shim.jar`.
That needs `scala-cli`: `devbox.json` has it, and a `scala-cli` on `PATH` is used when there is no devbox. If you
have neither, take `flixlint-shim-<flix version>.jar` from the release and pass it with `--shim` or `FLIXLINT_SHIM`
(`make release` is what attaches it). The jar holds only flixlint's own classes, compiled against the compiler's
internal AST, so one jar per Flix version serves every machine and every project.

```bash
make test            # lint the fixture and diff the report against test/expected*.txt
make test-resolved   # the same at the resolved stage
make shim            # rebuild build/flixlint-shim.jar
```

`make test` is also the type check of the rule engine: `rules/Flixlint*.flix` only compiles together with a generated
`Names.flix`, so running the fixture through is the only way to compile it.

## Using it from your project

Keep one file in your project — the rules — and call flixlint with the compiler jar and your dependencies:

```make
LINT = ../flixlint/bin/flixlint --flix-jar "$$(bin/flix-jar)" --rules lint/rules.flix --stage resolved \
       $$(bin/flix-deps) src

lint:
	$(LINT)
```

`--pkg` / `--jar` are the dependencies your sources need; the compiler has already resolved them into `lib/` by the
time `flix check` has run once, so a small script that turns `flix.toml` into `--pkg lib/... --jar lib/cache/...`
lines is all that is needed. Nothing else of flixlint has to live in your repository: the engine, the shim and the
`Names` enums are all built under `--build-dir` (default `build/flixlint`), which belongs in `.gitignore`.

### Why it is not an fpkg

`flix build-pkg` puts `flix.toml`, `README.md`, `LICENSE.md` and `src/**/*.flix` into the package and nothing else —
a jar or a resource file under `src/` is dropped, and so is everything outside `src/`. So neither `bin/flixlint` nor
the shim jar can travel in an fpkg. On top of that, `rules/Flixlint*.flix` refers to the generated `Names` module, so
as a package it would not compile in the consumer's project at all — and it has no business being compiled into the
consumer's program, since only the throwaway rule-engine project that `bin/flixlint` generates ever uses it.

Flix does have `[jar-dependencies]` (`"name.jar" = "url:https://..."`, downloaded into `lib/external/`), and it is
applied to transitive manifests too, but it delivers a jar to the consumer's *compile* classpath, which is not where
the shim runs: the shim runs on the compiler jar's classpath inside `bin/flixlint`. Hence the release asset.

## Usage

```
bin/flixlint [--flix-jar JAR] --rules PATH/rules.flix [--pkg FPKG]... [--jar JAR]... [--stage typed|resolved]
             [--today YYYY-MM-DD] [--facts-out DIR] [--build-dir DIR] [--shim JAR] [--java-opts "..."] SRC...
```

| Option | Meaning |
|---|---|
| `--flix-jar JAR` | The Flix compiler (`flix.jar`, 0.76.0). `FLIX_JAR` in the environment works too; with neither, `bin/flix-jar` resolves it. |
| `--rules PATH/rules.flix` | The rule file: a Flix module with `pub def rules(): Flixlint.RuleSet` (see below). |
| `--pkg FPKG` / `--jar JAR` | Dependencies the sources need (`lib/**/*.fpkg`, `lib/cache/**/*.jar`). Repeatable. |
| `--stage typed` (default) | Facts from the typed AST (`Flix.check()`): everything below, including compile errors. |
| `--stage resolved` | Facts from the AST right after name resolution, before kinding and typing. Several times faster; the same facts except Java instance-method calls (the receiver's class is not known yet). |
| `--today YYYY-MM-DD` | The date `allowUntil` is compared with (default: the real date). Tests fix it. |
| `--facts-out DIR` | Where the TSV facts go (default `BUILD/facts`). Keep them: they are the easiest way to look up a qualified name. |
| `--build-dir DIR` | Working directory for the facts and the rule engine (default `build/flixlint`), relative to the current directory. |
| `--shim JAR` | A prebuilt shim jar, instead of building one with `scala-cli`. `FLIXLINT_SHIM` works too. |
| `SRC...` | Source directories or files, relative to the current directory. File paths in violations and in `allowInFile` are relative to that directory too. |

Exit codes: `0` no violation, `1` violations, `2` the rules are wrong (the rule file does not compile, an allow that
covers nothing, an `allowInFile` of a file that is not among the sources), `3` the sources do not compile.

A violation is a `file:line:` header editors pick up, then the rule's reason, the path through the wrappers when
`transitivelyIn` found it, and how to get rid of it:

```
src/Report.flix:14: clock: Report.title: calls Wall.today
    the real clock is read where Main builds the clock; everything else takes the time as an argument
    Wall.today -> Wall.nowMillis -> java.lang.System.currentTimeMillis
    fix it, or add |> allowIn(Fn.Report_title, "reason") to rule clock
```

Violations are sorted by file, line and rule id, so the report is the same on every run.

The rule engine is a Flix program made of the `rules/Flixlint` library, the generated `Names.flix`, your rule file and
a generated `main`; `bin/flixlint` compiles it into a jar with the same compiler and rebuilds it only when one of those
changes (measured on a 227-file project: the engine builds in about 16 s, then a run costs the facts plus 3 s).

## Writing rules

A rule file is a Flix module with one `pub def rules(): Flixlint.RuleSet`. Each entry is a record with `id`, what is
disallowed, and `reason`; the functions chained after it add what the entry needs and nothing else. Names come from
the generated `Names` module: `Fn.Session_grant`, `Eff.Net_Http`, `Mod.Now`, `Case.Visible_Visible`,
`Enum.Condition`, `Type.ApiId` (the qualified name with every character that is not a letter or a digit replaced by
`_` and the first letter upper-cased; `java.lang.System.currentTimeMillis` is `Fn.Java_lang_System_currentTimeMillis`,
the root module is `Mod.Root`). The editor's completion on `Fn.` lists the candidates.

```flix
mod MyRules {
    use Flixlint.{RuleSet, disallowFunction, disallowEffectsTogether, disallowHandler, transitivelyIn, allowIn, allowInFile, allowUntil}
    use Names.{Fn, Eff, Mod}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.functions(List#{
            disallowFunction({ id = "clock", path = Fn.Java_lang_System_currentTimeMillis,
                reason = "the time is an argument; only Main reads the clock" })
                |> transitivelyIn(Mod.Now)
                |> allowIn(Fn.Now_real, "the one value of the real clock")
        }),
        Flixlint.effectsTogether(List#{
            disallowEffectsTogether({ id = "io-in-tx", effects = Set#{Eff.Db}, withEffects = Set#{Eff.ObjectStore, Eff.Net_Http},
                reason = "waiting on the network inside a Tx keeps the connection borrowed" })
                |> allowUntil(Fn.Assets_confirm, "2026-12-31", "split into two transactions (#123)")
        }),
        Flixlint.handlers(List#{
            disallowHandler({ id = "handler-site", effect = Eff.Session, reason = "the runner installs it" })
                |> transitivelyIn(Mod.Session)
                |> allowInFile("src/app/DbRunner.flix", "the runner")
        }),
        Flixlint.custom("schema-guard", schemaGuard)
    })

    def schemaGuard(facts: Flixlint.Facts.Facts): List[Flixlint.Violation.Violation] = ...
}
```

`Flixlint.ruleSet` merges the parts; a family that has no entries is simply not written.

### Families

"What" (a function, an effect, a handler, a constructor, a type) times "how" (do not use it, do not use it together
with, keep it out of this place, not with this literal, not inside a lambda passed to this) gives eleven families. Every entry has `id` and `reason`; the fields in the middle are
the family's.

| Family | Record fields | Facts | Says |
|---|---|---|---|
| `disallowFunction` | `path = Fn` | Calls | do not call this (with `transitivelyIn`, nor its wrappers) |
| `disallowCallsTogether` | `functions = Set[Fn], withFunctions = Set[Fn]` | Calls | a function that calls one of A does not call one of B |
| `disallowEffectsTogether` | `effects = Set[Eff], withEffects = Set[Eff]` | EffectOf | a signature does not have an effect of A together with one of B |
| `disallowOtherEffectsWith` | `effect = Eff` | EffectOf | a signature with this effect has no other |
| `disallowEffectsIn` | `files = glob, effects = Set[Eff]` | EffectOf + Def | the functions in these files do not have these effects (`Set#{}`: are pure) |
| `disallowHandler` | `effect = Eff` | Handles | do not install a handler for this effect (with `transitivelyIn`, nor call `X.runWith`) |
| `disallowConstructor` | `constructor = Case` | Constructs | do not build this case (with `transitivelyIn`, nor call a pub function that does) |
| `disallowCallInLambdaOf` | `function = Fn, inLambdaOf = Set[Fn]` | CallsInLambdaArgOf + Def | do not call this inside a lambda passed to one of these (`List.map(x -> f(x), xs)`, `List.map(f, xs)`); `inFiles(glob)` limits where |
| `disallowCallWithArg` | `function = Fn, argIndex = Int32, values = Set[String]` | ArgLit + StrLit | do not call this with one of these string literals at that argument; `valuesFromLiteralsIn(Fn.X)` adds the literals of `X`'s body |
| `disallowCaseArgType` | `ofEnum = Enum, argType = Type` | CaseTypeAll | no case of this enum has this type in a field (`ApiId` or `List[ApiId]`) |
| `disallowDependency` | `files = glob, module = Mod` | Calls + Constructs + ArgTypeAll + RetTypeAll + CaseTypeAll | the functions in these files neither call this module (or its submodules), nor build its cases, nor have its types in a parameter or the return type; the enums declared there have none in a case |

Effect sets are expanded through type aliases on both sides: `Eff.Db` in a rule means the members of the alias `Db`,
and a signature written `\ AdminEff` is seen as the members of `AdminEff`.

The judgments, one sentence each (`rules/Flixlint/Engine.flix`):

```
disallowFunction:         Calls(caller, callee), callee = path or callee ∈ wrappers(path), caller not on the way to path
disallowCallsTogether:    caller calls one of functions and one of withFunctions (reported at the withFunctions call)
disallowEffectsTogether:  EffectOf(fn) ∩ effects ≠ ∅ and EffectOf(fn) ∩ withEffects ≠ ∅
disallowOtherEffectsWith: effect ∈ EffectOf(fn) and EffectOf(fn) ≠ {effect}
disallowEffectsIn:        Def(fn).file matches files and EffectOf(fn) ∩ effects ≠ ∅ (effects = {}: EffectOf(fn) ≠ {})
disallowHandler:          Handles(fn, effect), or a call to a pub function of the transitivelyIn modules that reaches one
disallowConstructor:      Constructs(fn, case), or a call to a pub function of the transitivelyIn modules that reaches one
disallowCallInLambdaOf:   CallsInLambdaArgOf(caller, function, outer), outer ∈ inLambdaOf, Def(caller).file matches files
disallowCallWithArg:      ArgLit(caller, function, argIndex, text), text ∈ values ∪ StrLit(valuesFrom)
disallowCaseArgType:      CaseTypeAll(enum, case, argType), reported at the enum's declaration
disallowDependency:       Def(caller).file matches files, and the callee, a built case, a parameter or return type (nested) is in module; or an enum declared in files has such a case type
wrappers(x, mods):        the pub functions of mods that reach x through Calls (a fixpoint over the calls)
```

### Chained after an entry

| Function | Meaning |
|---|---|
| `inFiles(glob)` | Only the functions of the files matching the glob are judged (`disallowCallInLambdaOf`; the default is `**`). |
| `valuesFromLiteralsIn(Fn.X)` | The string literals in the body of `X` count as `values` (`disallowCallWithArg`), so a list the sources keep in one function is not copied into the rule. Repeatable. |
| `transitivelyIn(Mod.X)` | The pub functions of `X` that reach the disallowed thing through calls count as the thing itself (`Clock.today` calling `Clock.nowMillis` calling the clock). Computed from the facts on every run, so a new entry in `X` needs no rule change. Repeatable. Available on `disallowFunction`, `disallowHandler` and `disallowConstructor`. |
| `allowIn(Fn.X, reason)` | Violations inside `X` are not reported. |
| `allowInFile(path, reason)` | Violations in that file (the path as given to flixlint) are not reported; the only allow for a violation on an enum declaration. |
| `allowUntil(Fn.X, "YYYY-MM-DD", reason)` | `allowIn` until the date; after it the violation is reported again, with a note that the allow has expired. The ratchet for a rule that is being introduced. |

An allow is part of the entry, so the reason sits next to the rule and the whole set of exceptions is read off the
rule. Because the target is a generated enum, an allow of a function that was renamed or removed fails to compile;
an allow that compiles but covers no violation is reported (`flixlint: rule clock: allowIn(Fn.Report_title) matches
nothing (remove it)`) and the exit code is 2. There is no allow written in the code itself: Flix has no user
attributes, and a comment would be a string the linter would have to parse.

### Custom rules

What the families cannot say is written against the facts, in the same rule set:

```flix
Flixlint.custom("schema-guard", facts ->
    let mutating = Flixlint.Facts.defs(facts)
        |> List.filter(d -> d#module == Mod.ContentTypes and Flixlint.Facts.argType(facts, d#fn, 0) == Some(Type.Session_Granted))
        |> List.map(d -> d#fn) |> List.toSet;
    Flixlint.Facts.calls(facts)
        |> List.filter(c -> Set.memberOf(c#callee, mutating))
        |> List.filter(c -> Flixlint.Facts.defOf(facts, c#caller) |> Option.exists(d -> Flixlint.Glob.matches("src/admin/**", d#file)))
        |> List.filter(c -> not Flixlint.Facts.callsTo(facts, c#caller, Fn.SchemaGuard_guarded))
        |> List.map(c -> Flixlint.Violation.atCall(facts, "schema-guard", c, "schema changes go through SchemaGuard.guarded")))
```

`Flixlint.Facts` gives the relations as lists of records (`defs`, `calls`, `handles`, `constructs`, `callsInLambda`,
`argLits`, `argCalls`, `pipedInto`, `strLits`, `argTypes`, `argTypesAll`, `caseTypes`, `caseTypesAll`, `enums`, `effects`)
and the lookups (`defOf`, `callsFrom`, `callsTo`, `effectOf`, `argType`, `argTypesAllOf`, `retType`, `retTypesAllOf`,
`strLitsIn`, `expandEffects`, `fnName`, `isIn`); `Flixlint.Violation` builds violations (`atCall`, `atDef`, `inBody`,
`atDeclaration`, `withPath`, `withNote`); `Flixlint.Glob.matches(pattern, path)` is the glob of `files` (`*` stays
inside one path segment, `**` crosses segments, `{a,b}` is either alternative).

A custom rule takes allows like any entry when it is written as `customRule({ id = ..., check = ... })` chained with
`allowIn` / `allowInFile` / `allowUntil` and lifted with `Flixlint.customs(List#{...})`; `Flixlint.custom(id, check)` is the
short form without allows.

## Facts

The shim (`shim/Facts.scala`) writes one TSV per relation into the facts directory and `Names.flix` next to the
engine's sources. `fn`, `callee`, `eff`, `case`, `enum` and `tycon` are qualified the way the compiler qualifies
symbols: `Session.grant`, `Session.Granted.Granted` (enum cases carry their enum), `Net.Http` (an effect declared
inside `mod Net.Http`), `java.lang.System.currentTimeMillis` (Java interop; constructors are `pkg.Class.<init>`).
`file` is the path as given on the command line.

| Relation | Columns | Meaning |
|---|---|---|
| `Def` | `fn, name, mod, file, line, pub` | A top-level or instance definition; `name` is the unqualified name, `pub` is `true`/`false`. Definitions the compiler makes up (derived instances, `Eq.eq$123`) are left out. |
| `Calls` | `caller, callee, line` | A call inside the body of `caller` (lambdas and local defs count as the enclosing def). Def, trait signature, effect operation and Java calls alike; a function passed by name counts as a call. |
| `EffectOf` | `fn, eff` | One effect of the signature, type aliases expanded (`\ Db` with `Db = DbRead + DbWrite` gives two rows). |
| `EffAlias` | `alias, eff` | The members of an effect type alias (project, packages and stdlib), for expanding the effects named in a rule. |
| `Handles` | `fn, eff, line` | `run ... with handler Eff` inside the body of `fn`. |
| `Constructs` | `fn, case, line` | An enum case built inside the body of `fn` (an expression; a pattern that takes a case apart is not one). |
| `CallsInLambdaArgOf` | `caller, callee, outer, line` | A call to `callee` inside a lambda passed as an argument to `outer`, in the body of `caller` (`List.map(x -> callee(x), xs)`); one row per enclosing `outer`. A function passed by name (`List.map(callee, xs)`) and a partial application (`List.map(callee(a), xs)`) count as a lambda: the desugarer turns them into `let t = ...; x -> callee(t, x)`, and the shim reads a let-bound argument as the expression it stands for. |
| `ArgLit` | `caller, callee, index, text, line` | A string literal as the `index`-th argument of a call to `callee`. |
| `ArgCall` | `caller, callee, index, argCallee, line` | A call to `argCallee` (or a partial application of it) as the `index`-th argument of a call to `callee`. |
| `PipedInto` | `caller, source, target, line` | In a `|>` chain, the result of `source` reaches `target` through any number of stages (`a() |> f |> g(x)` gives a→f, a→g, f→g); `line` is the line of `target`. A lambda inside a stage is not part of the chain. |
| `StrLit` | `fn, text, line` | A string literal in the body of `fn` (the pieces of an interpolated string too). |
| `ArgType` | `fn, index, tycon` | Head type constructor of the `index`-th parameter (`Session.Granted`, `List`, `Str`, `Arrow(2)`, `?` for a type variable). |
| `ArgTypeAll` | `fn, index, tycon` | Every type constructor in the `index`-th parameter, nested ones included (`List[ApiId]` gives `List` and `ApiId`; an alias is listed by its own name and its arguments; type variables and record rows are left out). |
| `RetType` / `RetTypeAll` | `fn, tycon` | The head type constructor of the return type / every one in it. |
| `CaseType` / `CaseTypeAll` | `enum, case, index, tycon` | The head type constructor of the `index`-th field of an enum case / every one in it. |
| `Enum` / `Eff` | `name, mod, file, line, pub` | Where an enum / an effect is declared. |

Definitions coming from packages and the standard library are not listed in `Def` (only project sources are), but they
appear as callees, effects and types, and they are in `Names.flix`: `Fn` holds every function the sources could call
(project, packages, stdlib, and the Java methods the sources do call), so a rule can disallow a function nobody calls
yet. On a 227-file project that is about 10,600 `Fn` cases; the enums derive `Eq, Order` and not `ToString`, because
deriving `ToString` on an enum of that size takes the compiler minutes (80 s at 3,000 cases against 6 s without), and
the tables from case to name are split into chunks because one list literal of ten thousand tuples is a JVM method too
large to compile.

## Layout

```
flix.toml                    the package metadata (name, version, the Flix version the shim is compiled against)
Makefile                     test / test-resolved / shim / clean / release
bin/flixlint                 the command: shim -> facts + Names.flix, engine jar -> violations
bin/flix-jar                 where the compiler jar is, when neither --flix-jar nor FLIX_JAR says
shim/Facts.scala             AST -> TSV facts and Names.flix (typed stage, and the resolved stage that stops before the typer)
rules/Flixlint.flix          what a rule file uses: the family records and builders, transitivelyIn / allowIn / allowInFile / allowUntil, ruleSet
rules/Flixlint/Facts.flix    the facts loaded from the TSV, and the lookups custom rules use
rules/Flixlint/Engine.flix   the judgments, the allows, the report and the exit code
rules/Flixlint/Violation.flix  the violation record and how it is rendered
rules/Flixlint/Glob.flix     the glob of `files`
test/fixture/                a 7-file project that violates every family and three custom rules; test/run.sh checks the report
```

`make test` runs the test (`make test-resolved`, or `FLIXLINT_STAGE=resolved test/run.sh`, runs it at the resolved
stage). The fixture is a project of its own; nothing outside this repository is needed to run it.

## Notes and limits

- Names are matched exactly as the compiler qualifies them. When a rule does not hit what you expect, look at the
  facts TSV (`grep Http build/flixlint/facts/effect_of.tsv`) or at `build/flixlint/engine/src/Names.flix`.
- `Fn` has the functions the sources could call; it does not have Java methods the sources never call, so a Java
  method can be disallowed only once something calls it.
- `PipedInto` follows one `|>` chain. A parse inside a lambda of a stage (`Option.flatMap(t -> parse(t) |> Result.toOption) |> Option.getWithDefault(d)`)
  does not reach the chain's later stages; the lambda's body is its own chain.
- A let-bound expression is read where its variable is first used as an argument; a variable used as an argument twice is
  walked once, at the first use.
- The resolved stage does not see Java instance-method calls (`x.foo()`); static calls and constructors are the same at
  both stages. The two stages generate different `Names.flix`, so switching stage rebuilds the engine.
- The shim depends on the compiler's internal AST (`ca.uwaterloo.flix.language.ast.*`) and on two private members of
  `Flix` for the resolved stage. A compiler upgrade is a change to `shim/Facts.scala` only; the rules and the TSV
  contract do not move.
