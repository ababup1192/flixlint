/// The `param` rows (the parameters of a top-level def), `aparam=` on the arguments and `fields=` on the aliases.
mod Params {
    pub type alias Res = { scale = Int32, name = String }

    pub type alias World = { scale = Int32, res = Res }

    pub type alias Env = World

    pub type alias HasScale[r: RecordRow] = { scale = Int32 | r }

    /// `w` read twice, `res` once, `_seed` never (hidden: an unused parameter without `_` does not compile).
    pub def leaf(w: World, res: Res, _seed: Int32): Int32 = w#scale + w#res#scale + res#scale

    /// Type arguments, a function with an effect, a tuple; a type variable is `poly=1`.
    pub def shapes(xs: List[Option[Int32]], f: Int32 -> Unit \ IO, p: (Int32, String), x: a): Int32 \ IO =
        let (n, _) = p;
        f(n);
        List.length(xs) + List.length(x :: Nil)

    /// An open record (fields up to the row) and an alias of one; a closed record written out.
    pub def open(e: { res = Res | r }, h: HasScale[s], c: { b = Bool, a = Int32 }): Int32 = e#res#scale + h#scale + c#a

    /// `aparam=`: `w` passed itself (0, also to a case), an expression of it (none), a local bound to it (none), a lambda's
    /// parameter (none; Flix does not let a lambda shadow `w`).
    pub def callers(w: World, res: Res): Int32 =
        let n = leaf(w, res, w#scale);
        let w2 = w;
        leaf(w2, res, n) + (List.map(v -> v#scale, w :: Nil) |> List.sum)

    pub def noParams(): Int32 = 1

    pub def viaSynonym(env: Env): Int32 = env#scale
}
