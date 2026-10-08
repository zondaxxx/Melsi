package compat

import (
	"context"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"

	M "github.com/sagernet/sing/common/metadata"
	X "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
)

func TestXrayDialerRequiresProtectedOwner(t *testing.T) {
	destination := X.TCPDestination(X.LocalHostIP, 12345)
	for _, options := range []*internet.SocketConfig{nil, {}, {Interface: "closed-or-unknown"}} {
		if connection, err := (xraySystemDialer{}).Dial(context.Background(), nil, destination, options); err == nil {
			_ = connection.Close()
			t.Fatal("unowned Xray socket bypassed the protected dialer")
		}
	}
}

// XHTTP reconnects can lose the caller's context. Concurrent instances must
// still reach their own protected dialer, and a closed instance must fail closed.
func TestXrayDialerIsolatesBackgroundConnections(t *testing.T) {
	var group sync.WaitGroup
	for _, marker := range []string{"first", "second"} {
		ctx, cancel := context.WithCancel(context.Background())
		out := &XrayOutbound{ctx: ctx, cancel: cancel, token: "test-" + marker,
			dialer: xrayMarkerDialer(marker), sockets: make(map[*xraySocket]struct{})}
		xrayDialers.Store(out.token, out)
		t.Cleanup(func() { _ = out.Close() })
		group.Add(1)
		go func() {
			defer group.Done()
			options := &internet.SocketConfig{Interface: out.token}
			destination := X.TCPDestination(X.LocalHostIP, 12345)
			connection, err := (xraySystemDialer{}).Dial(context.Background(), nil, destination, options)
			if err != nil {
				t.Error(err)
				return
			}
			buffer := make([]byte, len(marker))
			if _, err = io.ReadFull(connection, buffer); err != nil || string(buffer) != marker {
				t.Errorf("protected dialer was mixed with another instance: %q, %v", buffer, err)
			}
			_ = out.Close()
			if _, err = (xraySystemDialer{}).Dial(context.Background(), nil, destination, options); err == nil {
				t.Error("closed instance accepted a new socket")
			}
			if _, err = connection.Read(buffer); err == nil {
				t.Error("closing the outbound did not close its socket")
			}
		}()
	}
	group.Wait()
}

type xrayMarkerDialer string

func (marker xrayMarkerDialer) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	client, server := net.Pipe()
	go func() { defer server.Close(); _, _ = server.Write([]byte(marker)) }()
	return client, nil
}

func (xrayMarkerDialer) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, fmt.Errorf("unexpected UDP socket")
}
