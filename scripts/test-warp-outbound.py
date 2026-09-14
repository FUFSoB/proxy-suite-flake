#!/usr/bin/env python3

import unittest

from warp_outbound import ConfigError, build

WGCF = """[Interface]
PrivateKey = priv=
Address = 172.16.0.2/32, 2606:4700:110:8d58::2/128
DNS = 1.1.1.1
MTU = 1280
[Peer]
PublicKey = pub=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
"""


class WarpOutboundTest(unittest.TestCase):
    def test_sing_box_endpoint(self):
        ob = build(WGCF, "sing-box", "warp", 255)
        self.assertEqual(ob["type"], "wireguard")
        self.assertEqual(ob["address"], ["172.16.0.2/32", "2606:4700:110:8d58::2/128"])
        self.assertEqual(ob["private_key"], "priv=")
        self.assertEqual(ob["routing_mark"], 255)
        self.assertEqual(
            ob["peers"],
            [{"address": "engage.cloudflareclient.com", "port": 2408, "public_key": "pub=", "allowed_ips": ["0.0.0.0/0", "::/0"]}],
        )

    def test_xray_outbound(self):
        ob = build(WGCF, "xray", "warp", None)
        self.assertEqual(ob["protocol"], "wireguard")
        self.assertEqual(ob["settings"]["secretKey"], "priv=")
        self.assertEqual(ob["settings"]["peers"][0]["endpoint"], "engage.cloudflareclient.com:2408")
        self.assertNotIn("streamSettings", ob)

    def test_ipv6_endpoint(self):
        ob = build(WGCF.replace("engage.cloudflareclient.com:2408", "[2606:4700:d0::a29f:c001]:500"), "sing-box", "warp", None)
        self.assertEqual((ob["peers"][0]["address"], ob["peers"][0]["port"]), ("2606:4700:d0::a29f:c001", 500))

    def test_rejects_missing_peer(self):
        with self.assertRaises(ConfigError):
            build(WGCF.split("[Peer]")[0], "sing-box", "warp", None)


if __name__ == "__main__":
    unittest.main()
