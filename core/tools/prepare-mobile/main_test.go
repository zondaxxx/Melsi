package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestPrepareReusesCopyAndTracksInputs(t *testing.T) {
	root, source := fixture(t)
	first, err := prepare(root, source)
	if err != nil {
		t.Fatal(err)
	}
	again, err := prepare(root, source)
	if err != nil || first != again {
		t.Fatalf("unchanged inputs did not reuse the tree: %q, %q, %v", first, again, err)
	}
	goMod := read(t, filepath.Join(first, "go.mod"))
	if !strings.Contains(goMod, filepath.Join(filepath.Dir(first), "sing-box")) {
		t.Fatalf("replacement must point at the published tree: %s", goMod)
	}
	if strings.Contains(read(t, filepath.Join(source, "experimental/libbox/config.go")), "melsicompat") {
		t.Fatal("modified the shared module cache")
	}
	if !strings.Contains(read(t, filepath.Join(filepath.Dir(first), "sing-box/experimental/libbox/config.go")), "melsicompat.OutboundRegistry()") {
		t.Fatal("mobile registry patch is missing")
	}
	write(t, filepath.Join(root, "melsicore/core.go"), "updated core")
	if got := read(t, filepath.Join(first, "melsicore/core.go")); got != "updated core" {
		t.Fatalf("core changes were hidden by the prepared tree: %q", got)
	}
	write(t, filepath.Join(root, "go.sum"), "changed dependency checksum")
	changed, err := prepare(root, source)
	if err != nil || changed == first {
		t.Fatalf("dependency change reused the old tree: %q, %v", changed, err)
	}
	write(t, filepath.Join(root, "newpackage/new.go"), "new package")
	added, err := prepare(root, source)
	if err != nil || added == changed {
		t.Fatalf("new package is missing from the tree: %q, %v", added, err)
	}
	if got := read(t, filepath.Join(added, "newpackage/new.go")); got != "new package" {
		t.Fatalf("new package content = %q", got)
	}
}

func TestPrepareConcurrent(t *testing.T) {
	root, source := fixture(t)
	var wg sync.WaitGroup
	paths := make(chan string, 8)
	for range 8 {
		wg.Go(func() {
			path, err := prepare(root, source)
			if err != nil {
				t.Errorf("prepare: %v", err)
			}
			paths <- path
		})
	}
	wg.Wait()
	close(paths)
	first := <-paths
	for path := range paths {
		if path != first {
			t.Fatalf("concurrent preparations diverged: %q and %q", first, path)
		}
	}
	if first != "" {
		read(t, filepath.Join(first, "go.mod"))
	}
}

func fixture(t *testing.T) (root, source string) {
	t.Helper()
	root, source = t.TempDir(), t.TempDir()
	write(t, filepath.Join(root, "go.mod"), "module example.test/core\n")
	write(t, filepath.Join(root, "go.sum"), "")
	write(t, filepath.Join(root, "melsicore/core.go"), "original core")
	write(t, filepath.Join(source, "experimental/libbox/config.go"), "package libbox\nimport (\n \"example.test/include\"\n)\nfunc registry() { include.OutboundRegistry() }\n")
	return root, source
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}
