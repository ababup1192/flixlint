// Package cli は flix-search と flix-refactor の入口（同じ refactor の道を、許す op だけ変えて流す）。
//
// 索引を作る flixlint はそのまま流す（組み込む側が枠を取る道は無い。flix_game_engine の bin/fge refactor は
// heavy の枠の中で流す自前の Runner を渡す）。
package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flixlint/go/refactor"
)

// ReadOnlyOps は flix-search が受ける op（ソースを書き換えない物）。
var ReadOnlyOps = []string{"show", "search", "outline", "trace", "context", "usages", "refs", "match-sites", "field-sites", "index"}

// Main は name の道具として args（os.Args[1:]）を流し、終了コードを返す。ops が nil なら全部の op を受ける。
func Main(name string, args []string, ops []string) int {
	// 答えの中の呼び方は flix-refactor のまま（書き換える op の next も通る）。flix-search では読むだけの op を flix-search に。
	refactor.SetHost(refactor.HostHooks{})
	root, rest := rootFlag(args)
	if ops != nil && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") && rest[0] != "help" && !contains(ops, rest[0]) {
		fmt.Fprintf(os.Stderr, "%s: %s は書き換える op（flix-refactor %s）。%s が受けるのは %s\n", name, rest[0], rest[0], name, strings.Join(ops, "・"))
		return 2
	}
	var out, errOut strings.Builder
	code := refactor.Run(&out, &errOut, root, rest, refactor.Options{Run: runIndex, Verify: runVerify, Log: os.Stderr})
	os.Stdout.WriteString(asTool(name, ops, out.String()))
	os.Stderr.WriteString(asTool(name, ops, errOut.String()))
	return code
}

// asTool は答えの「flix-refactor <op>」のうち、name が受ける op を name の呼び方にする。
func asTool(name string, ops []string, s string) string {
	if ops == nil {
		return s
	}
	for _, op := range ops {
		s = strings.ReplaceAll(s, "flix-refactor "+op+" ", name+" "+op+" ")
		s = strings.ReplaceAll(s, "flix-refactor "+op+"\n", name+" "+op+"\n")
	}
	return s
}

// rootFlag は --root <dir> を抜く。無ければ今の所から上へ flix.toml のある所（無ければ今の所）。
func rootFlag(args []string) (string, []string) {
	var rest []string
	root := ""
	for i := 0; i < len(args); i++ {
		if args[i] == "--root" && i+1 < len(args) {
			root = args[i+1]
			i++
			continue
		}
		if v, ok := strings.CutPrefix(args[i], "--root="); ok {
			root = v
			continue
		}
		rest = append(rest, args[i])
	}
	if root != "" {
		return root, rest
	}
	dir, err := os.Getwd()
	if err != nil {
		return ".", rest
	}
	for d := dir; ; d = filepath.Dir(d) {
		if info, err := os.Stat(filepath.Join(d, "flix.toml")); err == nil && !info.IsDir() {
			return d, rest
		}
		if filepath.Dir(d) == d {
			return dir, rest
		}
	}
}

func runIndex(_ refactor.Stage, _ string, dir string, cmd []string, log string) int {
	return run(dir, cmd, log)
}

func runVerify(cmd, dir, log string) int {
	fmt.Fprintf(os.Stderr, "[refactor] 確かめ: %s（出力は %s）\n", cmd, log)
	return run(dir, []string{"sh", "-c", cmd}, log)
}

// run は cmd を dir で流す。log が空でなければ出力をそのファイルへ。
func run(dir string, cmd []string, log string) int {
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Dir = dir
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if log != "" {
		f, err := os.Create(log)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[refactor] %s を書けない: %v\n", log, err)
			return 2
		}
		defer f.Close()
		c.Stdout, c.Stderr = f, f
	}
	if err := c.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "[refactor] %s を起動できない: %v\n", cmd[0], err)
		return 2
	}
	return 0
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}
