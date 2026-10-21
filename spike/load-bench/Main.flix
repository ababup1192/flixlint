// Times Flixlint.Ast.load on the columns under $FLIXLINT_GENERIC, and a scan of each column after it.
import java.lang.System

def main(): Unit \ IO =
    let dir = System.getenv("FLIXLINT_GENERIC");
    let t0 = System.nanoTime();
    match Flixlint.Ast.load(dir) {
        case Err(e) => println("load-bench: ${e}")
        case Ok(ast) =>
            let t1 = System.nanoTime();
            let applyDefs = Vector.length(Flixlint.Ast.ofKind(ast, Flixlint.AstKinds.Kind.Expr_ApplyDef));
            let roots = Vector.range(0, Flixlint.Ast.size(ast)) |> Vector.count(n -> Option.isEmpty(Flixlint.Ast.parent(ast, n)));
            let t2 = System.nanoTime();
            println("load-bench: nodes=${Flixlint.Ast.size(ast)} applyDef=${applyDefs} roots=${roots} load=${(t1 - t0) / 1_000_000i64}ms scan=${(t2 - t1) / 1_000_000i64}ms")
    }
