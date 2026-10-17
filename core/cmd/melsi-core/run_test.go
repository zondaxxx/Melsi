package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const logHelperEnv = "MELSI_TEST_LOG_HELPER"

func logTestPayload() []byte {
	return bytes.Repeat([]byte("melsi diagnostic value=42\n"), 4096)
}

func TestRedirectLogsClosedStdout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "core.log")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestRedirectLogsHelper$")
	cmd.Env = append(os.Environ(), logHelperEnv+"="+path)
	// Keep the handles separate: CombinedOutput may give stdout and stderr
	// the same Win32 handle, so closing stdout would also close helper errors.
	var output, helperErrors bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &helperErrors
	err := cmd.Run()
	if err != nil {
		t.Fatalf("closed-stdout helper failed: %v\n%s\n%s", err, &output, &helperErrors)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := bytes.Repeat(logTestPayload(), 4)
	if !bytes.Equal(got, want) {
		t.Fatalf("saved %d bytes, want all %d diagnostic bytes", len(got), len(want))
	}
}

func TestRedirectLogsReportsFileError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestRedirectLogsHelper$")
	cmd.Env = append(os.Environ(),
		logHelperEnv+"="+filepath.Join(t.TempDir(), "core.log"),
		"MELSI_TEST_LOG_FILE_FAILURE=1")
	var output, helperErrors bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &helperErrors
	if err := cmd.Run(); err != nil {
		t.Fatalf("file-error helper failed: %v\n%s\n%s", err, &output, &helperErrors)
	}
}

func TestRunLogsStartupFailureWithoutConsole(t *testing.T) {
	for _, kind := range []string{"missing", "invalid"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "engine.json"), []byte(`{}`), 0o600); err != nil {
				t.Fatal(err)
			}
			want := "read config:"
			if kind == "invalid" {
				if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(`{`), 0o600); err != nil {
					t.Fatal(err)
				}
				want = "decode config "
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestRunStartupFailureHelper$")
			cmd.Env = append(os.Environ(), "MELSI_TEST_STARTUP_FAILURE="+dir)
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("startup-failure helper failed: %v\n%s", err, output)
			}
			log, err := os.ReadFile(filepath.Join(dir, "core.log"))
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(log), "melsi-core: "+want) {
				t.Fatalf("fatal startup reason %q was not persisted: %s", want, log)
			}
		})
	}
}

func TestRunStartupFailureHelper(t *testing.T) {
	dir := os.Getenv("MELSI_TEST_STARTUP_FAILURE")
	if dir == "" {
		return
	}
	originalStderr := os.Stderr
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	// Dart's detached Windows launcher supplies NUL handles. There is no
	// user-visible console to recover the error printed by main after return.
	os.Stdout, os.Stderr = null, null
	err = cmdRun([]string{
		"--config", filepath.Join(dir, "config.json"),
		"--engine", filepath.Join(dir, "engine.json"),
		"--log", filepath.Join(dir, "core.log"),
	})
	if err == nil {
		fmt.Fprintln(originalStderr, "startup should have failed")
		os.Exit(2)
	}
}

// Global stdio is changed only in this child, never in the test runner.
func TestRedirectLogsHelper(t *testing.T) {
	path := os.Getenv(logHelperEnv)
	if path == "" {
		return
	}
	originalStderr := os.Stderr
	fail := func(format string, args ...any) {
		fmt.Fprintf(originalStderr, format+"\n", args...)
		os.Exit(2)
	}
	if err := os.Stdout.Close(); err != nil {
		fail("close stdout: %v", err)
	}
	sink, err := redirectLogs(path)
	if err != nil {
		fail("redirect: %v", err)
	}
	if os.Getenv("MELSI_TEST_LOG_FILE_FAILURE") == "1" {
		if err := sink.file.Close(); err != nil {
			fail("close primary file: %v", err)
		}
		_, _ = os.Stderr.Write([]byte("diagnostic after file failure\n"))
		err := sink.Close()
		if !errors.Is(err, os.ErrClosed) {
			fail("Close lost the primary file error: %v", err)
		}
		if secondErr := sink.Close(); secondErr != err {
			fail("repeated Close changed the result: %v, %v", err, secondErr)
		}
		return
	}
	for i := 0; i < 4; i++ {
		if _, err := os.Stderr.Write(logTestPayload()); err != nil {
			fail("stderr write %d: %v", i, err)
		}
	}
	if err := sink.Close(); err != nil {
		fail("close sink: %v", err)
	}
	if err := sink.Close(); err != nil {
		fail("close sink again: %v", err)
	}
	if os.Stderr != originalStderr {
		fail("Close did not restore stderr")
	}
}

func TestLogMirrorWriterKeepsWorkingConsole(t *testing.T) {
	var file, console bytes.Buffer
	w := &logMirrorWriter{primary: &file, mirror: &console}
	for _, line := range []string{"first line\n", "second line\n"} {
		if n, err := w.Write([]byte(line)); err != nil || n != len(line) {
			t.Fatalf("write: n=%d, err=%v", n, err)
		}
	}
	if file.String() != "first line\nsecond line\n" || !bytes.Equal(file.Bytes(), console.Bytes()) {
		t.Fatalf("file=%q, console=%q", file.String(), console.String())
	}
}

type failingLogWriter struct {
	err    error
	writes int
}

func (w *failingLogWriter) Write([]byte) (int, error) {
	w.writes++
	return 0, w.err
}

func TestLogMirrorWriterDisablesFailedConsole(t *testing.T) {
	var file bytes.Buffer
	console := &failingLogWriter{err: os.ErrClosed}
	w := &logMirrorWriter{primary: &file, mirror: console}
	for i := 0; i < 4; i++ {
		if _, err := w.Write(logTestPayload()); err != nil {
			t.Fatal(err)
		}
	}
	if console.writes != 1 || !bytes.Equal(file.Bytes(), bytes.Repeat(logTestPayload(), 4)) {
		t.Fatalf("mirror writes=%d, file bytes=%d", console.writes, file.Len())
	}
}

func TestLogMirrorWriterPreservesPrimaryErrors(t *testing.T) {
	for _, primaryErr := range []error{os.ErrPermission, nil} {
		var console bytes.Buffer
		primary := &failingLogWriter{err: primaryErr}
		w := &logMirrorWriter{primary: primary, mirror: &console}
		n, err := w.Write([]byte("diagnostic\n"))
		wantErr := primaryErr
		if wantErr == nil {
			wantErr = io.ErrShortWrite
		}
		if n != 0 || !errors.Is(err, wantErr) {
			t.Fatalf("n=%d err=%v, want primary error %v", n, err, wantErr)
		}
		if console.String() != "diagnostic\n" {
			t.Fatalf("working console lost diagnostic: %q", console.String())
		}
	}
}
