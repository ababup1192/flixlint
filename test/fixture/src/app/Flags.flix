/// Bool literals passed straight to a function (bool-arg): `page` passes `true`, `quiet` passes `not false` (seen through).
mod Flags {
    def send(urgent: Bool, to: String): String = if (urgent) "!${to}" else to

    pub def page(to: String): String = send(true, to)

    pub def quiet(to: String): String = send(not false, to)

    pub def plain(to: String): String = to

    /// Bool values wrapped in a case (test-bool-some in internet_dungeon): a comparison, a negation, a conjunction.
    pub def isOne(n: Int32): Option[Bool] = Some(n == 1)

    pub def notOne(n: Int32): Option[Bool] = Some(not (n == 1))

    pub def inRange(n: Int32): Result[String, Bool] = Ok(n > 1 and n < 9)
}
