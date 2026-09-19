mod Entries {
    use Session.Granted

    pub def create(_proof: Granted, title: String): String \ Db =
        Db.exec("insert ${title}")

    pub def createAndFetch(_proof: Granted, title: String): String \ Db + Http =
        let _ = Db.exec("insert ${title}");
        Http.get("https://example.test/${title}")

    pub def viaAlias(title: String): String \ AdminEff =
        let _ = Db.exec("insert ${title}");
        Http.get("https://example.test/${title}")

    pub def confirm(title: String): String \ Db + Http =
        let _ = Http.get("https://example.test/${title}");
        Db.exec("update ${title}")

    pub def selfGranting(title: String): String \ Db + Session =
        let _ = Session.grant();
        Db.exec("insert ${title}")

    pub def grantsInLambda(titles: List[String]): List[Granted] \ Session =
        List.map(_ -> Session.grant(), titles)

    pub def forgesProof(): Granted =
        Granted.Granted(0)

    pub def stamped(title: String): String \ Clock =
        "${title}@${Clock.now()}"

    pub def stampedRow(title: String): String \ Clock + Db =
        Db.exec("insert ${title}@${Clock.now()}")

    pub def listMine(): String \ Db =
        Generated.findEntries(Tenant.currentId(), 10)

    pub def count(q: Generated.Query): Int32 =
        Generated.limitOf(q)

    pub def filterBy(id: ApiId): Condition =
        Condition.Eq(id, "x")

    pub def visibleOf(name: String): Filter =
        Filter.On(Visible.Visible(name))

    pub def find(id: String): String \ Db =
        Db.exec("select ${id}")

    /// One read per id, but in the domain: outside the files of the find-many rule.
    pub def findEach(ids: List[String]): List[String] \ Db =
        List.map(id -> find(id), ids)

    pub def defaultRole(): Generated.Role =
        Generated.Role.Admin

    pub def rolesOf(): List[Option[Generated.Role]] = Nil

    pub def logged(message: String): String =
        Log.str("error.message", message)

    pub def loggedCode(code: String): String =
        Log.str("code", code)

    pub def loggedSecret(value: String): String =
        Log.str("secret", value)

    pub def loggedText(message: String): String =
        Log.text("detail", message)
}

pub enum Wrapped {
    case Of(List[Generated.Query])
}
