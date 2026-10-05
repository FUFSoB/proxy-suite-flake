#!/usr/bin/env python3

import base64
import ipaddress
import re
import socket
import sys
import urllib.parse
import urllib.request

from proxy_url_parsers import BACKEND_AWARE_PARSERS, PARSERS


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
            "encryption": "none",
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
    url: str, tag: str, routing_mark: int | None = None, backend: str = "sing-box"
) -> dict:
    if backend not in {"sing-box", "xray"}:
        raise ValueError(f"unsupported backend '{backend}'")

    return _finish_outbound(_parse_url(url, tag, backend), routing_mark, backend)


def _finish_outbound(outbound: dict, routing_mark: int | None, backend: str) -> dict:
    if backend == "xray":
        return render_xray_outbound(outbound, routing_mark)
    if routing_mark is not None:
        outbound["routing_mark"] = routing_mark
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


def fetch_raw(url: str) -> bytes:
    # urlopen also speaks file:, ftp: and data:. This runs as root over a URL that
    # reaches it from a group-writable spool, so only the two a subscription is
    # ever served over, redirects included.
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise FetchError("subscription URL must be http:// or https://")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "v2rayN/6.0"},
    )
    opener = urllib.request.build_opener(_HttpOnlyRedirects)
    with opener.open(request, timeout=30) as response:
        data = response.read(MAX_SUBSCRIPTION_BYTES + 1)
    if len(data) > MAX_SUBSCRIPTION_BYTES:
        raise FetchError(f"subscription is larger than {MAX_SUBSCRIPTION_BYTES} bytes")
    return data


def decode_subscription(data: bytes) -> list[str]:
    text = None
    # Line-wrapped and URL-safe base64 both occur; the lenient decoder would drop
    # "-" and "_" as junk instead of reading them as "+" and "/".
    stripped = b"".join(data.split()).translate(bytes.maketrans(b"-_", b"+/"))
    try:
        pad = b"=" * (-len(stripped) % 4)
        decoded = base64.b64decode(stripped + pad).decode("utf-8")
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
                outbound = _finish_outbound(outbound, routing_mark, backend)
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
    )
    return outbounds


def parse_hybrid_subscription(
    lines: list[str],
    tag_prefix: str,
    routing_mark: int | None = None,
    links: dict[str, str] | None = None,
    allow_private: bool = False,
    allow_insecure: bool = False,
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
    )
    return outbounds
