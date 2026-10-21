///
/// The ratchet: a rule whose id has a limit in the limits file (`--limits FILE`) is judged by how many violations it
/// has, not one by one. At the limit it passes and prints nothing; above it, the violations are reported with a line
/// that says by how much; below it, the run fails until the limit is lowered to the count, so a violation that was
/// fixed cannot come back unnoticed.
///
/// The limits file is JSON: `{ "note": "...", "limits": { "<rule id>": <count>, ... } }`. Other top-level keys are
/// left to the project (a note on why, how to list the violations).
///
pub mod Flixlint.Ratchet {
    use Flixlint.Violation.Violation
    use Util.Json.Json
    use Util.Json.Json.{JNumber, JObject}

    /// One limit: the rule `id` may have at most `limit` violations.
    pub type alias Limit = { id = String, limit = Int32 }

    /// What the ratchet leaves of the judged violations: the ones to report, the lines that fail the run (exit 1)
    /// and the errors in the limits file (exit 2, like any other mistake in the rules).
    pub type alias Outcome = { violations = List[Violation], failures = List[String], errors = List[String] }

    /// The limits in the text of the limits file `path`, or why they cannot be read.
    pub def parse(path: String, text: String): Result[String, List[Limit]] =
        match Util.Json.parse(text) {
            case Err(e) => Err("${path}: not JSON (${e})")
            case Ok(JObject(top)) => match Map.get("limits", top) {
                case Some(JObject(limits)) =>
                    Map.toList(limits) |> List.map(limitOf(path)) |> List.sequence
                case _ => Err("${path}: needs a \"limits\" object (rule id -> count)")
            }
            case Ok(_) => Err("${path}: needs a JSON object at the top")
        }

    def limitOf(path: String, entry: (String, Json)): Result[String, Limit] =
        let (id, value) = entry;
        match value {
            case JNumber(n) => match BigDecimal.tryToInt32(n) {
                case Some(limit) if limit >= 0 => Ok({ id = id, limit = limit })
                case _ => Err("${path}: the limit of ${id} is not a count")
            }
            case _ => Err("${path}: the limit of ${id} is not a number")
        }

    /// Applies the limits to the judged violations. `ruleIds` are the ids the rule set has: a limit for an id that
    /// is not among them is an error, so that a renamed or removed rule does not leave a limit that checks nothing.
    pub def apply(path: String, limits: List[Limit], ruleIds: Set[String], violations: List[Violation]): Outcome =
        let counts = List.foldLeft((acc, v) -> Map.insertWith(Add.add, v#id, 1, acc), Map.empty(), violations);
        let ratcheted = limits |> List.map(l -> l#id) |> List.toSet;
        let overIds = limits |> List.filter(l -> Map.getWithDefault(l#id, 0, counts) > l#limit) |> List.map(l -> l#id) |> List.toSet;
        let kept = violations |> List.filter(v -> not Set.memberOf(v#id, ratcheted) or Set.memberOf(v#id, overIds));
        let failures = limits |> List.filterMap(l ->
            let n = Map.getWithDefault(l#id, 0, counts);
            if (n > l#limit)
                Some("flixlint: ratchet ${l#id}: ${n} violations, the limit is ${l#limit} (${n - l#limit} new; they are listed above)")
            else if (n < l#limit)
                Some("flixlint: ratchet ${l#id}: ${n} violations, the limit is ${l#limit}; lower the limit to ${n} in ${path}")
            else None);
        let errors = limits |> List.filter(l -> not Set.memberOf(l#id, ruleIds))
            |> List.map(l -> "flixlint: ratchet ${l#id}: no rule has this id (remove it from ${path})");
        { violations = kept, failures = failures, errors = errors }
}
