mod Runner {
    pub def transact(f: Unit -> a \ ef): a \ ef - Db =
        run {
            f()
        } with handler Db {
            def exec(sql, k) = k("row:${sql}")
        }
}
