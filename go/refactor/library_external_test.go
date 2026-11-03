package refactor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ライブラリでも --allow-external なら pub の def を消す計画に入れる（索引の外の使い手は直らない）。
func TestPlanDeadOnALibraryWithAllowExternalRemovesThePublicDef(t *testing.T) {
	plan, err := PlanDead(filepath.Join("testdata", "proj"), zooRows(t), DeadQuery{WithTests: true, TestDirs: []string{"test"}, Library: true, AllowExternal: true})
	must(t, err)
	if deadSyms(plan.Targets)["Zoo.unused"] == "" {
		t.Errorf("消す %v・fix %v", deadSyms(plan.Targets), deadSyms(plan.Fix))
	}
}

// ライブラリでも pub でない def は索引の外から使えないので、名指せば消す。
func TestPlanDeadOnALibraryRemovesANonPublicDef(t *testing.T) {
	rows := []Row{
		{Kind: KindDefDecl, File: "src/M.flix", Line: 2, Col: 9, EndLine: 2, EndCol: 16, Sym: "M.getBean", Owner: "M.getBean", Extra: "ext=2:5:2:29"},
	}
	plan, err := PlanDead(libFixture(t), rows, DeadQuery{Def: "M.getBean", Library: true})
	must(t, err)
	if deadSyms(plan.Targets)["M.getBean"] == "" {
		t.Errorf("消す %v・fix %v", deadSyms(plan.Targets), deadSyms(plan.Fix))
	}
}

func TestRenameOnALibrary(t *testing.T) {
	root, rows := renameFixture(t)
	p, err := PlanRename(root, rows, "World.moveTo", "goTo", nil, true, false)
	must(t, err)
	if len(p.Fix) != 1 || !strings.Contains(p.Fix[0].Why, "--allow-external") {
		t.Errorf("pub の def は旗が無ければ fix で、旗の名前を言うはず: %v", p.Fix)
	}
	p, err = PlanRename(root, rows, "World.moveTo", "goTo", nil, true, true)
	must(t, err)
	if len(p.Fix) != 0 || len(p.Edits) == 0 {
		t.Errorf("--allow-external なら書く: fix %v", p.Fix)
	}
	rows[0].Extra = ""
	p, err = PlanRename(root, rows, "World.moveTo", "goTo", nil, true, false)
	must(t, err)
	if len(p.Fix) != 0 {
		t.Errorf("pub でない def はライブラリでも断らない: %v", p.Fix)
	}
}

func libFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "src"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "src", "M.flix"), []byte("mod M {\n    def getBean(): Int32 = 1\n}\n"), 0o644))
	return root
}

func TestVerifyRunsTheConfiguredCheckOnly(t *testing.T) {
	root := t.TempDir()
	var ran []string
	o := Options{Verify: func(cmd, dir, log string) int { ran = append(ran, cmd); return 0 }}
	var out strings.Builder
	code := verifyRun(&out, root, Config{Verify: "make check", VerifyTests: "make test"}, args{}, o)
	if code != 0 || len(ran) != 1 || ran[0] != "make check" || !strings.Contains(out.String(), "通った") {
		t.Errorf("code %d ran %v out %s", code, ran, out.String())
	}
	ran = nil
	code = verifyRun(&out, root, Config{Verify: "make check", VerifyTests: "make test"}, args{withTests: true}, Options{Verify: func(cmd, dir, log string) int { ran = append(ran, cmd); return 3 }})
	if code != 1 || len(ran) != 1 || ran[0] != "make test" {
		t.Errorf("--with-tests は verifyTests を流し、落ちれば 1: code %d ran %v", code, ran)
	}
}

func TestVerifyIsAnOperationInTheHelp(t *testing.T) {
	if u := opUsage("verify"); !strings.Contains(u, "verify [--with-tests]") {
		t.Errorf("%s", u)
	}
}

// ライブラリの make-private: 旗が無ければ同じ mod の中だけの pub も fix・--allow-external なら pub を外す。
func TestMakePrivateOnALibraryNeedsAllowExternal(t *testing.T) {
	rows, err := ReadIndex(filepath.Join("testdata", "refmore-spans-resolved.tsv"), Resolved)
	must(t, err)
	root := fixtureRoot(t, "refmore")
	plain, err := PlanPrivate(root, rows, PrivateQuery{TestDirs: []string{"test"}})
	must(t, err)
	if len(plain.Targets) == 0 {
		t.Skip("fixture に同じ mod の中だけの pub が無い")
	}
	lib, err := PlanPrivate(root, rows, PrivateQuery{TestDirs: []string{"test"}, Library: true})
	must(t, err)
	if len(lib.Targets) != 0 {
		t.Errorf("旗が無ければ外さない: %v", lib.Targets)
	}
	ext, err := PlanPrivate(root, rows, PrivateQuery{TestDirs: []string{"test"}, Library: true, AllowExternal: true})
	must(t, err)
	if len(ext.Targets) != len(plain.Targets) {
		t.Errorf("--allow-external ならライブラリでない時と同じだけ外す: %d・%d", len(ext.Targets), len(plain.Targets))
	}
}

// ライブラリの pub でない alias は断らない。
func TestRenameAliasOnALibraryLeavesANonPublicAlias(t *testing.T) {
	root, rows := aliasFixture(t)
	must(t, os.WriteFile(filepath.Join(root, "src/Tex.flix"), []byte("mod Tex {\n    type alias BillboardTexture = { id = Int32 }\n}\n"), 0o644))
	rows[0].Col, rows[0].EndCol = 16, 32
	p, err := PlanRenameAlias(root, rows, "Tex.BillboardTexture", "RegisteredTexture", true, false)
	must(t, err)
	if len(p.Fix) != 0 {
		t.Errorf("fix %v", p.Fix)
	}
}
