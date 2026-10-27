/// The defs of an instance: their bodies are in the index, under the name of the module the instance is in. The defs
/// of a derived instance (`with Eq`) are not written in the sources and are not in it.
mod Insts {
    pub trait Load[a] {
        pub def load(s: String): a
    }

    pub enum Coin with Eq {
        case Heads
        case Tails
    }

    pub def parse(s: String): Int32 = String.length(s)

    instance Load[Coin] {
        pub def load(s: String): Coin = if (parse(s) > 0) Coin.Heads else Coin.Tails
    }
}
