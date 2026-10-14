#!/usr/bin/env python3
"""A user's subscription in the shape their client asks for (inbounds.manager).

The manager serves one URL per user. Most clients (v2rayN, v2rayNG, Happ, Hiddify,
Streisand, Shadowrocket, NekoBox) read base64 of the share links, which stays the answer to
anything not recognized. Clash and mihomo clients get a config of proxies and groups, the
sing-box apps a sing-box config, and a browser a page with the subscription's state, a QR
code and buttons that open it in an app. `?format=` picks one by hand.

Everything comes from rendered.json (proxy_inbound.build_inbounds): each link's client
outbound is already parsed there, as sing-box JSON where sing-box can dial it and XRay's
where only XRay can (XHTTP, ECH). The configs leave those out; the links keep them.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import html
import json
import re
import urllib.parse

FORMATS = ("base64", "links", "clash", "sing-box", "html")
# The configs' own groups and exits, which no server may be named as.
RESERVED = {"proxy", "auto", "direct", "block", "reject", "dns"}

# By the start of the User-Agent: Hiddify says "like ClashMeta v2ray sing-box" further on,
# and reads the links best.
_CLASH_AGENTS = re.compile(r"(clash|mihomo|stash|flclash|koala-clash)", re.IGNORECASE)
_SING_BOX_AGENTS = re.compile(r"(SF[AIMT]/|sing-box)", re.IGNORECASE)


def pick_format(query_format: str | None, user_agent: str, accept: str) -> str:
    """The format to answer in: the query's, or one the client is known to read."""
    if query_format in FORMATS:
        return query_format
    if _CLASH_AGENTS.match(user_agent):
        return "clash"
    if _SING_BOX_AGENTS.match(user_agent):
        return "sing-box"
    if user_agent.startswith("Mozilla/") and "text/html" in accept:
        return "html"
    return "base64"


def entries(rendered: dict, user: str) -> list[dict]:
    """The user's links as subscriptions carry them: no AmneziaWG configs, which clients
    reading these do not speak. Each with a name of its own, the listener's tag and variant."""
    result = []
    seen: set[str] = set()
    for link in rendered.get("links") or []:
        if link.get("user") != user or link.get("config") is not None:
            continue
        name = link.get("tag", "proxy") + (f"-{link['variant']}" if link.get("variant") else "")
        base, index = name, 2
        if name.lower() in RESERVED:
            name = f"{base}-{index}"
            index += 1
        while name in seen:
            name, index = f"{base}-{index}", index + 1
        seen.add(name)
        result.append({**link, "name": name})
    return result


# --- sing-box -------------------------------------------------------------------------


def sing_box_outbounds(items: list[dict]) -> list[dict]:
    """Outbounds sing-box dials, named for the config: XRay-only ones are left out."""
    outbounds = []
    for item in items:
        outbound = item.get("outbound")
        if isinstance(outbound, dict) and "type" in outbound:
            outbounds.append({**outbound, "tag": item["name"]})
    return outbounds


def sing_box_config(items: list[dict]) -> dict:
    """A whole client config for the sing-box apps (1.12 and later): TUN, the user's
    servers under a selector whose default picks the fastest, private networks direct."""
    outbounds = sing_box_outbounds(items)
    names = [o["tag"] for o in outbounds]
    groups = []
    if names:
        groups = [
            {"type": "selector", "tag": "proxy", "outbounds": ["auto", *names], "default": "auto"},
            {"type": "urltest", "tag": "auto", "outbounds": names, "interval": "10m"},
        ]
    return {
        "log": {"level": "warn"},
        "dns": {
            "servers": [
                {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy" if names else "direct"},
                {"type": "local", "tag": "local"},
            ],
            "final": "remote",
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "auto_route": True,
                "strict_route": True,
            }
        ],
        "outbounds": [*groups, *outbounds, {"type": "direct", "tag": "direct"}],
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": True, "outbound": "direct"},
            ],
            "final": "proxy" if names else "direct",
            "auto_detect_interface": True,
            "default_domain_resolver": "local",
        },
    }


# --- Clash and mihomo -----------------------------------------------------------------


def _clash_tls(proxy: dict, tls: dict, sni_key: str) -> None:
    if not tls.get("enabled"):
        return
    proxy["tls"] = True
    if tls.get("server_name"):
        proxy[sni_key] = tls["server_name"]
    if tls.get("insecure"):
        proxy["skip-cert-verify"] = True
    if tls.get("alpn"):
        proxy["alpn"] = list(tls["alpn"])
    fingerprint = (tls.get("utls") or {}).get("fingerprint")
    if fingerprint:
        proxy["client-fingerprint"] = fingerprint
    reality = tls.get("reality") or {}
    if reality.get("enabled"):
        proxy["reality-opts"] = {"public-key": reality.get("public_key", ""), "short-id": reality.get("short_id", "")}
        proxy.setdefault("client-fingerprint", "chrome")


def _clash_transport(proxy: dict, transport: dict | None) -> bool:
    """mihomo's network and its options; False for a transport it lacks."""
    if not transport:
        proxy["network"] = "tcp"
        return True
    kind = transport.get("type")
    if kind in ("ws", "httpupgrade"):
        proxy["network"] = "ws"
        opts: dict = {"path": transport.get("path") or "/"}
        host = (transport.get("headers") or {}).get("Host") or transport.get("host")
        if host:
            opts["headers"] = {"Host": host}
        if kind == "httpupgrade":
            opts["v2ray-http-upgrade"] = True
        proxy["ws-opts"] = opts
    elif kind == "grpc":
        proxy["network"] = "grpc"
        proxy["grpc-opts"] = {"grpc-service-name": transport.get("service_name", "")}
    elif kind == "http":
        proxy["network"] = "h2"
        proxy["h2-opts"] = {"host": list(transport.get("host") or []), "path": transport.get("path") or "/"}
    else:
        return False
    return True


def clash_proxy(name: str, outbound: dict) -> dict | None:
    """A mihomo proxy from a sing-box outbound; None for what it cannot dial the same way."""
    kind = outbound.get("type")
    proxy: dict = {"name": name, "server": outbound.get("server"), "port": outbound.get("server_port")}
    tls = outbound.get("tls") or {}
    if kind in ("vless", "vmess"):
        proxy.update(type=kind, uuid=outbound.get("uuid"), udp=True)
        if kind == "vless":
            if outbound.get("flow"):
                proxy["flow"] = outbound["flow"]
            if outbound.get("packet_encoding"):
                proxy["packet-encoding"] = outbound["packet_encoding"]
        else:
            proxy.update({"alterId": outbound.get("alter_id", 0), "cipher": outbound.get("security") or "auto"})
        _clash_tls(proxy, tls, "servername")
    elif kind == "trojan":
        proxy.update(type="trojan", password=outbound.get("password"), udp=True)
        _clash_tls(proxy, tls, "sni")
    elif kind == "shadowsocks":
        if outbound.get("plugin"):
            return None
        proxy.update(type="ss", cipher=outbound.get("method"), password=outbound.get("password"), udp=True)
    elif kind == "hysteria2":
        proxy.update(type="hysteria2", password=outbound.get("password"))
        if tls.get("server_name"):
            proxy["sni"] = tls["server_name"]
        if tls.get("insecure"):
            proxy["skip-cert-verify"] = True
        if tls.get("alpn"):
            proxy["alpn"] = list(tls["alpn"])
        obfs = outbound.get("obfs") or {}
        if obfs.get("type"):
            proxy.update({"obfs": obfs["type"], "obfs-password": obfs.get("password", "")})
        if outbound.get("server_ports"):
            proxy["ports"] = ",".join(p.replace(":", "-") for p in outbound["server_ports"])
        return proxy
    elif kind in ("socks", "http"):
        proxy["type"] = "socks5" if kind == "socks" else "http"
        for key in ("username", "password"):
            if outbound.get(key):
                proxy[key] = outbound[key]
        _clash_tls(proxy, tls, "sni")
        return proxy
    else:
        return None
    if kind in ("vless", "vmess", "trojan") and not _clash_transport(proxy, outbound.get("transport")):
        return None
    return proxy


def clash_config(items: list[dict]) -> dict:
    """A mihomo config: the user's servers, a group that picks the fastest and one to choose
    by hand, private networks direct."""
    proxies = []
    for item in items:
        outbound = item.get("outbound")
        if isinstance(outbound, dict) and "type" in outbound:
            proxy = clash_proxy(item["name"], outbound)
            if proxy is not None:
                proxies.append(proxy)
    names = [p["name"] for p in proxies]
    groups = [
        {"name": "PROXY", "type": "select", "proxies": ["auto", *names] if names else ["DIRECT"]},
        {"name": "auto", "type": "url-test", "proxies": names or ["DIRECT"],
         "url": "https://www.gstatic.com/generate_204", "interval": 600},
    ]
    return {
        "mixed-port": 7890,
        "mode": "rule",
        "log-level": "warning",
        "proxies": proxies,
        "proxy-groups": groups,
        "rules": [
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "MATCH,PROXY",
        ],
    }


# --- the page -------------------------------------------------------------------------

TEXT = {
    "en": {
        "active": "Active", "hold": "Starts with the first connection", "off": "Switched off",
        "disabled": "switched off", "expired": "expired", "traffic": "out of traffic",
        "used": "Traffic", "of": "of", "unlimited": "unlimited", "renews": "renews",
        "expires": "Expires", "never": "never", "term": "for {} from the first connection",
        "sub": "Subscription", "copy": "Copy", "copied": "Copied", "open": "Add to an app",
        "more": "Other apps", "links": "Connections", "support": "Support", "user": "User",
        "hint": "Keep this page to yourself: its address is your access.",
    },
    "ru": {
        "active": "Активна", "hold": "Начнётся с первого подключения", "off": "Отключена",
        "disabled": "отключена", "expired": "срок истёк", "traffic": "трафик исчерпан",
        "used": "Трафик", "of": "из", "unlimited": "без лимита", "renews": "обновится",
        "expires": "Действует до", "never": "бессрочно", "term": "{} с первого подключения",
        "sub": "Подписка", "copy": "Копировать", "copied": "Скопировано", "open": "Добавить в приложение",
        "more": "Другие приложения", "links": "Подключения", "support": "Поддержка", "user": "Пользователь",
        "hint": "Не показывайте эту страницу никому: её адрес и есть ваш доступ.",
    },
}

ANDROID, IOS, MACOS, WINDOWS, LINUX = "android", "ios", "macos", "windows", "linux"
EVERYWHERE = frozenset({ANDROID, IOS, MACOS, WINDOWS, LINUX})

# Each opens the subscription in that app, on the systems the app takes the link on; {url} is
# quoted, {raw} is not. clash:// is taken by Clash Meta, FlClash, Clash Verge Rev, Clash Party
# and Stash; v2rayN and Throne take no link, only the URL pasted.
APPS = [
    ("Happ", "happ://add/{raw}", EVERYWHERE),
    ("Hiddify", "hiddify://import/{raw}#{name}", EVERYWHERE),
    ("v2rayNG", "v2rayng://install-config?url={url}#{name}", {ANDROID}),
    ("Streisand", "streisand://import/{raw}#{name}", {IOS, MACOS}),
    ("Karing", "karing://install-config?url={url}&name={name}", {ANDROID, IOS, MACOS, WINDOWS}),
    ("sing-box", "sing-box://import-remote-profile?url={url}#{name}", {ANDROID, IOS, MACOS}),
    ("Clash / mihomo", "clash://install-config?url={url}&name={name}", EVERYWHERE),
    # proxy-suite-gui (gui.enable): asks before it runs `proxy subs add`.
    ("Proxy Suite", "proxy-suite://install-config?url={url}&name={name}", {LINUX}),
]

# In this order: Android's User-Agent says Linux too, and a Chromebook runs Android apps.
_PLATFORMS = [
    (ANDROID, re.compile(r"Android|CrOS")),
    (IOS, re.compile(r"iPhone|iPad|iPod")),
    (WINDOWS, re.compile(r"Windows")),
    (MACOS, re.compile(r"Macintosh|Mac OS X")),
    (LINUX, re.compile(r"Linux|X11")),
]


def platform(user_agent: str) -> str | None:
    """The system a browser runs on, as APPS names them; None when it does not say."""
    return next((name for name, pattern in _PLATFORMS if pattern.search(user_agent or "")), None)


def language(accept_language: str) -> str:
    for part in (accept_language or "").split(","):
        tag = part.split(";")[0].strip().lower()
        if tag.startswith("ru"):
            return "ru"
        if tag.startswith("en"):
            return "en"
    return "en"


def human_bytes(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{value} B"


def human_span(seconds: int) -> str:
    for unit, size in (("w", 604800), ("d", 86400), ("h", 3600), ("m", 60)):
        if seconds % size == 0:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


_STYLE = """
:root{--bg:#f6f7f9;--card:#fff;--fg:#1c1f24;--muted:#646b75;--line:#e1e4e8;--accent:#2563eb;--ok:#15803d;--warn:#b45309;--bad:#b91c1c}
@media (prefers-color-scheme:dark){:root{--bg:#111316;--card:#1b1e23;--fg:#e8eaed;--muted:#9aa1ab;--line:#2c3036;--accent:#6ea0ff;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:560px;margin:0 auto;padding:24px 16px 48px}h1{font-size:22px;margin:0 0 4px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-top:16px}
.status{font-weight:600}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}
.row{display:flex;justify-content:space-between;gap:12px;padding:6px 0;border-bottom:1px solid var(--line)}.row:last-child{border:0}
.muted{color:var(--muted);font-size:14px}.bar{display:block;width:100%;height:6px;border-radius:3px;overflow:hidden;margin-top:6px}
.bar .track{fill:var(--line)}.bar .fill{fill:var(--accent)}
.qr{display:flex;justify-content:center;margin:8px 0}.qr svg{width:220px;height:220px;background:#fff;border-radius:8px}
code{display:block;word-break:break-all;font-size:13px;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:8px;margin:8px 0}
button,a.app{font:inherit;font-size:14px;border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:8px;padding:6px 12px;cursor:pointer;text-decoration:none;display:inline-block;margin:4px 4px 0 0}
button:hover,a.app:hover{border-color:var(--accent)}
summary{cursor:pointer;color:var(--muted);font-size:14px;margin-top:12px}h2{font-size:16px;margin:0 0 8px}h2.next{margin-top:16px}
"""

# The QR code is drawn by the browser: a request costs the server no encoder run, and the page
# takes no image from elsewhere, for the people opening it may not reach much. qrMatrix(text):
# the modules, rows of booleans, of the smallest QR code (byte mode, error correction M) that
# holds text, mask chosen by the standard's penalty; null past version 40. A test decodes its
# output with zbar.
_QR_SCRIPT = """
function qrMatrix(text){
var ECC=[0,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28],
BLK=[0,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49];
var bytes=new TextEncoder().encode(text),ver,size,raw,i,j,x,y;
function rawModules(v){var r=(16*v+128)*v+64;if(v>=2){var n=Math.floor(v/7)+2;r-=(25*n-10)*n-55;if(v>=7)r-=36}return r}
for(ver=1;;ver++){if(ver>40)return null;raw=Math.floor(rawModules(ver)/8);if(4+(ver<10?8:16)+8*bytes.length<=(raw-ECC[ver]*BLK[ver])*8)break}
size=ver*4+17;var cap=raw-ECC[ver]*BLK[ver],bits=[];
function put(v,n){for(var k=n-1;k>=0;k--)bits.push(v>>>k&1)}
put(4,4);put(bytes.length,ver<10?8:16);for(i=0;i<bytes.length;i++)put(bytes[i],8);
put(0,Math.min(4,cap*8-bits.length));put(0,(8-bits.length%8)%8);
for(var pad=0xEC;bits.length<cap*8;pad^=0xEC^0x11)put(pad,8);
var data=[];for(i=0;i<bits.length;i+=8){for(x=0,j=0;j<8;j++)x=x<<1|bits[i+j];data.push(x)}
function mul(a,b){for(var z=0,k=7;k>=0;k--){z=(z<<1)^((z>>>7)*0x11D);z^=(b>>>k&1)*a}return z}
var deg=ECC[ver],gen=[],root=1;for(i=0;i<deg;i++)gen.push(0);gen[deg-1]=1;
for(i=0;i<deg;i++){for(j=0;j<deg;j++){gen[j]=mul(gen[j],root);if(j+1<deg)gen[j]^=gen[j+1]}root=mul(root,2)}
var nb=BLK[ver],nshort=nb-raw%nb,slen=Math.floor(raw/nb),blocks=[],eccs=[],at=0;
for(i=0;i<nb;i++){var d=data.slice(at,at+=slen-deg+(i<nshort?0:1)),rem=gen.map(function(){return 0});
for(j=0;j<d.length;j++){var f=d[j]^rem.shift();rem.push(0);for(var k=0;k<deg;k++)rem[k]^=mul(gen[k],f)}
blocks.push(d);eccs.push(rem)}
var words=[];for(i=0;i<=slen-deg;i++)for(j=0;j<nb;j++)if(i<blocks[j].length)words.push(blocks[j][i]);
for(i=0;i<deg;i++)for(j=0;j<nb;j++)words.push(eccs[j][i]);
var m=[],fn=[];for(y=0;y<size;y++){m.push([]);fn.push([]);for(x=0;x<size;x++){m[y].push(false);fn[y].push(false)}}
function set(x,y,dark){m[y][x]=dark;fn[y][x]=true}
for(i=0;i<size;i++){set(6,i,i%2==0);set(i,6,i%2==0)}
[[3,3],[size-4,3],[3,size-4]].forEach(function(c){for(var dy=-4;dy<=4;dy++)for(var dx=-4;dx<=4;dx++){
var q=Math.max(Math.abs(dx),Math.abs(dy)),xx=c[0]+dx,yy=c[1]+dy;if(xx>=0&&xx<size&&yy>=0&&yy<size)set(xx,yy,q!=2&&q!=4)}});
var pos=[];if(ver>1){var na=Math.floor(ver/7)+2,step=Math.floor((ver*8+na*3+5)/(na*4-4))*2;pos=[6];for(x=size-7;pos.length<na;x-=step)pos.splice(1,0,x)}
for(i=0;i<pos.length;i++)for(j=0;j<pos.length;j++){if(i==0&&j==0||i==0&&j==pos.length-1||i==pos.length-1&&j==0)continue;
for(var ay=-2;ay<=2;ay++)for(var ax=-2;ax<=2;ax++)set(pos[i]+ax,pos[j]+ay,Math.max(Math.abs(ax),Math.abs(ay))!=1)}
function format(mask){var v=mask,r=v;for(var k=0;k<10;k++)r=(r<<1)^((r>>>9)*0x537);v=(v<<10|r)^0x5412;
function b(k){return (v>>>k&1)==1}
for(k=0;k<=5;k++)set(8,k,b(k));set(8,7,b(6));set(8,8,b(7));set(7,8,b(8));for(k=9;k<15;k++)set(14-k,8,b(k));
for(k=0;k<8;k++)set(size-1-k,8,b(k));for(k=8;k<15;k++)set(8,size-15+k,b(k));set(8,size-8,true)}
format(0);
if(ver>=7){var r=ver;for(i=0;i<12;i++)r=(r<<1)^((r>>>11)*0x1F25);var vb=ver<<12|r;
for(i=0;i<18;i++){var bit=(vb>>>i&1)==1,a=size-11+i%3,c=Math.floor(i/3);set(a,c,bit);set(c,a,bit)}}
for(i=0,x=size-1;x>=1;x-=2){if(x==6)x=5;for(var v=0;v<size;v++)for(j=0;j<2;j++){
var xx=x-j;y=(x+1&2)==0?size-1-v:v;if(!fn[y][xx]&&i<words.length*8){m[y][xx]=(words[i>>>3]>>>7-(i&7)&1)==1;i++}}}
var masks=[function(x,y){return (x+y)%2==0},function(x,y){return y%2==0},function(x,y){return x%3==0},
function(x,y){return (x+y)%3==0},function(x,y){return (Math.floor(x/3)+Math.floor(y/2))%2==0},
function(x,y){return x*y%2+x*y%3==0},function(x,y){return (x*y%2+x*y%3)%2==0},function(x,y){return ((x+y)%2+x*y%3)%2==0}];
function flip(k){for(var y=0;y<size;y++)for(var x=0;x<size;x++)if(!fn[y][x]&&masks[k](x,y))m[y][x]=!m[y][x]}
function line(get){var p=0,dark=0,run=0,last=null,seq='';for(var k=0;k<size;k++){var d=get(k);dark+=d;seq+=d?'1':'0';
if(d===last)run++;else{if(run>=5)p+=run-2;run=1;last=d}}if(run>=5)p+=run-2;
for(k=seq.indexOf('1011101');k>=0;k=seq.indexOf('1011101',k+1))
if(seq.substr(k-4,4)=='0000'||seq.substr(k+7,4)=='0000'||k<4||k+11>size)p+=40;return p}
function score(){var p=0,dark=0;for(var a=0;a<size;a++){p+=line(function(k){return m[a][k]?1:0});p+=line(function(k){return m[k][a]?1:0})}
for(var y=0;y<size;y++)for(var x=0;x<size;x++){dark+=m[y][x];if(x<size-1&&y<size-1&&m[y][x]==m[y][x+1]&&m[y][x]==m[y+1][x]&&m[y][x]==m[y+1][x+1])p+=3}
return p+10*Math.max(0,Math.ceil(Math.abs(dark*20-size*size*10)/(size*size))-1)}
var best=0,low=Infinity;for(k=0;k<8;k++){flip(k);format(k);var s=score();if(s<low){low=s;best=k}flip(k)}
flip(best);format(best);return m}
"""

_SCRIPT = _QR_SCRIPT + """
document.querySelectorAll('[data-qr]').forEach(function(e){var m=qrMatrix(e.getAttribute('data-qr'));if(!m)return;
var n=m.length+8,ns='http://www.w3.org/2000/svg',s=document.createElementNS(ns,'svg'),p=document.createElementNS(ns,'path'),d='';
for(var y=0;y<m.length;y++)for(var x=0;x<m.length;x++)if(m[y][x])d+='M'+(x+4)+' '+(y+4)+'h1v1h-1z';
s.setAttribute('viewBox','0 0 '+n+' '+n);s.setAttribute('shape-rendering','crispEdges');p.setAttribute('d',d);p.setAttribute('fill','#000');
s.appendChild(p);e.appendChild(s)});
document.querySelectorAll('button[data-copy]').forEach(function(b){b.addEventListener('click',function(){
var t=b.getAttribute('data-copy'),l=b.textContent;function done(){b.textContent=b.getAttribute('data-done');setTimeout(function(){b.textContent=l},1500)}
if(navigator.clipboard){navigator.clipboard.writeText(t).then(done)}else{var a=document.createElement('textarea');a.value=t;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove();done()}})});
"""


def _csp_hash(source: str) -> str:
    return "'sha256-" + base64.b64encode(hashlib.sha256(source.encode("utf-8")).digest()).decode("ascii") + "'"


# Every answer: the address is the secret, not to be sent on, indexed, sniffed into something
# else or read by other sites' pages.
HEADERS = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Robots-Tag": "noindex, nofollow",
    "X-Content-Type-Options": "nosniff",
    "Cross-Origin-Resource-Policy": "same-origin",
}
# The page, besides: nothing runs or styles it but its own script and stylesheet, by their
# hashes; no style attribute, no frame, no form, no other origin.
PAGE_HEADERS = {
    "Content-Security-Policy": f"default-src 'none'; script-src {_csp_hash(_SCRIPT)}; style-src {_csp_hash(_STYLE)}; "
                               "base-uri 'none'; form-action 'none'; frame-ancestors 'none'; "
                               "require-trusted-types-for 'script'",
    "Cross-Origin-Opener-Policy": "same-origin",
}


def html_page(row: dict, items: list[dict], sub_url: str, title: str, settings: dict, lang: str,
              user_agent: str = "") -> str:
    """The page a browser gets: the state of the subscription, its QR code and links. The apps
    for the browser's system come first, the rest folded away: the page may be open on a laptop
    to set up a phone."""
    t = TEXT[lang]
    esc = html.escape
    if not row.get("active"):
        state = f'<span class="status bad">{esc(t["off"])}</span>'
        reasons = ", ".join(t.get(r, r) for r in row.get("reasons") or [])
        if reasons:
            state += f' <span class="muted">({esc(reasons)})</span>'
    elif row.get("onHold"):
        state = f'<span class="status warn">{esc(t["hold"])}</span>'
    else:
        state = f'<span class="status ok">{esc(t["active"])}</span>'
    traffic = row.get("traffic") or {}
    used, limit = traffic.get("used") or 0, traffic.get("limit")
    usage = esc(human_bytes(used)) + (f' {esc(t["of"])} {esc(human_bytes(limit))}' if limit else f' <span class="muted">({esc(t["unlimited"])})</span>')
    if limit and traffic.get("periodEnd"):
        renew = datetime.datetime.fromtimestamp(traffic["periodEnd"]).strftime("%Y-%m-%d")
        usage += f' <span class="muted">· {esc(t["renews"])} {esc(renew)}</span>'
    # An SVG's width attribute, not a style one: the CSP lets no style attribute through.
    bar = (f'<svg class="bar" viewBox="0 0 100 1" preserveAspectRatio="none"><rect class="track" width="100" height="1"/>'
           f'<rect class="fill" width="{min(100, int(used * 100 / limit))}" height="1"/></svg>') if limit else ""
    if row.get("onHold"):
        expires = esc(t["term"].format(human_span((row.get("policy") or {}).get("expiresAfter") or 0)))
    elif row.get("expiresAt"):
        expires = esc(datetime.datetime.fromtimestamp(row["expiresAt"]).strftime("%Y-%m-%d %H:%M"))
    else:
        expires = esc(t["never"])
    name = urllib.parse.quote(title, safe="")
    system = platform(user_agent)
    buttons = {
        label: f'<a class="app" href="{esc(pattern.format(url=urllib.parse.quote(sub_url, safe=""), raw=sub_url, name=name))}">{esc(label)}</a>'
        for label, pattern, _ in APPS
    }
    mine = [label for label, _, systems in APPS if system in systems]
    others = [label for label, _, _ in APPS if label not in mine]
    if mine:
        apps = "".join(buttons[label] for label in mine)
        if others:
            apps += f'<details><summary>{esc(t["more"])}</summary>{"".join(buttons[label] for label in others)}</details>'
    else:
        apps = "".join(buttons.values())
    links = "".join(
        f'<div class="row"><span>{esc(item["name"])}</span>'
        f'<button data-copy="{esc(item["link"])}" data-done="{esc(t["copied"])}">{esc(t["copy"])}</button></div>'
        for item in items
    )
    # Whose it is, unless the title (profileTitle's {user}) says so already.
    user = ""
    if row.get("name") and row["name"] not in title:
        user = f'<div class="muted">{esc(t["user"])}: {esc(row["name"])}</div>'
    support = ""
    if settings.get("supportUrl"):
        support = f'<p class="muted"><a href="{esc(settings["supportUrl"])}">{esc(t["support"])}</a></p>'
    return f"""<!doctype html>
<html lang="{lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer">
<title>{esc(title)}</title><style>{_STYLE}</style></head>
<body><main>
<h1>{esc(title)}</h1>{user}<div>{state}</div>
<div class="card">
<div class="row"><span>{esc(t["used"])}</span><span>{usage}</span></div>{bar}
<div class="row"><span>{esc(t["expires"])}</span><span>{expires}</span></div>
</div>
<div class="card"><h2>{esc(t["sub"])}</h2>
<div class="qr" data-qr="{esc(sub_url)}"></div>
<code>{esc(sub_url)}</code>
<button data-copy="{esc(sub_url)}" data-done="{esc(t["copied"])}">{esc(t["copy"])}</button>
<h2 class="next">{esc(t["open"])}</h2>{apps}
</div>
{f'<div class="card"><h2>{esc(t["links"])}</h2>{links}</div>' if links else ''}
<p class="muted">{esc(t["hint"])}</p>{support}
</main><script>{_SCRIPT}</script></body></html>
"""


# --- the answer -----------------------------------------------------------------------


def render(fmt: str, rendered: dict, user: str, body_b64: str, row: dict | None, sub_url: str, title: str,
           settings: dict, accept_language: str = "", user_agent: str = "") -> tuple[bytes, str]:
    """(body, Content-Type) of a subscription in one format."""
    items = entries(rendered, user)
    if fmt == "links":
        return base64.b64decode(body_b64) + b"\n", "text/plain; charset=utf-8"
    if fmt == "sing-box":
        return (json.dumps(sing_box_config(items), indent=2) + "\n").encode("utf-8"), "application/json; charset=utf-8"
    if fmt == "clash":
        # JSON is YAML: no YAML library needed, and mihomo reads it as such.
        return (json.dumps(clash_config(items), indent=2, ensure_ascii=False) + "\n").encode("utf-8"), "text/yaml; charset=utf-8"
    if fmt == "html" and row is not None:
        page = html_page(row, items, sub_url, title, settings, language(accept_language), user_agent)
        return page.encode("utf-8"), "text/html; charset=utf-8"
    return body_b64.encode("ascii"), "text/plain; charset=utf-8"
