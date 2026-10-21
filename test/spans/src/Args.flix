/// The `arg` rows: the arguments of a case of two fields built and matched, and of a call written over two lines.
mod Args {
    pub enum Scene {
        case Deck(Int32, String)
        case Empty
    }

    pub def label(n: Int32, s: String): String = "${n}${s}"

    pub def deck(): Scene = Scene.Deck(1 + 2, "a")

    pub def show(s: Scene): String = match s {
        case Scene.Deck(n, name) => label(n,
            name)
        case Scene.Empty => label(0, "")
    }
}
