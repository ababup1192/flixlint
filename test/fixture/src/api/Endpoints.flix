mod Mapping {
    pub def orderId(raw: String): String = raw
}

mod Inventory {
    use Auth.Permit
    pub def bulkUpdate(_proof: Permit, sku: String): String \ Db = Db.exec("update ${sku}")
    pub def relabel(_proof: Permit, sku: String): String \ Db = Db.exec("relabel ${sku}")
    pub def describe(sku: String): String \ Db = Db.exec("describe ${sku}")
    pub def guarded(f: Unit -> a \ ef): a \ ef = f()
}

mod Endpoints {
    pub def pairedPermit(raw: String): String \ Db + Auth =
        let id = Mapping.orderId(raw);
        let _ = Auth.permit();
        Db.exec("update ${id}")

    pub def orderPermit(raw: String): String \ Db + Auth =
        let _ = Auth.permitOn(raw);
        Db.exec("update ${raw}")

    pub def leaky(raw: String): String \ Db + Auth =
        let _ = Auth.permitOn(raw);
        let _ = Auth.permit();
        Db.exec("update ${raw}")

    pub def bulkUpdateGuarded(sku: String): String \ Db + Auth =
        let proof = Auth.permit();
        Inventory.guarded(() -> Inventory.bulkUpdate(proof, sku))

    pub def bulkUpdateBare(sku: String): String \ Db + Auth =
        let proof = Auth.permit();
        Inventory.bulkUpdate(proof, sku)

    pub def describeItem(sku: String): String \ Db =
        Inventory.describe(sku)

    /// One read per id in a lambda passed to List.map (N+1).
    pub def eachInLambda(ids: List[String]): List[String] \ Db =
        List.map(id -> Orders.find(id), ids)

    /// The same, with the function passed by name.
    pub def eachByName(ids: List[String]): List[String] \ Db =
        ids |> List.map(Orders.find)

    /// One read per id, but in a lambda passed to a function the rule does not name.
    pub def eachInFilter(ids: List[String]): List[String] \ Db =
        List.filter(id -> Orders.find(id) == "", ids)

    /// A value that does not parse is dropped by List.filterMap.
    pub def parsedIds(texts: List[String]): List[Int32] =
        List.filterMap(Ids.parse, texts)

    /// A value that does not parse becomes the default, through a pipe.
    pub def parsedOrZero(text: String): Int32 =
        Ids.parse(text) |> Option.map(n -> n + 1) |> Option.getWithDefault(0)

    /// The same, as a direct argument.
    pub def parsedOrOne(text: String): Int32 =
        Option.getWithDefault(1, Ids.parse(text))

    /// The default is an error: a rejection, not a drop.
    pub def parsedOrErr(text: String): Result[String, Int32] =
        Ids.parse(text) |> Option.map(Ok) |> Option.getWithDefault(Err(text))
}
