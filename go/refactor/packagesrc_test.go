package refactor

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeFpkg は root の lib/github の下に、版 version の files を詰めた束を置く。
func writeFpkg(t *testing.T, root, version string, files map[string]string) {
	t.Helper()
	dir := filepath.Join(root, "lib", "github", "o", "e", version)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(filepath.Join(dir, "e-"+version+".fpkg"))
	if err != nil {
		t.Fatal(err)
	}
	z := zip.NewWriter(f)
	for name, body := range files {
		w, _ := z.Create(name)
		w.Write([]byte(body))
	}
	z.Close()
	f.Close()
}

// パッケージの record の alias の形は、flix.toml が名指す版の束の中のソースから読める（前の版の束は読まない）。
func TestPackageAliasShapeIsReadFromTheFpkg(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "flix.toml"), []byte("[dependencies]\n\"github:o/e\" = { version = \"1.0.0\", mount = \"e\" }\n"), 0o644)
	writeFpkg(t, root, "0.9.0", map[string]string{"src/scene/Cam.flix": "pub mod Cam {\n    pub type alias Cam = { eye = Int32 }\n}\n"})
	writeFpkg(t, root, "1.0.0", map[string]string{
		"flix.toml":           "[package]\n",
		"src/scene/Cam.flix":  "pub mod Cam {\n    pub type alias Cam = { eye = Int32, lensShift = Int32 }\n}\n",
		"src/scene/Other.txt": "type alias Cam = { no = Int32 }",
	})
	pkg := packageSources(root)
	if len(pkg) != 1 {
		t.Fatalf("束の .flix だけを読む: %v", pkg)
	}
	s, err := FindAliasShape(pkg, "$pkg$github$o$e.Cam.Cam")
	if err != nil || !s.Has("lensShift") || !strings.HasSuffix(s.File, "e-1.0.0.fpkg!/src/scene/Cam.flix") {
		t.Errorf("got %+v %v", s, err)
	}
}
