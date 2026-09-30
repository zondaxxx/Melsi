package main

import (
	"context"
	"fmt"
	"os"
	"time"

	box "github.com/sagernet/sing-box"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/experimental/deprecated"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

// baseContext mirrors sing-box's cmd: registries for every compiled-in
// protocol plus a deprecation reporter.
func baseContext() context.Context {
	return include.Context(service.ContextWith(context.Background(), deprecated.NewStderrManager(log.StdLogger())))
}

func readOptions(ctx context.Context, path string) (option.Options, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return option.Options{}, fmt.Errorf("read config: %w", err)
	}
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return option.Options{}, fmt.Errorf("decode config %s: %w", path, err)
	}
	return options, nil
}

func checkConfig(path string) error {
	ctx := baseContext()
	options, err := readOptions(ctx, path)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(service.ExtendContext(ctx))
	defer cancel()
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return err
	}
	return instance.Close()
}

// initStdLogger points sing-box's global logger at the current os.Stderr
// (our log tee) without colors.
func initStdLogger() {
	factory := log.NewDefaultFactory(context.Background(), log.Formatter{BaseTime: time.Now(), DisableColors: true}, os.Stderr, "", nil, false)
	if err := factory.Start(); err == nil {
		log.SetStdLogger(factory.Logger())
	}
}

// sbInstance is a started sing-box plus the context it runs in.
type sbInstance struct {
	box    *box.Box
	cancel context.CancelFunc
}

func startBox(path string) (*sbInstance, error) {
	ctx := baseContext()
	options, err := readOptions(ctx, path)
	if err != nil {
		return nil, err
	}
	if options.Log == nil {
		options.Log = &option.LogOptions{}
	}
	options.Log.DisableColor = true
	ctx, cancel := context.WithCancel(service.ExtendContext(ctx))
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		cancel()
		return nil, fmt.Errorf("create sing-box: %w", err)
	}
	if err := instance.Start(); err != nil {
		cancel()
		_ = instance.Close()
		return nil, fmt.Errorf("start sing-box: %w", err)
	}
	return &sbInstance{box: instance, cancel: cancel}, nil
}

// Close stops sing-box, aborting the process if it hangs (as upstream does).
func (s *sbInstance) Close() error {
	s.cancel()
	done := make(chan struct{})
	go func() {
		select {
		case <-done:
		case <-time.After(C.FatalStopTimeout):
			log.Fatal("sing-box did not close!")
		}
	}()
	err := s.box.Close()
	close(done)
	return err
}
