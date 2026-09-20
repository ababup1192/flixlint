/// A file with nothing but a type alias: it has no Def, Enum or Eff row, and allowInFile must still see it.
mod Money {
    pub type alias Cents = Int64
}
