mod Shapes {
    pub trait Area[a] {
        pub def area(x: a): Int32
    }

    pub trait Perimeter[a] {
        pub def perimeter(x: a): Int32
    }
}

mod Tiles {
    use Shapes.Area
    use Shapes.Perimeter
    use List.length

    pub enum Tile(List[Int32])

    instance Area[Tile] {
        pub def area(x: Tile): Int32 = match x {
            case Tile.Tile(xs) => length(xs)
        }
    }
}
