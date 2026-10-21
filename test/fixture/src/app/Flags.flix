/// Bool literals passed straight to a function (bool-arg): `page` passes `true`, `quiet` passes `not false` (seen through).
mod Flags {
    def send(urgent: Bool, to: String): String = if (urgent) "!${to}" else to

    pub def page(to: String): String = send(true, to)

    pub def quiet(to: String): String = send(not false, to)

    pub def plain(to: String): String = to
}
