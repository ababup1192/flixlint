mod Clock {
    import java.lang.System

    pub def real(): Int64 \ IO = System.currentTimeMillis()

    pub def today(): String \ IO = Int64.toString(real() / 86400000i64)
}
