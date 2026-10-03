// Command melsi-core is the Melsi desktop daemon: sing-box plus the
// auto-select engine in one elevated process (CONTRACT §4).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/zondaxxx/melsi/core/version"
)

const usage = `usage:
  melsi-core run --config <singbox.json> --engine <engine.json> [--log <file>]
  melsi-core check --config <singbox.json>
  melsi-core version
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch cmd, args := os.Args[1], os.Args[2:]; cmd {
	case "run":
		err = cmdRun(args)
	case "check":
		err = cmdCheck(args)
	case "version", "--version", "-v":
		err = json.NewEncoder(os.Stdout).Encode(map[string]string{
			"melsi":    version.Melsi,
			"sing_box": version.SingBox(),
		})
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "melsi-core:", err)
		os.Exit(1)
	}
}

func newFlagSet(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	return fs
}

func cmdCheck(args []string) error {
	fs := newFlagSet("check")
	configPath := fs.String("config", "", "sing-box config path")
	fs.StringVar(configPath, "c", "", "sing-box config path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *configPath == "" {
		return fmt.Errorf("--config is required")
	}
	return checkConfig(*configPath)
}
