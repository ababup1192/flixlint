/// move の enum のお手本: Suit を Deck へ移す。元の mod の中の素の Suit.Red・外の修飾 Cards.Suit.Black・
/// use で入れた Suit・型の注記を全部移し先へ向ける。
mod Cards {
    /// 札の色。
    pub enum Suit with Eq {
        case Red
        case Black(Int32)
    }

    pub def red(): Suit = Suit.Red

    pub def isRed(s: Suit): Bool = match s {
        case Suit.Red => true
        case Suit.Black(_) => false
    }
}
