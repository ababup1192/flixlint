pub eff Db {
    def exec(sql: String): String
}

pub eff Http {
    def get(url: String): String
}

pub eff Clock {
    def now(): Int64
}

pub type alias WriteEff = Db + Http

pub enum ColumnName(String)

pub enum Predicate {
    case Eq(ColumnName, String)
    case In(List[ColumnName])
    case Any
}

pub enum Column(String)

pub enum Filter {
    case On(Column)
}

mod Scope {
    pub def currentId(): String = "s1"
}

mod Generated {
    pub enum Query(Int32)

    pub enum Role {
        case Owner
        case Viewer
    }

    pub def findOrders(scopeId: String, limit: Int32): String \ Db = Db.exec("select ${scopeId} ${limit}")

    pub def limitOf(q: Query): Int32 = match q { case Query.Query(n) => n }
}

mod Ids {
    pub def parse(text: String): Option[Int32] = Int32.fromString(text)
}

mod Log {
    pub def str(key: String, value: String): String = "${key}=${value}"

    /// The keys that carry a human-written sentence; the rule reads them from here.
    pub def freeTextKeys(): List[String] = List#{"error.message", "detail"}

    pub def text(key: String, value: String): String = str(key, String.takeLeft(20, value))
}
