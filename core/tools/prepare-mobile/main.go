package main

import (
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
	content, err := os.ReadFile(filepath.Join(source, "experimental", "libbox", "config.go"))
	if err != nil {
		return err
	}
	text := string(content)
	needle := "include.OutboundRegistry()"
	if strings.Count(text, needle) != 1 || !strings.Contains(text, "import (") {
		return fmt.Errorf("unsupported libbox config: registry integration point changed")
	}
	text = strings.Replace(text, needle, "melsicompat.OutboundRegistry()", 1)
	text = strings.Replace(text, "import (", "import (\n melsicompat \"github.com/zondaxxx/melsi/core/compat\"", 1)
	patched, err := format.Source([]byte(text))
	if err != nil {
		return err
	}
	dist := filepath.Join(root, "dist")
	if err = os.MkdirAll(dist, 0755); err != nil {
		return err
	}
	directory, err := os.MkdirTemp(dist, "mobile-build-")
	if err != nil {
		return err
	}
	boxDir := filepath.Join(directory, "sing-box")
	if err = os.CopyFS(boxDir, os.DirFS(source)); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(boxDir, "experimental", "libbox", "config.go"), patched, 0644); err != nil {
		return err
	}
	moduleDir := filepath.Join(directory, "core")
	if err = os.MkdirAll(moduleDir, 0755); err != nil {
		return err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == "dist" || strings.HasPrefix(name, ".") {
			continue
		}
		if name == "go.mod" || name == "go.sum" {
			data, readError := os.ReadFile(filepath.Join(root, name))
			if readError != nil {
				return readError
			}
			if name == "go.mod" {
				data = append(data, []byte(fmt.Sprintf("\nreplace github.com/sagernet/sing-box => %q\n", boxDir))...)
			}
			if err = os.WriteFile(filepath.Join(moduleDir, name), data, 0644); err != nil {
				return err
			}
		} else if err = os.Symlink(filepath.Join(root, name), filepath.Join(moduleDir, name)); err != nil {
			return err
		}
	}
	fmt.Println(moduleDir)
	return nil
}
