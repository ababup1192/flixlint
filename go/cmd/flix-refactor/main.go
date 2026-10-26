// flix-refactor は Flix のコードを構造で書き換える（rewrite・remove-dead・move・field-to-accessor など。既定は dry-run）。
// 探す op（show・usages など）も受ける。flix-refactor --help。
package main

import (
	"os"

	"github.com/ababup1192/flixlint/go/cli"
)

func main() { os.Exit(cli.Main("flix-refactor", os.Args[1:], nil)) }
