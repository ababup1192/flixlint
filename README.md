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

The project to lint is an ordinary Flix project; an empty one is `java -jar flix.jar init` in an empty directory.

You need a JDK and the Flix compiler jar of the version in `flix.toml` (`flix = "0.76.0"`). Download `flix.jar`
from [Flix's GitHub releases](https://github.com/flix/flix/releases) and pass it with `--flix-jar` or `FLIX_JAR`.
With neither, `bin/flix-jar` looks for a `flix` on `PATH` and takes the `share/java/flix/flix.jar` next to it, and
falls back on the author's devbox (`~/Desktop/flix_game_engine`, moved with `FLIXLINT_ENGINE_ROOT`) last.

The Scala shim is built once, on first use and whenever `shim/*.scala` changes, into `build/flixlint-shim.jar`.
That needs `scala-cli`: `devbox.json` has it, and a `scala-cli` on `PATH` is used when there is no devbox. If you
have neither, take `flixlint-shim-<flix version>.jar` from the release and pass it with `--shim` or `FLIXLINT_SHIM`
(`make release` is what attaches it). The jar holds only flixlint's own classes, compiled against the compiler's
internal AST, so one jar per Flix version serves every machine and every project.

```bash
make test            # lint test/fixture and examples/, diff the reports against test/expected*.txt
make test-resolved   # the same at the resolved stage
make shim            # rebuild build/flixlint-shim.jar
```

`make test` is also the type check of the rule engine: `src/Flixlint*.flix` only compiles together with a generated
`Names.flix`, so running a project through is the only way to compile it. This repository therefore has no
`flix check` of its own — `test/` holds a fixture that must not compile (`rules/broken.flix` names a function the
sources do not have), which is exactly what the test asserts.

## Using it from your project

Keep one file in your project — the rules — and call flixlint with the compiler jar:

```make
lint:
	../flixlint/bin/flixlint --flix-jar /path/to/flix.jar --rules lint/rules.flix --stage resolved src
```

The dependencies need no argument. When neither `--pkg` nor `--jar` is given, flixlint reads your `flix.toml` with
the compiler's own `ManifestParser` and passes the versions it names out of `lib/`, where the compiler has unpacked
them: `lib/github/<owner>/<name>/<version>/` for a Flix package (its own manifest is read there too, so a package's
own dependencies come along), `lib/external/` for a `[jar-dependencies]` jar, and every jar under `lib/cache/` for
`[mvn-dependencies]`. Nothing is downloaded. The project is the nearest directory with a `flix.toml` at or above the
sources, never above the current directory; `--project-root DIR` names it when that is not where it is. A project
with no dependencies gets nothing and needs nothing, and `--pkg` / `--jar` override the whole thing. Either way the
packages have to be there: sources that `flix check` accepts fail here with a Resolution Error and exit code 3 when
they are missing, so run `flix check` once before the first lint.

Your rule file names things through the generated module, so it starts with
`use Flixlint.Names.{Fn, Eff, Mod, Case, Enum, Type}` (up to flixlint 0.1.0 that module was the top-level `Names`;
upgrading is that one `use` line, and the case names inside `Fn` / `Eff` / `Mod` / `Case` / `Enum` / `Type` are
unchanged).

Nothing else of flixlint has to live in your repository: the engine, the shim and the
`Names` enums are all built under `--build-dir` (default `build/flixlint`), which belongs in `.gitignore`.

### Why it is not an fpkg

`flix build-pkg` puts `flix.toml`, `README.md`, `LICENSE.md` and `src/**/*.flix` into the package and nothing else —
a jar or a resource file under `src/` is dropped, and so is everything outside `src/`. So neither `bin/flixlint` nor
the shim jar can travel in an fpkg. On top of that, `src/Flixlint*.flix` refers to the generated `Flixlint.Names`
module, so
as a package it would not compile in the consumer's project at all — and it has no business being compiled into the
consumer's program, since only the throwaway rule-engine project that `bin/flixlint` generates ever uses it.

Flix does have `[jar-dependencies]` (`"name.jar" = "url:https://..."`, downloaded into `lib/external/`), and it is
applied to transitive manifests too, but it delivers a jar to the consumer's *compile* classpath, which is not where
the shim runs: the shim runs on the compiler jar's classpath inside `bin/flixlint`. Hence the release asset.

## Usage

```
bin/flixlint [--flix-jar JAR] --rules PATH/rules.flix [--pkg FPKG]... [--jar JAR]... [--stage typed|resolved]
             [--today YYYY-MM-DD] [--facts-out DIR] [--build-dir DIR] [--project-root DIR] [--shim JAR]
             [--java-opts "..."] SRC...
bin/flixlint --version
```

| Option | Meaning |
|---|---|
| `--flix-jar JAR` | The Flix compiler (`flix.jar`, 0.76.0). `FLIX_JAR` in the environment works too; with neither, `bin/flix-jar` resolves it. |
| `--rules PATH/rules.flix` | The rule file: a Flix module with `pub def rules(): Flixlint.RuleSet` (see below). |
| `--pkg FPKG` / `--jar JAR` | Dependencies the sources need (`lib/**/*.fpkg`, `lib/cache/**/*.jar`). Repeatable. With neither, they are read from the project's `flix.toml`. |
| `--project-root DIR` | The directory whose `flix.toml` names the dependencies (default: the nearest one at or above the sources, within the current directory). |
| `--stage typed` (default) | Facts from the typed AST (`Flix.check()`): everything below, including compile errors. |
| `--stage resolved` | Facts from the AST right after name resolution, before kinding and typing. Several times faster; the same facts except Java instance-method calls (the receiver's class is not known yet). |
| `--today YYYY-MM-DD` | The date `allowUntil` is compared with (default: the real date). Tests fix it. |
| `--facts-out DIR` | Where the TSV facts go (default `BUILD/facts`). Keep them: they are the easiest way to look up a qualified name. |
| `--build-dir DIR` | Working directory for the facts and the rule engine (default `build/flixlint`), relative to the current directory. |
| `--shim JAR` | A prebuilt shim jar, instead of building one with `scala-cli`. `FLIXLINT_SHIM` works too. |
| `--version` | The version in `flix.toml`. |
| `SRC...` | Source directories or files, relative to the current directory. File paths in violations and in `allowInFile` are relative to that directory too. |

Exit codes: `0` no violation, `1` violations, `2` the rules are wrong (the rule file does not compile, an allow that
covers nothing, an `allowInFile` of a file that is not among the sources), `3` the sources do not compile, `4` the
call or the environment is wrong (an option flixlint does not know, no `flix.jar`, no `scala-cli` and no `--shim`, a
dependency that is not unpacked, a crash in the fact walker). `2` and `3` are what your sources and rules say; `4`
never is, so a `4` in CI is a broken setup rather than a lint finding.

A violation is a `file:line:` header editors pick up, then the rule's reason, the path through the wrappers when
`transitivelyIn` found it, and how to get rid of it:

```
src/Report.flix:14: clock: Report.title: calls Wall.today
    the real clock is read where Main builds the clock; everything else takes the time as an argument
    Wall.today -> Wall.nowMillis -> java.lang.System.currentTimeMillis
    fix it, or add |> allowIn(Fn.Report_title, "reason") to rule clock
```

Violations are sorted by file, line and rule id, so the report is the same on every run.

The rule engine is a Flix program made of the `src/Flixlint` library, the generated `Names.flix`, your rule file and
a generated `main`; `bin/flixlint` compiles it into a jar with the same compiler and rebuilds it only when one of those
changes (measured on a 227-file project: the engine builds in about 16 s, then a run costs the facts plus 3 s).

## Writing rules

A rule file is a Flix module with one `pub def rules(): Flixlint.RuleSet`. Entries are grouped by family, each group
goes into its family's lifting function, and `Flixlint.ruleSet` merges the groups:

```flix
Flixlint.ruleSet(List#{
    Flixlint.functions(List#{ ... }),
    Flixlint.effectsTogether(List#{ ... }),
    Flixlint.handlers(List#{ ... }),
    Flixlint.customs(List#{ ... })
})
```

Each entry is a record with `id`, what is disallowed, and `reason`; the functions chained after it add what the entry needs and nothing else. Names come from
the generated `Flixlint.Names` module (`use Flixlint.Names.{Fn, Eff, Mod, Case, Enum, Type}`):
`Fn.Auth_permit`, `Eff.Net_Http`, `Mod.Clock`, `Case.Column_Column`,
`Enum.Predicate`, `Type.ColumnName` (the qualified name with every character that is not a letter or a digit replaced by
`_` and the first letter upper-cased; `java.lang.System.currentTimeMillis` is `Fn.Java_lang_System_currentTimeMillis`,
the root module is `Mod.Root`). To find a name, run flixlint once and grep the file it generates:
`grep Auth_ build/flixlint/engine/src/Flixlint/Names.flix`. That file sits under `--build-dir`, outside your source
path, so the editor does not complete it.

[`examples/rules.flix`](examples/rules.flix) is a complete rule file — `disallowFunction` with `transitivelyIn`
and `allowIn`, `disallowEffectsTogether` with `allowUntil`, `disallowHandler` with `allowInFile`, and a custom rule —
against the six-file project in [`examples/src`](examples/src). `examples/README.md` shows the report it produces,
and `make test` diffs that report, so the example is never out of date. Read it first; the reference follows.

A family with no entries is simply left out of the list.

### Families

"What" (a function, an effect, a handler, a constructor, a type) times "how" (do not use it, do not use it together
with, keep it out of this place, not with this literal, not inside a lambda passed to this) gives eleven families. Every entry has `id` and `reason`; the fields in the middle are
the family's.

| Family | Lifted with | Record fields | Facts | Says |
|---|---|---|---|---|
| `Flixlint.disallowFunction` | `Flixlint.functions` | `path = Fn` | Calls | do not call this (with `transitivelyIn`, nor its wrappers) |
| `Flixlint.disallowCallsTogether` | `Flixlint.callsTogether` | `functions = Set[Fn], withFunctions = Set[Fn]` | Calls | a function that calls one of A does not call one of B |
| `Flixlint.disallowEffectsTogether` | `Flixlint.effectsTogether` | `effects = Set[Eff], withEffects = Set[Eff]` | EffectOf | a signature does not have an effect of A together with one of B |
| `Flixlint.disallowOtherEffectsWith` | `Flixlint.otherEffectsWith` | `effect = Eff` | EffectOf | a signature with this effect has no other |
| `Flixlint.disallowEffectsIn` | `Flixlint.effectsIn` | `files = glob, effects = Set[Eff]` | EffectOf + Def | the functions in these files do not have these effects (`Set#{}`: are pure) |
| `Flixlint.disallowHandler` | `Flixlint.handlers` | `effect = Eff` | Handles | do not install a handler for this effect (with `transitivelyIn`, nor call `X.runWith`) |
| `Flixlint.disallowConstructor` | `Flixlint.constructors` | `constructor = Case` | Constructs | do not build this case (with `transitivelyIn`, nor call a pub function that does) |
| `Flixlint.disallowCallInLambdaOf` | `Flixlint.callsInLambda` | `function = Fn, inLambdaOf = Set[Fn]` | CallsInLambdaArgOf + Def | do not call this inside a lambda passed to one of these (`List.map(x -> f(x), xs)`, `List.map(f, xs)`); `inFiles(glob)` limits where |
| `Flixlint.disallowCallWithArg` | `Flixlint.callsWithArg` | `function = Fn, argIndex = Int32, values = Set[String]` | ArgLit + StrLit | do not call this with one of these string literals at that argument; `valuesFromLiteralsIn(Fn.X)` adds the literals of `X`'s body |
| `Flixlint.disallowCaseArgType` | `Flixlint.caseArgTypes` | `ofEnum = Enum, argType = Type` | CaseTypeAll | no case of this enum has this type in a field (`ColumnName` or `List[ColumnName]`) |
| `Flixlint.disallowDependency` | `Flixlint.dependencies` | `files = glob, module = Mod` | Calls + Constructs + ArgTypeAll + RetTypeAll + CaseTypeAll | the functions in these files neither call this module (or its submodules), nor build its cases, nor have its types in a parameter or the return type; the enums declared there have none in a case |
| `Flixlint.customRule` | `Flixlint.customs` | `check = Facts -> List[Violation]` | all of them | what the families cannot say (see [Custom rules](#custom-rules)) |

A `use Flixlint.{disallowFunction, disallowHandler, ...}` at the top of the rule file shortens the entry builders;
the lifting functions are written qualified in the examples.

Effect sets are expanded through type aliases on both sides: `Eff.Db` in a rule means the members of the alias `Db`,
and a signature written `\ AdminEff` is seen as the members of `AdminEff`.

The judgments, one sentence each (`src/Flixlint/Engine.flix`):

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

What the families cannot say is written against the facts, in the same rule set; `findReadsOnly` in
[`examples/rules.flix`](examples/rules.flix) is one.

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

The shim (`shim/Facts.scala`) writes one TSV per relation into the facts directory and `Flixlint/Names.flix` next to the
engine's sources. `fn`, `callee`, `eff`, `case`, `enum` and `tycon` are qualified the way the compiler qualifies
symbols: `Auth.permit`, `Auth.Permit.Permit` (enum cases carry their enum), `Net.Http` (an effect declared
inside `mod Net.Http`), `java.lang.System.currentTimeMillis` (Java interop; constructors are `pkg.Class.<init>`).
`file` is the path as given on the command line. A relation with no rows gets no TSV file, so a small project's
facts directory holds fewer files than the table below has rows.

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
| `ArgType` | `fn, index, tycon` | Head type constructor of the `index`-th parameter (`Auth.Permit`, `List`, `Str`, `Arrow(2)`, `?` for a type variable). |
| `ArgTypeAll` | `fn, index, tycon` | Every type constructor in the `index`-th parameter, nested ones included (`List[ColumnName]` gives `List` and `ColumnName`; an alias is listed by its own name and its arguments; type variables and record rows are left out). |
| `RetType` / `RetTypeAll` | `fn, tycon` | The head type constructor of the return type / every one in it. |
| `CaseType` / `CaseTypeAll` | `enum, case, index, tycon` | The head type constructor of the `index`-th field of an enum case / every one in it. |
| `Enum` / `Eff` | `name, mod, file, line, pub` | Where an enum / an effect is declared. |

Definitions coming from packages and the standard library are not listed in `Def` (only project sources are), but they
appear as callees, effects and types, and they are in `Flixlint.Names`: `Fn` holds every function the sources could call
(project, packages, stdlib, and the Java methods the sources do call), so a rule can disallow a function nobody calls
yet. On a 227-file project that is about 10,600 `Fn` cases; the enums derive `Eq, Order` and not `ToString`, because
deriving `ToString` on an enum of that size takes the compiler minutes (80 s at 3,000 cases against 6 s without), and
the tables from case to name are split into chunks because one list literal of ten thousand tuples is a JVM method too
large to compile.

## Layout

```
flix.toml                    the package metadata (name, version, the Flix version the shim is compiled against)
LICENSE.md                   Apache-2.0
.github/workflows/ci.yml     make test and make test-resolved on the Flix release jar
Makefile                     test / test-resolved / shim / clean / release
bin/flixlint                 the command: shim -> facts + Flixlint/Names.flix, engine jar -> violations
bin/flix-jar                 where the compiler jar is, when neither --flix-jar nor FLIX_JAR says
shim/Facts.scala             AST -> TSV facts and Flixlint/Names.flix (typed stage, and the resolved stage that stops before the typer)
src/Flixlint.flix            what a rule file uses: the family records and builders, transitivelyIn / allowIn / allowInFile / allowUntil, ruleSet
src/Flixlint/Facts.flix      the facts loaded from the TSV, and the lookups custom rules use
src/Flixlint/Engine.flix     the judgments, the allows, the report and the exit code
src/Flixlint/Violation.flix  the violation record and how it is rendered
src/Flixlint/Glob.flix       the glob of `files`
examples/                    a six-file project and four rules, small enough to read in a minute
test/fixture/                a 7-file project that violates every family and three custom rules; test/run.sh checks the report
test/expected*.txt           the reports both of them must produce
```

`make test` runs the test (`make test-resolved`, or `FLIXLINT_STAGE=resolved test/run.sh`, runs it at the resolved
stage). Both projects are projects of their own, and their facts and rule engines are built under `build/`, outside
the sources; nothing outside this repository is needed to run them.

## Notes and limits

- Names are matched exactly as the compiler qualifies them. When a rule does not hit what you expect, look at the
  facts TSV (`grep Http build/flixlint/facts/effect_of.tsv`) or at `build/flixlint/engine/src/Flixlint/Names.flix`.
- `Fn` has the functions the sources could call; it does not have Java methods the sources never call, so a Java
  method can be disallowed only once something calls it.
- `PipedInto` follows one `|>` chain. A parse inside a lambda of a stage (`Option.flatMap(t -> parse(t) |> Result.toOption) |> Option.getWithDefault(d)`)
  does not reach the chain's later stages; the lambda's body is its own chain.
- A let-bound expression is read where its variable is first used as an argument; a variable used as an argument twice is
  walked once, at the first use.
- The resolved stage does not see Java instance-method calls (`x.foo()`); static calls and constructors are the same at
  both stages. The two stages generate different `Flixlint.Names`, so switching stage rebuilds the engine.
- The shim depends on the compiler's internal AST (`ca.uwaterloo.flix.language.ast.*`) and on two private members of
  `Flix` for the resolved stage. A compiler upgrade is a change to `shim/Facts.scala` only; the rules and the TSV
  contract do not move.

## License

[Apache-2.0](LICENSE.md).
