/// What a record receiver is (`owner=`): each way an owner is proved, and the ones that are not.
mod Owners {
    pub type alias Game = { top = Int32, deck = Int32 }

    pub type alias Model = Game

    pub type alias HasTop[r: RecordRow] = { top = Int32 | r }

    pub enum Panel {
        case Open({ row = Int32, col = Int32 })
        case Closed
    }

    pub def fromSynonym(m: Model): Int32 = m#top

    pub def fromOpenAlias(h: HasTop[r]): Int32 = h#top

    pub def fromPayloadParam(p: { row = Int32, col = Int32 }): Int32 = p#row

    pub def fromLetOfCase(x: Panel): Int32 = match x {
        case Panel.Open(o) =>
            let q = o;
            q#col
        case Panel.Closed => 0
    }

    pub def fromOther(r: { old = Bool, id = Int32 }): Int32 = r#id

    def game(): Game = { top = 1, deck = 2 }

    pub def fromParens(): Int32 = (game())#deck

    pub def nested(n: { inner = Game }): Int32 = n#inner#top

    pub def inText(g: Game): String = "top ${g#top}"
}
