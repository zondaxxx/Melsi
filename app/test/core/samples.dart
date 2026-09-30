// Realistic-shaped (but fake) share links and subscription bodies used by the
// core tests. Keys are random but well-formed so `sing-box check` accepts
// them.

const kUuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
const kRealityPbk = '6ElHfGRwKFsoJjqgyT0N-vOd96Z_vmhHRkTsY4Ftfv0';
const kWgPriv = 'AUyb4Xr9Wtd3XHAlDTDfPIMxhSD2dEo6Iy26VZlNu54=';
const kWgPub = 'Iew+k6F+s+8bBy4RZsyhggf6id5DffCzhIGbmyuXr+o=';
const kWgPsk = 'vy/OW7n7NYNNcAAFZIbeh+PLuReMtCHVEKfvjAHF6GM=';
const kSs2022Key = 'J6FKQKBIuM/4Tf54+jWw+A==';

/// name -> link. Every protocol/transport we support.
const Map<String, String> kSampleLinks = {
  'vmess_ws_tls':
      'vmess://eyJ2IjogIjIiLCAicHMiOiAi8J+HqfCfh6ogR2VybWFueSBWTWVzcyBXUyIsICJhZGQiOiAiZGUxLmV4YW1wbGUuY29tIiwgInBvcnQiOiAiNDQzIiwgImlkIjogImI4MzEzODFkLTYzMjQtNGQ1My1hZDRmLThjZGE0OGIzMDgxMSIsICJhaWQiOiAiMCIsICJzY3kiOiAiYXV0byIsICJuZXQiOiAid3MiLCAidHlwZSI6ICJub25lIiwgImhvc3QiOiAiY2RuLmV4YW1wbGUuY29tIiwgInBhdGgiOiAiL3Ztd3M/ZWQ9MjA0OCIsICJ0bHMiOiAidGxzIiwgInNuaSI6ICJjZG4uZXhhbXBsZS5jb20iLCAiYWxwbiI6ICJoMixodHRwLzEuMSIsICJmcCI6ICJjaHJvbWUifQ==',
  'vmess_grpc':
      'vmess://eyJ2IjogIjIiLCAicHMiOiAi0J3QuNC00LXRgNC70LDQvdC00YsgZ1JQQyIsICJhZGQiOiAibmwyLmV4YW1wbGUuY29tIiwgInBvcnQiOiA0NDMsICJpZCI6ICJiODMxMzgxZC02MzI0LTRkNTMtYWQ0Zi04Y2RhNDhiMzA4MTEiLCAiYWlkIjogMCwgInNjeSI6ICJhZXMtMTI4LWdjbSIsICJuZXQiOiAiZ3JwYyIsICJ0eXBlIjogImd1biIsICJob3N0IjogIiIsICJwYXRoIjogInZtZ3JwYyIsICJ0bHMiOiAidGxzIiwgInNuaSI6ICJubDIuZXhhbXBsZS5jb20ifQ==',
  'vmess_h2':
      'vmess://eyJ2IjogIjIiLCAicHMiOiAiVVMgaDIiLCAiYWRkIjogInVzMi5leGFtcGxlLmNvbSIsICJwb3J0IjogIjg0NDMiLCAiaWQiOiAiYjgzMTM4MWQtNjMyNC00ZDUzLWFkNGYtOGNkYTQ4YjMwODExIiwgImFpZCI6ICIwIiwgIm5ldCI6ICJoMiIsICJob3N0IjogInVzMi5leGFtcGxlLmNvbSIsICJwYXRoIjogIi9oMiIsICJ0bHMiOiAidGxzIn0=',
  'vmess_httpupgrade':
      'vmess://eyJ2IjogIjIiLCAicHMiOiAiRlIgaHR0cHVwZ3JhZGUiLCAiYWRkIjogImZyLmV4YW1wbGUuY29tIiwgInBvcnQiOiAiODAiLCAiaWQiOiAiYjgzMTM4MWQtNjMyNC00ZDUzLWFkNGYtOGNkYTQ4YjMwODExIiwgImFpZCI6ICIwIiwgIm5ldCI6ICJodHRwdXBncmFkZSIsICJob3N0IjogImZyLmV4YW1wbGUuY29tIiwgInBhdGgiOiAiL2h1IiwgInRscyI6ICIifQ==',
  'vmess_quic':
      'vmess://eyJ2IjogIjIiLCAicHMiOiAiSlAgcXVpYyIsICJhZGQiOiAianAuZXhhbXBsZS5jb20iLCAicG9ydCI6ICI0NDMiLCAiaWQiOiAiYjgzMTM4MWQtNjMyNC00ZDUzLWFkNGYtOGNkYTQ4YjMwODExIiwgImFpZCI6ICIwIiwgIm5ldCI6ICJxdWljIiwgInR5cGUiOiAibm9uZSIsICJob3N0IjogIm5vbmUiLCAicGF0aCI6ICIiLCAidGxzIjogInRscyIsICJzbmkiOiAianAuZXhhbXBsZS5jb20ifQ==',
  'vmess_tcp_http':
      'vmess://eyJ2IjogIjIiLCAicHMiOiAiU0UgdGNwIGh0dHAiLCAiYWRkIjogIjUuNi43LjgiLCAicG9ydCI6ICI4MCIsICJpZCI6ICJiODMxMzgxZC02MzI0LTRkNTMtYWQ0Zi04Y2RhNDhiMzA4MTEiLCAiYWlkIjogIjAiLCAibmV0IjogInRjcCIsICJ0eXBlIjogImh0dHAiLCAiaG9zdCI6ICJ3d3cuYmluZy5jb20iLCAicGF0aCI6ICIvIiwgInRscyI6ICIifQ==',
  'vless_reality_vision':
      'vless://$kUuid@nl1.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$kRealityPbk&sid=6ba85179e30d4fc2&spx=%2F&type=tcp&headerType=none#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands%20Reality',
  'vless_ws_tls':
      'vless://$kUuid@104.16.1.1:443?encryption=none&security=tls&sni=ws.example.com&fp=firefox&alpn=http%2F1.1&type=ws&host=ws.example.com&path=%2Fvlws%3Fed%3D2560#Франкфурт%20WS',
  'vless_grpc_reality':
      'vless://$kUuid@fi2.example.com:8443?encryption=none&security=reality&sni=dl.google.com&fp=safari&pbk=$kRealityPbk&sid=a1&type=grpc&serviceName=grpcsvc&mode=gun#FI%20gRPC%20Reality',
  'vless_httpupgrade':
      'vless://$kUuid@hu.example.com:80?encryption=none&security=none&type=httpupgrade&host=hu.example.com&path=%2Fup#[AT]%20Vienna',
  'vless_h2':
      'vless://$kUuid@h2.example.com:443?encryption=none&security=tls&sni=h2.example.com&type=http&host=h2.example.com&path=%2Fh2vl&packetEncoding=xudp#CH%20H2',
  'trojan_ws':
      'trojan://p%40ssw0rd@fi1.example.com:443?security=tls&sni=fi1.example.com&type=ws&path=%2Ftrojan&host=fi1.example.com#Finland%20Trojan',
  'trojan_grpc':
      'trojan://trojanpw@tr2.example.com:443?security=tls&sni=tr2.example.com&type=grpc&serviceName=trgrpc&allowInsecure=1#Trojan%20gRPC',
  'ss_sip002_b64':
      'ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpzZWNyZXRwYXNz@1.2.3.4:8388#SS%20%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0',
  'ss_2022':
      'ss://2022-blake3-aes-128-gcm:J6FKQKBIuM%2F4Tf54%2BjWw%2BA%3D%3D@us1.example.com:8443#US%20SS2022',
  'ss_obfs':
      'ss://YWVzLTI1Ni1nY206b2Jmc3Bhc3M=@obfs.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dwww.bing.com#SS%20obfs',
  'ss_v2ray_plugin':
      'ss://YWVzLTI1Ni1nY206b2Jmc3Bhc3M@v2p.example.com:443/?plugin=v2ray-plugin%3Bmode%3Dwebsocket%3Btls%3Bhost%3Dv2p.example.com%3Bpath%3D%2Fss#SS%20v2ray-plugin',
  'ss_legacy': 'ss://YWVzLTEyOC1nY206bGVnYWN5cHdANy43LjcuNzo4Mzg5#Legacy%20SS',
  'ss_shadowtls':
      'ss://2022-blake3-aes-128-gcm:J6FKQKBIuM%2F4Tf54%2BjWw%2BA%3D%3D@stls.example.com:443?plugin=shadow-tls%3Bhost%3Dwww.apple.com%3Bpassword%3Dstlspw%3Bversion%3D3#SS%20ShadowTLS',
  'ssr':
      'ssr://c3NyLmV4YW1wbGUuY29tOjg5ODk6YXV0aF9hZXMxMjhfbWQ1OmFlcy0yNTYtY2ZiOnRsczEuMl90aWNrZXRfYXV0aDpjM055Y0dGemN3Lz9vYmZzcGFyYW09WW1sdVp5NWpiMjAmcmVtYXJrcz1VMU5TSUVodmJtY2dTMjl1Wnc',
  'snell':
      'snell://snellpsk@snell.example.com:6333?version=4&obfs=http&obfs-host=www.bing.com#Snell%20v4',
  'hysteria':
      'hysteria://hy.example.com:36712?protocol=udp&auth=hyauth&peer=hy.example.com&insecure=0&upmbps=50&downmbps=200&alpn=hysteria&obfsParam=obfspw#Hysteria%20JP',
  'hysteria2_hopping':
      'hysteria2://hy2pass@sg.example.com:443,20000-30000/?obfs=salamander&obfs-password=obfspw&sni=sg.example.com&insecure=1#%F0%9F%87%B8%F0%9F%87%AC%20SG%20Hy2',
  'hy2_simple': 'hy2://pw@1.1.1.2:8443?sni=a.example.com#Latvia%20Hy2',
  'tuic':
      'tuic://$kUuid:tuicpass@kr.example.com:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=kr.example.com&allow_insecure=0#Korea%20TUIC',
  'anytls':
      'anytls://anypw@tr.example.com:443?sni=tr.example.com&insecure=0&fp=chrome#Turkey%20AnyTLS',
  'naive_https':
      'naive+https://user:pass@naive.example.com:443?padding=true#Naive%20DE',
  'naive_quic': 'naive+quic://user:pass@naiveq.example.com:443#Naive%20QUIC',
  'wireguard':
      'wireguard://AUyb4Xr9Wtd3XHAlDTDfPIMxhSD2dEo6Iy26VZlNu54%3D@wg.example.com:51820?publickey=Iew%2Bk6F%2Bs%2B8bBy4RZsyhggf6id5DffCzhIGbmyuXr%2Bo%3D&address=10.7.0.2%2F32,fd00::2&reserved=1,2,3&mtu=1280#WG%20Poland',
  'ssh': 'ssh://root:sshpass@ssh.example.com:22#SSH%20Estonia',
  'socks_v2rayn': 'socks://dXNlcjpwYXNz@5.6.7.8:1080#Socks%20v2rayN',
  'socks5': 'socks5://user:pass@5.6.7.9:1080#Socks5',
  'http': 'http://user:pass@9.9.9.9:3128#HTTP%20proxy',
  'https': 'https://user:pass@proxy.example.com:443#HTTPS%20proxy',
};

const String kClashYaml = r'''
mixed-port: 7890
mode: rule
proxies:
  - name: "🇩🇪 DE SS"
    type: ss
    server: de.example.com
    port: 8388
    cipher: aes-256-gcm
    password: "sspass"
    udp: true
  - name: "SS obfs"
    type: ss
    server: obfs.example.com
    port: 8388
    cipher: chacha20-ietf-poly1305
    password: pw
    plugin: obfs
    plugin-opts:
      mode: tls
      host: bing.com
  - name: "SS shadow-tls"
    type: ss
    server: stls.example.com
    port: 443
    cipher: 2022-blake3-aes-128-gcm
    password: "J6FKQKBIuM/4Tf54+jWw+A=="
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: "cloud.tencent.com"
      password: "shadow_tls_password"
      version: 3
  - name: "SSR HK"
    type: ssr
    server: ssr.example.com
    port: 443
    cipher: chacha20-ietf
    password: "ssrpw"
    obfs: tls1.2_ticket_auth
    protocol: auth_sha1_v4
  - name: "VMess WS"
    type: vmess
    server: vm.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    alterId: 0
    cipher: auto
    tls: true
    servername: vm.example.com
    network: ws
    ws-opts:
      path: /ws
      headers:
        Host: vm.example.com
      max-early-data: 2048
      early-data-header-name: Sec-WebSocket-Protocol
  - name: "VMess gRPC"
    type: vmess
    server: vmg.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    alterId: 0
    cipher: auto
    tls: true
    network: grpc
    grpc-opts:
      grpc-service-name: svc
  - name: "Нидерланды Reality"
    type: vless
    server: nl.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.microsoft.com
    client-fingerprint: chrome
    reality-opts:
      public-key: 6ElHfGRwKFsoJjqgyT0N-vOd96Z_vmhHRkTsY4Ftfv0
      short-id: 6ba85179e30d4fc2
  - name: "VLESS h2"
    type: vless
    server: vh2.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    network: h2
    tls: true
    h2-opts:
      host: [vh2.example.com]
      path: /h2
  - name: "Trojan"
    type: trojan
    server: tr.example.com
    port: 443
    password: trojanpw
    sni: tr.example.com
    skip-cert-verify: false
    alpn: [h2, http/1.1]
  - name: "Hysteria"
    type: hysteria
    server: hy.example.com
    port: 443
    auth-str: hyauth
    obfs: hyobfs
    up: "30 Mbps"
    down: "200 Mbps"
    sni: hy.example.com
  - name: "🇸🇬 Hy2"
    type: hysteria2
    server: hy2.example.com
    port: 443
    ports: 20000-30000
    password: hy2pw
    obfs: salamander
    obfs-password: obfspw
    sni: hy2.example.com
    up: 50
    down: 300
  - name: "TUIC"
    type: tuic
    server: tuic.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    password: tuicpw
    alpn: [h3]
    congestion-controller: bbr
    udp-relay-mode: native
    reduce-rtt: true
  - name: "WG"
    type: wireguard
    server: wg.example.com
    port: 51820
    ip: 172.16.0.2
    ipv6: fd01::2
    private-key: AUyb4Xr9Wtd3XHAlDTDfPIMxhSD2dEo6Iy26VZlNu54=
    public-key: Iew+k6F+s+8bBy4RZsyhggf6id5DffCzhIGbmyuXr+o=
    pre-shared-key: vy/OW7n7NYNNcAAFZIbeh+PLuReMtCHVEKfvjAHF6GM=
    reserved: [209, 98, 59]
    mtu: 1280
    udp: true
  - name: "Socks"
    type: socks5
    server: 10.0.0.9
    port: 1080
    username: u
    password: p
  - name: "HTTP TLS"
    type: http
    server: hp.example.com
    port: 443
    username: u
    password: p
    tls: true
  - name: "Snell v4"
    type: snell
    server: snell.example.com
    port: 6333
    psk: snellpsk
    version: 4
    obfs-opts:
      mode: tls
      host: bing.com
  - name: "Snell v2 (unsupported)"
    type: snell
    server: snell2.example.com
    port: 6333
    psk: snellpsk
    version: 2
  - name: "AnyTLS"
    type: anytls
    server: any.example.com
    port: 443
    password: anypw
    client-fingerprint: chrome
    sni: any.example.com
    idle-session-check-interval: 30
    idle-session-timeout: 30
    min-idle-session: 0
  - name: "SSH"
    type: ssh
    server: ssh.example.com
    port: 22
    username: root
    password: sshpw
proxy-groups:
  - name: PROXY
    type: select
    proxies: ["🇩🇪 DE SS", "Trojan"]
rules:
  - MATCH,PROXY
''';

const String kSingBoxJson = r'''
{
  "log": {"level": "info"},
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": ["🇫🇮 Helsinki VLESS", "hy2-sg"]},
    {"type": "urltest", "tag": "auto", "outbounds": ["🇫🇮 Helsinki VLESS"]},
    {
      "type": "vless", "tag": "🇫🇮 Helsinki VLESS",
      "server": "fi.example.com", "server_port": 443,
      "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "flow": "xtls-rprx-vision",
      "tls": {"enabled": true, "server_name": "www.microsoft.com",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {"enabled": true, "public_key": "6ElHfGRwKFsoJjqgyT0N-vOd96Z_vmhHRkTsY4Ftfv0", "short_id": "a1b2"}}
    },
    {
      "type": "hysteria2", "tag": "hy2-sg", "server": "sg.example.com", "server_port": 443,
      "password": "pw", "tls": {"enabled": true, "server_name": "sg.example.com"}
    },
    {
      "type": "shadowsocks", "tag": "ss-stls", "method": "2022-blake3-aes-128-gcm",
      "password": "J6FKQKBIuM/4Tf54+jWw+A==", "detour": "stls-out",
      "server": "127.0.0.1", "server_port": 1, "udp_over_tcp": true
    },
    {
      "type": "shadowtls", "tag": "stls-out", "server": "stls.example.com", "server_port": 443,
      "version": 3, "password": "stlspw",
      "tls": {"enabled": true, "server_name": "www.apple.com", "utls": {"enabled": true, "fingerprint": "chrome"}}
    },
    {
      "type": "wireguard", "tag": "legacy-wg", "server": "wg.example.com", "server_port": 51820,
      "local_address": ["10.0.0.2/32"], "private_key": "AUyb4Xr9Wtd3XHAlDTDfPIMxhSD2dEo6Iy26VZlNu54=",
      "peer_public_key": "Iew+k6F+s+8bBy4RZsyhggf6id5DffCzhIGbmyuXr+o=", "mtu": 1408
    },
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"},
    {"type": "dns", "tag": "dns-out"}
  ],
  "endpoints": [
    {
      "type": "wireguard", "tag": "WG Warsaw",
      "address": ["10.8.0.2/32"], "private_key": "AUyb4Xr9Wtd3XHAlDTDfPIMxhSD2dEo6Iy26VZlNu54=",
      "peers": [{"address": "pl.example.com", "port": 51820,
        "public_key": "Iew+k6F+s+8bBy4RZsyhggf6id5DffCzhIGbmyuXr+o=", "allowed_ips": ["0.0.0.0/0"]}]
    }
  ]
}
''';

const String kWireGuardConf = '''
# Name = Amsterdam WG
[Interface]
PrivateKey = AUyb4Xr9Wtd3XHAlDTDfPIMxhSD2dEo6Iy26VZlNu54=
Address = 10.66.66.2/32, fd42:42:42::2/128
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = Iew+k6F+s+8bBy4RZsyhggf6id5DffCzhIGbmyuXr+o=
PresharedKey = vy/OW7n7NYNNcAAFZIbeh+PLuReMtCHVEKfvjAHF6GM=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

const String kXrayJson = r'''
{
  "remarks": "🇩🇪 Xray DE",
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {"vnext": [{"address": "x.example.com", "port": 443,
        "users": [{"id": "b831381d-6324-4d53-ad4f-8cda48b30811", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"serverName": "www.microsoft.com", "fingerprint": "chrome",
          "publicKey": "6ElHfGRwKFsoJjqgyT0N-vOd96Z_vmhHRkTsY4Ftfv0", "shortId": "ab"}}
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
''';
