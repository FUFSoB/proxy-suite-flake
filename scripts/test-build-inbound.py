#!/usr/bin/env python3

import base64
import json
import os
import tempfile
import unittest
import urllib.parse

from proxy_inbound import build_inbounds, build_share_link, client_outbound, render_xray_inbound, subscription_token
from proxy_parsing import build_outbound


def listener(**overrides):
    """A listener spec with the same defaults the Nix option tree renders."""
    spec = {
        "tag": "test-in",
        "type": "vless",
        "port": 443,
        "sharePort": None,
        "listen": "::",
        "via": "direct",
        "users": [{"name": "", "uuid": "uuid-1", "uuidFile": None, "password": None, "passwordFile": None}],
        "flow": None,
        "method": "2022-blake3-aes-128-gcm",
        "transport": {
            "type": "raw",
            "path": "/",
            "host": None,
            "mode": None,
            "serviceName": "",
            "trustedXForwardedFor": [],
        },
        "tls": {"enable": False, "certificateFile": None, "keyFile": None, "serverName": None},
        "reality": {
            "enable": False,
            "dest": "www.microsoft.com:443",
            "serverNames": [],
            "privateKey": None,
            "privateKeyFile": None,
            "publicKey": None,
            "shortIds": [""],
        },
        "xrayJson": None,
        "jsonFile": None,
    }
    spec.update(overrides)
    return spec


def reality(**overrides):
    settings = {
        "enable": True,
        "dest": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": "private-key",
        "privateKeyFile": None,
        "publicKey": "public-key",
        "shortIds": ["0123abcd"],
    }
    settings.update(overrides)
    return settings


def multi_user_shadowsocks(**overrides):
    spec = {
        "type": "shadowsocks",
        "serverPassword": "server-psk",
        "serverPasswordFile": None,
        "users": [
            {"name": "a", "password": "psk-a", "passwordFile": None},
            {"name": "b", "password": "psk-b", "passwordFile": None},
        ],
    }
    spec.update(overrides)
    return listener(**spec)


def link_params(link: str) -> dict:
    query = urllib.parse.urlsplit(link).query
    return dict(urllib.parse.parse_qsl(query))


class RenderInboundTests(unittest.TestCase):
    def test_vless_reality_shape(self):
        ib = render_xray_inbound(listener(flow="xtls-rprx-vision", reality=reality()))
        self.assertEqual(ib["protocol"], "vless")
        self.assertEqual(ib["port"], 443)
        self.assertEqual(ib["listen"], "::")
        self.assertEqual(ib["settings"]["decryption"], "none")
        self.assertEqual(ib["settings"]["clients"][0]["id"], "uuid-1")
        self.assertEqual(ib["settings"]["clients"][0]["flow"], "xtls-rprx-vision")
        stream = ib["streamSettings"]
        self.assertEqual(stream["network"], "raw")
        self.assertEqual(stream["security"], "reality")
        self.assertEqual(stream["realitySettings"]["privateKey"], "private-key")
        self.assertEqual(stream["realitySettings"]["dest"], "www.microsoft.com:443")
        self.assertEqual(stream["realitySettings"]["shortIds"], ["0123abcd"])
        # The public key is a client-side concern; it must not leak into the server config.
        self.assertNotIn("publicKey", stream["realitySettings"])

    def test_sniffing_is_route_only(self):
        # Domain rules (blockRu) need sniffing, but a server must not rewrite
        # the destination its clients asked for.
        ib = render_xray_inbound(listener())
        self.assertTrue(ib["sniffing"]["enabled"])
        self.assertTrue(ib["sniffing"]["routeOnly"])

    def test_secrets_are_read_from_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            uuid_path = os.path.join(tmp, "uuid")
            key_path = os.path.join(tmp, "key")
            with open(uuid_path, "w", encoding="utf-8") as handle:
                handle.write("file-uuid\n")
            with open(key_path, "w", encoding="utf-8") as handle:
                handle.write("file-key\n")

            ib = render_xray_inbound(
                listener(
                    users=[{"name": "", "uuid": None, "uuidFile": uuid_path}],
                    reality=reality(privateKey=None, privateKeyFile=key_path),
                )
            )
        self.assertEqual(ib["settings"]["clients"][0]["id"], "file-uuid")
        self.assertEqual(ib["streamSettings"]["realitySettings"]["privateKey"], "file-key")

    def test_empty_secret_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            uuid_path = os.path.join(tmp, "uuid")
            with open(uuid_path, "w", encoding="utf-8") as handle:
                handle.write("\n")
            with self.assertRaisesRegex(ValueError, "is empty"):
                render_xray_inbound(listener(users=[{"uuid": None, "uuidFile": uuid_path}]))

    def test_ws_transport(self):
        ib = render_xray_inbound(
            listener(
                transport={"type": "ws", "path": "/download", "host": "cdn.example.com", "serviceName": ""},
                tls={
                    "enable": True,
                    "certificateFile": "/cert.pem",
                    "keyFile": "/key.pem",
                    "serverName": "cdn.example.com",
                },
            )
        )
        stream = ib["streamSettings"]
        self.assertEqual(stream["network"], "ws")
        self.assertEqual(stream["wsSettings"], {"path": "/download", "host": "cdn.example.com"})
        self.assertEqual(stream["security"], "tls")
        self.assertEqual(
            stream["tlsSettings"]["certificates"][0],
            {"certificateFile": "/cert.pem", "keyFile": "/key.pem"},
        )

    def test_trusted_x_forwarded_for_reaches_sockopt(self):
        """Without it XRay sees the web server's loopback address and records nobody online."""
        plain = {"type": "ws", "path": "/", "host": None, "serviceName": "", "trustedXForwardedFor": []}
        self.assertNotIn("sockopt", render_xray_inbound(listener(transport=plain))["streamSettings"])
        behind = dict(plain, trustedXForwardedFor=["X-Real-IP"])
        self.assertEqual(
            render_xray_inbound(listener(transport=behind))["streamSettings"]["sockopt"],
            {"trustedXForwardedFor": ["X-Real-IP"]},
        )

    def test_grpc_transport(self):
        ib = render_xray_inbound(
            listener(transport={"type": "grpc", "path": "/", "host": None, "serviceName": "GunService"})
        )
        self.assertEqual(ib["streamSettings"]["grpcSettings"], {"serviceName": "GunService"})

    def test_trojan_forces_tls(self):
        ib = render_xray_inbound(
            listener(
                type="trojan",
                users=[{"name": "", "password": "pw", "passwordFile": None}],
                tls={
                    "enable": False,
                    "certificateFile": "/cert.pem",
                    "keyFile": "/key.pem",
                    "serverName": None,
                },
            )
        )
        self.assertEqual(ib["settings"]["clients"][0]["password"], "pw")
        self.assertEqual(ib["streamSettings"]["security"], "tls")

    def test_shadowsocks_single_user_uses_password(self):
        ib = render_xray_inbound(
            listener(type="shadowsocks", users=[{"name": "", "password": "psk", "passwordFile": None}])
        )
        self.assertEqual(ib["settings"]["password"], "psk")
        self.assertEqual(ib["settings"]["method"], "2022-blake3-aes-128-gcm")
        self.assertEqual(ib["settings"]["network"], "tcp,udp")

    def test_shadowsocks_multi_user_has_server_key_and_clients(self):
        ib = render_xray_inbound(multi_user_shadowsocks())
        self.assertEqual(ib["settings"]["password"], "server-psk")
        self.assertEqual(
            ib["settings"]["clients"],
            [{"password": "psk-a", "email": "a"}, {"password": "psk-b", "email": "b"}],
        )

    def test_shadowsocks_multi_user_needs_server_key(self):
        with self.assertRaisesRegex(ValueError, "no server password"):
            render_xray_inbound(multi_user_shadowsocks(serverPassword=None))

    def test_socks_accounts_and_udp(self):
        ib = render_xray_inbound(
            listener(type="socks", users=[{"name": "me", "password": "pw", "passwordFile": None}])
        )
        self.assertEqual(ib["settings"]["accounts"], [{"user": "me", "pass": "pw"}])
        self.assertTrue(ib["settings"]["udp"])

    def test_unsupported_type_fails(self):
        with self.assertRaisesRegex(ValueError, "unsupported type"):
            render_xray_inbound(listener(type="tuic"))


class ShareLinkTests(unittest.TestCase):
    def test_vless_reality_link(self):
        link = build_share_link(
            listener(flow="xtls-rprx-vision", reality=reality()), "vpn.example.com"
        )
        self.assertTrue(link.startswith("vless://uuid-1@vpn.example.com:443?"))
        params = link_params(link)
        self.assertEqual(params["security"], "reality")
        self.assertEqual(params["pbk"], "public-key")
        self.assertEqual(params["sid"], "0123abcd")
        self.assertEqual(params["sni"], "www.microsoft.com")
        self.assertEqual(params["flow"], "xtls-rprx-vision")
        self.assertEqual(params["type"], "tcp")

    def test_reality_link_without_public_key_fails(self):
        with self.assertRaisesRegex(ValueError, "reality.publicKey is required"):
            build_share_link(listener(reality=reality(publicKey=None)), "vpn.example.com")

    def test_empty_short_id_is_omitted(self):
        link = build_share_link(listener(reality=reality(shortIds=[""])), "vpn.example.com")
        self.assertNotIn("sid=", link)

    def test_ipv6_server_address_is_bracketed(self):
        link = build_share_link(listener(reality=reality()), "2001:db8::1")
        self.assertIn("@[2001:db8::1]:443?", link)

    def test_label_becomes_fragment(self):
        spec = listener(reality=reality())
        spec["users"][0]["name"] = "my phone"
        link = build_share_link(spec, "vpn.example.com")
        self.assertTrue(link.endswith("#test-in%20%28my%20phone%29"))

    def test_multi_user_links_select_each_user(self):
        spec = listener(
            users=[
                {"name": "phone", "uuid": "uuid-phone", "password": None, "passwordFile": None},
                {"name": "laptop", "uuid": "uuid-laptop", "password": None, "passwordFile": None},
            ]
        )
        phone = build_share_link(spec, "vpn.example.com", 0)
        laptop = build_share_link(spec, "vpn.example.com", 1)
        self.assertTrue(phone.startswith("vless://uuid-phone@"))
        self.assertTrue(laptop.startswith("vless://uuid-laptop@"))
        self.assertTrue(phone.endswith("#test-in%20%28phone%29"))
        self.assertTrue(laptop.endswith("#test-in%20%28laptop%29"))

    def test_multi_user_password_links_select_each_account(self):
        spec = listener(
            type="socks",
            users=[
                {"name": "phone", "password": "pw-phone", "uuid": None, "uuidFile": None},
                {"name": "laptop", "password": "pw-laptop", "uuid": None, "uuidFile": None},
            ],
        )
        link = build_share_link(spec, "vpn.example.com", 1)
        userinfo = link[len("socks://") :].split("@", 1)[0]
        decoded = base64.urlsafe_b64decode(userinfo + "=" * (-len(userinfo) % 4)).decode()
        self.assertEqual(decoded, "laptop:pw-laptop")

    def test_vmess_link_blob(self):
        spec = listener(
            type="vmess",
            transport={"type": "ws", "path": "/v", "host": "cdn.example.com", "serviceName": ""},
            tls={"enable": True, "certificateFile": "/c", "keyFile": "/k", "serverName": "cdn.example.com"},
        )
        link = build_share_link(spec, "vpn.example.com")
        self.assertTrue(link.startswith("vmess://"))
        payload = link[len("vmess://") :]
        payload += "=" * (-len(payload) % 4)
        blob = json.loads(base64.urlsafe_b64decode(payload))
        self.assertEqual(blob["add"], "vpn.example.com")
        self.assertEqual(blob["id"], "uuid-1")
        self.assertEqual(blob["net"], "ws")
        self.assertEqual(blob["tls"], "tls")

    def test_vmess_link_names_raw_tcp_and_grpc_service(self):
        def blob(transport):
            payload = build_share_link(listener(type="vmess", transport=transport), "vpn.example.com")[len("vmess://") :]
            return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))

        self.assertEqual(blob({"type": "raw", "path": "/", "host": None, "serviceName": ""})["net"], "tcp")
        self.assertEqual(blob({"type": "grpc", "path": "/", "host": None, "serviceName": "Gun"})["path"], "Gun")

    def test_shadowsocks_link_is_sip002(self):
        spec = listener(
            type="shadowsocks", method="aes-128-gcm", users=[{"name": "", "password": "psk", "passwordFile": None}]
        )
        link = build_share_link(spec, "vpn.example.com")
        userinfo = link[len("ss://") :].split("@", 1)[0]
        userinfo += "=" * (-len(userinfo) % 4)
        decoded = base64.urlsafe_b64decode(userinfo).decode()
        self.assertEqual(decoded, "aes-128-gcm:psk")

    def test_shadowsocks_2022_link_is_percent_encoded(self):
        link = build_share_link(multi_user_shadowsocks(serverPassword="a+b/c="), "vpn.example.com")
        self.assertTrue(link.startswith("ss://2022-blake3-aes-128-gcm:a%2Bb%2Fc%3D%3Apsk-a@"), link)


    def test_http_link_over_tls_is_https(self):
        spec = listener(
            type="http",
            users=[{"name": "me", "password": "pw", "passwordFile": None}],
            tls={"enable": True, "certificateFile": "/c", "keyFile": "/k", "serverName": None},
        )
        self.assertTrue(build_share_link(spec, "vpn.example.com").startswith("https://me:pw@"))

    def test_raw_json_port_must_match_the_listener(self):
        from proxy_inbound import build_listener

        raw = listener(type=None, xrayJson={"protocol": "dokodemo-door"})
        self.assertEqual(build_listener(raw, "", False)["inbound"]["port"], 443)
        with self.assertRaisesRegex(ValueError, "port 8080, but port is 443"):
            build_listener(listener(type=None, xrayJson={"protocol": "dokodemo-door", "port": 8080}), "", False)


class RoundTripTests(unittest.TestCase):
    """A generated link must parse back into a working outbound.

    This is what makes the links usable, including by proxy-suite itself as a
    client, so the two halves are pinned against each other here.
    """

    def test_vless_reality_round_trip(self):
        link = build_share_link(
            listener(flow="xtls-rprx-vision", reality=reality()), "vpn.example.com"
        )
        ob = build_outbound(link, "round-trip", backend="xray")
        self.assertEqual(ob["protocol"], "vless")
        settings = ob["settings"]
        self.assertEqual(settings["address"], "vpn.example.com")
        self.assertEqual(settings["port"], 443)
        self.assertEqual(settings["id"], "uuid-1")
        self.assertEqual(settings["flow"], "xtls-rprx-vision")
        rs = ob["streamSettings"]["realitySettings"]
        self.assertEqual(rs["publicKey"], "public-key")
        self.assertEqual(rs["shortId"], "0123abcd")
        self.assertEqual(rs["serverName"], "www.microsoft.com")

    def test_vless_ws_tls_round_trip(self):
        link = build_share_link(
            listener(
                transport={"type": "ws", "path": "/download", "host": "cdn.example.com", "serviceName": ""},
                tls={
                    "enable": True,
                    "certificateFile": "/c",
                    "keyFile": "/k",
                    "serverName": "cdn.example.com",
                },
            ),
            "vpn.example.com",
        )
        ob = build_outbound(link, "round-trip", backend="sing-box")
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["transport"]["type"], "ws")
        self.assertEqual(ob["transport"]["path"], "/download")
        self.assertEqual(ob["tls"]["server_name"], "cdn.example.com")

    def test_hysteria2_round_trip(self):
        spec = listener(
            type="hysteria2",
            port=8443,
            users=[{"name": "phone", "password": "p@ss/word", "passwordFile": None}],
            tls={"enable": True, "certificateFile": "/c", "keyFile": "/k", "serverName": "hy.example.com"},
            hysteria={"masquerade": "https://www.example.com"},
        )
        ib = render_xray_inbound(spec)
        self.assertEqual(ib["protocol"], "hysteria")
        self.assertEqual(ib["settings"], {"version": 2, "clients": [{"auth": "p@ss/word", "email": "phone"}]})
        stream = ib["streamSettings"]
        self.assertEqual(stream["network"], "hysteria")
        self.assertEqual(stream["security"], "tls")
        self.assertEqual(stream["tlsSettings"]["alpn"], ["h3"])
        self.assertEqual(stream["hysteriaSettings"]["masquerade"]["url"], "https://www.example.com")
        link = build_share_link(spec, "vpn.example.com")
        self.assertTrue(link.startswith("hysteria2://p%40ss%2Fword@vpn.example.com:8443?"), link)
        self.assertEqual(link_params(link)["alpn"], "h3")
        ob = build_outbound(link, "round-trip", backend="sing-box")
        self.assertEqual(ob["type"], "hysteria2")
        self.assertEqual(ob["password"], "p@ss/word")
        self.assertEqual(ob["server_port"], 8443)
        self.assertEqual(ob["tls"]["server_name"], "hy.example.com")
        # Without masquerade XRay answers non-clients with 404; nothing to render.
        plain = render_xray_inbound(dict(spec, hysteria={"masquerade": None}))
        self.assertEqual(plain["streamSettings"]["hysteriaSettings"], {"version": 2})

    def test_trojan_round_trip(self):
        link = build_share_link(
            listener(
                type="trojan",
                users=[{"name": "", "password": "pw", "passwordFile": None}],
                tls={"enable": False, "certificateFile": "/c", "keyFile": "/k", "serverName": None},
            ),
            "vpn.example.com",
        )
        ob = build_outbound(link, "round-trip", backend="sing-box")
        self.assertEqual(ob["type"], "trojan")
        self.assertEqual(ob["password"], "pw")

    def test_shadowsocks_round_trip(self):
        link = build_share_link(
            listener(type="shadowsocks", users=[{"name": "", "password": "psk", "passwordFile": None}]),
            "vpn.example.com",
        )
        ob = build_outbound(link, "round-trip", backend="sing-box")
        self.assertEqual(ob["type"], "shadowsocks")
        self.assertEqual(ob["method"], "2022-blake3-aes-128-gcm")
        self.assertEqual(ob["password"], "psk")

    def test_shadowsocks_multi_user_round_trip(self):
        link = build_share_link(multi_user_shadowsocks(), "vpn.example.com", 1)
        ob = build_outbound(link, "round-trip", backend="sing-box")
        self.assertEqual(ob["password"], "server-psk:psk-b")

    def test_vmess_round_trip(self):
        link = build_share_link(listener(type="vmess"), "vpn.example.com")
        ob = build_outbound(link, "round-trip", backend="sing-box")
        self.assertEqual(ob["type"], "vmess")
        self.assertEqual(ob["uuid"], "uuid-1")


class BuildInboundsTests(unittest.TestCase):
    def test_spec_renders_inbounds_and_links(self):
        spec = {
            "serverAddress": "vpn.example.com",
            "shareLinks": True,
            "listeners": [
                listener(tag="a", reality=reality()),
                listener(tag="b", port=8443, type="socks", users=[{"name": "u", "password": "p"}]),
            ],
        }
        result = build_inbounds(spec, "vpn.example.com")
        self.assertEqual([ib["tag"] for ib in result["inbounds"]], ["a", "b"])
        self.assertEqual([entry["tag"] for entry in result["links"]], ["a", "b"])
        self.assertEqual(result["links"][1]["port"], 8443)
        self.assertEqual(result["links"][0]["outbound"]["type"], "vless")
        # v2rayN's socks:// is a link, but not one the outbound parsers take.
        self.assertIsNone(result["links"][1]["outbound"])

    def test_client_outbound_falls_back_to_xray(self):
        link = build_share_link(
            listener(transport={"type": "xhttp", "path": "/p", "host": None, "mode": "auto", "serviceName": ""}),
            "vpn.example.com",
        )
        self.assertEqual(client_outbound(link, "x")["protocol"], "vless")

    def test_xhttp_mode_reaches_the_inbound_and_the_link(self):
        spec = listener(
            transport={"type": "xhttp", "path": "/p", "host": None, "mode": "packet-up", "serviceName": ""}
        )
        stream = render_xray_inbound(spec)["streamSettings"]
        self.assertEqual(stream["xhttpSettings"]["mode"], "packet-up")
        # Without it in the link the client picks a mode on its own, which is
        # what breaks XHTTP behind an HTTP/1.1 reverse proxy.
        self.assertEqual(link_params(build_share_link(spec, "vpn.example.com"))["mode"], "packet-up")

    def test_alpn_reaches_the_inbound_and_the_link(self):
        spec = listener(
            transport={"type": "xhttp", "path": "/h3", "host": None, "mode": None, "serviceName": ""},
            tls={"enable": True, "certificateFile": "/c", "keyFile": "/k", "serverName": None, "alpn": ["h3"]},
        )
        # h3 alone is what makes XRay serve the listener as HTTP/3, on UDP.
        self.assertEqual(render_xray_inbound(spec)["streamSettings"]["tlsSettings"]["alpn"], ["h3"])
        # A client left to its own ALPN offers h2 and http/1.1 and never gets in.
        self.assertEqual(link_params(build_share_link(spec, "vpn.example.com"))["alpn"], "h3")
        plain = listener(tls={"enable": True, "certificateFile": "/c", "keyFile": "/k", "serverName": None})
        self.assertNotIn("alpn", render_xray_inbound(plain)["streamSettings"]["tlsSettings"])
        self.assertNotIn("alpn", link_params(build_share_link(plain, "vpn.example.com")))

    def test_subscriptions_gather_each_users_links(self):
        def users(uuid_a):
            return [
                {"name": "fufsob", "uuid": uuid_a, "password": None, "passwordFile": None},
                {"name": "teri", "uuid": "uuid-teri", "password": None, "passwordFile": None},
            ]

        def spec(uuid_a="uuid-fufsob", share=True):
            return {
                "serverAddress": "vpn.example.com",
                "shareLinks": share,
                "listeners": [
                    listener(tag="ws", users=users(uuid_a)),
                    listener(tag="h3", port=8443, users=users(uuid_a)),
                ],
            }

        result = build_inbounds(spec(), "vpn.example.com")
        subs = {s["user"]: s for s in result["subscriptions"]}
        self.assertEqual(sorted(subs), ["fufsob", "teri"])
        # Every listener's link for that user, as clients import them.
        body = base64.b64decode(subs["fufsob"]["body"]).decode()
        self.assertEqual(
            body.split("\n"),
            [entry["link"] for entry in result["links"] if entry["user"] == "fufsob"],
        )
        self.assertEqual(len(body.split("\n")), 2)
        # Stable while the credentials are, rotated with them, never shared.
        token = subs["fufsob"]["token"]
        self.assertRegex(token, "^[0-9a-f]{32}$")
        self.assertEqual(token, subscription_token("fufsob", ["uuid-fufsob"]))
        self.assertNotEqual(token, subs["teri"]["token"])
        rotated = build_inbounds(spec(uuid_a="uuid-new"), "vpn.example.com")["subscriptions"]
        self.assertNotEqual(token, next(s["token"] for s in rotated if s["user"] == "fufsob"))
        # No links, nothing to subscribe to.
        self.assertEqual(build_inbounds(spec(share=False), "vpn.example.com")["subscriptions"], [])

    def test_share_port_overrides_the_bound_port(self):
        spec = {
            "serverAddress": "vpn.example.com",
            "shareLinks": True,
            "listeners": [
                listener(
                    port=10002,
                    sharePort=443,
                    listen="127.0.0.1",
                    tls={"enable": True, "certificateFile": "/c", "keyFile": "/k", "serverName": None},
                    transport={"type": "ws", "path": "/vpnjantit", "host": None, "serviceName": ""},
                )
            ],
        }
        result = build_inbounds(spec, "vpn.example.com")
        # The listener still binds where it was told to; only the link moves.
        self.assertEqual(result["inbounds"][0]["port"], 10002)
        self.assertEqual(result["links"][0]["port"], 443)
        link = result["links"][0]["link"]
        self.assertTrue(link.startswith("vless://uuid-1@vpn.example.com:443?"), link)
        self.assertEqual(link_params(link)["path"], "/vpnjantit")

    def test_spec_emits_one_link_per_user(self):
        spec = {
            "serverAddress": "vpn.example.com",
            "shareLinks": True,
            "listeners": [
                listener(
                    users=[
                        {"name": "phone", "uuid": "uuid-phone", "password": None, "passwordFile": None},
                        {"name": "laptop", "uuid": "uuid-laptop", "password": None, "passwordFile": None},
                    ]
                )
            ],
        }
        result = build_inbounds(spec, "vpn.example.com")
        self.assertEqual([entry["user"] for entry in result["links"]], ["phone", "laptop"])
        self.assertTrue(result["links"][1]["link"].startswith("vless://uuid-laptop@"))

    def test_share_links_disabled_emits_no_links(self):
        spec = {
            "serverAddress": "vpn.example.com",
            "shareLinks": False,
            "listeners": [listener(reality=reality(publicKey=None))],
        }
        result = build_inbounds(spec, "vpn.example.com")
        self.assertEqual(result["links"], [])
        self.assertEqual(len(result["inbounds"]), 1)

    def test_raw_json_listener_passes_through_with_tag(self):
        spec = {
            "serverAddress": "vpn.example.com",
            "shareLinks": True,
            "listeners": [
                listener(
                    tag="raw",
                    type=None,
                    port=8080,
                    xrayJson={"protocol": "dokodemo-door", "tag": "ignored", "port": 8080},
                )
            ],
        }
        result = build_inbounds(spec, "vpn.example.com")
        self.assertEqual(result["inbounds"][0]["protocol"], "dokodemo-door")
        self.assertEqual(result["inbounds"][0]["tag"], "raw")
        self.assertEqual(result["links"], [])

    def test_json_file_listener_is_read_at_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "inbound.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"protocol": "vless", "port": 2053, "settings": {"clients": []}}, handle)
            spec = {
                "serverAddress": "vpn.example.com",
                "shareLinks": True,
                "listeners": [listener(tag="secret-in", type=None, port=2053, jsonFile=path)],
            }
            result = build_inbounds(spec, "vpn.example.com")
        self.assertEqual(result["inbounds"][0]["tag"], "secret-in")
        self.assertEqual(result["inbounds"][0]["port"], 2053)
        self.assertEqual(result["links"], [])

    def test_onion_links_dial_the_onion_and_keep_the_names(self):
        onion = "abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
        tls = {"enable": True, "certificateFile": "/c", "keyFile": "/k", "serverName": None}
        users = [{"name": "alice", "uuid": "uuid-1", "uuidFile": None, "password": None, "passwordFile": None}]
        spec = {
            "serverAddress": "vpn.example.com",
            "shareLinks": True,
            "onionListeners": ["reality", "ws", "vmess"],
            "listeners": [
                listener(tag="reality", users=users, reality=reality()),
                listener(
                    tag="ws",
                    users=users,
                    port=10002,
                    sharePort=443,
                    tls=tls,
                    transport={"type": "ws", "path": "/ws", "host": "cdn.example.com", "serviceName": ""},
                ),
                listener(tag="vmess", type="vmess", users=users, port=8443, tls=tls),
                listener(tag="plain", users=users, port=8080),
            ],
        }
        result = build_inbounds(spec, "vpn.example.com", onion)
        by_variant = {(e["tag"], e.get("variant", "")): e for e in result["links"]}
        self.assertEqual(
            sorted(by_variant),
            sorted(
                [
                    ("reality", ""),
                    ("reality", "onion"),
                    ("ws", ""),
                    ("ws", "onion"),
                    ("vmess", ""),
                    ("vmess", "onion"),
                    ("plain", ""),
                ]
            ),
        )

        real = by_variant[("reality", "onion")]["link"]
        self.assertTrue(real.startswith(f"vless://uuid-1@{onion}:443?"), real)
        self.assertEqual(link_params(real)["sni"], "www.microsoft.com")
        self.assertIn("onion", urllib.parse.unquote(urllib.parse.urlsplit(real).fragment))

        # The onion port is the share port, as the torrc maps it; TLS keeps the real name.
        ws = by_variant[("ws", "onion")]
        self.assertEqual(ws["port"], 443)
        self.assertTrue(ws["link"].startswith(f"vless://uuid-1@{onion}:443?"), ws["link"])
        self.assertEqual(link_params(ws["link"])["sni"], "vpn.example.com")
        self.assertEqual(link_params(ws["link"])["host"], "cdn.example.com")
        self.assertEqual(ws["outbound"]["server"], onion)

        payload = by_variant[("vmess", "onion")]["link"][len("vmess://") :]
        blob = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        self.assertEqual(blob["add"], onion)
        self.assertEqual(blob["sni"], "vpn.example.com")

        # The plain links are untouched, and a subscription carries both.
        self.assertTrue(by_variant[("reality", "")]["link"].startswith("vless://uuid-1@vpn.example.com:443?"))
        body = base64.b64decode(result["subscriptions"][0]["body"]).decode().split("\n")
        self.assertEqual(len(body), 7)
        self.assertIn(real, body)

        # No address yet: no onion links, and nothing else changes.
        without = build_inbounds(spec, "vpn.example.com")
        self.assertEqual([e for e in without["links"] if e.get("variant")], [])
        self.assertEqual(without["inbounds"], result["inbounds"])


if __name__ == "__main__":
    unittest.main()
