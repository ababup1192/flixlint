package refactor

import (
	"strings"
	"testing"
)

func TestFindEffectRowReadsTheForms(t *testing.T) {
	for _, c := range []struct {
		src    string
		terms  []string
		braces bool
		has    bool
	}{
		{"def f(x: Int32): Int32 \\ IO + Window = x", []string{"IO", "Window"}, false, true},
		{"def f[a](x: a): a \\ {IO, Exit} with Eq[a] = x", []string{"IO", "Exit"}, true, true},
		{"def f(r: { x = Int32 }): Int32 = r#x", nil, false, false},
		{"def f(): Unit \\ ef + Game.Platform.Window =\n    ()", []string{"ef", "Game.Platform.Window"}, false, true},
	} {
		row, err := FindEffectRow(c.src, len("def f"))
		if err != nil {
			t.Fatalf("%q: %v", c.src, err)
		}
		if strings.Join(row.Terms, ",") != strings.Join(c.terms, ",") || row.Braces != c.braces || (row.Start != row.End) != c.has {
			t.Errorf("%q: %+v", c.src, row)
		}
	}
}

func TestEffectEditsTheRowOnly(t *testing.T) {
	for _, c := range []struct{ src, add, remove, want string }{
		{"def f(x: Int32): Int32 \\ IO + Window = x", "", "Window", "def f(x: Int32): Int32 \\ IO = x"},
		{"def f(x: Int32): Int32 \\ IO + Window = x", "Audio", "Window", "def f(x: Int32): Int32 \\ IO + Audio = x"},
		{"def f(x: Int32): Int32 \\ Window = x", "", "Window", "def f(x: Int32): Int32 = x"},
		{"def f(x: Int32): Int32 = x", "IO", "", "def f(x: Int32): Int32 \\ IO = x"},
		{"def f[a](x: a): a \\ {IO, Exit} with Eq[a] = x", "Window", "Exit", "def f[a](x: a): a \\ {IO, Window} with Eq[a] = x"},
	} {
		row, err := FindEffectRow(c.src, len("def f"))
		must(t, err)
		terms, err := WithEffects(row.Terms, splitList(c.add), splitList(c.remove))
		must(t, err)
		start, end, after := row.Edit(c.src, terms)
		if got := c.src[:start] + after + c.src[end:]; got != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.src, got, c.want)
		}
	}
}

func TestWithEffectsStopsOnAMissingEffect(t *testing.T) {
	if _, err := WithEffects([]string{"IO"}, nil, []string{"Window"}); err == nil {
		t.Error("列に無い effect を外せと言われたら止まるはず")
	}
	if _, err := splitEffectTerms("IO - Exit"); err == nil {
		t.Error("- の式は読めないとして止まるはず")
	}
}

func TestFindEffectRowStopsOnAnUnbracketedFunctionReturn(t *testing.T) {
	if _, err := FindEffectRow("def f(x: Int32): Int32 -> Int32 \\ IO = y -> y", len("def f")); err == nil {
		t.Error("括弧の無い関数の型の戻りでは、どの列か決められないので止まるはず")
	}
	if row, err := FindEffectRow("def f(g: Int32 -> Int32 \\ IO): Int32 \\ Exit = g(1)", len("def f")); err != nil || strings.Join(row.Terms, ",") != "Exit" {
		t.Errorf("引数の中の列は def の列でない: %+v %v", row, err)
	}
}

func TestWithEffectsReplacesPure(t *testing.T) {
	got, err := WithEffects([]string{"Pure"}, []string{"IO"}, nil)
	if err != nil || strings.Join(got, ",") != "IO" {
		t.Errorf("Pure に足すと Pure を消して置き換えるはず: %v %v", got, err)
	}
}

func TestChangeSignatureRefusesParamsWithEffects(t *testing.T) {
	var out, errOut strings.Builder
	code := Run(&out, &errOut, t.TempDir(), []string{"change-signature", "--def", "A.f", "--params", "x: Int32", "--args", "x", "--add-effect", "IO"}, Options{})
	if code != 2 || !strings.Contains(errOut.String(), "一緒に使えない") {
		t.Errorf("code %d: %s", code, errOut.String())
	}
}

func TestRenameRefusesANameAndALabelTogether(t *testing.T) {
	var out, errOut strings.Builder
	code := Run(&out, &errOut, t.TempDir(), []string{"rename", "World.speed", "--label", "speed", "--receiver", "World", "--to", "v"}, Options{})
	if code != 2 || !strings.Contains(errOut.String(), "どちらか 1 つ") {
		t.Errorf("code %d: %s", code, errOut.String())
	}
}
