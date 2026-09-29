#!/usr/bin/env python3
"""Read an inbound spec file and emit XRay inbounds plus client share links."""

import argparse
import json
import sys

import inbound_runtime
from proxy_inbound import build_inbounds


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Render services.proxy-suite.inbounds into XRay inbounds."
    )
    ap.add_argument("--spec", required=True, help="path to the generated inbound spec JSON")
    ap.add_argument(
        "--server-address",
        default="",
        dest="server_address",
        help="public address used in generated share links",
    )
    ap.add_argument(
        "--onion-address",
        default="",
        dest="onion_address",
        help="the onion service's address, for a second set of links to its listeners",
    )
    ap.add_argument(
        "--template",
        help="the XRay config template: with inbounds.runtime, the result also carries its "
        "routing rules with the runtime listeners and users in",
    )
    args = ap.parse_args()

    with open(args.spec, encoding="utf-8") as handle:
        spec = json.load(handle)

    server_address = args.server_address or spec.get("serverAddress") or ""
    if spec.get("shareLinks", True) and not server_address:
        print("error: no server address available for share links", file=sys.stderr)
        sys.exit(1)

    try:
        spec, runtime, warnings = inbound_runtime.merge(spec, check_ports=True)
        for warning in warnings:
            print(f"proxy-suite: warning: {warning}", file=sys.stderr)
        result = build_inbounds(spec, server_address, args.onion_address)
        if args.template and spec.get("runtime"):
            with open(args.template, encoding="utf-8") as handle:
                template = json.load(handle)
            result.update(inbound_runtime.routing(spec, runtime, template["routing"]["rules"]))
    except (ValueError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    print(json.dumps(result))


if __name__ == "__main__":
    main()
