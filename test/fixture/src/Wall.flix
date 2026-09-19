mod Wall {
    import java.lang.System

    pub def nowMillis(): Int64 \ IO = System.currentTimeMillis()

    pub def today(): String \ IO = Int64.toString(nowMillis() / 86400000i64)

    def secret(): Int64 \ IO = nowMillis()

    pub def stamp(): String \ IO = "${secret()}"
}

mod Report {
    pub def title(): String \ IO = "report for ${Wall.today()}"

    pub def footer(): String \ IO = Wall.stamp()
}
