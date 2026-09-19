mod Reports {
    /// Violates db-handler: the handler belongs to the runner, not to a caller.
    pub def preview(): String =
        run {
            Orders.find("1")
        } with handler Db {
            def exec(_sql, k) = k("(preview)")
        }
}
