mod Dungeon {
    type alias Cell = { x = Int32, y = Int32 }

    enum Node {
        case Room(Cell)
        case Hall
    }

    pub enum Shade {
        case Dark
        case Lit
    }

    enum Kept {
        case Only
    }

    /// 呼び手 0 の pub。消すと size と、size だけが使う Node・Cell・Shade が使われなくなる。
    pub def describe(x: Int32): Int32 = size(Node.Room({ x = x, y = 0 }), Shade.Dark)

    def size(n: Node, s: Shade): Int32 = match (n, s) {
        case (Node.Room(c), Shade.Dark) => c#x
        case (Node.Room(c), Shade.Lit)  => c#y
        case (Node.Hall, _)             => 0
    }

    pub def keep(): Int32 = match Kept.Only {
        case Kept.Only => 1
    }
}
