package refactor

import (
	"path/filepath"
	"strings"
	"testing"
)

// testdata/inst: Save.parse を Saveable の instance の def の中から 1 か所・テストから 2 か所呼ぶ。
// testdata/inst-spans-resolved.tsv はそれに flixlint --spans --stage resolved src test を掛けた物。

func instRows(t *testing.T) []Row {
	t.Helper()
	rows, err := ReadIndex(filepath.Join("testdata", "inst-spans-resolved.tsv"), Resolved)
	must(t, err)
	return rows
}

func TestUsagesCountsTheCallInsideAnInstanceAsSrc(t *testing.T) {
	rows := instRows(t)
	tg, err := ResolveTarget(rows, "Save.parse")
	must(t, err)
	var src int
	for _, u := range SymbolUsages(rows, tg, &srcCache{root: filepath.Join("testdata", "inst")}) {
		if u.What == WhatCall && u.Owner == "Save.fromText" && filepath.Dir(u.File) == "src" {
			src++
		}
	}
	if src != 1 {
		t.Errorf("instance の def Save.fromText の中の呼び出し %d（want 1）", src)
	}
}

func TestInstanceDefIsDeclaredUnderItsModule(t *testing.T) {
	defs, _ := defTable(instRows(t))
	if d, ok := defs["Save.fromText"]; !ok || !d.Inst {
		t.Errorf("Save.fromText の宣言 %+v（want inst の def）", d)
	}
}

func TestRemoveDeadKeepsADefCalledFromAnInstanceOfItsModule(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "inst"), instRows(t), DeadQuery{TestDirs: []string{"test"}, WithTests: true})
	must(t, err)
	if len(plan.Targets) != 0 {
		t.Errorf("消す def %v（want 無し: Save.parse は同じ mod の instance から呼ばれる）", targetSyms(plan))
	}
	if len(plan.Fix) != 1 || plan.Fix[0].Sym != "Save.parse" || !strings.Contains(plan.Fix[0].Why, "同じ mod の中で 1 か所") {
		t.Errorf("人へ回す %+v（want Save.parse を同じ mod の中で 1 か所使うので）", plan.Fix)
	}
}

func TestRenameRefusesAnInstanceDef(t *testing.T) {
	_, err := PlanRename(fixtureRoot(t, "inst"), instRows(t), "Save.fromText", "fromStr", nil, false)
	if err == nil || !strings.Contains(err.Error(), "instance の def") {
		t.Errorf("err %v（want instance の def で止める）", err)
	}
}

func TestRenameToTheNameOfAnInstanceDefIsAllowed(t *testing.T) {
	_, err := PlanRename(fixtureRoot(t, "inst"), instRows(t), "Save.parse", "fromText", nil, false)
	if err != nil {
		t.Errorf("err %v（want 止めない: instance の def の名前は mod の名前と重ならない）", err)
	}
}

func TestSignatureToolsRefuseAnInstanceDef(t *testing.T) {
	root := fixtureRoot(t, "inst")
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	if _, _, _, _, err := readDefParams(instRows(t), srcs, "Save.fromText"); err == nil || !strings.Contains(err.Error(), "instance の def") {
		t.Errorf("change-signature: err %v（want instance の def で止める）", err)
	}
	if _, _, _, err := paramsOf(instRows(t), srcs, "Save.fromText"); err == nil || !strings.Contains(err.Error(), "instance の def") {
		t.Errorf("remove-param: err %v（want instance の def で止める）", err)
	}
}

func TestPropagateStopsAtAnInstanceDef(t *testing.T) {
	srcs := &reshapeSources{root: fixtureRoot(t, "inst"), m: map[string]string{}}
	why := stopReason(instRows(t), srcs, "Save.fromText", []string{"res"}, nil, nil, 1, 5)
	if !strings.Contains(why, "instance の def") {
		t.Errorf("止めた訳 %q（want instance の def）", why)
	}
}

func TestCallerCountingOpsNeedTheInstanceRows(t *testing.T) {
	for _, op := range []string{"usages", "remove-dead", "safe-delete", "make-private", "rename"} {
		need := args{op: op}.requiredAdds()
		if strings.Join(need, ",") != "inst" {
			t.Errorf("%s の要る adds %v（want inst）", op, need)
		}
	}
}

func TestTheIndexSaysItHasTheInstanceRows(t *testing.T) {
	_, adds, err := readIndex(filepath.Join("testdata", "inst-spans-resolved.tsv"), Resolved)
	must(t, err)
	if idx := (&Index{Adds: adds}); !idx.hasAdds("inst") {
		t.Errorf("頭の行の adds=%s に inst が無い", adds)
	}
}
