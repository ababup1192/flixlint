pub mod Flixlint.Glob {
    /// Whether `path` matches the glob `pattern`: `*` stays inside one path segment, `**` crosses segments,
    /// `{a,b}` is either alternative (`src/{api,app}/**`).
    pub def matches(pattern: String, path: String): Bool =
        expand(pattern) |> List.exists(p -> go(String.toList(p), String.toList(path)))

    /// The patterns without braces a pattern stands for: the first `{...}` is split on `,` and each alternative is expanded in turn.
    def expand(pattern: String): List[String] =
        match (String.indexOf(substr = "{", pattern), String.indexOf(substr = "}", pattern)) {
            case (Some(open), Some(close)) if open < close =>
                let before = String.takeLeft(open, pattern);
                let after = String.dropLeft(close + 1, pattern);
                String.slice(start = open + 1, end = close, pattern)
                    |> String.splitOn(substr = ",")
                    |> List.flatMap(alternative -> expand("${before}${alternative}${after}"))
            case _ => pattern :: Nil
        }

    def go(p: List[Char], s: List[Char]): Bool = match (p, s) {
        case (Nil, Nil) => true
        case (Nil, _ :: _) => false
        case ('*' :: '*' :: '/' :: pr, _) => go(pr, s) or (match s { case Nil => false case _ :: sr => go(p, sr) })
        case ('*' :: '*' :: pr, _) => go(pr, s) or (match s { case Nil => false case _ :: sr => go(p, sr) })
        case ('*' :: pr, Nil) => go(pr, Nil)
        case ('*' :: pr, c :: sr) => go(pr, s) or (c != '/' and go(p, sr))
        case (_ :: _, Nil) => false
        case (c :: pr, d :: sr) => c == d and go(pr, sr)
    }
}
