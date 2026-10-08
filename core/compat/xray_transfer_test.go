//go:build with_utls

package compat

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	XLog "github.com/xtls/xray-core/common/log"
)

const xrayTransferBytes = int64(4 << 20)

type xrayTransferSource struct{}

func (xrayTransferSource) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}

// Run the adapter in a fresh process: the fixture server installs Xray's
// global logger, which otherwise hides the embedded client's default logging.
// The request generator and both servers stay outside the measured client.
func TestXrayParallelHTTPS(t *testing.T) {
	for _, transport := range []string{"tcp", "xhttp"} {
		t.Run(transport, func(t *testing.T) {
			port, key := xrayRealityServer(t, transport)
			destination := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					count, err := io.Copy(io.Discard, r.Body)
					if err != nil || count != xrayTransferBytes {
						http.Error(w, fmt.Sprintf("upload %d: %v", count, err), http.StatusBadRequest)
						return
					}
					w.WriteHeader(http.StatusNoContent)
					return
				}
				w.Header().Set("Content-Length", strconv.FormatInt(xrayTransferBytes, 10))
				_, _ = io.CopyN(w, xrayTransferSource{}, xrayTransferBytes)
			}))
			destination.EnableHTTP2 = true
			destination.StartTLS()
			defer destination.Close()
			for _, h2 := range []bool{false, true} {
				t.Run(fmt.Sprintf("http2=%t", h2), func(t *testing.T) {
					directory := t.TempDir()
					ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					defer cancel()
					command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestXrayTransferClientProcess$", "-test.v")
					command.Env = append(os.Environ(), "MELSI_TEST_TRANSFER_DIR="+directory,
						"MELSI_TEST_TRANSFER_PORT="+strconv.Itoa(port), "MELSI_TEST_TRANSFER_KEY="+key,
						"MELSI_TEST_TRANSFER_TRANSPORT="+transport)
					var logs bytes.Buffer
					command.Stdout, command.Stderr = &logs, &logs
					if err := command.Start(); err != nil {
						t.Fatal(err)
					}
					t.Cleanup(func() { _ = command.Process.Kill() })
					var bridgeAddress []byte
					for attempts := 0; attempts < 100; attempts++ {
						bridgeAddress, _ = os.ReadFile(filepath.Join(directory, "address"))
						if len(bridgeAddress) > 0 {
							break
						}
						time.Sleep(20 * time.Millisecond)
					}
					if len(bridgeAddress) == 0 {
						t.Fatal("isolated Xray client did not start")
					}
					xrayTransferRequests(t, destination.URL, h2, string(bridgeAddress))
					if err := os.WriteFile(filepath.Join(directory, "done"), nil, 0o600); err != nil {
						t.Fatal(err)
					}
					if err := command.Wait(); err != nil {
						t.Fatalf("isolated Xray client: %v\n%s", err, logs.String())
					}
					output := logs.String()
					for _, expected := range []string{"melsi-test-warning-retained", "melsi-test-error-retained"} {
						if !strings.Contains(output, expected) {
							t.Errorf("Xray dropped %s", expected)
						}
					}
					for _, unwanted := range []string{"[Debug]", "[Info]", "melsi-test-debug-filtered", "melsi-test-info-filtered"} {
						if strings.Contains(output, unwanted) {
							t.Errorf("embedded Xray leaked verbose log %q", unwanted)
						}
					}
				})
			}
		})
	}
}

func TestXrayTransferClientProcess(t *testing.T) {
	directory := os.Getenv("MELSI_TEST_TRANSFER_DIR")
	if directory == "" {
		t.Skip("isolated subprocess helper")
	}
	// Match libbox's Go runtime budget without changing the parent test runner.
	debug.SetMemoryLimit(40 << 20)
	debug.SetGCPercent(50)
	port, err := strconv.Atoi(os.Getenv("MELSI_TEST_TRANSFER_PORT"))
	if err != nil {
		t.Fatal(err)
	}
	outbound := xrayRealityClient(t, port, os.Getenv("MELSI_TEST_TRANSFER_KEY"), os.Getenv("MELSI_TEST_TRANSFER_TRANSPORT"), "firefox")
	for severity, marker := range map[XLog.Severity]string{
		XLog.Severity_Debug: "melsi-test-debug-filtered", XLog.Severity_Info: "melsi-test-info-filtered",
		XLog.Severity_Warning: "melsi-test-warning-retained", XLog.Severity_Error: "melsi-test-error-retained",
	} {
		XLog.Record(&XLog.GeneralMessage{Severity: severity, Content: marker})
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err = os.WriteFile(filepath.Join(directory, "address"), []byte(listener.Addr().String()), 0o600); err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				reader := bufio.NewReader(connection)
				target, err := reader.ReadString('\n')
				if err != nil {
					return
				}
				proxy, err := outbound.DialContext(context.Background(), "tcp", M.ParseSocksaddr(strings.TrimSpace(target)))
				if err != nil {
					return
				}
				defer proxy.Close()
				go func() { _, _ = io.Copy(proxy, reader); _ = proxy.Close() }()
				_, _ = io.Copy(connection, proxy)
			}()
		}
	}()
	for deadline := time.Now().Add(25 * time.Second); time.Now().Before(deadline); {
		if _, err := os.Stat(filepath.Join(directory, "done")); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("isolated client timed out waiting for transfers")
}

func xrayTransferRequests(t *testing.T, target string, http2 bool, bridgeAddress string) {
	t.Helper()
	transport := &http.Transport{
		// The only destination is the synthetic loopback HTTPS fixture.
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
		ForceAttemptHTTP2: http2, MaxIdleConns: 8, MaxIdleConnsPerHost: 8,
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			connection, err := (&net.Dialer{}).DialContext(ctx, "tcp", bridgeAddress)
			if err != nil {
				return nil, err
			}
			if _, err = io.WriteString(connection, address+"\n"); err != nil {
				_ = connection.Close()
				return nil, err
			}
			return connection, nil
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second}
	var wg sync.WaitGroup
	for index := 0; index < 8; index++ {
		wg.Add(1)
		go func(upload bool) {
			defer wg.Done()
			method := http.MethodGet
			var body io.Reader
			if upload {
				method, body = http.MethodPost, io.LimitReader(xrayTransferSource{}, xrayTransferBytes)
			}
			request, err := http.NewRequest(method, target, body)
			if err != nil {
				t.Error(err)
				return
			}
			if upload {
				request.ContentLength = xrayTransferBytes
			}
			response, err := client.Do(request)
			if err != nil {
				t.Errorf("%s request: %v", method, err)
				return
			}
			defer response.Body.Close()
			count, err := io.Copy(io.Discard, response.Body)
			expectedBytes, expectedStatus := xrayTransferBytes, http.StatusOK
			if upload {
				expectedBytes, expectedStatus = 0, http.StatusNoContent
			}
			if err != nil || count != expectedBytes || response.StatusCode != expectedStatus {
				t.Errorf("%s response bytes=%d expected=%d status=%d error=%v", method, count, expectedBytes, response.StatusCode, err)
			}
			if (response.ProtoMajor == 2) != http2 {
				t.Errorf("unexpected HTTP protocol: %s", response.Proto)
			}
		}(index%2 != 0)
	}
	wg.Wait()
}
