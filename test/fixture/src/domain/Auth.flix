pub eff Auth {
    def principal(): String
}

mod Auth {
    pub enum Permit(Int32)

    pub def runWith(actor: String, f: Unit -> a \ ef): a \ ef - Auth =
        run {
            f()
        } with handler Auth {
            def principal(k) = k(actor)
        }

    pub def permit(): Permit \ Auth =
        let _ = Auth.principal();
        Permit.Permit(1)

    pub def permitOn(id: String): Permit \ Auth =
        let _ = Auth.principal();
        Permit.Permit(String.length(id))
}
