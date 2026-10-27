mod Save {
    pub trait Saveable[a] {
        pub def fromText(s: String): a
    }

    pub def parse(s: String): Int32 = String.length(s)

    instance Saveable[Int32] {
        pub def fromText(s: String): Int32 = parse(s)
    }
}
