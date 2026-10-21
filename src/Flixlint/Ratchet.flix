///
/// The ratchet: a rule whose id has a limit in the limits file (`--limits FILE`) is judged by how many violations it
/// has, not one by one. At the limit it passes and prints nothing; above it, the violations are reported with a line
/// that says by how much; below it, the run fails until the limit is lowered to the count, so a violation that was
/// fixed cannot come back unnoticed.
///
/// The limits file is JSON: `{ "note": "...", "limits": { "<rule id>": <count>, ... } }`; a count that went up against
/// `--limits-base` is written `{ "limit": <count>, "raiseReason": "why" }`. Other top-level keys are
/// left to the project (a note on why, how to list the violations).
///
pub mod Flixlint.Ratchet {
    use Flixlint.Violation.Violation
    use Util.Json.Json
    use Util.Json.Json.{JNumber, JObject, JString}

    /// One limit: the rule `id` may have at most `limit` violations. `raiseReason` says why the limit went up against the
    /// base limits (`--limits-base`); a limit written as a bare count has none.
    pub type alias Limit = { id = String, limit = Int32, raiseReason = Option[String] }

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
        let count = n -> match BigDecimal.tryToInt32(n) {
            case Some(limit) if limit >= 0 => Ok(limit)
            case _ => Err("${path}: the limit of ${id} is not a count")
        };
        match value {
            case JNumber(n) => count(n) |> Result.map(limit -> { id = id, limit = limit, raiseReason = None })
            case JObject(fields) => match (Map.get("limit", fields), Map.get("raiseReason", fields)) {
                case (Some(JNumber(n)), Some(JString(why))) => count(n) |> Result.map(limit -> { id = id, limit = limit, raiseReason = Some(why) })
                case (Some(JNumber(n)), None) => count(n) |> Result.map(limit -> { id = id, limit = limit, raiseReason = None })
                case _ => Err("${path}: the limit of ${id} is a count, or { \"limit\": <count>, \"raiseReason\": \"why\" }")
            }
            case _ => Err("${path}: the limit of ${id} is not a number")
        }

    /// The limits that went up against `base` (the limits of the branch the work goes into, e.g. origin/master's):
    /// a limit above its base fails the run unless it gives a `raiseReason`, and a `raiseReason` on a limit that is not
    /// above its base (or has no base) fails too, so the reason does not stay behind once the limit is back down.
    /// A rule the base does not have is new and has nothing to be compared with.
    pub def raised(path: String, basePath: String, limits: List[Limit], base: List[Limit]): List[String] =
        let baseOf = base |> List.map(b -> (b#id, b#limit)) |> List.toMap;
        limits |> List.filterMap(l -> match (Map.get(l#id, baseOf), l#raiseReason) {
            case (Some(b), None) if l#limit > b =>
                Some("flixlint: ratchet ${l#id}: the limit went up from ${b} to ${l#limit} against ${basePath}; lower it to ${b}, or write it as { \"limit\": ${l#limit}, \"raiseReason\": \"why\" } in ${path}")
            case (Some(b), Some(_)) if l#limit <= b =>
                Some("flixlint: ratchet ${l#id}: raiseReason is given, but the limit ${l#limit} is not above ${b} in ${basePath} (remove raiseReason from ${path})")
            case (None, Some(_)) =>
                Some("flixlint: ratchet ${l#id}: raiseReason is given, but ${basePath} has no limit for it (remove raiseReason from ${path})")
            case _ => None
        })

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
