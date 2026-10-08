//go:build with_utls

package compat

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
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
	reality "github.com/xtls/reality"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/vless/inbound"
)

const xrayTestUUID = "bf000d23-0752-40b4-affe-68f7707a9661"

// The previous clients report REALITY versions 1.8.x. Current Xray servers
// require 26.3.27, even when the same key, SNI and short ID are valid. Exercise
// a real server with that version gate and compare complete payload round trips.
func TestXrayRealityVersionGate(test *testing.T) {
	for _, transport := range []string{"tcp", "xhttp"} {
		test.Run(transport, func(test *testing.T) {
			port, publicKey := xrayRealityServer(test, transport)
			echo := xrayEchoServer(test)
			for _, fingerprint := range []string{"firefox", "chrome"} {
				test.Run(fingerprint, func(test *testing.T) {
					outbound := xrayRealityClient(test, port, publicKey, transport, fingerprint)
					flow := "xtls-rprx-vision"
					xrayPayloadRoundTrip(test, outbound, echo)
					if transport == "tcp" {
						legacy := xrayBoxOutbound(test, map[string]any{
							"type": "vless", "tag": "proxy", "server": "127.0.0.1", "server_port": port,
							"uuid": xrayTestUUID, "flow": flow,
							"tls": map[string]any{
								"enabled": true, "server_name": "reality.test",
								"utls":    map[string]any{"enabled": true, "fingerprint": fingerprint},
								"reality": map[string]any{"enabled": true, "public_key": publicKey, "short_id": "0123456789abcdef"},
							},
						})
						ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
						defer cancel()
						connection, err := legacy.DialContext(ctx, "tcp", echo)
						if err == nil {
							_ = connection.Close()
							test.Fatal("legacy REALITY client unexpectedly passed the 26.3.27 version gate")
						}
					}
				})
			}
		})
	}
}

func xrayPayloadRoundTrip(test *testing.T, outbound adapter.Outbound, destination M.Socksaddr) {
	test.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, err := outbound.DialContext(ctx, "tcp", destination)
	if err != nil {
		test.Fatal(err)
	}
	defer connection.Close()
	if err = connection.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		test.Fatal(err)
	}
	payload := bytes.Repeat([]byte("melsi-current-reality-payload\n"), 1024)
	if _, err = connection.Write(payload); err != nil {
		test.Fatal(err)
	}
	reply := make([]byte, len(payload))
	if _, err = io.ReadFull(connection, reply); err != nil {
		test.Fatal(err)
	}
	if !bytes.Equal(payload, reply) {
		test.Fatal("REALITY payload changed in transit")
	}
}

func xrayBoxOutbound(test *testing.T, outbound map[string]any) adapter.Outbound {
	test.Helper()
	data, err := json.Marshal(map[string]any{"log": map[string]any{"disabled": true}, "outbounds": []any{outbound}})
	if err != nil {
		test.Fatal(err)
	}
	ctx := box.Context(context.Background(), include.InboundRegistry(), OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
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
	result, found := instance.Outbound().Outbound("proxy")
	if !found {
		test.Fatal("Xray test outbound missing")
	}
	return result
}

func xrayEchoServer(test *testing.T) M.Socksaddr {
	test.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		test.Fatal(err)
	}
	test.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
				_, _ = io.Copy(connection, connection)
			}()
		}
	}()
	return M.SocksaddrFromNet(listener.Addr())
}

func xrayRealityServer(test *testing.T, transport string) (int, string) {
	test.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		test.Fatal(err)
	}
	decoy := httptest.NewUnstartedServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		_, _ = writer.Write([]byte("local TLS decoy"))
	}))
	decoy.Config.ErrorLog = log.New(io.Discard, "", 0)
	decoy.EnableHTTP2 = true
	decoy.TLS = &tls.Config{MinVersion: tls.VersionTLS13, CurvePreferences: []tls.CurveID{tls.X25519}}
	decoy.StartTLS()
	test.Cleanup(decoy.Close)
	reservation, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		test.Fatal(err)
	}
	port := reservation.Addr().(*net.TCPAddr).Port
	_ = reservation.Close()

	// The production global bridge never permits an unprotected socket. Give
	// only this test server a loopback-only dialer for forwarding to the echo.
	token := fmt.Sprintf("melsi-test-server-%d", port)
	ctx, cancel := context.WithCancel(context.Background())
	bridge := &XrayOutbound{token: token, ctx: ctx, cancel: cancel, dialer: xrayLoopbackDialer{}, sockets: make(map[*xraySocket]struct{})}
	xrayDialers.Store(token, bridge)
	test.Cleanup(func() { _ = bridge.Close() })
	flow := "xtls-rprx-vision"
	stream := map[string]any{
		"network": transport, "security": "reality",
		"realitySettings": map[string]any{
			"dest": decoy.Listener.Addr().String(), "serverNames": []string{"reality.test"},
			"privateKey": base64.RawURLEncoding.EncodeToString(key.Bytes()),
			"shortIds":   []string{"0123456789abcdef"}, "minClientVer": "26.3.27",
		},
	}
	if transport == "xhttp" {
		flow = ""
		stream["xhttpSettings"] = map[string]any{"path": "/melsi", "mode": "stream-one"}
	}
	encoded, err := json.Marshal(map[string]any{
		"log": map[string]any{"loglevel": "none"},
		"inbounds": []any{map[string]any{
			"listen": "127.0.0.1", "port": port, "protocol": "vless", "streamSettings": stream,
			"settings": map[string]any{"decryption": "none", "clients": []any{map[string]any{"id": xrayTestUUID, "flow": flow}}},
		}},
		"outbounds": []any{map[string]any{
			"protocol": "freedom", "streamSettings": map[string]any{"sockopt": map[string]any{"interface": token}},
		}},
	})
	if err != nil {
		test.Fatal(err)
	}
	var configuration conf.Config
	if err = json.Unmarshal(encoded, &configuration); err != nil {
		test.Fatal(err)
	}
	built, err := configuration.Build()
	if err != nil {
		test.Fatal(err)
	}
	xrayInstanceMu.Lock()
	server, err := xcore.NewWithContext(ctx, built)
	xrayInstanceMu.Unlock()
	if err != nil {
		test.Fatal(err)
	}
	test.Cleanup(func() { _ = server.Close() })
	if err = server.Start(); err != nil {
		test.Fatal(err)
	}
	// REALITY probes the decoy asynchronously and its first handshake waits in
	// five-second steps until the probe completes. Wait for fixture readiness
	// so the test does not mistake that startup race for a client timeout.
	deadline := time.Now().Add(8 * time.Second)
	for {
		ready := true
		for alpn := range 3 {
			value, exists := reality.GlobalPostHandshakeRecordsLens.Load(fmt.Sprintf("%s reality.test %d", decoy.Listener.Addr(), alpn))
			_, finished := value.([]int)
			ready = ready && exists && finished
		}
		if ready {
			break
		}
		if time.Now().After(deadline) {
			test.Fatal("REALITY decoy probes did not become ready")
		}
		time.Sleep(5 * time.Millisecond)
	}
	return port, base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
}

type xrayLoopbackDialer struct{}

func (xrayLoopbackDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if destination.Fqdn == "localhost" {
		destination = M.ParseSocksaddr(fmt.Sprintf("127.0.0.1:%d", destination.Port))
	}
	if !destination.Addr.IsLoopback() {
		return nil, fmt.Errorf("test cannot dial outside loopback: %s", destination)
	}
	return (&net.Dialer{}).DialContext(ctx, network, destination.String())
}

func (xrayLoopbackDialer) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return net.ListenPacket("udp", "127.0.0.1:0")
}

func xrayRealityClient(test *testing.T, port int, publicKey, transport, fingerprint string) adapter.Outbound {
	test.Helper()
	stream := map[string]any{
		"network": transport, "security": "reality",
		"realitySettings": map[string]any{
			"serverName": "reality.test", "fingerprint": fingerprint,
			"publicKey": publicKey, "shortId": "0123456789abcdef",
		},
	}
	flow := "xtls-rprx-vision"
	if transport == "xhttp" {
		flow = ""
		stream["xhttpSettings"] = map[string]any{"path": "/melsi", "mode": "stream-one"}
	}
	return xrayBoxOutbound(test, map[string]any{
		"type": "xray", "tag": "proxy",
		"outbound": map[string]any{
			"protocol": "vless", "streamSettings": stream,
			"settings": map[string]any{"vnext": []any{map[string]any{
				"address": "127.0.0.1", "port": port,
				"users": []any{map[string]any{"id": xrayTestUUID, "encryption": "none", "flow": flow}},
			}}},
		},
	})
}

func TestXrayRealityUDP(test *testing.T) {
	port, publicKey := xrayRealityServer(test, "tcp")
	outbound := xrayRealityClient(test, port, publicKey, "tcp", "firefox")
	destinations := []M.Socksaddr{xrayUDPEchoServer(test), xrayUDPEchoServer(test)}
	destinations = append(destinations, M.ParseSocksaddr(fmt.Sprintf("localhost:%d", destinations[0].Port)))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, err := outbound.ListenPacket(ctx, destinations[0])
	if err != nil {
		test.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	errors := make(chan error, 8)
	for index := range 8 {
		go func() {
			size := 4096 + index
			if index == 7 {
				size = 7526
			}
			payload := bytes.Repeat([]byte{byte(index + 1)}, size)
			written, err := connection.WriteTo(payload, destinations[index%len(destinations)])
			if err == nil && written != len(payload) {
				err = fmt.Errorf("partial UDP write: %d", written)
			}
			errors <- err
		}()
	}
	for range 8 {
		if err := <-errors; err != nil {
			test.Fatal(err)
		}
	}
	seen := make(map[byte]bool)
	buffer := make([]byte, 65535)
	for range 8 {
		length, address, err := connection.ReadFrom(buffer)
		if err != nil {
			test.Fatal(err)
		}
		id := buffer[0]
		if id < 1 || id > 8 || seen[id] {
			test.Fatalf("duplicate or corrupt datagram: %d", id)
		}
		seen[id] = true
		size := 4096 + int(id) - 1
		if id == 8 {
			size = 7526
		}
		expected := bytes.Repeat([]byte{id}, size)
		if !bytes.Equal(buffer[:length], expected) {
			test.Fatalf("datagram boundary or payload changed: id=%d length=%d", id, length)
		}
		if got := M.SocksaddrFromNet(address); got != destinations[(int(id)-1)%len(destinations)] {
			test.Fatalf("UDP source changed: got %s", got)
		}
	}
	for _, size := range []int{7527, 8191, 32768} {
		if written, err := connection.WriteTo(make([]byte, size), destinations[0]); err == nil || written != 0 {
			test.Fatalf("unsupported UDP size %d must return an explicit error, wrote %d: %v", size, written, err)
		}
	}
	// A failed stream must not poison later packets to the same destination.
	packet := connection.(*xrayPacketConn)
	packet.mu.Lock()
	previous := packet.connections[destinations[0]]
	packet.mu.Unlock()
	if previous == nil {
		test.Fatal("UDP session missing after round trip")
	}
	_ = previous.Close()
	if _, _, err := connection.ReadFrom(buffer); err == nil {
		test.Fatal("closed UDP transport did not report its error")
	}
	checkRetry := func(payload string) {
		test.Helper()
		if _, err := connection.WriteTo([]byte(payload), destinations[0]); err != nil {
			test.Fatal(err)
		}
		length, address, err := connection.ReadFrom(buffer)
		if err != nil {
			test.Fatal(err)
		}
		if string(buffer[:length]) != payload || M.SocksaddrFromNet(address) != destinations[0] {
			test.Fatal("UDP session did not recover")
		}
	}
	checkRetry("reconnect after closed UDP stream")
	packet.mu.Lock()
	replacement := packet.connections[destinations[0]]
	packet.mu.Unlock()
	if replacement == previous {
		test.Fatal("closed UDP transport was reused")
	}

	_ = connection.SetWriteDeadline(time.Now().Add(-time.Second))
	if written, err := connection.WriteTo([]byte("expired"), destinations[0]); err == nil || written != 0 {
		test.Fatalf("expired write deadline returned %d, %v", written, err)
	} else if networkError, ok := err.(net.Error); !ok || !networkError.Timeout() {
		test.Fatalf("UDP write deadline returned wrong error: %v", err)
	}
	_ = connection.SetWriteDeadline(time.Time{})
	checkRetry("UDP write deadline reset")

	_ = connection.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
	if _, _, err := connection.ReadFrom(buffer); err == nil {
		test.Fatal("UDP read deadline did not expire")
	} else if networkError, ok := err.(net.Error); !ok || !networkError.Timeout() {
		test.Fatalf("UDP deadline returned wrong error: %v", err)
	}
	_ = connection.SetReadDeadline(time.Time{})
	blocked := make(chan error, 1)
	go func() { _, _, err := connection.ReadFrom(buffer); blocked <- err }()
	_ = connection.Close()
	select {
	case err := <-blocked:
		if err == nil {
			test.Fatal("closed UDP read succeeded")
		}
	case <-time.After(time.Second):
		test.Fatal("closing UDP connection did not unblock ReadFrom")
	}
}

func xrayUDPEchoServer(test *testing.T) M.Socksaddr {
	test.Helper()
	connection, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		test.Fatal(err)
	}
	test.Cleanup(func() { _ = connection.Close() })
	go func() {
		buffer := make([]byte, 65535)
		for {
			length, address, err := connection.ReadFrom(buffer)
			if err != nil {
				return
			}
			_, _ = connection.WriteTo(buffer[:length], address)
		}
	}()
	return M.SocksaddrFromNet(connection.LocalAddr())
}
