package refactor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func aliasFixture(t *testing.T) (string, []Row) {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		"src/Tex.flix": "mod Tex {\n    pub type alias BillboardTexture = { id = Int32 }\n}\n",
		"src/A.flix":   "mod A {\n    pub def a(t: Tex.BillboardTexture): Int32 = t#id\n}\n",
		"src/B.flix":   "mod B {\n    use Tex.BillboardTexture\n    pub def b(t: BillboardTexture): Int32 = t#id\n}\n",
		"src/C.flix":   "mod C {\n    use Tex.{BillboardTexture => BT}\n    pub def c(t: BT): Int32 = t#id\n}\n",
	}
	for f, src := range files {
		must(t, os.MkdirAll(filepath.Join(root, filepath.Dir(f)), 0o755))
		must(t, os.WriteFile(filepath.Join(root, f), []byte(src), 0o644))
	}
	rows := []Row{
		{Kind: KindAliasDecl, File: "src/Tex.flix", Line: 2, Col: 20, EndLine: 2, EndCol: 36, Sym: "Tex.BillboardTexture", Owner: "Tex.BillboardTexture"},
		{Kind: KindTypeUse, File: "src/A.flix", Line: 2, Col: 18, EndLine: 2, EndCol: 38, Sym: "Tex.BillboardTexture", Owner: "A.a", Extra: "what=alias"},
		{Kind: KindUse, File: "src/B.flix", Line: 2, Col: 13, EndLine: 2, EndCol: 29, Sym: "Tex.BillboardTexture", Owner: "B", Extra: "alias=BillboardTexture what=alias"},
		{Kind: KindTypeUse, File: "src/B.flix", Line: 3, Col: 18, EndLine: 3, EndCol: 34, Sym: "Tex.BillboardTexture", Owner: "B.b", Extra: "what=alias"},
		{Kind: KindUse, File: "src/C.flix", Line: 2, Col: 9, EndLine: 2, EndCol: 37, Sym: "Tex.BillboardTexture", Owner: "C", Extra: "alias=BT what=alias"},
		{Kind: KindTypeUse, File: "src/C.flix", Line: 3, Col: 18, EndLine: 3, EndCol: 20, Sym: "Tex.BillboardTexture", Owner: "C.c", Extra: "what=alias"},
	}
	return root, rows
}

func applyPlan(t *testing.T, root string, es []Edit) map[string]string {
	t.Helper()
	byFile := map[string][]Edit{}
	for _, e := range es {
		byFile[e.File] = append(byFile[e.File], e)
	}
	got := map[string]string{}
	for f, es := range byFile {
		src, _ := os.ReadFile(filepath.Join(root, f))
		out, err := ApplyEdits(string(src), es)
		must(t, err)
		got[f] = out
	}
	return got
}

func TestRenameAliasWritesTheDeclarationTheTypesAndTheUse(t *testing.T) {
	root, rows := aliasFixture(t)
	p, err := PlanRenameAlias(root, rows, "Tex.BillboardTexture", "RegisteredTexture", false, false)
	must(t, err)
	if len(p.Fix) != 0 {
		t.Fatalf("fix: %v", p.Fix)
	}
	got := applyPlan(t, root, p.Edits)
	want := map[string]string{
		"src/Tex.flix": "mod Tex {\n    pub type alias RegisteredTexture = { id = Int32 }\n}\n",
		"src/A.flix":   "mod A {\n    pub def a(t: Tex.RegisteredTexture): Int32 = t#id\n}\n",
		"src/B.flix":   "mod B {\n    use Tex.RegisteredTexture\n    pub def b(t: RegisteredTexture): Int32 = t#id\n}\n",
		"src/C.flix":   "mod C {\n    use Tex.{RegisteredTexture => BT}\n    pub def c(t: BT): Int32 = t#id\n}\n",
	}
	for f, w := range want {
		if got[f] != w {
			t.Errorf("%s:\n got %q\nwant %q", f, got[f], w)
		}
	}
}

func TestRenameAliasOnALibraryAsksForAllowExternal(t *testing.T) {
	root, rows := aliasFixture(t)
	p, err := PlanRenameAlias(root, rows, "Tex.BillboardTexture", "RegisteredTexture", true, false)
	must(t, err)
	if len(p.Fix) != 1 || !strings.Contains(p.Fix[0].Why, "--allow-external") {
		t.Errorf("fix %v", p.Fix)
	}
}

func TestRenameAliasStopsOnATypeThatIsThere(t *testing.T) {
	root, rows := aliasFixture(t)
	rows = append(rows, Row{Kind: KindEnumDecl, File: "src/Tex.flix", Line: 9, Col: 10, EndLine: 9, EndCol: 27, Sym: "Tex.RegisteredTexture"})
	if _, err := PlanRenameAlias(root, rows, "Tex.BillboardTexture", "RegisteredTexture", false, false); err == nil || !strings.Contains(err.Error(), "もう在る") {
		t.Errorf("err %v", err)
	}
	if _, err := PlanRenameAlias(root, rows, "Tex.BillboardTexture", "registered", false, false); err == nil {
		t.Error("小文字の名前は型の名前でない")
	}
}

func TestRenameFieldWritesTheTypeTheConstructionsAndTheReadsAndWrites(t *testing.T) {
	root := shape(t, nil)
	code, text := runShape(t, root, func(string, string, string) int { return 0 }, "rename", "--label", "clock", "--receiver", "World", "--to", "time", "--apply")
	if code != 0 || !strings.Contains(text, "applied") {
		t.Fatalf("code %d\n%s", code, text)
	}
	src := read(t, root, "src/Shape.flix")
	for _, want := range []string{"        time = Float64,", "          time = 0.0,", "old = true, time = 1.0,", "{ time = w#time + 1.0 | w }", "pub type alias Pair = { speed = Int32, clock = Float64 }", "{ speed = 3, clock = 2.0 }"} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い:\n%s", want, src)
		}
	}
}

func TestRenameFieldLeavesAnUnprovedReceiverToThePerson(t *testing.T) {
	root := shape(t, nil)
	code, text := runShape(t, root, nil, "rename", "--label", "speed", "--receiver", "World", "--to", "velocity", "--apply")
	if code != 2 || !strings.Contains(text, "受け手が証明できない") || !strings.Contains(text, "refused") {
		t.Errorf("code %d\n%s", code, text)
	}
}

func TestExtendSitesFindsAddAndRemoveOfTheLabel(t *testing.T) {
	got := extendSites(map[string]string{"src/A.flix": "def a(r: R): R = { +clock = 1.0 | r }\ndef b(r: R) = { -clock | r }\ndef c(r: R) = { +clockwise = 1 | r }\n"}, "clock")
	if len(got) != 2 || got[0].Line != 1 || got[1].Line != 2 {
		t.Errorf("%+v", got)
	}
}
