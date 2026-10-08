package compat

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/dialer"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/bufio"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/xtls/xray-core/app/dispatcher"
	"github.com/xtls/xray-core/app/proxyman"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	XLog "github.com/xtls/xray-core/common/log"
	X "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	_ "github.com/xtls/xray-core/proxy/http"
	_ "github.com/xtls/xray-core/proxy/shadowsocks"
	_ "github.com/xtls/xray-core/proxy/socks"
	_ "github.com/xtls/xray-core/proxy/trojan"
	_ "github.com/xtls/xray-core/proxy/vless/outbound"
	_ "github.com/xtls/xray-core/proxy/vmess/outbound"
	"github.com/xtls/xray-core/transport/internet"
	_ "github.com/xtls/xray-core/transport/internet/grpc"
	_ "github.com/xtls/xray-core/transport/internet/httpupgrade"
	_ "github.com/xtls/xray-core/transport/internet/reality"
	_ "github.com/xtls/xray-core/transport/internet/splithttp"
	_ "github.com/xtls/xray-core/transport/internet/tagged/taggedimpl"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
	_ "github.com/xtls/xray-core/transport/internet/udp"
	_ "github.com/xtls/xray-core/transport/internet/websocket"
)

// XrayOptions embeds one ordinary Xray outbound, without an inbound listener or
// subprocess. DNS, interface binding, Android protection and detours stay owned
// by sing-box. In particular, current REALITY authentication uses Xray itself.
type XrayOptions struct {
	option.DialerOptions
	Outbound map[string]any `json:"outbound"`
}

var xrayDialers sync.Map
var xrayInstanceMu sync.Mutex

func init() {
	// Unlike the standalone client, embedded Xray has no app/log instance.
	// Its unfiltered default otherwise writes a debug line for each Vision
	// payload chunk. Install one process-wide filter, not a logger per node:
	// closing a probe must not disable logging for the live tunnel.
	XLog.ReplaceWithSeverityLogger(XLog.Severity_Warning)
	// Installed once, before any instances exist. Never fall back to an
	// unprotected OS socket, even for background HTTP/2 pool reconnects.
	internet.UseAlternativeSystemDialer(xraySystemDialer{})
}

type XrayOutbound struct {
	outbound.Adapter
	mu       sync.Mutex
	config   *xcore.Config
	instance *xcore.Instance
	closed   bool
	token    string
	ctx      context.Context
	cancel   context.CancelFunc
	dialer   N.Dialer
	sockets  map[*xraySocket]struct{}
}

func NewXrayOutbound(ctx context.Context, _ adapter.Router, _ log.ContextLogger, tag string, options XrayOptions) (adapter.Outbound, error) {
	protected, err := dialer.New(ctx, options.DialerOptions, true)
	if err != nil {
		return nil, err
	}
	id := make([]byte, 16)
	if _, err = rand.Read(id); err != nil {
		return nil, err
	}
	token := "melsi-xray-" + hex.EncodeToString(id)
	configuration, err := buildXrayOutbound(options.Outbound, token)
	if err != nil {
		return nil, err
	}
	lifetime, cancel := context.WithCancel(ctx)
	result := &XrayOutbound{
		Adapter: outbound.NewAdapterWithDialerOptions("xray", tag, []string{N.NetworkTCP, N.NetworkUDP}, options.DialerOptions),
		config:  configuration, token: token, ctx: lifetime, cancel: cancel,
		dialer: protected, sockets: make(map[*xraySocket]struct{}),
	}
	xrayDialers.Store(token, result)
	return result, nil
}

func buildXrayOutbound(mapping map[string]any, token string) (*xcore.Config, error) {
	encoded, err := json.Marshal(mapping)
	if err != nil {
		return nil, err
	}
	var copied map[string]any
	if err = json.Unmarshal(encoded, &copied); err != nil {
		return nil, err
	}
	protocol, _ := copied["protocol"].(string)
	switch protocol {
	case "vless", "vmess", "trojan", "shadowsocks", "socks", "http":
	default:
		return nil, fmt.Errorf("unsupported embedded Xray protocol %q", protocol)
	}
	for _, forbidden := range []string{"sendThrough", "proxySettings"} {
		if _, found := copied[forbidden]; found {
			return nil, fmt.Errorf("embedded Xray cannot override %s; use outer dialer options", forbidden)
		}
	}
	if strategy, _ := copied["targetStrategy"].(string); strategy != "" && strategy != "AsIs" && strategy != "asis" {
		return nil, fmt.Errorf("embedded Xray target DNS must use the outer resolver")
	}
	stream, _ := copied["streamSettings"].(map[string]any)
	if stream == nil {
		stream = make(map[string]any)
		copied["streamSettings"] = stream
	}
	network, _ := stream["network"].(string)
	switch network {
	case "", "tcp", "raw", "ws", "grpc", "httpupgrade", "xhttp", "splithttp":
	default:
		return nil, fmt.Errorf("unsupported embedded Xray transport %q", network)
	}
	protectXrayStream(stream, token)
	encoded, err = json.Marshal(copied)
	if err != nil {
		return nil, err
	}
	var outboundConfig conf.OutboundDetourConfig
	if err = json.Unmarshal(encoded, &outboundConfig); err != nil {
		return nil, err
	}
	handler, err := outboundConfig.Build()
	if err != nil {
		return nil, fmt.Errorf("invalid embedded Xray outbound: %w", err)
	}
	return &xcore.Config{
		App: []*serial.TypedMessage{
			serial.ToTypedMessage(&dispatcher.Config{}),
			serial.ToTypedMessage(&proxyman.OutboundConfig{}),
		},
		Outbound: []*xcore.OutboundHandlerConfig{handler},
	}, nil
}

func protectXrayStream(stream map[string]any, token string) {
	// A stable token in stream settings survives XHTTP's background reconnects
	// (which do not retain the caller's context). Unique tokens isolate probes,
	// VPN instances and XHTTP upload/download pools.
	stream["sockopt"] = map[string]any{"interface": token, "domainStrategy": "AsIs"}
	for key, value := range stream {
		if object, ok := value.(map[string]any); ok {
			if key == "downloadSettings" {
				protectXrayStream(object, token)
			} else if key != "sockopt" {
				protectXrayDownloads(object, token)
			}
		}
	}
}

func protectXrayDownloads(object map[string]any, token string) {
	for key, value := range object {
		if child, ok := value.(map[string]any); ok {
			if key == "downloadSettings" {
				protectXrayStream(child, token)
			} else {
				protectXrayDownloads(child, token)
			}
		}
	}
}

func (out *XrayOutbound) getInstance() (*xcore.Instance, error) {
	out.mu.Lock()
	defer out.mu.Unlock()
	if out.closed {
		return nil, os.ErrClosed
	}
	if out.instance != nil {
		return out.instance, nil
	}
	// Xray initializes process-global DNS/manager defaults while constructing
	// instances. They are unused here (all socket DNS is AsIs, no proxySettings),
	// but construction itself must be serialized for concurrent node probes.
	xrayInstanceMu.Lock()
	instance, err := xcore.NewWithContext(out.ctx, out.config)
	xrayInstanceMu.Unlock()
	if err != nil {
		return nil, err
	}
	if err = instance.Start(); err != nil {
		_ = instance.Close()
		return nil, err
	}
	out.instance = instance
	return instance, nil
}

func (out *XrayOutbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if N.NetworkName(network) == N.NetworkUDP {
		connection, err := out.ListenPacket(ctx, destination)
		if err != nil {
			return nil, err
		}
		return bufio.NewBindPacketConn(connection, destination), nil
	}
	if N.NetworkName(network) != N.NetworkTCP {
		return nil, N.ErrUnknownNetwork
	}
	instance, err := out.getInstance()
	if err != nil {
		return nil, err
	}
	ctx, release := out.sessionContext(ctx)
	connection, err := xcore.Dial(ctx, instance, X.TCPDestination(X.ParseAddress(destination.AddrString()), X.Port(destination.Port)))
	if err != nil {
		release()
		return nil, err
	}
	// Xray's convenience net.Conn silently ignores both read and write
	// deadlines. A local pipe supplies real deadlines, including interrupted
	// TLS handshakes and stalled proxy probes, without opening a local port.
	client, bridge := net.Pipe()
	stop := context.AfterFunc(ctx, func() { _ = connection.Close(); _ = bridge.Close() })
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			stop()
			release()
			_ = connection.Close()
			_ = bridge.Close()
		})
	}
	go func() { defer closeBoth(); _, _ = io.Copy(bridge, connection) }()
	go func() { defer closeBoth(); _, _ = io.Copy(connection, bridge) }()
	return client, nil
}

func (out *XrayOutbound) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	instance, err := out.getInstance()
	if err != nil {
		return nil, err
	}
	ctx, release := out.sessionContext(ctx)
	return newXrayPacketConn(ctx, instance, destination, release), nil
}

func (out *XrayOutbound) sessionContext(ctx context.Context) (context.Context, func()) {
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(out.ctx, cancel)
	return ctx, func() { stop(); cancel() }
}

func (out *XrayOutbound) Close() error {
	out.mu.Lock()
	if out.closed {
		out.mu.Unlock()
		return nil
	}
	out.closed = true
	out.cancel()
	xrayDialers.Delete(out.token)
	instance := out.instance
	sockets := make([]*xraySocket, 0, len(out.sockets))
	for socket := range out.sockets {
		sockets = append(sockets, socket)
	}
	out.mu.Unlock()
	for _, socket := range sockets {
		_ = socket.Close()
	}
	if instance != nil {
		return instance.Close()
	}
	return nil
}

type xraySystemDialer struct{}

func (xraySystemDialer) DestIpAddress() net.IP { return nil }

func (xraySystemDialer) Dial(ctx context.Context, _ X.Address, destination X.Destination, options *internet.SocketConfig) (net.Conn, error) {
	if options == nil {
		return nil, fmt.Errorf("Xray socket has no protected dialer")
	}
	value, exists := xrayDialers.Load(options.Interface)
	if !exists {
		return nil, fmt.Errorf("Xray protected dialer is closed or unavailable")
	}
	out := value.(*XrayOutbound)
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(out.ctx, cancel)
	defer stop()
	defer cancel()
	connection, err := out.dialer.DialContext(ctx, destination.Network.SystemString(), M.ParseSocksaddr(destination.NetAddr()))
	if err != nil {
		return nil, err
	}
	socket := &xraySocket{Conn: connection, outbound: out}
	out.mu.Lock()
	if out.closed {
		out.mu.Unlock()
		_ = connection.Close()
		return nil, os.ErrClosed
	}
	out.sockets[socket] = struct{}{}
	out.mu.Unlock()
	return socket, nil
}

type xraySocket struct {
	net.Conn
	outbound *XrayOutbound
	once     sync.Once
}

func (socket *xraySocket) Close() error {
	err := socket.Conn.Close()
	socket.once.Do(func() {
		socket.outbound.mu.Lock()
		delete(socket.outbound.sockets, socket)
		socket.outbound.mu.Unlock()
		// Upstream HTTP pools can retain a closed connection. Do not let that
		// closed wrapper retain the entire sing-box instance and its context.
		socket.outbound = nil
	})
	return err
}
