package compat

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sync"
	"time"

	meta "github.com/metacubex/mihomo/adapter"
	MC "github.com/metacubex/mihomo/constant"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/dialer"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/bufio"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

type Options struct {
	option.DialerOptions
	Proxy map[string]any `json:"proxy"`
}

func OutboundRegistry() *outbound.Registry {
	registry := include.OutboundRegistry()
	outbound.Register[Options](registry, "mihomo", NewOutbound)
	return registry
}

type Outbound struct {
	outbound.Adapter
	mu        sync.Mutex
	proxy     MC.Proxy
	options   map[string]any
	dialer    bridgeDialer
	dns       adapter.DNSRouter
	transport adapter.DNSTransportManager
	closed    bool
	ctx       context.Context
	cancel    context.CancelFunc
}

func NewOutbound(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options Options) (adapter.Outbound, error) {
	proxyType, _ := options.Proxy["type"].(string)
	if proxyType != "ssr" && proxyType != "vless" && proxyType != "wireguard" {
		return nil, fmt.Errorf("unsupported compatibility protocol %q", proxyType)
	}
	for _, forbidden := range []string{"dialer-proxy", "interface-name", "routing-mark", "remote-dns-resolve", "dns"} {
		if _, exists := options.Proxy[forbidden]; exists {
			return nil, fmt.Errorf("compatibility proxy cannot override %s", forbidden)
		}
	}
	if proxyType == "vless" {
		if options.Proxy["network"] != "xhttp" {
			return nil, fmt.Errorf("compatibility VLESS requires XHTTP")
		}
		if transport, ok := options.Proxy["xhttp-opts"].(map[string]any); ok {
			if _, exists := transport["download-settings"]; exists {
				return nil, fmt.Errorf("separate XHTTP download-settings are not supported")
			}
		}
	}
	protected, err := dialer.New(ctx, options.DialerOptions, true)
	if err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(options.Proxy)
	if err != nil {
		return nil, err
	}
	var copied map[string]any
	if err = json.Unmarshal(encoded, &copied); err != nil {
		return nil, err
	}
	copied["name"] = tag
	bridge := bridgeDialer{protected}
	probe, err := meta.ParseProxy(copied, meta.WithDialerForAPI(bridge))
	if err != nil {
		return nil, fmt.Errorf("invalid %s compatibility options: %w", proxyType, err)
	}
	_ = probe.Close()
	lifetime, cancel := context.WithCancel(ctx)
	return &Outbound{
		Adapter:   outbound.NewAdapterWithDialerOptions("mihomo", tag, []string{N.NetworkTCP, N.NetworkUDP}, options.DialerOptions),
		options:   copied,
		dialer:    bridge,
		dns:       service.FromContext[adapter.DNSRouter](ctx),
		transport: service.FromContext[adapter.DNSTransportManager](ctx),
		ctx:       lifetime,
		cancel:    cancel,
	}, nil
}

func (out *Outbound) resolve(ctx context.Context, host string, server bool) (netip.Addr, error) {
	if address, err := netip.ParseAddr(host); err == nil {
		return address, nil
	}
	if out.dns == nil {
		return netip.Addr{}, fmt.Errorf("compatibility DNS router unavailable")
	}
	query := adapter.DNSQueryOptions{}
	if server {
		if out.transport == nil {
			return netip.Addr{}, fmt.Errorf("compatibility server resolver unavailable")
		}
		var found bool
		query.Transport, found = out.transport.Transport("dns-direct")
		if !found {
			return netip.Addr{}, fmt.Errorf("compatibility requires dns-direct for server resolution")
		}
	}
	addresses, err := out.dns.Lookup(ctx, host, query)
	if err != nil {
		return netip.Addr{}, err
	}
	if len(addresses) == 0 {
		return netip.Addr{}, fmt.Errorf("no address for compatibility destination")
	}
	return addresses[0], nil
}

func (out *Outbound) getProxy(ctx context.Context) (MC.Proxy, error) {
	out.mu.Lock()
	defer out.mu.Unlock()
	if out.closed {
		return nil, os.ErrClosed
	}
	if out.proxy != nil {
		return out.proxy, nil
	}
	encoded, _ := json.Marshal(out.options)
	var mapping map[string]any
	_ = json.Unmarshal(encoded, &mapping)
	resolveServer := func(proxy map[string]any) error {
		host, _ := proxy["server"].(string)
		if host == "" {
			return nil
		}
		address, err := out.resolve(ctx, host, true)
		if err != nil {
			return err
		}
		proxy["server"] = address.String()
		return nil
	}
	if err := resolveServer(mapping); err != nil {
		return nil, err
	}
	if peers, ok := mapping["peers"].([]any); ok {
		for _, value := range peers {
			if peer, ok := value.(map[string]any); ok {
				if err := resolveServer(peer); err != nil {
					return nil, err
				}
			}
		}
	}
	proxy, err := meta.ParseProxy(mapping, meta.WithDialerForAPI(out.dialer))
	if err != nil {
		return nil, err
	}
	out.proxy = proxy
	return proxy, nil
}

func (out *Outbound) metadata(ctx context.Context, destination M.Socksaddr, udp bool) (*MC.Metadata, error) {
	metadata := &MC.Metadata{Host: destination.Fqdn, DstIP: destination.Addr, DstPort: destination.Port, NetWork: MC.TCP}
	if udp {
		metadata.NetWork = MC.UDP
	}
	if destination.IsDomain() && (udp || out.options["type"] == "wireguard") {
		address, err := out.resolve(ctx, destination.Fqdn, false)
		if err != nil {
			return nil, err
		}
		metadata.DstIP = address
	}
	return metadata, nil
}

func (out *Outbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
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
	proxy, err := out.getProxy(ctx)
	if err != nil {
		return nil, err
	}
	metadata, err := out.metadata(ctx, destination, false)
	if err != nil {
		return nil, err
	}
	return proxy.DialContext(ctx, metadata)
}

func (out *Outbound) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	proxy, err := out.getProxy(ctx)
	if err != nil {
		return nil, err
	}
	metadata, err := out.metadata(ctx, destination, true)
	if err != nil {
		return nil, err
	}
	connection, err := proxy.ListenPacketContext(ctx, metadata)
	if err != nil {
		return nil, err
	}
	if out.options["type"] == "wireguard" {
		return &resolvedPacketConn{PacketConn: connection, outbound: out, destination: destination, resolved: M.SocksaddrFrom(metadata.DstIP, metadata.DstPort)}, nil
	}
	return connection, nil
}

func (out *Outbound) Close() error {
	out.mu.Lock()
	defer out.mu.Unlock()
	if out.closed {
		return nil
	}
	out.closed = true
	out.cancel()
	if out.proxy != nil {
		return out.proxy.Close()
	}
	return nil
}

type bridgeDialer struct{ N.Dialer }

type resolvedPacketConn struct {
	net.PacketConn
	outbound    *Outbound
	destination M.Socksaddr
	resolved    M.Socksaddr
}

func (connection *resolvedPacketConn) WriteTo(buffer []byte, address net.Addr) (int, error) {
	destination := M.SocksaddrFromNet(address)
	if destination.IsDomain() {
		if destination == connection.destination {
			destination = connection.resolved
		} else {
			ctx, cancel := context.WithTimeout(connection.outbound.ctx, 5*time.Second)
			defer cancel()
			resolved, err := connection.outbound.resolve(ctx, destination.Fqdn, false)
			if err != nil {
				return 0, err
			}
			destination = M.SocksaddrFrom(resolved, destination.Port)
		}
	}
	return connection.PacketConn.WriteTo(buffer, net.UDPAddrFromAddrPort(destination.AddrPort()))
}

func (bridge bridgeDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	return bridge.Dialer.DialContext(ctx, network, M.ParseSocksaddr(address))
}

func (bridge bridgeDialer) ListenPacket(ctx context.Context, network, address string, remote netip.AddrPort) (net.PacketConn, error) {
	return bridge.Dialer.ListenPacket(ctx, M.SocksaddrFromNetIP(remote))
}
