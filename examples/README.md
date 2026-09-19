# A rule set you can run

`src/` is a six-file project with a `Db` effect, an `Http` effect and a wall clock; `rules.flix` is four rules
against it — three families and one custom rule — and every one of them has a violation to report.

```bash
cd examples
../bin/flixlint --rules rules.flix --today 2026-09-19 src
```

```
src/Orders.flix:5: clock: Orders.receipt: calls Clock.today
src/Orders.flix:7: find-reads-only: Orders.findAndNotify: has Http in its signature
src/Orders.flix:7: io-in-tx: Orders.findAndNotify: has Db and Http in its signature
src/Reports.flix:6: db-handler: Reports.preview: installs a handler for Db
```

What each rule shows:

| Rule | Family | Shows |
|---|---|---|
| `clock` | `disallowFunction` | `transitivelyIn(Mod.Clock)` makes `Clock.today` count as the clock it wraps, and `allowIn` keeps the one place that reads it |
| `io-in-tx` | `disallowEffectsTogether` | two effects that must not meet in one signature, and `allowUntil` as the ratchet for the one that is not split yet |
| `db-handler` | `disallowHandler` | `allowInFile` for the runner that installs the handler |
| `find-reads-only` | `customRule` | what the families cannot say, written against the facts |

`--today` is fixed so the report does not change when the `allowUntil` date passes; a real project leaves it off.
`test/run.sh` runs this and compares the report with `test/expected-examples.txt`, so the example cannot go stale.
