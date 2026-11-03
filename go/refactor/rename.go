package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// rename: def の名前を替える（refactor-tool-design §8.4 の rename・段 E）。宣言（def-decl）と、名前を書いた所全部
// （def-use: 呼び出し・名前で渡す所・`Mod.f` の形も `f` だけの形も）と、`use Mod.f`・`use Mod.{f, g}` の中の名前の、
// 書いた名前の最後の区切りだけを替える。`use Mod.{f => h}` の別名 h と、それを書いた所は替えない（別名は元の名前と
// 関わらない）。
//
// 人へ回す所（fix）: 書いた字が索引の名前で終わらない所（読めない書き方）・名前が文字列やコメント・入口のファイル
// （Makefile・json・flow）に字で出る所（名前で呼ばれるかもしれない。mentions.go）・ライブラリ（fpkg で配る。使い手は
// 索引の外）。同じ mod に新しい名前がもう在れば書かない（止める）。

// RenamePlan は rename の計画。
type RenamePlan struct {
	Edits []Edit
	Sites []Fixed // 替える所（宣言・使う所・use）
	Fix   []Fixed
	// Words は .flix のソースに元の名前が字で残る所（コメント・文字列。索引の外なので替えない。知らせるだけ）。
	Words []string
}

// identRe は Flix の def の名前（小文字か _ で始まる）。
var identRe = regexp.MustCompile(`^[a-z_][A-Za-z0-9_]*[!?']*$`)

// PlanRename は def s を to へ名前替えする計画。
func PlanRename(root string, rows []Row, s, to string, outside map[string]string, library, allowExternal bool) (RenamePlan, error) {
	var p RenamePlan
	if !identRe.MatchString(to) {
		return p, fmt.Errorf("--to %s は def の名前の形でない（小文字か _ で始まる）", to)
	}
	old := s[strings.LastIndex(s, ".")+1:]
	if old == to {
		return p, fmt.Errorf("--to が今の名前と同じ（%s）", to)
	}
	mod := modOf(s)
	newSym := to
	if mod != "" {
		newSym = mod + "." + to
	}
	var decl *Row
	for i, r := range rows {
		if r.Kind == KindDefDecl && r.Sym == newSym && !r.HasFlag("inst") {
			return p, fmt.Errorf("%s がもう在る（%s）。別の名前にするか、先にそちらを替える", newSym, r.Where())
		}
		if r.Kind == KindDefDecl && r.Sym == s {
			decl = &rows[i]
		}
	}
	if decl == nil {
		return p, fmt.Errorf("def %s の宣言が索引に無い", s)
	}
	if decl.HasFlag("inst") {
		return p, fmt.Errorf("%s は instance の def（%s）。名前は trait の sig が決める", s, decl.Where())
	}
	if library && decl.HasFlag("pub") && !allowExternal {
		p.Fix = append(p.Fix, Fixed{*decl, LibraryPubWhy})
	}
	if f := outside[s]; f != "" {
		p.Fix = append(p.Fix, Fixed{*decl, "名前が入口のファイルに字で出る（" + f + "）。そこは手で替える"})
	}
	w := newRenameWriter(root, &p, old, to)
	add, lastPart := w.add, w.lastPart
	add(*decl, "宣言", lastPart)
	for _, r := range rows {
		switch {
		case r.Kind == KindDefUse && r.Sym == s:
			add(r, "使う所", func(text string) (string, bool) {
				if repl, ok := lastPart(text); ok {
					return repl, true
				}
				// use で別名を付けて取り込んだ名前を書いた所（`h`）: 別名はそのまま
				if !strings.Contains(text, ".") && identRe.MatchString(text) {
					return text, true
				}
				return "", false
			})
		case r.Kind == KindUse && r.Sym == s:
			add(r, "use", func(text string) (string, bool) { return renameInUse(text, old, to) })
		}
	}
	p.Words = wordsLeft(root, rows, old, w.seen)
	sort.SliceStable(p.Sites, func(i, j int) bool { return p.Sites[i].Where() < p.Sites[j].Where() })
	sort.SliceStable(p.Fix, func(i, j int) bool { return p.Fix[i].Where() < p.Fix[j].Where() })
	return p, nil
}

// renameInUse は use の書いた字の中の元の名前を替える: `Mod.f`・`Mod.{f, g}`・`Mod.{f => h}`（=> の前の f だけ）。
func renameInUse(text, old, to string) (string, bool) {
	if strings.HasSuffix(text, "."+old) || text == old {
		return strings.TrimSuffix(text, old) + to, true
	}
	open := strings.Index(text, "{")
	if open < 0 || !strings.HasSuffix(strings.TrimSpace(text), "}") {
		return "", false
	}
	inner := text[open+1 : strings.LastIndex(text, "}")]
	parts := strings.Split(inner, ",")
	hit := false
	for i, part := range parts {
		name, rest, _ := strings.Cut(strings.TrimSpace(part), "=>")
		if strings.TrimSpace(name) != old {
			continue
		}
		lead := part[:len(part)-len(strings.TrimLeft(part, " \t\n"))]
		repl := lead + to
		if rest != "" {
			repl += " =>" + rest
		}
		parts[i] = repl
		hit = true
	}
	if !hit {
		return "", false
	}
	return text[:open+1] + strings.Join(parts, ",") + text[strings.LastIndex(text, "}"):], true
}

// renameReport は rename の入口。
func renameReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	if a.label != "" {
		return renameFieldReport(root, idx, a, cfg, o)
	}
	sym, err := Resolve(idx.Rows, a.def, map[string]bool{KindDefDecl: true, KindAliasDecl: true})
	if err != nil {
		return report{}, err
	}
	outside := loadMentions(root, engineDir(root)).withEntryDefs(idx.Rows, cfg.EntryTables).Entry
	var plan RenamePlan
	if isAliasSym(idx.Rows, sym) {
		plan, err = PlanRenameAlias(root, idx.Rows, sym, a.to, IsLibrary(root, cfg), a.allowExternal)
	} else {
		plan, err = PlanRename(root, idx.Rows, sym, a.to, outside, IsLibrary(root, cfg), a.allowExternal)
	}
	if err != nil {
		return report{}, err
	}
	how := a.applyWith(cfg.Verify, o)
	var out Outcome
	if len(plan.Fix) > 0 {
		out = Outcome{State: StateNothing}
		if a.apply {
			out.State, out.Reason = StateRefused, "人へ回す所があるので書かない（fix の理由を片付けてから）"
		}
	} else {
		out = Change(root, plan.Edits, how)
	}
	r := report{Op: "rename", Target: sym + " → " + a.to, code: CodeRename, Outcome: &out, Fix: plan.Fix}
	if a.allowExternal && IsLibrary(root, cfg) {
		r.extra = append(r.extra, ExternalNote)
	}
	r.got = len(plan.Fix)
	r.Sites = plan.Sites
	r.gotText = fmt.Sprintf("替える所 %d・人へ回す %d", len(plan.Sites), len(plan.Fix))
	r.wantText = "def の宣言・使う所・use の名前を替える（入口のファイルに字で出る・ライブラリ・読めない書き方は fix。fix があれば書かない）"
	for _, t := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s", t.Where(), t.Why, t.Sym))
	}
	if n := len(plan.Words); n > 0 {
		show := plan.Words
		if len(show) > 5 {
			show = show[:5]
		}
		r.extra = append(r.extra, fmt.Sprintf("元の名前が .flix のコメント・文字列に字で残る %d か所（替えない。要れば手で）: %s", n, strings.Join(show, "・")))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Sym, f.Why))
	}
	nextOf(&r, "flix-refactor rename --def "+a.def+" --to "+a.to, a, &out)
	if out.State == StateApplied {
		r.Done = fmt.Sprintf("done: %s → %s を %d か所 · check ok", sym, a.to, len(plan.Sites))
		r.Next, r.NextWhy = "flix-refactor usages "+modOf(sym)+"."+a.to, "替えた後の使われ所（参照の数が前と同じか）"
		r.lines = nil
	}
	return r, nil
}

// wordsLeft は、索引の行の在るファイル（.flix）で、元の名前が語として出るのに替える所（done の範囲）でない行の場所。
func wordsLeft(root string, rows []Row, old string, done map[string]bool) []string {
	word := regexp.MustCompile(`\b` + regexp.QuoteMeta(old) + `\b`)
	doneLines := map[string]bool{}
	for k := range done {
		parts := strings.SplitN(k, ":", 3)
		doneLines[parts[0]+":"+parts[1]] = true
	}
	files := map[string]bool{}
	for _, r := range rows {
		if strings.HasSuffix(r.File, ".flix") {
			files[r.File] = true
		}
	}
	names := make([]string, 0, len(files))
	for f := range files {
		names = append(names, f)
	}
	sort.Strings(names)
	var out []string
	for _, f := range names {
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			continue
		}
		for i, line := range strings.Split(string(b), "\n") {
			at := fmt.Sprintf("%s:%d", f, i+1)
			if word.MatchString(line) && !doneLines[at] {
				out = append(out, at)
			}
		}
	}
	return out
}

// typeNameRe は Flix の型の名前（大文字で始まる）。
var typeNameRe = regexp.MustCompile(`^[A-Z][A-Za-z0-9_]*$`)

func isAliasSym(rows []Row, sym string) bool {
	for _, r := range rows {
		if r.Kind == KindAliasDecl && r.Sym == sym {
			return true
		}
	}
	return false
}

// PlanRenameAlias は型 alias s を to へ名前替えする計画。宣言（alias-decl）・型に書いた所（type-use）・use の中の名前の、
// 書いた名前の最後の区切りだけを替える（def の rename と同じ決め）。use の別名（Mod.{T => U}）で書いた所は替えない。
// 同じ mod に同じ名前の型（alias・enum）が在れば止める。
// WhyNot: def と違って入口のファイル（Makefile・json）の名前を見ない。入口が名前で呼ぶのは def（jobs・main）だけで、型の名前は呼ばれない。
func PlanRenameAlias(root string, rows []Row, s, to string, library, allowExternal bool) (RenamePlan, error) {
	var p RenamePlan
	if !typeNameRe.MatchString(to) {
		return p, fmt.Errorf("--to %s は型の名前の形でない（大文字で始まる）", to)
	}
	old := s[strings.LastIndex(s, ".")+1:]
	if old == to {
		return p, fmt.Errorf("--to が今の名前と同じ（%s）", to)
	}
	newSym := to
	if mod := modOf(s); mod != "" {
		newSym = mod + "." + to
	}
	var decl *Row
	for i, r := range rows {
		if (r.Kind == KindAliasDecl || r.Kind == KindEnumDecl) && r.Sym == newSym {
			return p, fmt.Errorf("%s がもう在る（%s）。別の名前にするか、先にそちらを替える", newSym, r.Where())
		}
		if r.Kind == KindAliasDecl && r.Sym == s {
			decl = &rows[i]
		}
	}
	if decl == nil {
		return p, fmt.Errorf("型 alias %s の宣言が索引に無い", s)
	}
	w := newRenameWriter(root, &p, old, to)
	add, lastPart := w.add, w.lastPart
	if library && !allowExternal && isPubAliasAt(w.read, *decl) {
		p.Fix = append(p.Fix, Fixed{*decl, LibraryPubWhy})
	}
	add(*decl, "宣言", lastPart)
	for _, r := range rows {
		switch {
		case r.Kind == KindTypeUse && r.Sym == s:
			add(r, "型の注記", func(text string) (string, bool) {
				if repl, ok := lastPart(text); ok {
					return repl, true
				}
				// use で別名を付けて取り込んだ名前（`U`）を書いた所: 別名はそのまま
				if !strings.Contains(text, ".") && typeNameRe.MatchString(text) {
					return text, true
				}
				return "", false
			})
		case r.Kind == KindUse && r.Sym == s:
			add(r, "use", func(text string) (string, bool) { return renameInUse(text, old, to) })
		}
	}
	p.Words = wordsLeft(root, rows, old, w.seen)
	sort.SliceStable(p.Sites, func(i, j int) bool { return p.Sites[i].Where() < p.Sites[j].Where() })
	sort.SliceStable(p.Fix, func(i, j int) bool { return p.Fix[i].Where() < p.Fix[j].Where() })
	return p, nil
}

// isPubAliasAt は alias の宣言の行が pub か（索引の alias-decl は pub の印を持たない）。
func isPubAliasAt(read func(string) (string, error), d Row) bool {
	src, err := read(d.File)
	if err != nil {
		return true
	}
	lines := strings.Split(src, "\n")
	if d.Line < 1 || d.Line > len(lines) {
		return true
	}
	return pubAliasLine.MatchString(lines[d.Line-1])
}

var pubAliasLine = regexp.MustCompile(`\bpub\s+type\s+alias\b`)

// renameWriter は rename の書く所を集める（同じ所は 1 度・書いた字が当たらなければ fix）。
type renameWriter struct {
	root, old, to string
	p             *RenamePlan
	files         map[string]string
	seen          map[string]bool
}

func newRenameWriter(root string, p *RenamePlan, old, to string) *renameWriter {
	return &renameWriter{root: root, old: old, to: to, p: p, files: map[string]string{}, seen: map[string]bool{}}
}

func (w *renameWriter) read(file string) (string, error) {
	if src, ok := w.files[file]; ok {
		return src, nil
	}
	b, err := os.ReadFile(filepath.Join(w.root, file))
	if err != nil {
		return "", err
	}
	w.files[file] = string(b)
	return w.files[file], nil
}

// lastPart は書いた名前の最後の区切りだけを替える（old・Mod.old）。
func (w *renameWriter) lastPart(text string) (string, bool) {
	switch {
	case text == w.old:
		return w.to, true
	case strings.HasSuffix(text, "."+w.old):
		return strings.TrimSuffix(text, w.old) + w.to, true
	}
	return "", false
}

func (w *renameWriter) add(r Row, why string, edit func(text string) (string, bool)) {
	key := fmt.Sprintf("%s:%d:%d:%d:%d", r.File, r.Line, r.Col, r.EndLine, r.EndCol)
	if w.seen[key] {
		return
	}
	w.seen[key] = true
	src, err := w.read(r.File)
	if err != nil {
		w.p.Fix = append(w.p.Fix, Fixed{r, err.Error()})
		return
	}
	start, end, err := ByteRange(src, r)
	if err != nil {
		w.p.Fix = append(w.p.Fix, Fixed{r, "索引が古い（flix-refactor index --rebuild）"})
		return
	}
	text := src[start:end]
	repl, ok := edit(text)
	if !ok {
		w.p.Fix = append(w.p.Fix, Fixed{r, fmt.Sprintf("書いた字 %q が %s で終わらない（読めない書き方）", text, w.old)})
		return
	}
	if repl == text {
		return
	}
	w.p.Edits = append(w.p.Edits, Edit{File: r.File, Start: start, End: end, Site: r,
		Check: []Want{{Span: r, Text: text}},
		Make:  func(string) (string, error) { return repl, nil }})
	w.p.Sites = append(w.p.Sites, Fixed{r, why})
}

// labelRe は record の欄の名前。
var labelRe = regexp.MustCompile(`^[a-z_][A-Za-z0-9_]*$`)

// RenameRecordField は record の字（型か式。`{` から）の欄 old の名前を to に替える。
func RenameRecordField(text, old, to string) (string, error) {
	u, _, err := ParseRecord(text)
	if err != nil {
		return "", err
	}
	k := u.Find(old)
	if k < 0 {
		return "", fmt.Errorf("欄 %s が無い", old)
	}
	at := u.Fields[k].Start
	if !strings.HasPrefix(text[at:], old) {
		return "", fmt.Errorf("欄 %s の位置が読めない", old)
	}
	return text[:at] + to + text[at+len(old):], nil
}

// renameFieldReport は rename --label x (--receiver T | --case E.C) --to y: record の型の欄の名前を替え、組み立て（record の式）・
// 直の読み（e#x）・書き（{ x = v | e }）を全部替える（typed の段）。受け手が証明できない読み書き（maybe・ambiguous）と、
// 欄の組が同じ別の型の組み立ては fix（fix があれば書かない）。
func renameFieldReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	if !labelRe.MatchString(a.to) {
		return report{}, fmt.Errorf("--to %s は欄の名前の形でない（小文字か _ で始まる）", a.to)
	}
	if a.receiver == "" && a.caseName == "" {
		return report{}, fmt.Errorf("欄の rename は --receiver T（record の alias）か --case E.C が要ります")
	}
	srcs, err := loadSources(root, cfg)
	if err != nil {
		return report{}, err
	}
	shape, err := shapeOf(idx, a, srcs)
	if err != nil {
		return report{}, err
	}
	switch {
	case !shape.Has(a.label):
		return report{}, fmt.Errorf("型 %s に欄 %s が無い", shape.Name, a.label)
	case shape.Has(a.to):
		return report{}, fmt.Errorf("型 %s に欄 %s がもう在る", shape.Name, a.to)
	}
	old, to := a.label, a.to
	var edits []Edit
	var sites, fix []Fixed
	typeRow := rowAt(shape.File, srcs[shape.File], shape.Brace, shape.Name)
	if IsLibrary(root, cfg) && !a.allowExternal && isPubShape(idx.Rows, srcs, a) {
		fix = append(fix, Fixed{typeRow, LibraryPubWhy})
	}
	edits = append(edits, Edit{File: shape.File, Start: shape.Brace, End: shape.End, Site: typeRow,
		Make: func(cur string) (string, error) { return RenameRecordField(cur, old, to) }})
	sites = append(sites, Fixed{typeRow, "型の欄"})
	ans := FieldSites(idx.Rows, FieldQuery{Label: old, Receiver: a.receiver, Case: a.caseName, Op: "rename --label"})
	rw, built := 0, 0
	fix = append(fix, extendSites(srcs, old)...)
	for _, s := range ans.Unsure {
		fix = append(fix, Fixed{s.Row, "受け手が証明できない読み書き（" + s.Recv + "）。当たるかを決めて手で替える"})
	}
	for _, s := range ans.Sites {
		src := srcs[s.File]
		st, en, err := ByteRange(src, s.Row)
		if err != nil || src[st:en] != old {
			fix = append(fix, Fixed{s.Row, "索引が古い（flix-refactor index --stage typed --rebuild）"})
			continue
		}
		why := "読み"
		if s.Write {
			why = "書き"
		}
		rw++
		edits = append(edits, Edit{File: s.File, Start: st, End: en, Site: s.Row,
			Check: []Want{{Span: s.Row, Text: old}},
			Make:  func(string) (string, error) { return to, nil }})
		sites = append(sites, Fixed{s.Row, why})
	}
	key := fieldKey(shape.Fields)
	var others []string
	for _, at := range AllShapeKeys(srcs)[key] {
		if at != fmt.Sprintf("%s:%d", shape.File, shape.Brace) {
			others = append(others, at[:strings.LastIndex(at, ":")])
		}
	}
	err = eachLiteral(idx.Rows, srcs, func(d Row, src string, l Literal) {
		if fieldKey(l.Fields) != key {
			return
		}
		row := rowAt(d.File, src, l.Brace, d.Sym)
		if len(others) > 0 {
			fix = append(fix, Fixed{row, "欄の組が同じ別の型がある（" + strings.Join(others, "・") + "）。どちらを組み立てているか決められない"})
			return
		}
		edits = append(edits, Edit{File: d.File, Start: l.Brace, End: l.End, Site: row,
			Make: func(cur string) (string, error) { return RenameRecordField(cur, old, to) }})
		sites = append(sites, Fixed{row, "組み立て"})
		built++
	})
	if err != nil {
		return report{}, err
	}
	var out Outcome
	if len(fix) > 0 {
		out = Outcome{State: StateNothing}
		if a.apply {
			out.State, out.Reason = StateRefused, "人へ回す所があるので書かない（fix の理由を片付けてから）"
		}
	} else {
		out = Change(root, edits, a.applyWith(cfg.Verify, o))
	}
	r := report{Op: "rename", Target: shape.Name + "#" + old + " → " + to, code: CodeRename, Outcome: &out, Fix: fix}
	r.got = len(fix)
	r.Sites = sites
	r.gotText = fmt.Sprintf("替える所 %d（型 1・読み書き %d・組み立て %d）・人へ回す %d", len(sites), rw, built, len(fix))
	r.wantText = "型の欄・組み立て・直の読み書きの名前を替える（受け手が決まらない読み書き・欄の組が同じ別の型の組み立ては fix）"
	r.extra = append(r.extra, shapeNote(shape))
	if a.allowExternal && IsLibrary(root, cfg) {
		r.extra = append(r.extra, ExternalNote)
	}
	for _, t := range sites {
		r.lines = append(r.lines, fmt.Sprintf("%s	%s	%s", t.Where(), t.Why, t.Owner))
	}
	for _, f := range fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s	fix	%s", f.Where(), f.Why))
	}
	nextOf(&r, fmt.Sprintf("flix-refactor rename --label %s %s --to %s", old, shapeFlag(a), to), a, &out)
	if out.State == StateApplied {
		r.Next, r.NextWhy = fmt.Sprintf("flix-refactor field-sites --label %s %s", old, shapeFlag(a)), "前の名前の読み書きが 0 か"
	}
	return r, nil
}

// isPubShape は欄を替える型が pub か（alias はその宣言の行・case はいつも pub と見る）。
// WhyNot: case の record は enum の pub を引かない。pub でない enum の case の欄を替えるのは稀で、断る側に倒す。
func isPubShape(rows []Row, srcs map[string]string, a args) bool {
	if a.caseName != "" {
		return true
	}
	sym, err := Resolve(rows, a.receiver, map[string]bool{KindAliasDecl: true})
	if err != nil {
		return true
	}
	for _, r := range rows {
		if r.Kind == KindAliasDecl && r.Sym == sym {
			return isPubAliasAt(func(f string) (string, error) { return srcs[f], nil }, r)
		}
	}
	return true
}

// extendSites は欄 label を足す・外す式（`{ +x = v | r }`・`{ -x | r }`）の場所。索引に行が無く、受け手を決められないので fix。
// WhyNot: 匿名の record の型（`r: { x = Int32 }`）と record のパターンは見ない。欄の組で当てる組み立てと同じく確かめで
// 落ちて戻るので、ここでは拾い切らない（Usage に書いた）。
func extendSites(srcs map[string]string, label string) []Fixed {
	re := regexp.MustCompile(`\{\s*[+-]` + regexp.QuoteMeta(label) + `\b`)
	files := make([]string, 0, len(srcs))
	for f := range srcs {
		files = append(files, f)
	}
	sort.Strings(files)
	var out []Fixed
	for _, f := range files {
		src := srcs[f]
		for _, m := range re.FindAllStringIndex(src, -1) {
			out = append(out, Fixed{rowAt(f, src, m[0], ""), "欄を足す・外す式（{ +" + label + " … }・{ -" + label + " … }）。受け手が決まらないので手で"})
		}
	}
	return out
}
