// Package version reports the Melsi and embedded sing-box versions.
package version

import (
	"runtime/debug"
	"strings"
	"sync"

	C "github.com/sagernet/sing-box/constant"
)

// Melsi is the Melsi core version. Overridden at build time with
// -ldflags "-X github.com/zondaxxx/melsi/core/version.Melsi=<ver>".
var Melsi = "0.1.0"

// singBoxFallback is used when neither ldflags nor build info carry a version
// (e.g. `go test`).
const singBoxFallback = "1.14.2"

var singBox = sync.OnceValue(func() string {
	if C.Version != "" && C.Version != "unknown" {
		return C.Version
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			if dep.Path == "github.com/sagernet/sing-box" {
				m := dep
				if dep.Replace != nil {
					m = dep.Replace
				}
				if v := strings.TrimPrefix(m.Version, "v"); v != "" && v != "(devel)" {
					return v
				}
			}
		}
	}
	return singBoxFallback
})

// SingBox returns the embedded sing-box version, e.g. "1.14.2".
func SingBox() string { return singBox() }
