//go:build with_utls

package compat

import (
	"bytes"
	"context"
	"io"
	"net"
	"testing"
	"time"
)

// A probe and ordinary traffic can share the same XHTTP HTTP/2 connection.
// Cancelling one stream must preserve its neighbours. After the physical
// connection disappears, a new request must reconnect through the same owner.
func TestXrayXHTTPSharedConnectionLifecycle(t *testing.T) {
	port, publicKey := xrayRealityServer(t, "xhttp")
	out := xrayRealityClient(t, port, publicKey, "xhttp", "firefox").(*XrayOutbound)
	destination := xrayEchoServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	live, err := out.DialContext(ctx, "tcp", destination)
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close()
	roundTrip := func(connection net.Conn, marker string) {
		t.Helper()
		_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
		payload := bytes.Repeat([]byte(marker), 1024)
		if _, err := connection.Write(payload); err != nil {
			t.Fatal(err)
		}
		reply := make([]byte, len(payload))
		if _, err := io.ReadFull(connection, reply); err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(reply, payload) {
			t.Fatal("XHTTP stream payload changed")
		}
	}
	roundTrip(live, "live-before-probe")
	for range 5 {
		probeCtx, cancelProbe := context.WithCancel(ctx)
		probe, err := out.DialContext(probeCtx, "tcp", destination)
		if err != nil {
			cancelProbe()
			t.Fatal(err)
		}
		roundTrip(probe, "probe")
		cancelProbe()
		_ = probe.Close()
		roundTrip(live, "live-after-cancel")
	}
	out.mu.Lock()
	sockets := make([]*xraySocket, 0, len(out.sockets))
	for socket := range out.sockets {
		sockets = append(sockets, socket)
	}
	out.mu.Unlock()
	if len(sockets) == 0 {
		t.Fatal("XHTTP did not retain a protected physical connection")
	}
	// Model the old path being closed on a Wi-Fi/cellular change.
	for _, socket := range sockets {
		_ = socket.Close()
	}
	_ = live.Close()
	xrayPayloadRoundTrip(t, out, destination)
}
