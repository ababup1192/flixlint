pub eff Session {
    def current(): String
}

mod Session {
    pub enum Granted(Int32)

    pub def runWith(actor: String, f: Unit -> a \ ef): a \ ef - Session =
        run {
            f()
        } with handler Session {
            def current(k) = k(actor)
        }

    pub def grant(): Granted \ Session =
        let _ = Session.current();
        Granted.Granted(1)

    pub def grantOnEntry(id: String): Granted \ Session =
        let _ = Session.current();
        Granted.Granted(String.length(id))
}
