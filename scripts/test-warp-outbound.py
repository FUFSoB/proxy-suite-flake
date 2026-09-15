#!/usr/bin/env python3

import unittest

from warp_outbound import ConfigError, build, obfuscation_keys

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
        ob = build(WGCF, "warp", 255)
        self.assertEqual(ob["type"], "wireguard")
        self.assertEqual(ob["address"], ["172.16.0.2/32", "2606:4700:110:8d58::2/128"])
        self.assertEqual(ob["private_key"], "priv=")
        self.assertEqual(ob["routing_mark"], 255)
        self.assertEqual(
            ob["peers"],
            [{"address": "engage.cloudflareclient.com", "port": 2408, "public_key": "pub=", "allowed_ips": ["0.0.0.0/0", "::/0"]}],
        )

    def test_ipv6_endpoint(self):
        ob = build(WGCF.replace("engage.cloudflareclient.com:2408", "[2606:4700:d0::a29f:c001]:500"), "warp", None)
        self.assertEqual((ob["peers"][0]["address"], ob["peers"][0]["port"]), ("2606:4700:d0::a29f:c001", 500))
        self.assertNotIn("routing_mark", ob)

    def test_awg3_keepalive_range(self):
        # Generator AWG 3 profiles range the keepalive; sing-box gets the lower bound.
        ob = build(WGCF.replace("[Peer]", "RekeyAfterTime = 100-120\n[Peer]\nPersistentKeepalive = 25-35"), "warp", None)
        self.assertEqual(ob["peers"][0]["persistent_keepalive_interval"], 25)

    def test_obfuscation_keys(self):
        self.assertEqual(obfuscation_keys(WGCF), [])
        awg = WGCF.replace("[Peer]", "Jc = 4\nH1 = 1-2\n[Peer]")
        self.assertEqual(obfuscation_keys(awg), ["h1", "jc"])
        self.assertNotIn("jc", build(awg, "warp", None))

    def test_rejects_missing_peer(self):
        with self.assertRaises(ConfigError):
            build(WGCF.split("[Peer]")[0], "warp", None)


if __name__ == "__main__":
    unittest.main()
