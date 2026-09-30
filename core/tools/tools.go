//go:build tools

// Package tools pins modules that are only needed by scripts/build-libbox.sh:
// gomobile binds libbox together with melsicore from inside this module, so
// libbox's dependencies and the gomobile bind runtime must be in go.mod.
package tools

import (
	_ "github.com/sagernet/gomobile/bind"
	_ "github.com/sagernet/sing-box/experimental/libbox"
)
