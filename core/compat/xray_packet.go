package compat

import (
	"context"
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/common/pipe"
	XB "github.com/xtls/xray-core/common/buf"
	X "github.com/xtls/xray-core/common/net"
	xcore "github.com/xtls/xray-core/core"
)

type xrayDatagram struct {
	data    []byte
	address net.Addr
	err     error
}

// Xray's convenience DialUDP truncates writes and ignores deadlines. Use its
// native packet buffers, reject oversized datagrams, and supply the PacketConn
// semantics the tunnel and DNS clients require.
type xrayPacketConn struct {
	mu            sync.Mutex
	ctx           context.Context
	cancel        context.CancelFunc
	release       func()
	instance      *xcore.Instance
	connections   map[M.Socksaddr]net.Conn
	packets       chan xrayDatagram
	readDeadline  pipe.Deadline
	writeDeadline pipe.Deadline
}

func newXrayPacketConn(ctx context.Context, instance *xcore.Instance, _ M.Socksaddr, release func()) net.PacketConn {
	ctx, cancel := context.WithCancel(ctx)
	result := &xrayPacketConn{ctx: ctx, cancel: cancel, release: release, instance: instance,
		connections: make(map[M.Socksaddr]net.Conn), packets: make(chan xrayDatagram, 32),
		readDeadline: pipe.MakeDeadline(), writeDeadline: pipe.MakeDeadline()}
	context.AfterFunc(ctx, func() { _ = result.Close() })
	return result
}

func (packet *xrayPacketConn) connection(destination M.Socksaddr) (net.Conn, error) {
	packet.mu.Lock()
	defer packet.mu.Unlock()
	if packet.ctx.Err() != nil {
		return nil, os.ErrClosed
	}
	if connection := packet.connections[destination]; connection != nil {
		return connection, nil
	}
	connection, err := xcore.Dial(packet.ctx, packet.instance,
		X.UDPDestination(X.ParseAddress(destination.AddrString()), X.Port(destination.Port)))
	if err != nil {
		return nil, err
	}
	packet.connections[destination] = connection
	go packet.receive(connection, destination)
	return connection, nil
}

func (packet *xrayPacketConn) receive(connection net.Conn, destination M.Socksaddr) {
	defer packet.dropConnection(destination, connection)
	reader := connection.(XB.Reader)
	for {
		buffers, err := reader.ReadMultiBuffer()
		for _, buffer := range buffers {
			address := destination
			if buffer.UDP != nil {
				address = M.ParseSocksaddr(buffer.UDP.NetAddr())
			}
			message := xrayDatagram{data: append([]byte(nil), buffer.Bytes()...), address: address}
			select {
			case packet.packets <- message:
			case <-packet.ctx.Done():
				XB.ReleaseMulti(buffers)
				return
			}
		}
		XB.ReleaseMulti(buffers)
		if err != nil {
			// Retire the stream before exposing its error to the caller, so an
			// immediate retry cannot pick the same closed connection.
			packet.dropConnection(destination, connection)
			select {
			case packet.packets <- xrayDatagram{err: err}:
			case <-packet.ctx.Done():
			}
			return
		}
	}
}

func (packet *xrayPacketConn) dropConnection(destination M.Socksaddr, connection net.Conn) {
	packet.mu.Lock()
	if packet.connections[destination] == connection {
		delete(packet.connections, destination)
	}
	packet.mu.Unlock()
	_ = connection.Close()
}

func (packet *xrayPacketConn) ReadFrom(buffer []byte) (int, net.Addr, error) {
	select {
	case <-packet.ctx.Done():
		return 0, nil, os.ErrClosed
	case <-packet.readDeadline.Wait():
		return 0, nil, os.ErrDeadlineExceeded
	case message := <-packet.packets:
		return copy(buffer, message.data), message.address, message.err
	}
}

func (packet *xrayPacketConn) WriteTo(data []byte, address net.Addr) (int, error) {
	// Xray's XUDP writer reserves 666 bytes in its fixed-size buffer. Vision
	// uses that writer; larger payloads are silently discarded upstream.
	if len(data) > XB.Size-666 {
		return 0, fmt.Errorf("Xray UDP payload exceeds %d bytes", XB.Size-666)
	}
	select {
	case <-packet.ctx.Done():
		return 0, os.ErrClosed
	case <-packet.writeDeadline.Wait():
		return 0, os.ErrDeadlineExceeded
	default:
	}
	destination := M.SocksaddrFromNet(address)
	connection, err := packet.connection(destination)
	if err != nil {
		return 0, err
	}
	buffer := XB.NewWithSize(int32(len(data)))
	_, _ = buffer.Write(data)
	result := make(chan error, 1)
	go func() { result <- connection.(XB.Writer).WriteMultiBuffer(XB.MultiBuffer{buffer}) }()
	select {
	case err = <-result:
		if err != nil {
			packet.dropConnection(destination, connection)
			return 0, err
		}
		return len(data), nil
	case <-packet.ctx.Done():
		packet.dropConnection(destination, connection)
		return 0, os.ErrClosed
	case <-packet.writeDeadline.Wait():
		packet.dropConnection(destination, connection)
		return 0, os.ErrDeadlineExceeded
	}
}

func (packet *xrayPacketConn) Close() error {
	packet.cancel()
	packet.release()
	packet.mu.Lock()
	defer packet.mu.Unlock()
	for destination, connection := range packet.connections {
		_ = connection.Close()
		delete(packet.connections, destination)
	}
	packet.readDeadline.Set(time.Time{})
	packet.writeDeadline.Set(time.Time{})
	return nil
}

func (packet *xrayPacketConn) LocalAddr() net.Addr { return &net.UDPAddr{} }
func (packet *xrayPacketConn) SetDeadline(t time.Time) error {
	packet.readDeadline.Set(t)
	packet.writeDeadline.Set(t)
	return nil
}
func (packet *xrayPacketConn) SetReadDeadline(t time.Time) error {
	packet.readDeadline.Set(t)
	return nil
}
func (packet *xrayPacketConn) SetWriteDeadline(t time.Time) error {
	packet.writeDeadline.Set(t)
	return nil
}
