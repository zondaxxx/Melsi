//go:build melsi_mobile_registry

package compat_test

import (
	"testing"

	"github.com/sagernet/sing-box/experimental/libbox"
)

func TestMobileRegistry(test *testing.T) {
	if err := libbox.CheckConfig(string(configuration(ssr(1080)))); err != nil {
		test.Fatal(err)
	}
}
