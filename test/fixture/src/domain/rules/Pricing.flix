mod Pricing {
    pub def priceOf(seats: Int32): Int32 = seats * 100

    pub def discountOf(seats: Int32): Int32 = if (seats > 10) 10 else 0

    pub def splitOf(pair: (Int32, Int32)): Int32 = let (a, b) = pair; a + b

    pub def bandOf(seats: Int32): Int32 = match seats {
        case n if n > 10 => 2
        case _ => 1
    }

    /// One rule, but a match the source wrote (its rule sits at its `case`): flat-rules counts it, unlike `let (a, b)`.
    pub def sumOf(pair: (Int32, Int32)): Int32 = match pair {
        case (a, b) => a + b
    }

    /// The guard of a `forM` is an `if` to the compiler.
    pub def bigOf(seats: List[Int32]): List[Int32] = forM (s <- seats; if s > 10) yield s

    pub def tierOf(t: #| Gold(Int32), Free |#): Int32 = ematch t {
        case Gold(n) => n
        case Free => 0
    }

    pub def priceFromDb(plan: String): Int32 \ Db =
        String.length(Db.exec("select price ${plan}"))
}
