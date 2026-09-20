mod Pricing {
    pub def priceOf(seats: Int32): Int32 = seats * 100

    pub def priceFromDb(plan: String): Int32 \ Db =
        String.length(Db.exec("select price ${plan}"))
}
