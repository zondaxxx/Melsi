package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"go/format"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	if err := generate(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func generate() error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	output, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}", "github.com/sagernet/sing-box").Output()
	if err != nil {
		return err
	}
	source := strings.TrimSpace(string(output))
	directory, err := prepare(root, source)
	if err != nil {
		return err
	}
	fmt.Println(directory)
	return nil
}

// prepare gives gomobile a stable replacement path. Random paths changed the
// generated module on every invocation and prevented reuse of native builds.
// Core packages remain symlinked, so normal edits are always visible to Go.
func prepare(root, source string) (string, error) {
	content, err := os.ReadFile(filepath.Join(source, "experimental", "libbox", "config.go"))
	if err != nil {
		return "", err
	}
	text := string(content)
	needle := "include.OutboundRegistry()"
	if strings.Count(text, needle) != 1 || !strings.Contains(text, "import (") {
		return "", fmt.Errorf("unsupported libbox config: registry integration point changed")
	}
	text = strings.Replace(text, needle, "melsicompat.OutboundRegistry()", 1)
	text = strings.Replace(text, "import (", "import (\n melsicompat \"github.com/zondaxxx/melsi/core/compat\"", 1)
	patched, err := format.Source([]byte(text))
	if err != nil {
		return "", err
	}
	goMod, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		return "", err
	}
	goSum, err := os.ReadFile(filepath.Join(root, "go.sum"))
	if err != nil {
		return "", err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return "", err
	}
	digest := sha256.New()
	for _, input := range [][]byte{[]byte(root), []byte(source), goMod, goSum, patched} {
		fmt.Fprintf(digest, "%d:", len(input))
		digest.Write(input)
	}
	for _, entry := range entries {
		if name := entry.Name(); name != "dist" && !strings.HasPrefix(name, ".") {
			fmt.Fprintf(digest, "\x00%s", name)
		}
	}
	dist := filepath.Join(root, "dist")
	directory := filepath.Join(dist, fmt.Sprintf("mobile-source-%x", digest.Sum(nil)[:16]))
	moduleDir := filepath.Join(directory, "core")
	ready := filepath.Join(directory, ".ready")
	if _, err = os.Stat(ready); err == nil {
		return moduleDir, nil
	}
	if err = os.MkdirAll(dist, 0755); err != nil {
		return "", err
	}
	// Publish only complete trees. Parallel invocations can safely converge on
	// the same immutable copy without deleting a build another process uses.
	staging, err := os.MkdirTemp(dist, ".mobile-source-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(staging)
	boxDir := filepath.Join(staging, "sing-box")
	if err = os.CopyFS(boxDir, os.DirFS(source)); err != nil {
		return "", err
	}
	if err = os.WriteFile(filepath.Join(boxDir, "experimental", "libbox", "config.go"), patched, 0644); err != nil {
		return "", err
	}
	stagingModule := filepath.Join(staging, "core")
	if err = os.MkdirAll(stagingModule, 0755); err != nil {
		return "", err
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == "dist" || strings.HasPrefix(name, ".") {
			continue
		}
		if name == "go.mod" || name == "go.sum" {
			data := goSum
			if name == "go.mod" {
				data = []byte(string(goMod) + fmt.Sprintf("\nreplace github.com/sagernet/sing-box => %q\n", filepath.Join(directory, "sing-box")))
			}
			if err = os.WriteFile(filepath.Join(stagingModule, name), data, 0644); err != nil {
				return "", err
			}
		} else if err = os.Symlink(filepath.Join(root, name), filepath.Join(stagingModule, name)); err != nil {
			return "", err
		}
	}
	if err = os.WriteFile(filepath.Join(staging, ".ready"), nil, 0644); err != nil {
		return "", err
	}
	if err = os.Rename(staging, directory); err != nil {
		if _, readyErr := os.Stat(ready); readyErr != nil {
			return "", errors.Join(err, readyErr)
		}
	}
	return moduleDir, nil
}
