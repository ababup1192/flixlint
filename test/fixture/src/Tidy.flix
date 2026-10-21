/// A module whose `use` brings in a name it never uses (rules/uses.flix reports it); the other name is used.
mod Tidy {
    use Auth.Permit
    use List.length

    pub def count(xs: List[Int32]): Int32 = length(xs)
}
