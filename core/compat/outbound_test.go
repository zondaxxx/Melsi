package compat_test

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"

	metahttp "github.com/metacubex/http"
	"github.com/metacubex/mihomo/transport/xhttp"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-vmess/vless"
	singjson "github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/zondaxxx/melsi/core/compat"
)

func configuration(proxy map[string]any) []byte {
	data, _ := json.Marshal(map[string]any{
		"log": map[string]any{"disabled": true},
		"dns": map[string]any{
			"servers": []any{
				map[string]any{"type": "local", "tag": "dns-direct"},
				map[string]any{"type": "hosts", "tag": "dns-target", "predefined": map[string]any{"awg.test": []string{"10.7.0.1"}}},
			},
			"final": "dns-target",
		},
		"outbounds": []any{map[string]any{"type": "mihomo", "tag": "compat", "domain_resolver": "dns-direct", "proxy": proxy}},
		"route":     map[string]any{"final": "compat"},
	})
	return data
}

func openOutbound(test *testing.T, proxy map[string]any) adapter.Outbound {
	test.Helper()
	ctx := box.Context(context.Background(), include.InboundRegistry(), compat.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	options, err := singjson.UnmarshalExtendedContext[option.Options](ctx, configuration(proxy))
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
	result, found := instance.Outbound().Outbound("compat")
	if !found {
		test.Fatal("compatibility outbound not registered")
	}
	return result
}

func ssr(port int) map[string]any {
	return map[string]any{"type": "ssr", "server": "127.0.0.1", "port": port, "cipher": "none", "password": "test", "protocol": "origin", "obfs": "plain", "udp": true}
}

func TestSSRRoundTrip(test *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		test.Fatal(err)
	}
	defer listener.Close()
	go func() {
		connection, acceptError := listener.Accept()
		if acceptError != nil {
			return
		}
		defer connection.Close()
		_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
		if _, readError := io.ReadFull(connection, make([]byte, 7)); readError == nil {
			_, _ = io.Copy(connection, connection)
		}
	}()
	out := openOutbound(test, ssr(listener.Addr().(*net.TCPAddr).Port))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, err := out.DialContext(ctx, "tcp", M.ParseSocksaddr("127.0.0.1:80"))
	if err != nil {
		test.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = connection.Write([]byte("melsi-ssr")); err != nil {
		test.Fatal(err)
	}
	reply := make([]byte, 9)
	if _, err = io.ReadFull(connection, reply); err != nil {
		test.Fatal(err)
	}
	if string(reply) != "melsi-ssr" {
		test.Fatalf("unexpected reply %q", reply)
	}
}

func TestSSRUDPRoundTrip(test *testing.T) {
	server, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		test.Fatal(err)
	}
	defer server.Close()
	go func() {
		buffer := make([]byte, 2048)
		length, address, readError := server.ReadFrom(buffer)
		if readError == nil {
			_, _ = server.WriteTo(buffer[:length], address)
		}
	}()
	out := openOutbound(test, ssr(server.LocalAddr().(*net.UDPAddr).Port))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	destination := M.ParseSocksaddr("127.0.0.1:8080")
	connection, err := out.ListenPacket(ctx, destination)
	if err != nil {
		test.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = connection.WriteTo([]byte("melsi-udp"), destination); err != nil {
		test.Fatal(err)
	}
	buffer := make([]byte, 64)
	length, _, err := connection.ReadFrom(buffer)
	if err != nil {
		test.Fatal(err)
	}
	if string(buffer[:length]) != "melsi-udp" {
		test.Fatalf("unexpected reply %q", buffer[:length])
	}
}

func TestXHTTPRoundTrip(test *testing.T) {
	for _, mode := range []string{"packet-up", "stream-up", "stream-one"} {
		test.Run(mode, func(test *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				test.Fatal(err)
			}
			handler, err := xhttp.NewServerHandler(xhttp.ServerOption{
				Config: xhttp.Config{Path: "/melsi", Mode: mode},
				ConnHandler: func(connection net.Conn) {
					defer connection.Close()
					if _, readError := vless.ReadRequest(connection); readError != nil {
						return
					}
					_, _ = connection.Write([]byte{0, 0})
					_, _ = io.Copy(connection, connection)
				},
			})
			if err != nil {
				test.Fatal(err)
			}
			protocols := new(metahttp.Protocols)
			protocols.SetHTTP1(true)
			protocols.SetUnencryptedHTTP2(true)
			server := &metahttp.Server{Handler: handler, Protocols: protocols, ReadHeaderTimeout: 5 * time.Second}
			go func() { _ = server.Serve(listener) }()
			test.Cleanup(func() { _ = server.Close(); _ = listener.Close() })
			out := openOutbound(test, map[string]any{
				"type": "vless", "server": "127.0.0.1", "port": listener.Addr().(*net.TCPAddr).Port,
				"uuid": "bf000d23-0752-40b4-affe-68f7707a9661", "network": "xhttp", "udp": true,
				"xhttp-opts": map[string]any{"path": "/melsi", "mode": mode},
			})
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			connection, err := out.DialContext(ctx, "tcp", M.ParseSocksaddr("127.0.0.1:80"))
			if err != nil {
				test.Fatal(err)
			}
			defer connection.Close()
			_ = connection.SetDeadline(time.Now().Add(8 * time.Second))
			if _, err = connection.Write([]byte("melsi-xhttp")); err != nil {
				test.Fatal(err)
			}
			buffer := make([]byte, 11)
			if _, err = io.ReadFull(connection, buffer); err != nil {
				test.Fatal(err)
			}
			if string(buffer) != "melsi-xhttp" {
				test.Fatalf("unexpected reply %q", buffer)
			}
		})
	}
}

func TestVmessParses(test *testing.T) {
	openOutbound(test, map[string]any{
		"type": "vmess", "server": "127.0.0.1", "port": 1, "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
		"alterId": 0, "cipher": "auto", "udp": true, "network": "tcp",
	})
}

func TestVlessTcpParses(test *testing.T) {
	openOutbound(test, map[string]any{
		"type": "vless", "server": "127.0.0.1", "port": 443, "uuid": "bf000d23-0752-40b4-affe-68f7707a9661",
		"network": "tcp", "tls": true, "servername": "www.microsoft.com", "udp": true,
		"client-fingerprint": "chrome",
		"reality-opts": map[string]any{"public-key": "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc", "short-id": "6ba85179"},
		"flow": "xtls-rprx-vision",
	})
}

func TestAmneziaConstruction(test *testing.T) {
	openOutbound(test, map[string]any{
		"type": "wireguard", "server": "127.0.0.1", "port": 51820,
		"private-key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=",
		"public-key":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI=",
		"ip":          "10.0.0.2", "udp": true,
		"amnezia-wg-option": map[string]any{"jc": 4, "jmin": 40, "jmax": 70, "h1": "11-12", "h2": "21-22", "h3": "31-32", "h4": "41-42", "i1": "<r 32>"},
	})
}
