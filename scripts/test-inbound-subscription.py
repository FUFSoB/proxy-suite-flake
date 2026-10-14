#!/usr/bin/env python3

import base64
import json
import os
import re
import subprocess
import tempfile
import unittest

import inbound_subscription as sub
import proxy_inbound

UUID = "11111111-2222-3333-4444-555555555555"
LINKS = {
    "reality": f"vless://{UUID}@vpn.example.com:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome"
               "&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=0123abcd&flow=xtls-rprx-vision#reality",
    "ws": f"vless://{UUID}@vpn.example.com:443?type=ws&security=tls&sni=vpn.example.com&path=%2Fws"
          "&host=vpn.example.com&fp=chrome&alpn=h2%2Chttp%2F1.1#ws",
    "grpc": f"vless://{UUID}@vpn.example.com:443?type=grpc&security=tls&sni=vpn.example.com&serviceName=gs#grpc",
    "xhttp": f"vless://{UUID}@vpn.example.com:443?type=xhttp&security=tls&sni=vpn.example.com&path=%2Fx#xh",
    "trojan": "trojan://pass@vpn.example.com:8443?security=tls&sni=vpn.example.com&type=httpupgrade&path=%2Fhu#tr",
    "hy2": "hysteria2://pw@vpn.example.com:443?sni=vpn.example.com&obfs=salamander&obfs-password=xx&mport=20000-20010#hy2",
}


def rendered_for(user="alice"):
    links = [{"tag": tag, "user": user, "link": link, "outbound": proxy_inbound.client_outbound(link, tag)}
             for tag, link in LINKS.items()]
    links.append({"tag": "reality", "user": user, "link": LINKS["reality"], "variant": "onion",
                  "outbound": proxy_inbound.client_outbound(LINKS["reality"], "reality")})
    links.append({"tag": "awg", "user": user, "link": "vpn://x", "config": "[Interface]", "outbound": None})
    links.append({"tag": "ws", "user": "bob", "link": LINKS["ws"], "outbound": None})
    body = base64.b64encode("\n".join(LINKS.values()).encode()).decode()
    return {"links": links, "subscriptions": [{"user": user, "token": "a" * 32, "body": body}]}


ROW = {"name": "alice", "active": True, "reasons": [], "onHold": False, "expiresAt": 2_000_000_000,
       "policy": {"expiresAfter": None},
       "traffic": {"up": 1, "down": 1023, "used": 1024, "limit": 4096, "periodEnd": 1_900_000_000}}


class Formats(unittest.TestCase):
    def test_pick_by_client(self):
        cases = {
            "ClashMetaForAndroid/2.11.2.Meta": "clash",
            "clash-verge/v2.0.0": "clash",
            "FlClash/v0.8": "clash",
            "mihomo/1.19": "clash",
            "Stash/2.4.6 Clash/1.9.0": "clash",
            "SFA/1.11.4 (Android 14; sing-box 1.11.4)": "sing-box",
            "SFI/1.12.0": "sing-box",
            "sing-box 1.12.0": "sing-box",
            # Hiddify names Clash and sing-box after "like": the links serve it best.
            "HiddifyNext/2.5.7 (android) like ClashMeta v2ray sing-box": "base64",
            "v2rayNG/1.9.1": "base64",
            "Happ/1.0": "base64",
            "": "base64",
        }
        for agent, expected in cases.items():
            self.assertEqual(sub.pick_format(None, agent, "*/*"), expected, agent)
        browser = "Mozilla/5.0 (X11; Linux x86_64) Firefox/131.0"
        self.assertEqual(sub.pick_format(None, browser, "text/html,application/xhtml+xml"), "html")
        # A client that says Mozilla but wants no page.
        self.assertEqual(sub.pick_format(None, browser, "*/*"), "base64")
        self.assertEqual(sub.pick_format("clash", "v2rayNG/1.9", ""), "clash")
        self.assertEqual(sub.pick_format("nonsense", "v2rayNG/1.9", ""), "base64")

    def test_entries_are_the_users_links_named_apart(self):
        names = [e["name"] for e in sub.entries(rendered_for(), "alice")]
        self.assertEqual(names, ["reality", "ws", "grpc", "xhttp", "trojan", "hy2", "reality-onion"])

    def test_names_stay_clear_of_the_groups(self):
        rendered = {"links": [{"tag": tag, "user": "u", "link": LINKS["ws"], "outbound": None}
                              for tag in ("proxy", "AUTO", "direct", "proxy")]}
        self.assertEqual([e["name"] for e in sub.entries(rendered, "u")], ["proxy-2", "AUTO-2", "direct-2", "proxy-3"])

    def test_sing_box_config(self):
        config = sub.sing_box_config(sub.entries(rendered_for(), "alice"))
        tags = [o["tag"] for o in config["outbounds"]]
        # XHTTP only XRay dials: left out of the config.
        self.assertNotIn("xhttp", tags)
        self.assertEqual(tags[:2], ["proxy", "auto"])
        self.assertEqual(config["outbounds"][0]["outbounds"][0], "auto")
        self.assertIn("reality-onion", config["outbounds"][1]["outbounds"])
        self.assertEqual(config["route"]["final"], "proxy")
        empty = sub.sing_box_config([])
        self.assertEqual(empty["route"]["final"], "direct")
        self.assertEqual([o["tag"] for o in empty["outbounds"]], ["direct"])
        sing_box = os.environ.get("SING_BOX")
        if sing_box:
            for value in (config, empty):
                with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
                    json.dump(value, handle)
                    handle.flush()
                    done = subprocess.run([sing_box, "check", "-c", handle.name], capture_output=True, text=True)
                    self.assertEqual(done.returncode, 0, done.stderr)

    def test_clash_proxies(self):
        config = sub.clash_config(sub.entries(rendered_for(), "alice"))
        proxies = {p["name"]: p for p in config["proxies"]}
        self.assertNotIn("xhttp", proxies)
        reality = proxies["reality"]
        self.assertEqual((reality["type"], reality["server"], reality["port"], reality["uuid"]),
                         ("vless", "vpn.example.com", 443, UUID))
        self.assertEqual(reality["flow"], "xtls-rprx-vision")
        self.assertEqual(reality["servername"], "www.microsoft.com")
        self.assertEqual(reality["reality-opts"], {"public-key": "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0",
                                                   "short-id": "0123abcd"})
        self.assertEqual(reality["client-fingerprint"], "chrome")
        self.assertEqual(reality["network"], "tcp")
        self.assertEqual(proxies["ws"]["ws-opts"], {"path": "/ws", "headers": {"Host": "vpn.example.com"}})
        self.assertEqual(proxies["ws"]["alpn"], ["h2", "http/1.1"])
        self.assertEqual(proxies["grpc"]["grpc-opts"], {"grpc-service-name": "gs"})
        trojan = proxies["trojan"]
        self.assertEqual((trojan["type"], trojan["sni"], trojan["network"]), ("trojan", "vpn.example.com", "ws"))
        self.assertTrue(trojan["ws-opts"]["v2ray-http-upgrade"])
        hy2 = proxies["hy2"]
        self.assertEqual((hy2["type"], hy2["obfs"], hy2["obfs-password"], hy2["ports"]),
                         ("hysteria2", "salamander", "xx", "20000-20010"))
        groups = {g["name"]: g for g in config["proxy-groups"]}
        self.assertEqual(groups["PROXY"]["proxies"][0], "auto")
        self.assertEqual(config["rules"][-1], "MATCH,PROXY")
        self.assertEqual(sub.clash_proxy("x", {"type": "shadowsocks", "method": "aes-128-gcm", "password": "p",
                                               "server": "h", "server_port": 1, "plugin": "obfs-local"}), None)
        self.assertEqual(sub.clash_proxy("x", {"type": "shadowsocks", "method": "aes-128-gcm", "password": "p",
                                               "server": "h", "server_port": 1})["cipher"], "aes-128-gcm")

    def test_render(self):
        rendered = rendered_for()
        body_b64 = rendered["subscriptions"][0]["body"]
        args = (rendered, "alice", body_b64, ROW, "https://vpn.example.com/sub/" + "a" * 32, "VPN alice", {})
        body, kind = sub.render("base64", *args)
        self.assertEqual((body, kind), (body_b64.encode(), "text/plain; charset=utf-8"))
        body, _ = sub.render("links", *args)
        self.assertEqual(body.decode().split("\n")[0], LINKS["reality"])
        body, kind = sub.render("clash", *args)
        self.assertEqual(kind, "text/yaml; charset=utf-8")
        self.assertIn("proxies", json.loads(body))
        body, kind = sub.render("sing-box", *args)
        self.assertEqual(json.loads(body)["route"]["final"], "proxy")

    def test_page(self):
        rendered = rendered_for()
        url = "https://vpn.example.com/sub/" + "a" * 32
        row = {**ROW, "name": "<b>alice</b>"}
        page = sub.html_page(row, sub.entries(rendered, "alice"), url, "VPN <b>", {"supportUrl": "https://t.me/x"}, "en")
        self.assertIn("VPN &lt;b&gt;", page)
        self.assertNotIn("<b>", page)
        self.assertIn("User: &lt;b&gt;alice&lt;/b&gt;", page)
        # Named in the title already: not again.
        self.assertNotIn("Пользователь", sub.html_page(ROW, [], url, "VPN alice", {}, "ru"))
        self.assertIn("Пользователь: alice", sub.html_page(ROW, [], url, "Stage", {}, "ru"))
        self.assertIn("Active", page)
        self.assertIn("1.0 KiB of 4.0 KiB", page)
        self.assertIn('<rect class="fill" width="25"', page)
        self.assertIn(f'data-qr="{url}"', page)
        self.assertIn("happ://add/" + url, page)
        self.assertIn("v2rayng://install-config?url=https%3A%2F%2Fvpn.example.com", page)
        self.assertIn("https://t.me/x", page)
        # Share links are attributes, escaped: & stays &amp;.
        self.assertIn("type=tcp&amp;security=reality", page)
        held = sub.html_page({**ROW, "onHold": True, "expiresAt": None, "policy": {"expiresAfter": 30 * 86400}},
                             [], url, "VPN", {}, "ru")
        self.assertIn("Начнётся с первого подключения", held)
        self.assertIn("30d с первого подключения", held)
        off = sub.html_page({**ROW, "active": False, "reasons": ["expired", "traffic"]}, [], url, "VPN", {}, "en")
        self.assertIn("expired, out of traffic", off)
        self.assertEqual(sub.language("ru-RU,ru;q=0.9,en;q=0.8"), "ru")
        self.assertEqual(sub.language("de-DE,en;q=0.5"), "en")
        self.assertEqual(sub.language(""), "en")

    def test_apps_for_the_system(self):
        url = "https://vpn.example.com/sub/" + "a" * 32
        agents = {
            "android": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36",
            "ios": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            "macos": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15",
            "windows": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36",
            "linux": "Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0",
        }
        for system, agent in agents.items():
            self.assertEqual(sub.platform(agent), system)
        self.assertEqual(sub.platform("Mozilla/5.0 (X11; CrOS x86_64 15917.0.0) Chrome/130.0"), "android")
        self.assertIsNone(sub.platform(""))

        def shown(agent):
            """(labels up front, labels folded away) on the page for this browser."""
            page = sub.html_page(ROW, [], url, "VPN", {}, "en", user_agent=agent)
            apps = page.split("Add to an app</h2>", 1)[1].split("</div>", 1)[0]
            first, _, folded = apps.partition("<details>")
            label = lambda part: re.findall(r'<a class="app" href="[^"]*">([^<]*)</a>', part)
            return label(first), label(folded)

        first, folded = shown(agents["android"])
        self.assertIn("v2rayNG", first)
        self.assertIn("Streisand", folded)
        self.assertNotIn("Proxy Suite", first)
        first, folded = shown(agents["linux"])
        self.assertEqual(first, ["Happ", "Hiddify", "Clash / mihomo", "Proxy Suite"])
        self.assertIn("v2rayNG", folded)
        # Nothing said: every app, none folded away.
        first, folded = shown("")
        self.assertEqual((len(first), folded), (len(sub.APPS), []))
        self.assertIn('proxy-suite://install-config?url=https%3A%2F%2Fvpn.example.com%2Fsub%2F' + "a" * 32 + "&amp;name=VPN",
                      sub.html_page(ROW, [], url, "VPN", {}, "ru", user_agent=agents["linux"]))
        self.assertIn("Другие приложения", sub.html_page(ROW, [], url, "VPN", {}, "ru", user_agent=agents["linux"]))

    def test_page_policy(self):
        """The CSP lets the page's own script and stylesheet run, by their hashes, and nothing
        else: no style attribute, no other script or stylesheet."""
        page = sub.html_page({**ROW, "active": False, "reasons": ["expired"]},
                             sub.entries(rendered_for(), "alice"), "https://vpn.example.com/sub/x", "VPN", {}, "en")
        csp = dict(part.strip().split(" ", 1) for part in sub.PAGE_HEADERS["Content-Security-Policy"].split(";"))
        scripts = re.findall(r"<script>(.*?)</script>", page, re.S)
        styles = re.findall(r"<style>(.*?)</style>", page, re.S)
        self.assertEqual((len(scripts), len(styles)), (1, 1))
        self.assertEqual(csp["script-src"], sub._csp_hash(scripts[0]))
        self.assertEqual(csp["style-src"], sub._csp_hash(styles[0]))
        self.assertEqual(csp["default-src"], "'none'")
        self.assertNotIn("unsafe", sub.PAGE_HEADERS["Content-Security-Policy"])
        self.assertNotIn(" style=", page)
        self.assertEqual(page.count("<script"), 1)

    def test_qr_code(self):
        """The browser's QR encoder, run by node, read back by zbar: each length up to version
        40, multibyte text, and every mask."""
        node, zbarimg = os.environ.get("NODE"), os.environ.get("ZBARIMG")
        if not (node and zbarimg):
            self.skipTest("needs NODE and ZBARIMG")
        driver = """
const fs = require('fs');
const [source, text, mask, out] = process.argv.slice(2);
let code = fs.readFileSync(source, 'utf8');
if (mask !== '') code = code.replace('flip(best);format(best);return m', `flip(${mask});format(${mask});return m`);
const qrMatrix = new Function(code + ';return qrMatrix')();
const m = qrMatrix(text), quiet = 4, scale = 3, n = (m.length + 2 * quiet) * scale;
const rows = [];
for (let y = 0; y < n; y++) {
  const row = [];
  for (let x = 0; x < n; x++) {
    const my = Math.floor(y / scale) - quiet, mx = Math.floor(x / scale) - quiet;
    row.push(my >= 0 && mx >= 0 && my < m.length && mx < m.length && m[my][mx] ? 1 : 0);
  }
  rows.push(row.join(' '));
}
fs.writeFileSync(out, `P1\\n${n} ${n}\\n${rows.join('\\n')}\\n`);
console.log(m.length);
"""
        self.assertIn("flip(best);format(best);return m", sub._QR_SCRIPT)
        cases = [("https://vpn.example.com/sub/" + "0123456789abcdef" * 2, ""), ("https://vpn.example.com/sub/привет", "")]
        cases += [("".join(chr(0x21 + (i * 7 + n) % 90) for i in range(n)), "") for n in (1, 14, 15, 84, 154, 213, 400, 1000, 2331)]
        cases += [("https://vpn.example.com/sub/" + "a" * 32, str(mask)) for mask in range(8)]
        with tempfile.TemporaryDirectory() as tmp:
            source, script, image = (os.path.join(tmp, name) for name in ("qr.js", "driver.js", "qr.pbm"))
            with open(source, "w", encoding="utf-8") as handle:
                handle.write(sub._QR_SCRIPT)
            with open(script, "w", encoding="utf-8") as handle:
                handle.write(driver)
            sizes = set()
            for text, mask in cases:
                with self.subTest(length=len(text), mask=mask):
                    drawn = subprocess.run([node, script, source, text, mask, image], capture_output=True, text=True, check=True)
                    sizes.add(int(drawn.stdout))
                    read = subprocess.run([zbarimg, "-q", "--raw", image], capture_output=True)
                    self.assertEqual(read.stdout.decode("utf-8").rstrip("\n"), text)
            # Versions 1 and 40, and some between.
            self.assertTrue({21, 177} <= sizes and len(sizes) >= 8, sizes)


if __name__ == "__main__":
    unittest.main()
