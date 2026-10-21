// Every node of the columns under $FLIXLINT_GENERIC: the kind number the shim wrote names, in the shim's own kinds.txt,
// the same kind as in AstKinds.flix. Prints `generic: ok ...`, or each node that differs, or why the columns did not load.
import java.io.File
import java.lang.System
import java.nio.file.Files

def main(): Unit \ IO =
    let dir = System.getenv("FLIXLINT_GENERIC");
    match Flixlint.Ast.load(dir) {
        case Err(e) => println("generic: ${e}")
        case Ok(ast) =>
            let shimNames = Files.readString((new File("${dir}/kinds.txt")).toPath()) |> String.lines |> List.filter(l -> not String.isEmpty(l)) |> List.toVector;
            let differ = Vector.range(0, Flixlint.Ast.size(ast)) |> Vector.filterMap(n -> {
                let k = Flixlint.Ast.kind(ast, n);
                let shimName = Vector.nth(Flixlint.AstKinds.kindIndex(k), shimNames) |> Option.getWithDefault("(none)");
                if (shimName == Flixlint.AstKinds.kindName(k)) None
                else Some("generic: node ${n}: the shim wrote ${shimName}, AstKinds names ${Flixlint.AstKinds.kindName(k)}")
            });
            let kinds = Vector.range(0, Flixlint.Ast.size(ast)) |> Vector.map(n -> Flixlint.Ast.kind(ast, n)) |> Vector.toSet;
            if (Vector.isEmpty(differ))
                println("generic: ok nodes=${Flixlint.Ast.size(ast)} kinds=${Set.size(kinds)} applyDef=${Vector.length(Flixlint.Ast.ofKind(ast, Flixlint.AstKinds.Kind.Expr_ApplyDef))}")
            else Vector.forEach(println, differ)
    }
