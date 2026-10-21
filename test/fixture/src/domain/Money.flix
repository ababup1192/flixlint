/// A file with nothing but type aliases: it has no Def, Enum or Eff row, and allowInFile must still see it.
mod Money {
    pub type alias Cents = Int64

    /// A record of two fields: raw-alias reports `Cents` (a bare Int64) and not this one.
    pub type alias Price = { cents = Cents, currency = String }
}
