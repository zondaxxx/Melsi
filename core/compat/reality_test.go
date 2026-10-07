//go:build with_utls

package compat_test

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	singjson "github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/zondaxxx/melsi/core/compat"
)

// Exercise the native VLESS route used on iOS, including authentication and
// actual payload bytes. A successful TCP ping alone cannot detect regressions
// in REALITY or Vision. Every listener and the TLS decoy stay on loopback.
func TestNativeRealityRoundTrip(test *testing.T) {
	for _, fingerprint := range []string{"chrome", "firefox"} {
		test.Run(fingerprint, func(test *testing.T) { testRealityRoundTrip(test, false, fingerprint) })
	}
}

func TestMihomoRealityRoundTrip(test *testing.T) {
	for _, fingerprint := range []string{"chrome", "firefox"} {
		test.Run(fingerprint, func(test *testing.T) { testRealityRoundTrip(test, true, fingerprint) })
	}
}

func testRealityRoundTrip(test *testing.T, useMihomo bool, fingerprint string) {
	test.Helper()
	for _, flow := range []string{"", "xtls-rprx-vision"} {
		test.Run("flow="+flow, func(test *testing.T) {
			key, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				test.Fatal(err)
			}
			decoy := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte("local TLS decoy"))
			}))
			// REALITY intentionally takes over before the decoy handshake ends.
			decoy.Config.ErrorLog = log.New(io.Discard, "", 0)
			decoy.TLS = &tls.Config{MinVersion: tls.VersionTLS13, CurvePreferences: []tls.CurveID{tls.X25519}}
			decoy.StartTLS()
			test.Cleanup(decoy.Close)
			listener := realityListener(test)
			echo := realityListener(test)
			go func() {
				connection, err := echo.Accept()
				if err != nil {
					return
				}
				defer connection.Close()
				_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
				_, _ = io.Copy(connection, connection)
			}()
			const uuid = "bf000d23-0752-40b4-affe-68f7707a9661"
			server := nativeRealityBox(test, map[string]any{
				"inbounds": []any{map[string]any{
					"type": "vless", "tag": "reality", "listen": "127.0.0.1",
					"users": []any{map[string]any{"uuid": uuid, "flow": flow}},
					"tls": map[string]any{"enabled": true, "server_name": "reality.test",
						"reality": map[string]any{
							"enabled": true, "private_key": base64.RawURLEncoding.EncodeToString(key.Bytes()),
							"short_id":  []string{"0123456789abcdef"},
							"handshake": map[string]any{"server": "127.0.0.1", "server_port": decoy.Listener.Addr().(*net.TCPAddr).Port},
						}},
				}},
				"outbounds": []any{map[string]any{"type": "direct", "tag": "direct"}},
			})
			inbound, found := server.Inbound().Get("reality")
			if !found {
				test.Fatal("native REALITY inbound missing")
			}
			// Inject an already-bound loopback socket to avoid closing/reserving a
			// port between choosing it and starting the core's own listener.
			go func() {
				connection, err := listener.Accept()
				if err != nil {
					return
				}
				inbound.(adapter.TCPInjectableInbound).NewConnection(context.Background(), connection,
					adapter.InboundContext{Source: M.SocksaddrFromNet(connection.RemoteAddr())}, nil)
			}()
			var outbound adapter.Outbound
			if useMihomo {
				outbound = openOutbound(test, map[string]any{
					"type": "vless", "server": "127.0.0.1", "port": listener.Addr().(*net.TCPAddr).Port,
					"uuid": uuid, "flow": flow, "tls": true, "servername": "reality.test",
					"client-fingerprint": fingerprint,
					"reality-opts": map[string]any{
						"public-key": base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),
						"short-id":   "0123456789abcdef",
					},
				})
			} else {
				client := nativeRealityBox(test, map[string]any{
					"outbounds": []any{map[string]any{
						"type": "vless", "tag": "proxy", "server": "127.0.0.1", "server_port": listener.Addr().(*net.TCPAddr).Port,
						"uuid": uuid, "flow": flow,
						"tls": map[string]any{"enabled": true, "server_name": "reality.test",
							"utls":    map[string]any{"enabled": true, "fingerprint": fingerprint},
							"reality": map[string]any{"enabled": true, "public_key": base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()), "short_id": "0123456789abcdef"}},
					}},
				})
				outbound, found = client.Outbound().Outbound("proxy")
				if !found {
					test.Fatal("native REALITY outbound missing")
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			connection, err := outbound.DialContext(ctx, "tcp", M.SocksaddrFromNet(echo.Addr()))
			if err != nil {
				test.Fatal(err)
			}
			defer connection.Close()
			_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
			payload := bytes.Repeat([]byte("melsi-reality-payload\n"), 1024)
			if _, err = connection.Write(payload); err != nil {
				test.Fatal(err)
			}
			reply := make([]byte, len(payload))
			if _, err = io.ReadFull(connection, reply); err != nil {
				test.Fatal(err)
			}
			if !bytes.Equal(reply, payload) {
				test.Fatal("REALITY payload changed in transit")
			}
		})
	}
}

func realityListener(test *testing.T) net.Listener {
	test.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		test.Fatal(err)
	}
	test.Cleanup(func() { _ = listener.Close() })
	return listener
}

func nativeRealityBox(test *testing.T, configuration map[string]any) *box.Box {
	test.Helper()
	configuration["log"] = map[string]any{"disabled": true}
	data, err := json.Marshal(configuration)
	if err != nil {
		test.Fatal(err)
	}
	ctx := box.Context(context.Background(), include.InboundRegistry(), compat.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	options, err := singjson.UnmarshalExtendedContext[option.Options](ctx, data)
	if err != nil {
		test.Fatal(err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		test.Fatal(err)
	}
	test.Cleanup(func() { _ = instance.Close() })
	if err = instance.Start(); err != nil {
		test.Fatal(err)
	}
	return instance
}
