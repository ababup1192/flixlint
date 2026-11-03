package refactor

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 消す def だけが使っていた型（enum・型 alias）も消す: testdata/deadtype の Dungeon.describe を消すと、道連れの
// Dungeon.size と、size だけが使う非 pub の enum Node・Node の case だけが使う非 pub の型 alias Cell が使われなくなる
// （残すと Flix の Redundancy で落ちる）。pub の enum Shade は --allow-external の時だけ消し、それ以外は fix に回す。
// keep が使う Kept は残す。期待は deadtype の Dungeon.flix の書き方から手で書いた物。

func deadtypeRows(t *testing.T) []Row {
	t.Helper()
	rows, err := ReadIndex(filepath.Join("testdata", "deadtype-spans-resolved.tsv"), Resolved)
	must(t, err)
	return rows
}

func TestRemoveDeadTakesTypesOnlyTheRemovedDefsUsed(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "deadtype"), deadtypeRows(t), DeadQuery{Def: "Dungeon.describe"})
	must(t, err)
	if got, want := removedSyms(plan), []string{"Dungeon.Cell", "Dungeon.Node", "Dungeon.describe", "Dungeon.size"}; !equalSyms(got, want) {
		t.Fatalf("消す物 %v（want %v）", got, want)
	}
}

// pub の型は残し、人へ回す fix にせず知らせる（残してもコンパイルは通る）。
func TestRemoveDeadKeepsAPubTypeWithoutAllowExternalAndSaysSo(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "deadtype"), deadtypeRows(t), DeadQuery{Def: "Dungeon.describe"})
	must(t, err)
	if len(plan.Fix) != 0 || len(plan.TypeNotes) != 1 || !strings.Contains(plan.TypeNotes[0], "Dungeon.Shade") {
		t.Fatalf("fix %+v・知らせ %v（want fix 0・Shade の知らせ 1）", plan.Fix, plan.TypeNotes)
	}
}

// use で case を入れる型は消さない（消すと use が名前を失う）。その型の case の中だけが使う Cell も残る。
func TestRemoveDeadKeepsATypeWhoseCaseIsImported(t *testing.T) {
	rows := append(deadtypeRows(t), Row{Kind: KindUse, File: "src/Main.flix", Line: 1, Col: 1, Sym: "Dungeon.Node.Room", Owner: "Main"})
	plan, err := PlanDead(fixtureRoot(t, "deadtype"), rows, DeadQuery{Def: "Dungeon.describe", AllowExternal: true})
	must(t, err)
	if got, want := removedSyms(plan), []string{"Dungeon.Shade", "Dungeon.describe", "Dungeon.size"}; !equalSyms(got, want) {
		t.Fatalf("消す物 %v（want %v）", got, want)
	}
}

// --skip の型は消さない。
func TestRemoveDeadKeepsASkippedType(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "deadtype"), deadtypeRows(t), DeadQuery{Def: "Dungeon.describe", AllowExternal: true,
		Skip: map[string]bool{"src/Dungeon.flix:9": true}})
	must(t, err)
	if got, want := removedSyms(plan), []string{"Dungeon.Cell", "Dungeon.Node", "Dungeon.describe", "Dungeon.size"}; !equalSyms(got, want) {
		t.Fatalf("消す物 %v（want %v）", got, want)
	}
}

func TestRemoveDeadTakesAPubTypeWithAllowExternal(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "deadtype"), deadtypeRows(t), DeadQuery{Def: "Dungeon.describe", AllowExternal: true})
	must(t, err)
	if got, want := removedSyms(plan), []string{"Dungeon.Cell", "Dungeon.Node", "Dungeon.Shade", "Dungeon.describe", "Dungeon.size"}; !equalSyms(got, want) {
		t.Fatalf("消す物 %v（want %v）", got, want)
	}
}

// 書き換えの後に残るのは、使い手の残る Kept と keep だけ。
func TestRemoveDeadEditsLeaveOnlyWhatIsStillUsed(t *testing.T) {
	root := fixtureRoot(t, "deadtype")
	plan, err := PlanDead(root, deadtypeRows(t), DeadQuery{Def: "Dungeon.describe", AllowExternal: true})
	must(t, err)
	data, err := os.ReadFile(filepath.Join(root, "src", "Dungeon.flix"))
	must(t, err)
	got, err := ApplyEdits(string(data), plan.Edits)
	must(t, err)
	want := "mod Dungeon {\n    enum Kept {\n        case Only\n    }\n\n    pub def keep(): Int32 = match Kept.Only {\n        case Kept.Only => 1\n    }\n}\n"
	if got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
}

func removedSyms(p DeadPlan) []string {
	all := p
	all.Targets = append(append([]Fixed{}, p.Targets...), p.Types...)
	return targetSyms(all)
}

// 下見（--apply 無し）の報告にも、一緒に消す型を消す物として載せる。
func TestRemoveDeadDryRunListsTheTypes(t *testing.T) {
	root := fixtureRoot(t, "deadtype")
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, []string{"remove-dead", "--def", "Dungeon.describe", "--flixlint", filepath.Join(root, "flixlint")},
		Options{Run: spansRunner("deadtype"), Verify: verifyWith(0, "", &cmds), Log: io.Discard})
	text := out.String() + errOut.String()
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, text)
	}
	mustContain(t, text, "Dungeon.Node（道連れ（消す物だけが使っていた enum））")
	mustContain(t, text, "一緒に消す型 2")
}

// 開き括弧の直後の宣言を消す時は、後ろの空行も消す（`{` の直後に空行を残さない）。
func TestDeclLinesDropsTheBlankAfterAnOpeningBrace(t *testing.T) {
	src := "mod M {\n    def a(): Int32 = 1\n\n    def b(): Int32 = 2\n}\n"
	ext := Row{Line: 2, Col: 5, EndLine: 2, EndCol: 23}
	cut, _, err := declLines(src, ext, Row{File: "src/M.flix", Line: 2, Col: 9})
	must(t, err)
	if got, want := src[:cut[0]]+src[cut[1]:], "mod M {\n    def b(): Int32 = 2\n}\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}
