#!/usr/bin/env python3

import base64
import ipaddress
import json
import re
import socket
import sys
import urllib.parse
import urllib.request

from proxy_url_parsers import BACKEND_AWARE_PARSERS, PARSERS, _strip_socket_keys, local_file_keys


def detect_scheme(url: str) -> str:
    return url.split("://", 1)[0].lower()


def _parse_url(url: str, tag: str, backend: str) -> dict:
    scheme = detect_scheme(url)
    if scheme not in PARSERS:
        raise ValueError(f"unsupported scheme '{scheme}'")

    parser = PARSERS[scheme]
    if scheme in BACKEND_AWARE_PARSERS:
        return parser(url, tag, backend)
    return parser(url, tag)


def _xray_sockopt(routing_mark: int | None) -> dict:
    if routing_mark is None:
        return {}
    return {"streamSettings": {"sockopt": {"mark": routing_mark}}}


def _xray_tls(tls: dict | None) -> tuple[str, dict]:
    if not tls or not tls.get("enabled"):
        return "none", {}

    if tls.get("reality", {}).get("enabled"):
        reality = tls["reality"]
        settings = {
            "serverName": tls.get("server_name", ""),
            "publicKey": reality["public_key"],
            "shortId": reality.get("short_id", ""),
        }
        utls = tls.get("utls", {})
        if reality.get("spider_x"):
            settings["spiderX"] = reality["spider_x"]
        if utls.get("enabled") and utls.get("fingerprint"):
            settings["fingerprint"] = utls["fingerprint"]
        return "reality", {"realitySettings": settings}

    settings = {"serverName": tls.get("server_name", "")}
    if tls.get("alpn"):
        settings["alpn"] = tls["alpn"]
    if tls.get("insecure"):
        raise ValueError(
            "XRay no longer supports tlsSettings.allowInsecure; "
            "remove insecure=1 or use a supported certificate verification option"
        )
    if tls.get("certificate_sha256"):
        settings["pinnedPeerCertSha256"] = tls["certificate_sha256"]
    if tls.get("ech_config_list"):
        settings["echConfigList"] = tls["ech_config_list"]
    utls = tls.get("utls", {})
    if utls.get("enabled") and utls.get("fingerprint"):
        settings["fingerprint"] = utls["fingerprint"]
    return "tls", {"tlsSettings": settings}


def _xray_transport(transport: dict | None) -> tuple[str, dict]:
    if not transport:
        return "raw", {}

    t = transport["type"]
    if t == "ws":
        return "ws", {"wsSettings": {"path": transport.get("path", "/"), "headers": transport.get("headers", {})}}
    if t == "grpc":
        return "grpc", {"grpcSettings": {"serviceName": transport.get("service_name", "")}}
    if t == "http":
        return "http", {"httpSettings": {"host": transport.get("host", []), "path": transport.get("path", "/")}}
    if t == "httpupgrade":
        return "httpupgrade", {
            "httpupgradeSettings": {
                "host": transport.get("host", ""),
                "path": transport.get("path", "/"),
            }
        }
    if t == "quic":
        return "quic", {}
    if t == "tcp":
        request = {"path": transport["path"], "headers": {"Host": transport["host"]} if transport["host"] else {}}
        return "raw", {"rawSettings": {"header": {"type": transport["header"], "request": request}}}
    if t == "xhttp":
        settings = {"path": transport.get("path", "/")}
        if transport.get("host"):
            settings["host"] = transport["host"]
        if transport.get("mode"):
            settings["mode"] = transport["mode"]
        if transport.get("extra") is not None:
            settings["extra"] = transport["extra"]
        return "xhttp", {"xhttpSettings": settings}
    return t, {}


def render_xray_outbound(ob: dict, routing_mark: int | None = None) -> dict:
    typ = ob["type"]
    tag = ob["tag"]

    def stream_settings() -> dict:
        security, sec = _xray_tls(ob.get("tls"))
        network, net = _xray_transport(ob.get("transport"))
        stream = {"network": network, "security": security}
        stream.update(sec)
        stream.update(net)
        stream.setdefault("sockopt", {})["domainStrategy"] = "UseIP"
        if routing_mark is not None:
            stream.setdefault("sockopt", {})["mark"] = routing_mark
        return stream

    if typ == "vless":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "id": ob["uuid"],
            "encryption": ob.get("encryption", "none"),
        }
        if ob.get("flow"):
            settings["flow"] = ob["flow"]
        return {"protocol": "vless", "tag": tag, "settings": settings, "streamSettings": stream_settings()}

    if typ == "vmess":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "id": ob["uuid"],
            "security": ob.get("security", "auto"),
            "alterId": ob.get("alter_id", 0),
        }
        return {"protocol": "vmess", "tag": tag, "settings": settings, "streamSettings": stream_settings()}

    if typ == "trojan":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "password": ob["password"],
        }
        return {"protocol": "trojan", "tag": tag, "settings": settings, "streamSettings": stream_settings()}

    if typ == "shadowsocks":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "method": ob["method"],
            "password": ob["password"],
        }
        return {"protocol": "shadowsocks", "tag": tag, "settings": settings, **_xray_sockopt(routing_mark)}

    if typ == "hysteria2":
        stream = stream_settings()
        stream["network"] = "hysteria"
        stream["security"] = "tls"
        stream["hysteriaSettings"] = {"version": 2}
        settings = {
            "version": 2,
            "address": ob["server"],
            "port": ob["server_port"],
        }
        if ob.get("password"):
            stream["hysteriaSettings"]["auth"] = ob["password"]
        # XRay wants udphop outermost, ahead of any other UDP mask.
        if ob.get("server_ports"):
            stream.setdefault("finalmask", {}).setdefault("udp", []).append(
                {
                    "type": "udphop",
                    "settings": {
                        "mode": "intervalRemote",
                        "interval": "20-40",
                        "remotePorts": ",".join(r.replace(":", "-") for r in ob["server_ports"]),
                    },
                }
            )
        if ob.get("obfs", {}).get("type") == "salamander":
            stream.setdefault("finalmask", {}).setdefault("udp", []).append(
                {
                    "type": "salamander",
                    "settings": {"password": ob["obfs"].get("password", "")},
                }
            )
        return {"protocol": "hysteria", "tag": tag, "settings": settings, "streamSettings": stream}

    if typ == "socks":
        # XRay's client greets with SOCKS5 whatever the settings say; a SOCKS4 server drops it.
        if ob.get("version", "5") != "5":
            raise ValueError(f"XRay's socks outbound speaks SOCKS5 only, not SOCKS{ob['version']}")
        settings = {"address": ob["server"], "port": ob["server_port"]}
        if ob.get("username"):
            settings["user"] = ob["username"]
            settings["pass"] = ob.get("password", "")
        return {"protocol": "socks", "tag": tag, "settings": settings, **_xray_sockopt(routing_mark)}

    if typ == "http":
        settings = {"address": ob["server"], "port": ob["server_port"]}
        if ob.get("username"):
            settings["user"] = ob["username"]
            settings["pass"] = ob.get("password", "")
        outbound = {"protocol": "http", "tag": tag, "settings": settings}
        if ob.get("tls"):
            security, sec = _xray_tls(ob.get("tls"))
            outbound["streamSettings"] = {"security": security, **sec}
            if routing_mark is not None:
                outbound["streamSettings"].setdefault("sockopt", {})["mark"] = routing_mark
        elif routing_mark is not None:
            outbound.update(_xray_sockopt(routing_mark))
        return outbound

    raise ValueError(f"unsupported XRay outbound type '{typ}'")


def build_outbound(
    url: str, tag: str, routing_mark: int | None = None, backend: str = "sing-box", tweaks: dict | None = None
) -> dict:
    if backend not in {"sing-box", "xray"}:
        raise ValueError(f"unsupported backend '{backend}'")

    return _finish_outbound(_parse_url(url, tag, backend), routing_mark, backend, tweaks)


# What a link cannot say but an outbound or a subscription may ask for (`fragment`,
# `multiplex`): checked here, as it comes from the config or a group-writable spool.
FRAGMENT_DEFAULTS = {"packets": "tlshello", "length": "50-100", "interval": "10-20"}
MULTIPLEX_PROTOCOLS = ("h2mux", "smux", "yamux")
MULTIPLEX_DEFAULTS = {"protocol": "h2mux", "maxConnections": 4, "padding": False, "concurrency": 8}
_RANGE = re.compile(r"[0-9]{1,5}(-[0-9]{1,5})?")
# Both backends take these over a TLS or REALITY stream they dial over TCP.
MUX_TYPES = ("vless", "vmess", "trojan", "shadowsocks")


def checked_tweaks(tweaks) -> dict:
    """{"fragment": {packets, length, interval} | None, "multiplex": {...} | None}; ValueError
    for anything else."""
    if tweaks in (None, ""):
        return {"fragment": None, "multiplex": None}
    if not isinstance(tweaks, dict) or set(tweaks) - {"fragment", "multiplex"}:
        raise ValueError("outbound settings take fragment and multiplex only")
    out = {"fragment": None, "multiplex": None}
    fragment = tweaks.get("fragment")
    if fragment is not None:
        if fragment is True:
            fragment = {}
        if not isinstance(fragment, dict) or set(fragment) - set(FRAGMENT_DEFAULTS):
            raise ValueError("fragment takes packets, length and interval")
        fragment = {**FRAGMENT_DEFAULTS, **{k: v for k, v in fragment.items() if v is not None}}
        if fragment["packets"] != "tlshello" and not (isinstance(fragment["packets"], str) and _RANGE.fullmatch(fragment["packets"])):
            raise ValueError("fragment packets is \"tlshello\" or a range such as 1-3")
        for key in ("length", "interval"):
            if not isinstance(fragment[key], str) or not _RANGE.fullmatch(fragment[key]):
                raise ValueError(f"fragment {key} is a number or a range such as 10-20")
        out["fragment"] = fragment
    multiplex = tweaks.get("multiplex")
    if multiplex is not None:
        if multiplex is True:
            multiplex = {}
        if not isinstance(multiplex, dict) or set(multiplex) - set(MULTIPLEX_DEFAULTS):
            raise ValueError("multiplex takes protocol, maxConnections, padding and concurrency")
        multiplex = {**MULTIPLEX_DEFAULTS, **{k: v for k, v in multiplex.items() if v is not None}}
        if multiplex["protocol"] not in MULTIPLEX_PROTOCOLS:
            raise ValueError(f"multiplex protocol is one of {', '.join(MULTIPLEX_PROTOCOLS)}")
        for key, top in (("maxConnections", 64), ("concurrency", 1024)):
            value = multiplex[key]
            if type(value) is not int or not 1 <= value <= top:
                raise ValueError(f"multiplex {key} is a number from 1 to {top}")
        if type(multiplex["padding"]) is not bool:
            raise ValueError("multiplex padding is true or false")
        out["multiplex"] = multiplex
    return out


def _skip(tag, what, why):
    print(f"warning: outbound {tag!r}: {what} left out: {why}", file=sys.stderr)


def _sing_box_tweaks(outbound: dict, tweaks: dict) -> None:
    tag = outbound.get("tag")
    if tweaks["fragment"]:
        tls = outbound.get("tls")
        if not (isinstance(tls, dict) and tls.get("enabled")) or outbound.get("type") in ("hysteria2", "tuic"):
            _skip(tag, "fragment", "it splits a TLS ClientHello sent over TCP, and this outbound sends none")
        elif isinstance(tls.get("reality"), dict) and tls["reality"].get("enabled"):
            # sing-box builds REALITY's handshake on the connection itself, past its fragmenter.
            _skip(tag, "fragment", "sing-box does not fragment REALITY; the XRay backend does")
        else:
            # sing-box sizes the pieces itself; packets, length and interval are XRay's.
            tls["fragment"] = True
    if multiplex := tweaks["multiplex"]:
        if outbound.get("type") not in MUX_TYPES:
            _skip(tag, "multiplex", f"{outbound.get('type')} has none")
        else:
            outbound["multiplex"] = {
                "enabled": True,
                "protocol": multiplex["protocol"],
                "max_connections": multiplex["maxConnections"],
                "padding": multiplex["padding"],
            }


def _xray_tweaks(rendered: dict, tweaks: dict) -> None:
    tag = rendered.get("tag")
    stream = rendered.get("streamSettings") if isinstance(rendered.get("streamSettings"), dict) else {}
    if multiplex := tweaks["multiplex"]:
        if rendered.get("protocol") not in MUX_TYPES:
            _skip(tag, "multiplex", f"{rendered.get('protocol')} has none")
        elif stream.get("network") == "xhttp":
            _skip(tag, "multiplex", "XHTTP multiplexes itself (proxy.xray.xhttpXmux)")
        else:
            settings = rendered.get("settings") if isinstance(rendered.get("settings"), dict) else {}
            # XRay's flat VLESS settings, or the older vnext form.
            users = [settings] + [u for v in settings.get("vnext") or [] for u in v.get("users") or []]
            if any(isinstance(u, dict) and u.get("flow") for u in users):
                # Vision: mux.cool for UDP alone (XUDP); the server breaks a muxed TCP stream.
                rendered["mux"] = {"enabled": True, "concurrency": -1, "xudpConcurrency": multiplex["concurrency"]}
            else:
                rendered["mux"] = {"enabled": True, "concurrency": multiplex["concurrency"]}
    if fragment := tweaks["fragment"]:
        if stream.get("security") not in ("tls", "reality") or stream.get("network") in ("kcp", "mkcp", "quic"):
            _skip(tag, "fragment", "it splits a TLS ClientHello sent over TCP, and this outbound sends none")
        else:
            # The start script makes it a freedom hop of its own, which this outbound dials
            # through (backend-filter-xray, xrayFragmentJq): XRay fragments in freedom alone.
            rendered["_fragment"] = dict(fragment)


def _finish_outbound(outbound: dict, routing_mark: int | None, backend: str, tweaks: dict | None = None) -> dict:
    tweaks = checked_tweaks(tweaks)
    if backend == "xray":
        rendered = render_xray_outbound(outbound, routing_mark)
        _xray_tweaks(rendered, tweaks)
        return rendered
    if routing_mark is not None:
        outbound["routing_mark"] = routing_mark
    _sing_box_tweaks(outbound, tweaks)
    return outbound


class RefusedServer(ValueError):
    """A subscription entry whose server is this host or its link."""


# Opt-in per subscription (allowPrivateServers): a provider's servers are not on the LAN.
_PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(net)
    for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7")
)


def _server_address(host: str) -> "ipaddress.IPv4Address | ipaddress.IPv6Address | None":
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        # inet_aton's forms (2130706433, 0x7f.1, 127.1), which a resolver may still take.
        if not re.fullmatch(r"[0-9A-Fa-fXx.]+", host):
            return None
        try:
            address = ipaddress.IPv4Address(socket.inet_aton(host))
        except OSError:
            return None
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        return address.ipv4_mapped
    return address


def _check_address(host, address, allow_private: bool) -> None:
    if address.is_loopback or address.is_unspecified or address in ipaddress.ip_network("0.0.0.0/8"):
        raise RefusedServer(f"server {host} is this host")
    if address.is_link_local or address.is_multicast:
        raise RefusedServer(f"server {host} is a link-local or multicast address")
    if not allow_private and any(address in net for net in _PRIVATE_NETWORKS):
        raise RefusedServer(f"server {host} is a private address (see allowPrivateServers)")


def check_server(host, allow_private: bool = False) -> None:
    """Raises RefusedServer for a literal address (or localhost) on this host, its link, or,
    unless allow_private, a private network: urltest would pick a loopback entry as the exit."""
    if not isinstance(host, str):
        return
    name = host.strip().rstrip(".").lower()
    # The backends dial "[127.0.0.1]" as 127.0.0.1: judged unbracketed, or it is no
    # address and no name either, and passes unchecked.
    if name.startswith("[") and name.endswith("]"):
        name = name[1:-1].rstrip(".")
    if name == "localhost" or name.endswith(".localhost"):
        raise RefusedServer(f"server {host} is this host")
    address = _server_address(name)
    if address is not None:
        _check_address(host, address, allow_private)


# A subscription is a list of share links; the biggest real ones are tens of KiB.
# Read runs as root at service start, so a server that never stops sending must not
# take the whole proxy down with it.
MAX_SUBSCRIPTION_BYTES = 8 * 1024 * 1024


class FetchError(ValueError):
    """A fetch refused or cut short here: its message never quotes the URL, which is a secret."""


def _nearness(host) -> int:
    """How close to this host a URL's host is: 2 for this host or its link, 1 for a private
    network, 0 for anywhere else or a name other than localhost."""
    if not isinstance(host, str):
        return 0
    name = host.strip().rstrip(".").lower()
    if name == "localhost" or name.endswith(".localhost"):
        return 2
    address = _server_address(name)
    if address is None:
        return 0
    if address.is_loopback or address.is_unspecified or address.is_link_local or address in ipaddress.ip_network("0.0.0.0/8"):
        return 2
    return 1 if any(address in net for net in _PRIVATE_NETWORKS) else 0


class _HttpOnlyRedirects(urllib.request.HTTPRedirectHandler):
    """Redirects stay on http and https (urllib's own also follows ftp:), never downgrade
    https, and never point nearer to this host (loopback, LAN, metadata) than their source."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl)
        scheme = target.scheme
        if scheme not in ("http", "https"):
            raise FetchError("subscription redirected off http:// and https://")
        if scheme == "http" and urllib.parse.urlsplit(req.full_url).scheme == "https":
            raise FetchError("subscription redirected from https:// to http://")
        if _nearness(target.hostname) > _nearness(urllib.parse.urlsplit(req.full_url).hostname):
            raise FetchError("subscription redirected to this host or a private network")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


# Panels pick what they serve by the User-Agent: v2rayN's gets the plain list of links.
DEFAULT_USER_AGENT = "v2rayN/6.0"


def fetch_subscription(
    url: str, user_agent: str = DEFAULT_USER_AGENT, headers: "dict[str, str] | None" = None
) -> tuple[bytes, dict[str, str]]:
    """The body and the response's headers (names lowercased; the last of a repeated one)."""
    # urlopen also speaks file:, ftp: and data:. This runs as root over a URL that
    # reaches it from a group-writable spool, so only the two a subscription is
    # ever served over, redirects included.
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise FetchError("subscription URL must be http:// or https://")
    request = urllib.request.Request(
        url,
        headers={**(headers or {}), "User-Agent": user_agent},
    )
    opener = urllib.request.build_opener(_HttpOnlyRedirects)
    with opener.open(request, timeout=30) as response:
        data = response.read(MAX_SUBSCRIPTION_BYTES + 1)
        response_headers = {name.lower(): value for name, value in response.headers.items()}
    if len(data) > MAX_SUBSCRIPTION_BYTES:
        raise FetchError(f"subscription is larger than {MAX_SUBSCRIPTION_BYTES} bytes")
    return data, response_headers


def fetch_raw(url: str) -> bytes:
    return fetch_subscription(url)[0]


def decode_subscription(data: bytes) -> list[str]:
    text = None
    # A BOM, before the base64 or inside it, would otherwise skew the padding or ride
    # into the first link; a stray bad byte costs its own line, not the whole subscription.
    data = data.removeprefix(b"\xef\xbb\xbf")
    # Line-wrapped and URL-safe base64 both occur; the lenient decoder would drop
    # "-" and "_" as junk instead of reading them as "+" and "/".
    stripped = b"".join(data.split()).translate(bytes.maketrans(b"-_", b"+/"))
    try:
        pad = b"=" * (-len(stripped) % 4)
        decoded = base64.b64decode(stripped + pad).decode("utf-8-sig", errors="replace")
        if any(f"{scheme}://" in decoded for scheme in PARSERS):
            text = decoded
    except Exception:
        pass

    if text is None:
        text = data.decode("utf-8", errors="replace")

    return [line.strip() for line in text.splitlines() if line.strip()]


def slugify_tag(remark: str) -> str:
    # \w is Unicode-aware: non-Latin remarks (e.g. Cyrillic country names) keep
    # their letters instead of collapsing to a bare "proxy" tag. Tags only ever
    # reach JSON configs and the Clash API, both UTF-8 safe.
    slug = re.sub(r"[^\w-]", "-", remark)
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug[:60] or "proxy"


def make_tag(prefix: str, remark: str, index: int) -> str:
    if remark:
        return f"{prefix}-{slugify_tag(urllib.parse.unquote(remark))}"
    return f"{prefix}-{index}"


def _remark_from_line(line: str) -> str:
    return line.split("#", 1)[1] if "#" in line else ""


def _unique_tag(base_tag: str, seen_tags: set[str]) -> str:
    if base_tag not in seen_tags:
        return base_tag

    suffix = 2
    while f"{base_tag}-{suffix}" in seen_tags:
        suffix += 1
    return f"{base_tag}-{suffix}"


def _subscription_tag(line: str, tag_prefix: str, index: int, seen_tags: set[str]) -> str:
    return _unique_tag(make_tag(tag_prefix, _remark_from_line(line), index), seen_tags)


# Real subscriptions hold hundreds; 8 MiB of short lines would be minutes of start script
# and gigabytes of backend config.
MAX_SUBSCRIPTION_ENTRIES = 5000


def _ech_dns_server(value) -> str | None:
    """The resolver XRay asks for the ECH config, when echConfigList names one instead of
    holding the config: "[name+]udp://1.1.1.1:53", "https://dns.example/dns-query", "h2c://…"."""
    if not isinstance(value, str) or "://" not in value:
        return None
    url = value.split("+", 1)[1] if "+" in value.split("://", 1)[0] else value
    try:
        host = urllib.parse.urlsplit(url).hostname
    except ValueError:
        host = None
    # Unparsable: the whole value, which check_server passes unless it is an address itself.
    return host or value


def _dialed_servers(outbound: dict) -> list:
    """Every address the outbound dials: its server, any "address" (any case) in an xhttp
    extra's downloadSettings, and the resolver an ECH config is fetched from."""
    servers = [outbound.get("server")]
    tls = outbound.get("tls")
    if isinstance(tls, dict) and (ech := _ech_dns_server(tls.get("ech_config_list"))):
        servers.append(ech)
    transport = outbound.get("transport")
    stack = [transport.get("extra")] if isinstance(transport, dict) else []
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            for key, value in item.items():
                if str(key).lower() == "address":
                    servers.append(value if isinstance(value, str) else str(value))
                elif str(key).lower() == "echconfiglist" and (ech := _ech_dns_server(value)):
                    servers.append(ech)
                stack.append(value)
        elif isinstance(item, list):
            stack.extend(item)
    return servers


def _walk_subscription(
    lines: list[str],
    tag_prefix: str,
    routing_mark: int | None,
    backends: list[str],
    links: dict[str, str] | None,
    keep,
    allow_private: bool = False,
    allow_insecure: bool = False,
    tweaks: dict | None = None,
) -> None:
    """Parses every supported line, trying each backend in turn, and hands the result to keep.

    A line no backend accepts is reported with every backend's complaint and skipped, as is
    one whose server check_server refuses.
    """
    seen_tags: set[str] = set()

    for index, line in enumerate(lines):
        scheme = detect_scheme(line)
        if scheme not in PARSERS:
            continue
        if len(seen_tags) >= MAX_SUBSCRIPTION_ENTRIES:
            print(
                f"warning: subscription has more than {MAX_SUBSCRIPTION_ENTRIES} entries: the rest are left out",
                file=sys.stderr,
            )
            break

        tag = _subscription_tag(line, tag_prefix, index, seen_tags)
        errors = []
        for backend in backends:
            try:
                outbound = _parse_url(line, tag, backend)
                for server in _dialed_servers(outbound):
                    check_server(server, allow_private)
                # Whoever serves the list could otherwise have the tunnel trust any certificate:
                # anyone on the way stands in for the server then. Per backend: XRay may pin it.
                if not allow_insecure and isinstance(outbound.get("tls"), dict) and outbound["tls"].get("insecure"):
                    raise ValueError("it turns certificate checks off (insecure=1; see allowInsecure)")
                outbound = _finish_outbound(outbound, routing_mark, backend, tweaks)
            except RefusedServer as exc:
                # The same server whichever backend reads the line.
                print(f"warning: skipping entry {index} ({scheme}): {exc}", file=sys.stderr)
                break
            except Exception as exc:
                errors.append(f"{backend}: {exc}" if len(backends) > 1 else str(exc))
                continue

            seen_tags.add(tag)
            keep(backend, outbound)
            if links is not None:
                links[tag] = line
            break
        else:
            print(
                f"warning: skipping entry {index} ({scheme}): " + "; ".join(errors),
                file=sys.stderr,
            )


def parse_subscription(
    lines: list[str],
    tag_prefix: str,
    routing_mark: int | None,
    backend: str = "sing-box",
    links: dict[str, str] | None = None,
    allow_private: bool = False,
    allow_insecure: bool = False,
    tweaks: dict | None = None,
) -> list[dict]:
    """links, when given, collects tag -> the line it came from, to share it back."""
    if backend not in {"sing-box", "xray"}:
        raise ValueError(f"unsupported backend '{backend}'")
    outbounds: list[dict] = []
    _walk_subscription(
        lines,
        tag_prefix,
        routing_mark,
        [backend],
        links,
        lambda _, ob: outbounds.append(ob),
        allow_private,
        allow_insecure,
        tweaks,
    )
    return outbounds


def parse_hybrid_subscription(
    lines: list[str],
    tag_prefix: str,
    routing_mark: int | None = None,
    links: dict[str, str] | None = None,
    allow_private: bool = False,
    allow_insecure: bool = False,
    tweaks: dict | None = None,
) -> dict[str, list[dict]]:
    """Each line goes to whichever backend can dial it, sing-box first."""
    outbounds: dict[str, list[dict]] = {"singBox": [], "xray": []}
    _walk_subscription(
        lines,
        tag_prefix,
        routing_mark,
        ["sing-box", "xray"],
        links,
        lambda backend, ob: outbounds["singBox" if backend == "sing-box" else "xray"].append(ob),
        allow_private,
        allow_insecure,
        tweaks,
    )
    return outbounds


# --- JSON subscriptions -----------------------------------------------------------------
#
# Panels serve some clients JSON instead of links (Remnawave and Happ: an array of whole XRay
# configs, one per server), with what a link cannot say: XHTTP's extra, a fragment, mux. Taken
# as entries the same way links are: each one's servers checked, nothing that steers around
# this host's routing or reads its files, renamed after the subscription. Their routing and
# DNS are the panel's idea of a client, not this host's, and are left out.

XRAY_SYSTEM_PROTOCOLS = ("freedom", "blackhole", "dns", "loopback")
SING_BOX_SYSTEM_TYPES = ("direct", "block", "dns", "selector", "urltest")
# sing-box dial fields that would steer around this host's routing (detour, marks, an
# interface, a bind address) or name a DNS server this config does not have.
SING_BOX_DIAL_KEYS = (
    "detour", "bind_interface", "inet4_bind_address", "inet6_bind_address", "routing_mark",
    "reuse_addr", "netns", "domain_resolver", "network_strategy", "network_type", "fallback_network_type",
)


def _json_kind(outbound) -> "str | None":
    if not isinstance(outbound, dict):
        return None
    if isinstance(outbound.get("protocol"), str):
        return "xray"
    if isinstance(outbound.get("type"), str):
        return "sing-box"
    return None


def _xray_dialed_servers(outbound: dict) -> list:
    settings = outbound.get("settings") if isinstance(outbound.get("settings"), dict) else {}
    servers = [settings.get("address")]
    for group in ("vnext", "servers"):
        for server in settings.get(group) or []:
            if isinstance(server, dict):
                servers.append(server.get("address"))
    for peer in settings.get("peers") or []:
        if isinstance(peer, dict) and isinstance(peer.get("endpoint"), str):
            servers.append(peer["endpoint"].rsplit(":", 1)[0])
    stack = [outbound.get("streamSettings")]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            for key, value in item.items():
                if str(key).lower() == "address":
                    servers.append(value if isinstance(value, str) else str(value))
                elif str(key).lower() == "echconfiglist" and (ech := _ech_dns_server(value)):
                    servers.append(ech)
                stack.append(value)
        elif isinstance(item, list):
            stack.extend(item)
    return [s for s in servers if s is not None]


def _xray_insecure(outbound: dict) -> bool:
    stack = [outbound.get("streamSettings")]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            if item.get("allowInsecure") is True:
                return True
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)
    return False


def _xray_config_entries(config: dict) -> list[tuple[str, dict]]:
    """(remark, outbound) of a whole XRay config: its "proxy" outbound, or else its first that
    is not freedom, blackhole or dns. A fragment freedom it dials through comes along as
    `fragment` (_xray_tweaks' mark); a chain through anything else does not."""
    outbounds = [ob for ob in config.get("outbounds") or [] if isinstance(ob, dict)]
    proxies = [ob for ob in outbounds if ob.get("protocol") not in XRAY_SYSTEM_PROTOCOLS]
    main = next((ob for ob in proxies if ob.get("tag") == "proxy"), proxies[0] if proxies else None)
    if main is None:
        return []
    main = json.loads(json.dumps(main))
    sockopt = ((main.get("streamSettings") or {}).get("sockopt") or {}) if isinstance(main.get("streamSettings"), dict) else {}
    hop = sockopt.get("dialerProxy") if isinstance(sockopt, dict) else None
    if hop:
        through = next((ob for ob in outbounds if ob.get("tag") == hop), None)
        fragment = ((through or {}).get("settings") or {}).get("fragment") if through and through.get("protocol") == "freedom" else None
        if isinstance(fragment, dict):
            main["_fragment"] = {k: str(v) for k, v in fragment.items() if k in FRAGMENT_DEFAULTS}
        else:
            raise ValueError(f"it dials through another outbound ({hop}), which a subscription entry cannot bring")
    remark = config.get("remarks") if isinstance(config.get("remarks"), str) else ""
    return [(remark, main)]


def json_subscription_entries(data: bytes) -> "tuple[str, list] | None":
    """(kind, [(remark, outbound)]) of a JSON body: "xray" or "sing-box", from whole configs or
    an array of outbounds; None when the body is not JSON of either."""
    text = data.removeprefix(b"\xef\xbb\xbf").strip()
    if text[:1] not in (b"{", b"["):
        return None
    try:
        doc = json.loads(text)
    except ValueError:
        return None
    items = doc if isinstance(doc, list) else [doc]
    items = [item for item in items if isinstance(item, dict)]
    if not items:
        return None
    entries: list = []
    if all(isinstance(item.get("outbounds"), list) for item in items):
        kinds = {_json_kind(ob) for item in items for ob in item["outbounds"]} - {None}
        if len(kinds) != 1:
            return None
        kind = kinds.pop()
        for index, item in enumerate(items):
            if kind == "xray":
                try:
                    entries.extend(_xray_config_entries(item))
                except ValueError as exc:
                    print(f"warning: skipping config {index}: {exc}", file=sys.stderr)
            else:
                entries.extend((str(ob.get("tag") or ""), ob) for ob in item["outbounds"]
                               if ob.get("type") not in SING_BOX_SYSTEM_TYPES)
        return kind, entries
    kinds = {_json_kind(item) for item in items}
    if len(kinds) != 1 or None in kinds:
        return None
    kind = kinds.pop()
    for ob in items:
        if kind == "xray" and ob.get("protocol") not in XRAY_SYSTEM_PROTOCOLS:
            entries.append((str(ob.get("tag") or ""), ob))
        elif kind == "sing-box" and ob.get("type") not in SING_BOX_SYSTEM_TYPES:
            entries.append((str(ob.get("tag") or ""), ob))
    return kind, entries


def parse_json_subscription(
    found: tuple[str, list],
    tag_prefix: str,
    routing_mark: int | None,
    backend: str,
    allow_private: bool = False,
    allow_insecure: bool = False,
    tweaks: dict | None = None,
):
    """The entries json_subscription_entries found, for the backend: a list, or on hybrid
    {singBox, xray}. Ones the backend cannot run (XRay configs on sing-box) are reported and left."""
    kind, entries = found
    tweaks = checked_tweaks(tweaks)
    out_kind = "xray" if kind == "xray" else "singBox"
    if backend == "hybrid":
        result = {"singBox": [], "xray": []}
    elif (backend == "xray") != (kind == "xray"):
        print(
            f"warning: the subscription serves {'XRay' if kind == 'xray' else 'sing-box'} JSON, which the "
            f"{backend} backend cannot run; try another userAgent",
            file=sys.stderr,
        )
        return []
    else:
        result = []
    seen: set[str] = set()
    for index, (remark, outbound) in enumerate(entries):
        if len(seen) >= MAX_SUBSCRIPTION_ENTRIES:
            print(f"warning: subscription has more than {MAX_SUBSCRIPTION_ENTRIES} entries: the rest are left out", file=sys.stderr)
            break
        outbound = json.loads(json.dumps(outbound))
        name = outbound.get("protocol") or outbound.get("type")
        try:
            if keys := local_file_keys(outbound):
                raise ValueError(f"it names a local file or program ({', '.join(keys)})")
            if kind == "xray":
                fragment = outbound.pop("_fragment", None)
                outbound.pop("proxySettings", None)
                _strip_socket_keys(outbound.get("streamSettings"))
                servers = _xray_dialed_servers(outbound)
                insecure = _xray_insecure(outbound)
            else:
                fragment = None
                for key in SING_BOX_DIAL_KEYS:
                    outbound.pop(key, None)
                servers = _dialed_servers(outbound)
                insecure = isinstance(outbound.get("tls"), dict) and outbound["tls"].get("insecure") is True
            if not servers or not any(isinstance(s, str) and s for s in servers):
                raise ValueError("it names no server")
            for server in servers:
                check_server(server, allow_private)
            if insecure and not allow_insecure:
                raise ValueError("it turns certificate checks off (see allowInsecure)")
        except RefusedServer as exc:
            print(f"warning: skipping entry {index} ({name}): {exc}", file=sys.stderr)
            continue
        except ValueError as exc:
            print(f"warning: skipping entry {index} ({name}): {exc}", file=sys.stderr)
            continue
        tag = _unique_tag(make_tag(tag_prefix, remark, index), seen)
        seen.add(tag)
        outbound["tag"] = tag
        if kind == "xray":
            if routing_mark is not None:
                outbound.setdefault("streamSettings", {}).setdefault("sockopt", {})["mark"] = routing_mark
            _xray_tweaks(outbound, tweaks)
            # One the config itself carried, unless the subscription sets its own.
            if fragment and "_fragment" not in outbound:
                try:
                    outbound["_fragment"] = checked_tweaks({"fragment": fragment})["fragment"]
                except ValueError:
                    print(f"warning: entry {index}: its fragment settings are left out", file=sys.stderr)
        else:
            if routing_mark is not None:
                outbound["routing_mark"] = routing_mark
            _sing_box_tweaks(outbound, tweaks)
        if backend == "hybrid":
            result[out_kind].append(outbound)
        else:
            result.append(outbound)
    return result
