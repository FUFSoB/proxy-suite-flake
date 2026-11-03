#!/usr/bin/env python3
"""The geoip.dat tags a sing-box rule-set directory lacks, as sing-box rule-set sources.

geoip.dat (V2Ray/XRay) is a protobuf GeoIPList:
  GeoIPList { repeated GeoIP entry = 1; }
  GeoIP     { string country_code = 1; repeated CIDR cidr = 2; bool reverse_match = 3; }
  CIDR      { bytes ip = 1; uint32 prefix = 2; }
sing-geoip carries countries only; XRay's data (v2ray-rules-dat) also has TELEGRAM, GOOGLE,
CLOUDFLARE, PRIVATE and the like. Each tag with no geoip-<tag>.srs beside it becomes
<out>/geoip-<tag>.json, for `sing-box rule-set compile`.

Usage: sing-geoip-extended.py <geoip.dat> <existing rule-set dir> <out dir>
"""

import ipaddress
import json
import os
import sys


def _varint(data: bytes, i: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        byte = data[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, i
        shift += 7


def _fields(data: bytes):
    """(field number, wire type, value) of one message: bytes for length-delimited ones."""
    i = 0
    while i < len(data):
        key, i = _varint(data, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _varint(data, i)
        elif wire == 2:
            length, i = _varint(data, i)
            value, i = data[i : i + length], i + length
        elif wire == 5:
            value, i = data[i : i + 4], i + 4
        elif wire == 1:
            value, i = data[i : i + 8], i + 8
        else:
            raise ValueError(f"unsupported wire type {wire}")
        yield number, wire, value


def entries(data: bytes):
    """(tag, [CIDR text], reverse_match) for every GeoIP in a GeoIPList."""
    for number, wire, entry in _fields(data):
        if number != 1 or wire != 2:
            continue
        tag, cidrs, reverse = "", [], False
        for field, kind, value in _fields(entry):
            if field == 1 and kind == 2:
                tag = value.decode("utf-8")
            elif field == 2 and kind == 2:
                ip, prefix = b"", 0
                for part, part_kind, part_value in _fields(value):
                    if part == 1 and part_kind == 2:
                        ip = part_value
                    elif part == 2 and part_kind == 0:
                        prefix = part_value
                if len(ip) in (4, 16):
                    network = ipaddress.ip_network((ipaddress.ip_address(ip), prefix), strict=False)
                    cidrs.append(str(network))
            elif field == 3 and kind == 0:
                reverse = bool(value)
        yield tag, cidrs, reverse


def main() -> None:
    if len(sys.argv) != 4:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(2)
    dat, existing, out = sys.argv[1:]
    with open(dat, "rb") as f:
        data = f.read()
    have = {name[len("geoip-") : -len(".srs")] for name in os.listdir(existing) if name.startswith("geoip-") and name.endswith(".srs")}
    os.makedirs(out, exist_ok=True)
    added = []
    for tag, cidrs, reverse in entries(data):
        name = tag.lower()
        # A reversed entry matches what is outside its list: no rule set says that.
        if not name or name in have or reverse or not cidrs or not name.replace("-", "").replace("_", "").isalnum():
            continue
        with open(os.path.join(out, f"geoip-{name}.json"), "w", encoding="utf-8") as f:
            json.dump({"version": 2, "rules": [{"ip_cidr": cidrs}]}, f)
        added.append(name)
    print(" ".join(sorted(added)))


if __name__ == "__main__":
    main()
