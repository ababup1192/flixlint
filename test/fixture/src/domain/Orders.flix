mod Orders {
    use Auth.Permit

    pub def create(_proof: Permit, title: String): String \ Db =
        Db.exec("insert ${title}")

    pub def createAndFetch(_proof: Permit, title: String): String \ Db + Http =
        let _ = Db.exec("insert ${title}");
        Http.get("https://example.test/${title}")

    pub def viaAlias(title: String): String \ WriteEff =
        let _ = Db.exec("insert ${title}");
        Http.get("https://example.test/${title}")

    pub def confirm(title: String): String \ Db + Http =
        let _ = Http.get("https://example.test/${title}");
        Db.exec("update ${title}")

    pub def selfPermitting(title: String): String \ Db + Auth =
        let _ = Auth.permit();
        Db.exec("insert ${title}")

    pub def permitsInLambda(titles: List[String]): List[Permit] \ Auth =
        List.map(_ -> Auth.permit(), titles)

    pub def forgesProof(): Permit =
        Permit.Permit(0)

    pub def stamped(title: String): String \ Clock =
        "${title}@${Clock.now()}"

    pub def stampedRow(title: String): String \ Clock + Db =
        Db.exec("insert ${title}@${Clock.now()}")

    pub def listMine(): String \ Db =
        Generated.findOrders(Scope.currentId(), 10)

    pub def count(q: Generated.Query): Int32 =
        Generated.limitOf(q)

    pub def filterBy(name: ColumnName): Predicate =
        Predicate.Eq(name, "x")

    pub def columnOf(name: String): Filter =
        Filter.On(Column.Column(name))

    pub def find(id: String): String \ Db =
        Db.exec("select ${id}")

    /// One read per id, but in the domain: outside the files of the find-many rule.
    pub def findEach(ids: List[String]): List[String] \ Db =
        List.map(id -> find(id), ids)

    pub def defaultRole(): Generated.Role =
        Generated.Role.Owner

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
