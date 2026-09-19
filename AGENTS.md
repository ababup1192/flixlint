# flixlint

Flix のアーキテクチャ規則を、grep でなくコンパイラの AST から取った facts で check する linter。
使い方・規則の書き方・facts の一覧は [README.md](README.md)。

## 会話ポリシー

日本語で会話してください。途中報告なども含めて、日本語で回答してください。

単語は業界の言葉をそのまま使う（カタカナ・英語のまま。和語へ言い換えない・造語を作らない）。
説明は平易に書く。独自の比喩で名付けない。

## Flix のお約束

- **Flix を書く前・テストを書く前に `/flix-docs` を引く**（本文は `.claude/skills/flix-docs/SKILL.md`）
- **コンパイルエラーが出たら `/compile-fix`**（本文は `.claude/skills/compile-fix/SKILL.md`）

## コーディングポリシー

コードには **How** / テストコードには **What** / コミットログには **Why** / コードコメントには **WhyNot**

特にコードコメントは WhyNot を重視し、How・What を書かない。実装の由来や旧実装などの歴史背景も書かない。

## 3 つの層と、どこを直すか

| 層 | 場所 | 直すのは |
|---|---|---|
| shim（Scala） | `shim/Facts.scala` | facts の列を足す・変える、コンパイラのバージョンを上げる |
| エンジン（Flix） | `rules/Flixlint.flix`、`rules/Flixlint/` | family を足す、判定を変える、報告の文面 |
| CLI（bash） | `bin/flixlint` | 引数、shim と engine の組み方とキャッシュ |

shim は TSV と `Names.flix` を書く所までで、規則を知らない。エンジンは TSV しか読まない。
**この境界を越えない**（shim に規則を書かない、エンジンから AST を触らない）。
コンパイラのバージョンを上げる時に動くのは `shim/Facts.scala` だけで、TSV の契約と規則は動かない。

## 破ると事故る決まり

- **flixlint は特定のプロジェクトを知らない。** effect・モジュール・ファイル・enum の case の名前は
  利用側の `rules.flix` の物で、`rules/` にも `shim/` にも書かない
- **`rules/Flixlint*.flix` は単体でコンパイルできない**（生成物の `Names` を参照する）。型検査は
  `make test`（fixture を 1 回通す）で、これがエンジンのコンパイルそのもの
- **fpkg では配らない。** `flix build-pkg` は `src/**/*.flix` しか詰めず、`bin/` も shim の jar も入らない
  （理由は `flix.toml` の WhyNot と README の「Why it is not an fpkg」）。`src/` を作らない
- **報告は決定的に。** 違反はファイル・行・rule id で並べ替えてから出す。`--today` を受けるのは
  `allowUntil` を実時刻に依らせないため（テストは日付を固定する）
- **facts の列を足したら `test/fixture/` に違反を 1 件足す。** fixture は「全 family と custom 規則に
  少なくとも 1 件ずつ違反が在る」状態を保つ
- **`test/expected*.txt` を手で合わせない。** 報告が変わったら、変えて良い変更かを先に決めてから
  差分を取り込む

## ビルドと実行

Flix コンパイラ jar は `FLIX_JAR` で渡すか、無ければ flix_game_engine の devbox の物を借りる
（`bin/flix-jar`。`FLIXLINT_ENGINE_ROOT` で場所を変えられる）。shim を組む scala-cli は `devbox.json`。

```bash
make test            # fixture に掛けて test/expected*.txt と突き合わせる（型検査もこれ）
make test-resolved   # 名前解決の直後の AST でも同じ報告になる事
make shim            # build/flixlint-shim.jar を組み直す
make clean           # build/ と .scala-build/ を消す
make release         # shim の jar を GitHub の release に付ける（version は flix.toml）
```
