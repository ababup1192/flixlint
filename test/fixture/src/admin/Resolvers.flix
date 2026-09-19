mod AdminMapping {
    pub def entryId(raw: String): String = raw
}

mod ContentTypes {
    use Session.Granted
    pub def addField(_proof: Granted, name: String): String \ Db = Db.exec("alter ${name}")
    pub def rename(_proof: Granted, name: String): String \ Db = Db.exec("rename ${name}")
    pub def describe(name: String): String \ Db = Db.exec("describe ${name}")
    pub def guarded(f: Unit -> a \ ef): a \ ef = f()
}

mod Resolvers {
    pub def pairedGrant(raw: String): String \ Db + Session =
        let id = AdminMapping.entryId(raw);
        let _ = Session.grant();
        Db.exec("update ${id}")

    pub def entryGrant(raw: String): String \ Db + Session =
        let _ = Session.grantOnEntry(raw);
        Db.exec("update ${raw}")

    pub def leaky(raw: String): String \ Db + Session =
        let _ = Session.grantOnEntry(raw);
        let _ = Session.grant();
        Db.exec("update ${raw}")

    pub def addFieldGuarded(name: String): String \ Db + Session =
        let proof = Session.grant();
        ContentTypes.guarded(() -> ContentTypes.addField(proof, name))

    pub def addFieldBare(name: String): String \ Db + Session =
        let proof = Session.grant();
        ContentTypes.addField(proof, name)

    pub def describeType(name: String): String \ Db =
        ContentTypes.describe(name)

    /// One read per id in a lambda passed to List.map (N+1).
    pub def eachInLambda(ids: List[String]): List[String] \ Db =
        List.map(id -> Entries.find(id), ids)

    /// The same, with the function passed by name.
    pub def eachByName(ids: List[String]): List[String] \ Db =
        ids |> List.map(Entries.find)

    /// One read per id, but in a lambda passed to a function the rule does not name.
    pub def eachInFilter(ids: List[String]): List[String] \ Db =
        List.filter(id -> Entries.find(id) == "", ids)

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
