/// A price taken and a number returned through aliases only: the Int64 under them is in the Deep relations, not the All ones.
mod Billing {
    pub def centsOf(p: Money.Price): Money.Cents = p#cents
}
