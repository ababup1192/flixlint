/// The shapes test-makers counts in internet_dungeon (builder-shapes): a non-test def returning a record, a local def
/// without a return type, a lambda with a written parameter type, and a record update from a variable.
mod Builders {
    @Test
    def testNothingToCheck(): Unit = ()

    pub def fresh(): { n = Int32 } = { n = 1 }

    pub def bumped(r: { n = Int32 }): { n = Int32 } = { n = r#n + 1 | r }

    pub def twice(x: Int32): Int32 =
        def go(y) = y * 2;
        go(x)

    pub def thrice(x: Int32): Int32 =
        def go(y: Int32): Int32 = y * 3;
        go(x)

    pub def plusOne(xs: List[Int32]): List[Int32] = List.map((y: Int32) -> y + 1, xs)

    pub def plusTwo(xs: List[Int32]): List[Int32] = List.map(y -> y + 2, xs)
}
