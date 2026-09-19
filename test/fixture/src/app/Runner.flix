mod Runner {
    pub def transact(actor: String, f: Unit -> a \ ef): a \ ef - Session - Db =
        run {
            Session.runWith(actor, f)
        } with handler Db {
            def exec(sql, k) = k("row:${sql}")
        }

    pub def bypass(f: Unit -> a \ ef): a \ ef - Session =
        run {
            f()
        } with handler Session {
            def current(k) = k("system")
        }

    pub def nowMillis(): Int64 \ Clock = Clock.now()
}

def main(): Unit \ IO =
    let out = Runner.transact("alice", () -> Entries.create(Session.grant(), "t"));
    println(out)
