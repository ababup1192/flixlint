pub mod Flixlint.Glob {
    /// Whether `path` matches the glob `pattern`: `*` stays inside one path segment, `**` crosses segments,
    /// `{a,b}` is either alternative (`src/{api,app}/**`).
    pub def matches(pattern: String, path: String): Bool =
        expand(pattern) |> List.exists(p -> go(String.toList(p), String.toList(path)))

    /// The patterns without braces a pattern stands for: the first `{...}` is replaced by each of its alternatives in
    /// turn, and what comes out is expanded again, so a nested group (`src/{a,{b,c}}/**`) is expanded too.
    def expand(pattern: String): List[String] =
        match String.indexOf(substr = "{", pattern) {
            case None => pattern :: Nil
            case Some(open) => match closeOf(String.toList(pattern) |> List.drop(open), open, 0) {
                case None => pattern :: Nil
                case Some(close) =>
                    let before = String.takeLeft(open, pattern);
                    let after = String.dropLeft(close + 1, pattern);
                    String.slice(start = open + 1, end = close, pattern)
                        |> alternatives
                        |> List.flatMap(alternative -> expand("${before}${alternative}${after}"))
            }
        }

    ///
    /// The index of the `}` closing the `{` that `cs` starts at, `i` being that `{`'s index in the whole pattern.
    ///
    /// WhyNot: not the first `}` of the pattern. `src/{a,{b,c}}/**` would be cut at the inner one and the
    /// alternatives would come out as `a` and `{b`, matching nothing while the rule looks like it is applied.
    ///
    def closeOf(cs: List[Char], i: Int32, depth: Int32): Option[Int32] = match cs {
        case Nil => None
        case '{' :: rest => closeOf(rest, i + 1, depth + 1)
        case '}' :: _ if depth == 1 => Some(i)
        case '}' :: rest => closeOf(rest, i + 1, depth - 1)
        case _ :: rest => closeOf(rest, i + 1, depth)
    }

    /// The alternatives of a group: the commas outside every nested group split it.
    def alternatives(inner: String): List[String] =
        let cuts = topCommas(String.toList(inner), 0, 0);
        let starts = 0 :: List.map(c -> c + 1, cuts);
        let ends = cuts ::: (String.length(inner) :: Nil);
        List.zip(starts, ends) |> List.map(match (lo, hi) -> String.slice(start = lo, end = hi, inner))

    def topCommas(cs: List[Char], i: Int32, depth: Int32): List[Int32] = match cs {
        case Nil => Nil
        case '{' :: rest => topCommas(rest, i + 1, depth + 1)
        case '}' :: rest => topCommas(rest, i + 1, depth - 1)
        case ',' :: rest if depth == 0 => i :: topCommas(rest, i + 1, depth)
        case _ :: rest => topCommas(rest, i + 1, depth)
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
