package compat_test

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	amnezia "github.com/metacubex/amneziawg-go/device_v1"
	"github.com/metacubex/mipstack"
	"github.com/metacubex/wireguard-go/conn"
	"github.com/metacubex/wireguard-go/device"
	"github.com/metacubex/wireguard-go/tun"
	M "github.com/sagernet/sing/common/metadata"
)

type packetDevice struct {
	*mipstack.Stack
	events chan tun.Event
	once   sync.Once
}

func (packet *packetDevice) File() *os.File           { return nil }
func (packet *packetDevice) Events() <-chan tun.Event { return packet.events }
func (packet *packetDevice) Close() error {
	packet.once.Do(func() { close(packet.events) })
	return packet.Stack.Close()
}

func TestAmneziaRoundTrip(test *testing.T) {
	for _, rangeHeaders := range []bool{false, true} {
		test.Run(fmt.Sprintf("range-headers=%t", rangeHeaders), func(test *testing.T) {
			serverKey, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				test.Fatal(err)
			}
			clientKey, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				test.Fatal(err)
			}
			stack, err := mipstack.New(mipstack.Config{LocalAddresses: []netip.Prefix{netip.MustParsePrefix("10.7.0.1/32")}, MTU: 1280})
			if err != nil {
				test.Fatal(err)
			}
			if err = stack.Start(); err != nil {
				test.Fatal(err)
			}
			packet := &packetDevice{Stack: stack, events: make(chan tun.Event, 1)}
			server := amnezia.NewDevice(packet, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""), 2)
			test.Cleanup(server.Close)
			headers := []string{"11", "21", "31", "41"}
			if rangeHeaders {
				headers = []string{"11-12", "21-22", "31-32", "41-42"}
			}
			config := fmt.Sprintf("private_key=%s\nlisten_port=0\njc=2\njmin=40\njmax=70\ns1=10\ns2=20\nh1=%s\nh2=%s\nh3=%s\nh4=%s\npublic_key=%s\nallowed_ip=10.7.0.2/32\n",
				hex.EncodeToString(serverKey.Bytes()), headers[0], headers[1], headers[2], headers[3], hex.EncodeToString(clientKey.PublicKey().Bytes()))
			if err = server.IpcSet(config); err != nil {
				test.Fatal(err)
			}
			if err = server.Up(); err != nil {
				test.Fatal(err)
			}
			state, err := server.IpcGet()
			if err != nil {
				test.Fatal(err)
			}
			port := 0
			for _, line := range strings.Split(state, "\n") {
				if value, found := strings.CutPrefix(line, "listen_port="); found {
					port, err = strconv.Atoi(value)
				}
			}
			if err != nil || port == 0 {
				test.Fatalf("server listen port unavailable: %v", err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			listener, err := stack.ListenTCP(ctx, "tcp", netip.MustParseAddrPort("10.7.0.1:8080"))
			if err != nil {
				test.Fatal(err)
			}
			test.Cleanup(func() { _ = listener.Close() })
			go func() {
				connection, acceptError := listener.Accept()
				if acceptError != nil {
					return
				}
				defer connection.Close()
				_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
				_, _ = io.Copy(connection, connection)
			}()
			out := openOutbound(test, map[string]any{
				"type": "wireguard", "server": "127.0.0.1", "port": port,
				"private-key": base64.StdEncoding.EncodeToString(clientKey.Bytes()),
				"public-key":  base64.StdEncoding.EncodeToString(serverKey.PublicKey().Bytes()),
				"ip":          "10.7.0.2", "udp": true, "mtu": 1280,
				"amnezia-wg-option": map[string]any{"jc": 2, "jmin": 40, "jmax": 70, "s1": 10, "s2": 20, "h1": headers[0], "h2": headers[1], "h3": headers[2], "h4": headers[3]},
			})
			connection, err := out.DialContext(ctx, "tcp", M.ParseSocksaddr("10.7.0.1:8080"))
			if err != nil {
				test.Fatal(err)
			}
			defer connection.Close()
			_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
			if _, err = connection.Write([]byte("melsi-awg")); err != nil {
				test.Fatal(err)
			}
			buffer := make([]byte, 9)
			if _, err = io.ReadFull(connection, buffer); err != nil {
				test.Fatal(err)
			}
			if string(buffer) != "melsi-awg" {
				test.Fatalf("unexpected reply %q", buffer)
			}
			udpServer, err := stack.ListenUDP(ctx, "udp", netip.MustParseAddrPort("10.7.0.1:8081"))
			if err != nil {
				test.Fatal(err)
			}
			test.Cleanup(func() { _ = udpServer.Close() })
			go func() {
				buffer := make([]byte, 64)
				length, source, readError := udpServer.ReadFrom(buffer)
				if readError == nil {
					_, _ = udpServer.WriteTo(buffer[:length], source)
				}
			}()
			destination := M.ParseSocksaddr("awg.test:8081")
			udpClient, err := out.ListenPacket(ctx, destination)
			if err != nil {
				test.Fatal(err)
			}
			defer udpClient.Close()
			_ = udpClient.SetDeadline(time.Now().Add(10 * time.Second))
			if _, err = udpClient.WriteTo([]byte("melsi-udp"), destination); err != nil {
				test.Fatal(err)
			}
			length, _, err := udpClient.ReadFrom(buffer)
			if err != nil {
				test.Fatal(err)
			}
			if string(buffer[:length]) != "melsi-udp" {
				test.Fatalf("unexpected UDP reply %q", buffer[:length])
			}
		})
	}
}
