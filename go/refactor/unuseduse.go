package refactor

// 使っていない use・import を flixlint の判定で探す（usages --unused と remove-use の元）。
//
// 埋め込みの規則（unused_use.flix: Flixlint.Flix.uses・namesUsed・isUnused）を flixlint の lint として resolved の段で
// 流し、unused-use の違反の行（file:line・モジュール・取り込んだ名前）を読む。ゲームの lint/rules.flix の unused-use と
// 同じ判定なので、道具が消した後に lint が別の物を言い出さない。effect・trait・mod・Java の import も判じられる
// （索引の行で決める判定は def・enum・case・alias の use しか見られなかった）。
// 答えは build/refactor/unused-use.tsv に索引と同じ鍵（ソース・依存・flixlint の版）で控え、同じなら流さない。
//
// WhyNot: 判定を Go で書き直さない。flixlint の判定と 2 つになると、片方だけ直って食い違う（BoardGifRender の
// 戻りの型にだけ書いた Java の型を、道具と lint のどちらが使っていると見るか）。

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed unused_use.flix
var unusedUseRules string

// MinFlixlintUnusedUse は Flixlint.Flix.namesUsed・isUnused を持つ一番古い flixlint の版。
const MinFlixlintUnusedUse = "0.7.2"

// UseFinding は使っていない use・import の 1 つ（flixlint の unused-use の違反 1 件）。
type UseFinding struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Module string `json:"module"`
	Name   string `json:"name"` // 取り込んだ物の名前（Auth.Permit・java.io.File）
}

var unusedUseLine = regexp.MustCompile(`^(\S+\.flix):(\d+): unused-use: (\S+): brings in (\S+), which the module never uses$`)

// parseUnusedUses は flixlint の出力から unused-use の違反を読む（ほかの行は見ない）。
func parseUnusedUses(text string) []UseFinding {
	var out []UseFinding
	for _, l := range strings.Split(text, "\n") {
		m := unusedUseLine.FindStringSubmatch(strings.TrimRight(l, "\r"))
		if m == nil {
			continue
		}
		n, _ := strconv.Atoi(m[2])
		out = append(out, UseFinding{File: m[1], Line: n, Module: m[3], Name: m[4]})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].File != out[j].File {
			return out[i].File < out[j].File
		}
		return out[i].Line < out[j].Line
	})
	return out
}

func (b Builder) unusedUsePaths() (tsv, key, log string) {
	return filepath.Join(b.Dir(), "unused-use.tsv"), filepath.Join(b.Dir(), "unused-use.key"), filepath.Join(b.Dir(), "unused-use.log")
}

// UnusedUses は使っていない use・import を flixlint の判定で返す。flixlint が古い・流せない時は誤り（呼ぶ側は索引の
// 判定に戻して、そう書く）。
func (b Builder) UnusedUses() ([]UseFinding, error) {
	if v := b.version(); !versionAtLeast(v, MinFlixlintUnusedUse) {
		return nil, fmt.Errorf("flixlint %s 以上が要る（今は %s）", MinFlixlintUnusedUse, v)
	}
	src, err := b.sourceKey(Resolved)
	if err != nil {
		return nil, err
	}
	key := joinKey(src+" unused-use "+unusedUseRules, b.envKey())
	tsvPath, keyPath, log := b.unusedUsePaths()
	if !b.Rebuild {
		if old, _, ok := readKey(keyPath); ok && old == key {
			if data, err := os.ReadFile(tsvPath); err == nil {
				return parseUnusedUses(string(data)), nil
			}
		}
	}
	dir := filepath.Join(b.Dir(), "unused-use")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	rules := filepath.Join(dir, "rules.flix")
	if err := os.WriteFile(rules, []byte(unusedUseRules), 0o644); err != nil {
		return nil, err
	}
	cmd := []string{b.Flixlint}
	if versionAtLeast(b.version(), MinFlixlint) {
		cmd = append(cmd, "--resident")
	}
	cmd = append(cmd, "--rules", rules, "--stage", string(Resolved), "--build-dir", filepath.Join(dir, "build"))
	if b.FlixJar != "" {
		cmd = append(cmd, "--flix-jar", b.FlixJar)
	}
	if extra := strings.Fields(b.Config.JavaOpts); len(extra) > 0 {
		cmd = append(cmd, "--java-opts", b.Config.JavaOpts)
	}
	cmd = append(cmd, b.sources()...)
	fmt.Fprintf(b.Log, "[refactor] 使っていない use を flixlint で探します（ログ %s）\n", rel(log))
	start := time.Now()
	// 違反があれば 1・無ければ 0。ほかは流せていない（規則がコンパイルできない・ソースが通らない・環境）。
	code := b.Run(Resolved, "flixlint --rules unused-use", b.Root, cmd, log)
	if code != 0 && code != 1 {
		return nil, fmt.Errorf("flixlint の終了コード %d（%s）", code, rel(log))
	}
	found := parseUnusedUses(logText(log))
	var lines []string
	for _, f := range found {
		lines = append(lines, fmt.Sprintf("%s:%d: unused-use: %s: brings in %s, which the module never uses", f.File, f.Line, f.Module, f.Name))
	}
	if err := os.WriteFile(tsvPath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		return nil, err
	}
	key = joinKey(src+" unused-use "+unusedUseRules, b.envKey())
	if err := os.WriteFile(keyPath, []byte(fmt.Sprintf("%s %.1f\n", key, time.Since(start).Seconds())), 0o644); err != nil {
		return nil, err
	}
	return found, nil
}

var (
	instanceHead = regexp.MustCompile(`^\s*instance\s+([A-Za-z_][A-Za-z0-9_.:]*)\s*\[`)
	declHead     = regexp.MustCompile(`^\s*(pub\s+)?(mod|trait|enum|eff|type\s+alias|def)\b`)
)

// dropInstanceUses は flixlint の判定から、instance の頭（trait と型）か instance の def の中で使う use を外す（外した数も返す）。
// WhyNot: flixlint の判定に任せきりにしない。flixlint の汎用の AST は instance の def を持たない（コンパイラが instance の
// def に番号つきの名前を付け、作られた def と同じに外れる）ので、instance にだけ書いた名前の use を使っていないと言い、
// 消すとコンパイルが通らない。flixlint の shim が instance の def を AST に入れたら、この手当ては外す。
// WhyNot: instance の中だけで使う Java の import・effect は拾えない（索引に行が無い）。頭の `with` の trait も見ない。
func dropInstanceUses(root string, rows []Row, found []UseFinding) ([]UseFinding, int) {
	if len(found) == 0 {
		return found, 0
	}
	type key struct{ file, mod string }
	decls := map[string]bool{}     // def・enum・型 alias の名前（instance の型の owner と見分ける）
	instMod := map[string]string{} // instance の def → その mod
	type at struct {
		file, mod string
		line      int
		up        bool // 上へ instance の頭を探す（def の行から）。false はその行が頭
	}
	var heads []at
	for _, r := range rows {
		switch r.Kind {
		case KindDefDecl:
			decls[r.Sym] = true
			if r.HasFlag("inst") {
				instMod[r.Sym] = modOf(r.Sym)
				heads = append(heads, at{r.File, modOf(r.Sym), r.Line, true})
			}
		case KindEnumDecl, KindAliasDecl:
			decls[r.Sym] = true
		}
	}
	written := map[key][]string{}       // instance の def の中で書いた名前
	traits := map[key]map[string]bool{} // instance の頭に素の名前で書いた trait
	aliases := map[string]string{}      // file:line:名前 → use の別名
	for _, r := range rows {
		switch {
		case r.Kind == KindUse:
			aliases[fmt.Sprintf("%s:%d:%s", r.File, r.Line, r.Sym)] = r.Attr("alias")
		case !refKinds[r.Kind]:
		case instMod[r.Owner] != "":
			k := key{r.File, instMod[r.Owner]}
			written[k] = append(written[k], r.Sym)
		case r.Kind == KindTypeUse && !decls[r.Owner] && strings.Contains(r.Owner, "."):
			// instance の型の owner は `<mod>.<trait>`（instance に名前が無い）。その行が instance の頭で、型も頭が使う名前。
			heads = append(heads, at{r.File, modOf(r.Owner), r.Line, false})
			k := key{r.File, modOf(r.Owner)}
			written[k] = append(written[k], r.Sym)
		}
	}
	srcs := map[string][]string{}
	for _, h := range heads {
		lines, ok := srcs[h.file]
		if !ok {
			data, err := os.ReadFile(filepath.Join(root, h.file))
			if err != nil {
				continue
			}
			lines = strings.Split(string(data), "\n")
			srcs[h.file] = lines
		}
		for l := h.line; l >= 1 && l <= len(lines); l-- {
			if m := instanceHead.FindStringSubmatch(lines[l-1]); m != nil {
				if !strings.ContainsAny(m[1], ".:") {
					k := key{h.file, h.mod}
					if traits[k] == nil {
						traits[k] = map[string]bool{}
					}
					traits[k][m[1]] = true
				}
				break
			}
			if !h.up || l < h.line && declHead.MatchString(lines[l-1]) {
				break
			}
		}
	}
	var keep []UseFinding
	for _, f := range found {
		k := key{f.File, f.Module}
		local := aliases[fmt.Sprintf("%s:%d:%s", f.File, f.Line, f.Name)]
		if local == "" {
			local = lastSeg(f.Name)
		}
		used := traits[k][local]
		for _, n := range written[k] {
			used = used || n == f.Name || strings.HasPrefix(n, f.Name+".")
		}
		if !used {
			keep = append(keep, f)
		}
	}
	return keep, len(found) - len(keep)
}
