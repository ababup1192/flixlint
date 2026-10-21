///
/// The AST as generic relations (docs/design-generic.md, chapter 2): node `i` is row `i` of every column the shim's
/// `flixlint.Generic` writes. This is the loading part only: the `kind` and `parent` columns, the nodes of a kind and
/// the parent of a node. The kinds are the generated `Flixlint.AstKinds.Kind`.
///
pub mod Flixlint.Ast {
    use Flixlint.AstKinds.Kind
    import java.io.File
    import java.io.IOException
    import java.nio.ByteBuffer
    import java.nio.IntBuffer
    import java.nio.file.Files

    pub enum Ast(AstData)

    /// A node of the AST: its row in the columns.
    pub type alias Node = Int32

    type alias AstData = {
        kind = Vector[Int32],
        parent = Vector[Int32]
    }

    def data(ast: Ast): AstData = match ast { case Ast.Ast(d) => d }

    /// The columns under `dir`, or what could not be read. Columns numbered by another `ast_schema` than the one
    /// AstKinds.flix was made from are refused: their numbers would name other kinds.
    pub def load(dir: String): Result[String, Ast] \ IO =
        forM (
            hash <- readText("${dir}/schema_hash.txt");
            _ <- if (String.trim(hash) == Flixlint.AstKinds.schemaHash()) Ok(())
                 else Err("${dir}: the columns were written for the ast_schema ${String.trim(hash)}, and this flixlint has ${Flixlint.AstKinds.schemaHash()} (the shim and the library are of different versions)");
            kind <- readColumn("${dir}/kind.i32");
            parent <- readColumn("${dir}/parent.i32");
            _ <- if (Vector.length(kind) == Vector.length(parent)) Ok(())
                 else Err("${dir}: kind.i32 has ${Vector.length(kind)} rows and parent.i32 ${Vector.length(parent)}")
        ) yield Ast.Ast({ kind = kind, parent = parent })

    /// How many nodes there are.
    pub def size(ast: Ast): Int32 = Vector.length(data(ast)#kind)

    /// The nodes of kind `k`, in id order.
    pub def ofKind(ast: Ast, k: Kind): Vector[Node] =
        let column = data(ast)#kind;
        let i = Flixlint.AstKinds.kindIndex(k);
        Vector.range(0, Vector.length(column)) |> Vector.filter(n -> Vector.get(n, column) == i)

    /// The kind of `n`.
    pub def kind(ast: Ast, n: Node): Kind =
        let i = Vector.get(n, data(ast)#kind);
        match Flixlint.AstKinds.kindOfIndex(i) {
            case Some(k) => k
            case None    => bug!("Flixlint.Ast: kind number ${i} of node ${n} is not in AstKinds (load checks the schema hash)")
        }

    /// The node `n` sits in; none for a declaration.
    pub def parent(ast: Ast, n: Node): Option[Node] =
        let p = Vector.get(n, data(ast)#parent);
        if (p < 0) None else Some(p)

    def readText(path: String): Result[String, String] \ IO =
        try {
            Ok(Files.readString((new File(path)).toPath()))
        } catch {
            case e: IOException => Err("${path}: ${e.getMessage()}")
        }

    /// A column: big-endian Int32 values, the row count is the file size / 4.
    def readColumn(path: String): Result[String, Vector[Int32]] \ IO =
        let bytes = try {
            Ok(Files.readAllBytes((new File(path)).toPath()))
        } catch {
            case e: IOException => Err("${path}: ${e.getMessage()}")
        };
        Result.map(b -> toInts(ByteBuffer.wrap(b).asIntBuffer()), bytes)

    def toInts(ints: IntBuffer): Vector[Int32] \ IO = region rc {
        let arr: Array[Int32, rc] = Array.repeat(rc, ints.remaining(), 0);
        discard ints.get(arr);
        Array.toVector(arr)
    }
}
