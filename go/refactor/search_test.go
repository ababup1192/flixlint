package refactor

import (
	"os"
	"path/filepath"
	"testing"
)

func syms(fs []Found) []string {
	out := make([]string, len(fs))
	for i, f := range fs {
		out[i] = f.Sym
	}
	return out
}

// 名前がそのまま → 頭が同じ → 語の頭から → 途中に含む。同じ内は src → test。
func TestSearchRanksExactThenPrefixThenWordThenSubstring(t *testing.T) {
	all := []Found{
		{Sym: "G.center", Kind: "def", File: "src/G.flix"},
		{Sym: "R.pickEnter", Kind: "def", File: "src/R.flix"},
		{Sym: "T.enterTest", Kind: "def", File: "test/T.flix"},
		{Sym: "W.enterFight", Kind: "def", File: "src/W.flix"},
		{Sym: "W.enter", Kind: "def", File: "src/W.flix"},
		{Sym: "W.Exit", Kind: "enum", File: "src/W.flix"},
	}
	got := syms(Search(all, "enter", "", nil))
	want := []string{"W.enter", "W.enterFight", "T.enterTest", "R.pickEnter", "G.center"}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%v（%v のはず）", got, want)
		}
	}
	if got := syms(Search(all, "W.enter", "def", nil)); len(got) != 2 || got[0] != "W.enter" {
		t.Errorf("mod つき: %v", got)
	}
}

// 直したファイルは字から拾う: mod の直下の宣言と enum の case。局所の def（字下げが深い）は拾わない。
func TestTextDeclsTakesTopLevelOnly(t *testing.T) {
	src := "mod Foo {\n    pub enum E {\n        case A\n        case B(Int32)\n    }\n    def f(): Int32 =\n        def loop(x) = x;\n        loop(1)\n    pub type alias R = { x = Int32 }\n}\n"
	got := textDecls("src/Foo.flix", src)
	want := []string{"Foo.E", "Foo.E.A", "Foo.E.B", "Foo.f", "Foo.R"}
	if s := syms(got); len(s) != len(want) || s[3] != "Foo.f" || s[4] != "Foo.R" {
		t.Fatalf("%v（%v のはず）", s, want)
	}
	if !got[0].Pub || got[3].Pub || got[3].Line != 6 || !got[3].Text {
		t.Errorf("%+v", got)
	}
}

// outline は行の順に頭の行つき。1 行の enum の case は出さない。
func TestOutlineSortsAndSkipsOneLineEnumCase(t *testing.T) {
	src := &srcCache{root: "testdata/spans"}
	all := []Found{
		{Sym: "Shapes.area", Kind: "def", File: "src/Shapes.flix", Line: 15},
		{Sym: "Shapes.Shape", Kind: "enum", File: "src/Shapes.flix", Line: 5},
		{Sym: "Shapes.Shape.Dot", Kind: "case", File: "src/Shapes.flix", Line: 8},
		{Sym: "Shapes.Shape.X", Kind: "case", File: "src/Shapes.flix", Line: 5},
	}
	got := Outline(all, "src/Shapes.flix", src)
	if len(got) != 3 || got[0].Line != 5 || got[1].Line != 8 || got[2].Sig != "pub def area(s: Shape): Int32 = match s {" {
		t.Errorf("%+v", got)
	}
}

// 名前に当たらない時は、宣言の /// コメント（@ の注記の上も）に含む物を後ろに並べ、doc の印を付ける。
func TestSearchFallsBackToDocComments(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "mod B {\n    /// 受けた傷の半分を返す反撃。\n    @Experimental\n    pub def riposteBack(x: Int32): Int32 = x / 2\n\n    /// 反撃の名前を持つ。\n    pub def counterName(): String = \"riposte\"\n    pub def plain(): Int32 = 1\n}\n"
	if err := os.WriteFile(filepath.Join(root, "src", "B.flix"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	all := []Found{{Sym: "B.riposteBack", Kind: "def", File: "src/B.flix", Line: 4}, {Sym: "B.counterName", Kind: "def", File: "src/B.flix", Line: 7},
		{Sym: "B.plain", Kind: "def", File: "src/B.flix", Line: 8}, {Sym: "B.reflect", Kind: "def", File: "src/B.flix", Line: 8}}
	doc := docOf(&srcCache{root: root})
	got := Search(all, "反撃", "", doc)
	if len(got) != 2 || !got[0].Doc || !got[1].Doc || got[0].Sym+got[1].Sym != "B.counterNameB.riposteBack" {
		t.Errorf("コメントで引けていない: %+v", got)
	}
	if got := Search(all, "reflect", "", doc); len(got) != 1 || got[0].Doc {
		t.Errorf("名前の当たりは doc にしない: %+v", got)
	}
}
