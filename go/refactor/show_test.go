package refactor

import (
	"strings"
	"testing"
)

// def は索引の ext= の範囲（match の本文の閉じ括弧まで）。
func TestShowDefUsesTheIndexExtent(t *testing.T) {
	s, err := ShowDecl(loadFixture(t, Resolved), "area", fixtureSrc())
	must(t, err)
	if s.Kind != "def" || s.Start != 15 || s.End != 19 || !strings.HasSuffix(s.Text, "    }") {
		t.Errorf("%+v", s)
	}
}

// enum は括弧を数えて閉じるまで。case はそれを持つ enum を見せる。
func TestShowCaseShowsItsEnum(t *testing.T) {
	rows := loadFixture(t, Resolved)
	s, err := ShowDecl(rows, "Shape.Dot", fixtureSrc())
	must(t, err)
	if s.Kind != "enum" || s.Via != "Shapes.Shape.Dot" || s.Start != 5 || s.End != 9 {
		t.Errorf("%+v", s)
	}
}

// 1 行の型 alias は `=` の行で終わる（`{ … }` を閉じた所）。
func TestShowOneLineAlias(t *testing.T) {
	s, err := ShowDecl(loadFixture(t, Resolved), "Shapes.World", fixtureSrc())
	must(t, err)
	if s.Start != 11 || s.End != 11 {
		t.Errorf("%+v", s)
	}
}

// 括弧を数える時、字の列とコメントの中の物は数えない。上の /// と @ は範囲に入れる。
func TestBodyEndSkipsStringsAndTakesDoc(t *testing.T) {
	lines := strings.Split("    /// doc {\n    @Deprecated\n    pub enum E {\n        case A // }\n        case B(String) \"}\"\n    }\n    def x(): Int32 = 1", "\n")
	r := Row{Kind: KindEnumDecl, Line: 3, Col: 14}
	if s, e := declRange(r, lines); s != 1 || e != 6 {
		t.Errorf("%d-%d（1-6 のはず）", s, e)
	}
}

func TestClipShownKeepsTheDocAndSignature(t *testing.T) {
	text := "    /// 傷を数える。\n    /// 二行目。\n    pub def damage(a: Int32,\n                   b: Int32): Int32 =\n        let c = a + b;\n        c * 2"
	if got := clipShown(text, true, 0); got != "    /// 傷を数える。\n    /// 二行目。\n    pub def damage(a: Int32,\n                   b: Int32): Int32 =\n    …（あと 2 行。全部は --head・--lines を外す）" {
		t.Errorf("--head:\n%s", got)
	}
	if got := clipShown(text, false, 3); !strings.HasSuffix(got, "pub def damage(a: Int32,\n    …（あと 3 行。全部は --head・--lines を外す）") {
		t.Errorf("--lines 3:\n%s", got)
	}
	if got := clipShown(text, false, 0); got != text {
		t.Errorf("旗なしは全部:\n%s", got)
	}
}
