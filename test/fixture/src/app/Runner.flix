mod Runner {
    pub def transact(actor: String, f: Unit -> a \ ef): a \ ef - Auth - Db =
        run {
            Auth.runWith(actor, f)
        } with handler Db {
            def exec(sql, k) = k("row:${sql}")
        }

    pub def bypass(f: Unit -> a \ ef): a \ ef - Auth =
        run {
            f()
        } with handler Auth {
            def principal(k) = k("system")
        }

    pub def nowMillis(): Int64 \ Clock = Clock.now()
}

def main(): Unit \ IO =
    let out = Runner.transact("alice", () -> Orders.create(Auth.permit(), "t"));
    println(out)
