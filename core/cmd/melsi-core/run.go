package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	runtimeDebug "runtime/debug"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/zondaxxx/melsi/core/engine"
	"github.com/zondaxxx/melsi/core/version"
)

const (
	pidFileName     = "melsi-core.pid"
	clashReadyLimit = 20 * time.Second
)

func cmdRun(args []string) error {
	fs := newFlagSet("run")
	configPath := fs.String("config", "", "sing-box config path")
	enginePath := fs.String("engine", "", "engine config path")
	logPath := fs.String("log", "", "also append logs to this file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *configPath == "" || *enginePath == "" {
		return errors.New("--config and --engine are required")
	}
	engineData, err := os.ReadFile(*enginePath)
	if err != nil {
		return fmt.Errorf("read engine config: %w", err)
	}
	engineCfg, err := engine.ParseConfig(engineData)
	if err != nil {
		return err
	}

	logs, err := redirectLogs(*logPath)
	if err != nil {
		return err
	}
	defer logs.Close()
	initStdLogger()
	logger := engine.NewLogger(os.Stderr, engineCfg.LogLevel)
	logger.Info("melsi-core starting", "melsi", version.Melsi, "sing_box", version.SingBox(), "pid", os.Getpid())

	pidPath := filepath.Join(filepath.Dir(*configPath), pidFileName)
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644); err != nil {
		logger.Warn("write pid file", "err", err)
	} else {
		defer os.Remove(pidPath)
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)

	sb, err := startBox(*configPath)
	if err != nil {
		return err
	}
	runtimeDebug.FreeOSMemory()
	logger.Info("sing-box started")

	stopReq := make(chan struct{})
	var stopOnce sync.Once
	requestStop := func() { stopOnce.Do(func() { close(stopReq) }) }

	// Wait for the Clash API, but stay interruptible.
	readyCtx, readyDone := context.WithTimeout(context.Background(), clashReadyLimit)
	go func() {
		select {
		case sig := <-signals:
			logger.Info("signal received during startup", "signal", sig.String())
			requestStop()
			readyDone()
		case <-readyCtx.Done():
		}
	}()
	clash := engine.NewClashClient(engineCfg.ClashAPI, engineCfg.Secret)
	if err := clash.WaitReady(readyCtx, 200*time.Millisecond); err != nil {
		logger.Warn("clash api not reachable; engine will keep retrying", "err", err)
	}
	clash.Close()
	readyDone()

	var eng *engine.Engine
	select {
	case <-stopReq:
	default:
		eng, err = engine.New(engineCfg, engine.Options{Logger: logger, OnStop: requestStop})
		if err == nil {
			err = eng.Start()
		}
		if err != nil {
			_ = sb.Close()
			return fmt.Errorf("start engine: %w", err)
		}
		select {
		case sig := <-signals:
			logger.Info("signal received", "signal", sig.String())
		case <-stopReq:
			logger.Info("stop requested via control api")
		}
	}

	if eng != nil {
		_ = eng.Close()
	}
	if err := sb.Close(); err != nil {
		logger.Error("sing-box did not close properly", "err", err)
	}
	logger.Info("melsi-core stopped")
	return nil
}

// logSink tees everything written to os.Stderr (sing-box's default log
// writer, and the engine logger) to stdout and an optional file.
type logSink struct {
	origStderr *os.File
	pw         *os.File
	file       *os.File
	done       chan struct{}
}

func redirectLogs(path string) (*logSink, error) {
	s := &logSink{origStderr: os.Stderr, done: make(chan struct{})}
	var dst io.Writer = os.Stdout
	if path != "" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return nil, fmt.Errorf("open log file: %w", err)
		}
		s.file = f
		dst = io.MultiWriter(os.Stdout, f)
	}
	pr, pw, err := os.Pipe()
	if err != nil {
		if s.file != nil {
			s.file.Close()
		}
		return nil, err
	}
	s.pw = pw
	os.Stderr = pw
	go func() {
		defer close(s.done)
		_, _ = io.Copy(dst, pr)
		pr.Close()
	}()
	return s, nil
}

func (s *logSink) Close() {
	os.Stderr = s.origStderr
	s.pw.Close()
	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
	}
	if s.file != nil {
		s.file.Close()
	}
}
