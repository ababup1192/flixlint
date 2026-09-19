mod Orders {
    pub def find(id: String): String \ Db = Db.exec("select total from orders where id = '${id}'")

    /// Violates clock: Clock.today is a wrapper of the wall clock (transitivelyIn).
    pub def receipt(id: String): String \ {Db, IO} = "${find(id)} on ${Clock.today()}"

    /// Violates io-in-tx, and find-reads-only: a find* function with Http.
    pub def findAndNotify(id: String): String \ {Db, Http} =
        let row = find(id);
        Http.get("https://example.invalid/notify?order=${row}")

    /// Violates io-in-tx, but the allowUntil holds the rule back until the date.
    pub def syncInventory(): String \ {Db, Http} =
        let _ = Db.exec("select sku from inventory");
        Http.get("https://example.invalid/inventory")
}
