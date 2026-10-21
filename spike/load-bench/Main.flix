// Times Flixlint.Ast.load on the relations under $FLIXLINT_GENERIC, then the first use of the indices (children,
// kinds, attributes), which are made when first read.
import java.lang.System

def main(): Unit \ IO =
    let dir = System.getenv("FLIXLINT_GENERIC");
    let t0 = System.nanoTime();
    match Flixlint.Ast.load(dir) {
        case Err(e) => println("load-bench: ${e}")
        case Ok(ast) =>
            let t1 = System.nanoTime();
            let applyDefs = List.length(Flixlint.Ast.ofKind(ast, Flixlint.AstKinds.Kind.Expr_ApplyDef));
            let roots = Flixlint.Ast.nodes(ast) |> List.count(n -> Option.isEmpty(Flixlint.Ast.parent(ast, n)));
            let named = Flixlint.Ast.ofKind(ast, Flixlint.AstKinds.Kind.Def) |> List.count(d -> Option.nonEmpty(Flixlint.Ast.attr(ast, d, Flixlint.AstKinds.Attr.Sym)));
            let children = Flixlint.Ast.ofKind(ast, Flixlint.AstKinds.Kind.Def) |> List.map(d -> List.length(Flixlint.Ast.children(ast, d))) |> List.sum;
            let t2 = System.nanoTime();
            println("load-bench: nodes=${Flixlint.Ast.size(ast)} applyDef=${applyDefs} roots=${roots} defs=${named} defChildren=${children} load=${(t1 - t0) / 1_000_000i64}ms index=${(t2 - t1) / 1_000_000i64}ms")
    }
