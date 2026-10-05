#!/usr/bin/env python3
"""DNS for apps run `--via` an AmneziaWG interface: queries over UDP and TCP on loopback, sent
on to the profile's resolvers from sockets carrying a mark that policy routing takes into the
interface. The app's lookups cannot reach the tunnel themselves: one asked of a stub resolver
on 127.0.0.53 has a loopback source, which the kernel never routes out of a real interface.

With no route in the interface's table the mark meets an unreachable rule, so a lookup fails
rather than leaving any other way.

Per-app TUN and TProxy use it too, a port per mark (--listen): there a lookup of a resolver on
loopback is sent on into the route, where the backend's DNS hijack answers it.
"""

import argparse
import asyncio
import os
import re
import socket
import struct
import sys

TIMEOUT = 4.0
MAX_MESSAGE = 65535


# The source address of the queries sent on (--bind): on a TProxy route's local route the
# kernel would pick the destination as the source, and the reply would not come back.
BIND: dict[int, str] = {}


def upstream_socket(server: str, kind: int, mark: int) -> socket.socket:
    family = socket.AF_INET6 if ":" in server else socket.AF_INET
    sock = socket.socket(family, kind)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
        if family in BIND:
            sock.bind((BIND[family], 0))
        sock.setblocking(False)
    except OSError:
        sock.close()
        raise
    return sock


async def ask_udp(query: bytes, servers: list[str], mark: int) -> bytes | None:
    """The first answer any server gives, in order; None when none does."""
    loop = asyncio.get_running_loop()
    for server in servers:
        try:
            sock = upstream_socket(server, socket.SOCK_DGRAM, mark)
        except OSError:
            continue
        try:
            await loop.sock_connect(sock, (server, 53))
            await loop.sock_sendall(sock, query)
            return await asyncio.wait_for(loop.sock_recv(sock, MAX_MESSAGE), TIMEOUT)
        except (OSError, asyncio.TimeoutError):
            continue
        finally:
            sock.close()
    return None


class UdpListener(asyncio.DatagramProtocol):
    def __init__(self, servers: list[str], mark: int):
        self.servers = servers
        self.mark = mark
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        asyncio.ensure_future(self.answer(data, addr))

    async def answer(self, query, addr):
        reply = await ask_udp(query, self.servers, self.mark)
        if reply is not None and self.transport is not None:
            self.transport.sendto(reply, addr)


async def read_message(reader: asyncio.StreamReader) -> bytes | None:
    try:
        (length,) = struct.unpack("!H", await reader.readexactly(2))
        return await reader.readexactly(length)
    except (asyncio.IncompleteReadError, ConnectionError):
        return None


async def ask_tcp(query: bytes, servers: list[str], mark: int) -> bytes | None:
    loop = asyncio.get_running_loop()
    for server in servers:
        try:
            sock = upstream_socket(server, socket.SOCK_STREAM, mark)
        except OSError:
            continue
        try:
            await asyncio.wait_for(loop.sock_connect(sock, (server, 53)), TIMEOUT)
            reader, writer = await asyncio.open_connection(sock=sock)
        except (OSError, asyncio.TimeoutError):
            sock.close()
            continue
        try:
            writer.write(struct.pack("!H", len(query)) + query)
            await writer.drain()
            reply = await asyncio.wait_for(read_message(reader), TIMEOUT)
            if reply is not None:
                return reply
        except (OSError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()
    return None


def tcp_handler(servers: list[str], mark: int):
    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        try:
            while (query := await asyncio.wait_for(read_message(reader), 30)) is not None:
                reply = await ask_tcp(query, servers, mark)
                if reply is None:
                    break
                writer.write(struct.pack("!H", len(reply)) + reply)
                await writer.drain()
        except (OSError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()

    return handle


def notify_ready():
    """sd_notify(READY=1), for Type=notify: the start is done once the listeners are up."""
    path = os.environ.get("NOTIFY_SOCKET")
    if not path:
        return
    if path.startswith("@"):
        path = "\0" + path[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.connect(path)
        sock.sendall(b"READY=1")


def listen_spec(item: str) -> tuple[int, int]:
    """PORT:MARK, ASCII digits only (str.isdigit also takes "²", which int() then refuses)."""
    match = re.fullmatch(r"([0-9]+):([0-9]+)", item)
    if not match or not 1 <= int(match[1]) <= 65535 or int(match[2]) >= 2**32:
        raise argparse.ArgumentTypeError(f"{item!r}: not PORT:MARK (port 1-65535, a 32-bit mark)")
    return int(match[1]), int(match[2])


async def serve(listeners: list[tuple[int, int]], servers: list[str]):
    loop = asyncio.get_running_loop()
    for port, mark in listeners:
        for host in ("127.0.0.1", "::1"):
            try:
                await loop.create_datagram_endpoint(
                    lambda mark=mark: UdpListener(servers, mark), local_addr=(host, port)
                )
                await asyncio.start_server(tcp_handler(servers, mark), host, port)
            except OSError as exc:
                # IPv6 may be off.
                if host == "127.0.0.1":
                    raise
                print(f"per-app-dns: not on [{host}]:{port}: {exc}", file=sys.stderr)
    notify_ready()
    await asyncio.Event().wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int)
    parser.add_argument("--mark", type=int)
    parser.add_argument(
        "--listen",
        action="append",
        default=[],
        type=listen_spec,
        metavar="PORT:MARK",
        help="another port, whose lookups are sent on with this mark; repeatable",
    )
    parser.add_argument(
        "--bind",
        action="append",
        default=[],
        metavar="ADDRESS",
        help="the source address of the queries sent on, one per family",
    )
    parser.add_argument("servers", nargs="*", help="resolver addresses, asked in order")
    args = parser.parse_args()
    for address in args.bind:
        BIND[socket.AF_INET6 if ":" in address else socket.AF_INET] = address
    listeners = []
    if args.port is not None or args.mark is not None:
        if args.port is None or args.mark is None:
            parser.error("--port and --mark go together")
        listeners.append((args.port, args.mark))
    listeners.extend(args.listen)
    if not listeners:
        parser.error("nothing to listen on: --port and --mark, or --listen")
    asyncio.run(serve(listeners, args.servers))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
