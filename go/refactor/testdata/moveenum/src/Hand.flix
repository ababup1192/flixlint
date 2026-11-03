mod Hand {
    use Cards.Suit

    pub def pick(n: Int32): Suit = if (n > 0) Cards.Suit.Black(n) else Suit.Red

    pub def count(s: Suit): Int32 = match s {
        case Cards.Suit.Red => 0
        case Suit.Black(n) => n
    }
}
