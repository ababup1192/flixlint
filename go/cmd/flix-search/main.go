// flix-search は Flix のコードを構造で探す（読むだけ）: show・search・outline・trace・context・usages・refs など。
// 索引は flixlint --spans（コンパイラの名前の解決）。flix-search --help。
package main

import (
	"os"

	"github.com/ababup1192/flixlint/go/cli"
)

func main() { os.Exit(cli.Main("flix-search", os.Args[1:], cli.ReadOnlyOps)) }
