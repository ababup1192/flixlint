/// Receivers bound by a case pattern (`case-recv`) and record literals (`record-literal`): the typed stage's rows.
mod Scenes {
    pub type alias DeckUi = { cursor = Int32, open = Bool }

    pub enum Scene {
        case Deck(DeckUi)
        case Board({ turn = Int32 })
        case Pair(DeckUi, { turn = Int32 })
        case Title
    }

    pub def cursorOf(s: Scene): Int32 = match s {
        case Scene.Deck(d) => d#cursor
        case Scene.Board(b) => b#turn
        case Scene.Pair(d, b) => d#cursor + b#turn
        case Scene.Title => 0
    }

    pub def start(): Scene = Scene.Deck({ cursor = 0, open = false })

    pub def board(): Scene = Scene.Board({ turn = 1 })

    pub def moved(d: DeckUi): DeckUi = { cursor = d#cursor + 1 | d }
}
