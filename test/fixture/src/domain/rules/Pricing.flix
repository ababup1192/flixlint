mod Pricing {
    pub def priceOf(seats: Int32): Int32 = seats * 100

    pub def discountOf(seats: Int32): Int32 = if (seats > 10) 10 else 0

    pub def splitOf(pair: (Int32, Int32)): Int32 = let (a, b) = pair; a + b

    pub def bandOf(seats: Int32): Int32 = match seats {
        case n if n > 10 => 2
        case _ => 1
    }

    pub def priceFromDb(plan: String): Int32 \ Db =
        String.length(Db.exec("select price ${plan}"))
}
