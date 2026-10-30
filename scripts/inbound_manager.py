#!/usr/bin/env python3
"""The inbound manager (services.proxy-suite.inbounds.manager): users' policies, kept.

A daemon, as root. Every `interval` seconds it adds up the traffic (the collector,
proxy-suite-inbound-stats), moves renewing traffic periods on, and works out who may connect
(inbound_policy.py); when that changed, it applies it to the running inbounds without a
restart (inbound_apply.py). It also bans the addresses past a user's ipLimit and keeps the
speed limits in nftables (inbound_netfilter.py), starts the terms of users on hold when they
first connect, deletes runtime users long expired, and tells webhooks what happened.

It answers an HTTP+JSON API (/api/v1/...) on a Unix socket, whose group decides who may use
it, and, with tokens, on TCP for a bot elsewhere; and serves the subscriptions, with the
headers clients show traffic and expiry from, on a socket of its own for the web server.
proxy-ctl's `inbounds users ...` commands are a client of the same API.
"""

from __future__ import annotations

import argparse
import base64
import copy
import grp
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import queue
import re
import secrets
import socket
import socketserver
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request

import inbound_apply
import inbound_netfilter
import inbound_policy as policy
import inbound_runtime as rt
import inbound_subscription

API = "/api/v1"
BUNDLE_FORMAT = "proxy-suite-inbounds"
BUNDLE_VERSION = 1
MAX_BODY = 1 << 20
MAX_IMPORT_BODY = 64 << 20
EVENTS = ("user.created", "user.deleted", "user.updated", "user.enabled", "user.disabled", "user.reset",
          "user.activated", "user.traffic", "user.expiring", "user.ip-limit")


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def _log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


# --- webhooks -------------------------------------------------------------------------


class Webhooks:
    """POSTs each event as JSON to the hooks that want it, from a thread of their own, a few
    times until one answers 2xx. With a secret, X-Proxy-Suite-Signature: sha256=<HMAC of the
    body>."""

    def __init__(self, hooks: list[dict], opener=None):
        self.hooks = []
        for hook in hooks:
            secret = None
            if hook.get("secretFile"):
                try:
                    with open(hook["secretFile"], encoding="utf-8") as handle:
                        secret = handle.read().strip().encode("utf-8")
                except OSError as exc:
                    _log(f"webhook {hook['url']}: cannot read its secret: {exc}")
            self.hooks.append({"url": hook["url"], "events": set(hook.get("events") or []), "secret": secret})
        self.queue: queue.Queue = queue.Queue()
        self.opener = opener or urllib.request.urlopen
        self.sent: list[dict] = []
        if self.hooks:
            threading.Thread(target=self._worker, daemon=True, name="webhooks").start()

    def emit(self, event: str, user: str | None, data: dict | None = None, at: float | None = None) -> None:
        payload = {"event": event, "user": user, "at": int(at or time.time()), "data": data or {}}
        self.sent.append(payload)
        del self.sent[:-200]
        _log(f"event {event} {user or ''} {json.dumps(data or {}, sort_keys=True)}")
        for hook in self.hooks:
            if not hook["events"] or event in hook["events"]:
                self.queue.put((hook, payload))

    def _worker(self) -> None:
        while True:
            hook, payload = self.queue.get()
            body = json.dumps(payload).encode("utf-8")
            headers = {"Content-Type": "application/json", "User-Agent": "proxy-suite-inbounds-manager",
                       "X-Proxy-Suite-Event": payload["event"]}
            if hook["secret"]:
                digest = hmac.new(hook["secret"], body, hashlib.sha256).hexdigest()
                headers["X-Proxy-Suite-Signature"] = f"sha256={digest}"
            for attempt in range(4):
                try:
                    request = urllib.request.Request(hook["url"], data=body, headers=headers, method="POST")
                    with self.opener(request, timeout=10) as response:
                        if 200 <= response.status < 300:
                            break
                        failure = f"it answered {response.status}"
                except Exception as exc:  # noqa: BLE001 - a hook down must not stop the next
                    failure = str(exc)
                if attempt == 3:
                    _log(f"webhook {hook['url']}: {payload['event']} not delivered: {failure}")
                else:
                    time.sleep(2**attempt)


# --- the manager ----------------------------------------------------------------------


class Manager:
    def __init__(self, config: dict, spec: dict, clock=time.time, netfilter=None, webhooks=None, runner=None):
        self.config = config
        self.spec = spec
        self.clock = clock
        self.lock = threading.RLock()
        self.netfilter = netfilter if netfilter is not None else inbound_netfilter.Netfilter(config.get("nft"))
        self.webhooks = webhooks if webhooks is not None else Webhooks(config.get("webhooks") or [])
        self.runner = runner or subprocess.run
        self.applied: dict | None = None
        self.last_tick: float | None = None
        self.last_error: str | None = None
        runtime = spec.get("runtime") or {}
        self.spool = runtime.get("spool")
        self.spool_lock = runtime.get("lock")
        self._rendered_cache: tuple[float, dict] | None = None

    # --- files ------------------------------------------------------------------------

    def stored_policies(self) -> dict:
        return policy.load_policies(self.config["policyFile"])

    def save_policies(self, stored: dict) -> None:
        policy.write_json(self.config["policyFile"], {"version": 1, "users": stored})

    def state(self) -> dict:
        return policy.load_state(self.config["stateFile"])

    def save_state(self, state: dict) -> None:
        policy.write_json(self.config["stateFile"], state)

    def stats(self) -> dict:
        return policy.read_stats(self.config["statsFile"])

    def rendered(self) -> dict:
        """What the inbounds run now: build-inbound.py's output, as their start script or
        the last apply saved it."""
        path = os.path.join(self.config["apply"]["runtimeDir"], "rendered.json")
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            return {}
        if self._rendered_cache is None or self._rendered_cache[0] != mtime:
            self._rendered_cache = (mtime, policy.read_json(path, {}))
        return self._rendered_cache[1]

    def runtime_state(self) -> dict:
        if not self.spool:
            return {"users": {}, "listeners": {}}
        return rt.load_spool(self.spool)[0]

    # --- users ------------------------------------------------------------------------

    def names(self, runtime_state: dict | None = None) -> list[str]:
        runtime_state = runtime_state if runtime_state is not None else self.runtime_state()
        return policy.user_names(self.spec, runtime_state["users"])

    def require_user(self, name: str, runtime_state: dict | None = None) -> None:
        if name not in self.names(runtime_state):
            raise ApiError(404, f"no user '{name}'")

    def view(self, now: float | None = None) -> dict:
        """{name: (active, level)}: what the inbounds should run with now."""
        statuses = policy.statuses(self.spec, self.runtime_state()["users"], now if now is not None else self.clock())
        return {name: (v["active"], v["level"]) for name, v in statuses.items()}

    def overview(self, only: str | None = None) -> list[dict]:
        now = self.clock()
        runtime_state = self.runtime_state()
        rows = {row["name"]: row for row in rt.users_view(self.spec, runtime_state)}
        declared = policy.declared_policies(self.spec)
        stored = self.stored_policies()
        state = self.state()
        stats = self.stats()
        rendered = self.rendered()
        tokens = {entry["user"]: entry["token"] for entry in rendered.get("subscriptions") or []}
        online = {entry.get("email"): entry.get("ips") or [] for entry in stats.get("online") or []}
        base_url = (self.config.get("subscriptions") or {}).get("baseUrl")
        result = []
        for name in self.names(runtime_state):
            if only is not None and name != only:
                continue
            row = rows.get(name, {"source": "runtime", "order": None, "listeners": [], "problems": []})
            effective = policy.effective(declared.get(name), stored.get(name))
            user_state = copy.deepcopy(state["users"].get(name) or {})
            policy.roll_period(effective, user_state, now)
            up, down = policy.period_traffic(stats, user_state, name)
            status = policy.status(effective, up + down, now)
            limit = effective.get("trafficLimit")
            token = tokens.get(name)
            result.append({
                "name": name,
                "source": row.get("source"),
                "order": row.get("order"),
                "address": row.get("address") or None,
                "listeners": row.get("listeners") or [],
                "problems": row.get("problems") or [],
                "active": status["active"],
                "reasons": status["reasons"],
                "policy": effective,
                "declared": declared.get(name, {}),
                "stored": stored.get(name, {}),
                "traffic": {
                    "up": up, "down": down, "used": up + down, "limit": limit,
                    "remaining": None if limit is None else max(limit - up - down, 0),
                    "period": effective.get("trafficPeriod"),
                    "periodStart": user_state.get("periodStart"),
                    "periodEnd": policy.period_end(effective, user_state),
                },
                "expiresAt": effective.get("expiresAt"),
                "onHold": policy.on_hold(effective),
                "online": {"ips": [ip.get("ip") for ip in online.get(name, [])],
                           "lastSeen": (stats.get("seen") or {}).get(name)},
                "level": state["slots"].get(name, 0) if effective.get("speedLimit") else 0,
                "subscription": None if token is None else {
                    "token": token, "url": f"{base_url.rstrip('/')}/{token}" if base_url else None},
            })
        if only is not None and not result:
            raise ApiError(404, f"no user '{only}'")
        return result

    def links(self, name: str) -> list[dict]:
        self.require_user(name)
        return [link for link in self.rendered().get("links") or [] if link.get("user") == name]

    # --- changes ----------------------------------------------------------------------

    def _spool_locked(self):
        if not self.spool:
            raise ApiError(409, "runtime users need inbounds.runtime.enable")
        return rt.lock_spool(self.spool, self.spool_lock)

    def _supports(self, fields: dict) -> None:
        if fields.get("ipLimit") and not self.netfilter.enabled:
            raise ApiError(409, "ipLimit needs nftables, which this host's manager cannot use")
        if fields.get("speedLimit") and not (self.netfilter.enabled and self.config.get("speedLimits")):
            raise ApiError(409, "speed limits need inbounds.manager.speedLimits and nftables")

    def _allocate_slot(self, state: dict, name: str) -> None:
        if name in state["slots"]:
            return
        taken = set(state["slots"].values())
        for slot in range(1, int(self.config.get("slots", 512)) + 1):
            if slot not in taken:
                state["slots"][name] = slot
                return
        raise ApiError(409, "no speed-limit slot is free: raise inbounds.manager.speedLimits.slots")

    def set_policy(self, name: str, fields: dict, unset: list[str] = (), event: str = "user.updated",
                   apply: bool = True) -> dict:
        with self.lock:
            self.require_user(name)
            try:
                normalized = policy.normalize(fields, self.clock())
            except policy.PolicyError as exc:
                raise ApiError(400, str(exc)) from None
            bad = [field for field in unset if field not in policy.FIELDS]
            if bad:
                raise ApiError(400, f"unknown policy fields: {', '.join(bad)}")
            self._supports(normalized)
            stored = self.stored_policies()
            entry = dict(stored.get(name, {}))
            entry.update(normalized)
            for field in unset:
                entry.pop(field, None)
            effective = policy.effective(policy.declared_policies(self.spec).get(name), entry)
            # The slot first: with none free, nothing is saved.
            if effective.get("speedLimit"):
                state = self.state()
                if name not in state["slots"]:
                    self._allocate_slot(state, name)
                    self.save_state(state)
            if entry:
                stored[name] = entry
            else:
                stored.pop(name, None)
            self.save_policies(stored)
            self.webhooks.emit(event, name, {"policy": normalized, "unset": list(unset)}, self.clock())
            if apply:
                self.apply_now()
            return self.overview(name)[0]

    def create_user(self, body: dict) -> dict:
        name = body.get("name")
        if not isinstance(name, str):
            raise ApiError(400, "name is missing")
        listeners = body.get("listeners") or []
        order = body.get("order")
        if not isinstance(listeners, list) or not all(isinstance(t, str) for t in listeners):
            raise ApiError(400, "listeners must be a list of tags")
        if order is not None and type(order) is not int:
            raise ApiError(400, "order must be a number")
        fields = body.get("policy") or {}
        try:
            normalized = policy.normalize(fields, self.clock())
        except policy.PolicyError as exc:
            raise ApiError(400, str(exc)) from None
        self._supports(normalized)
        with self.lock:
            if normalized.get("speedLimit"):
                # Refused before the user is made, not after.
                probe = self.state()
                probe["slots"].pop(name, None)
                self._allocate_slot(probe, name)
            lock = self._spool_locked()
            try:
                message = rt.cmd_users_add(self.spec, self.spool, name, order, listeners)
            except rt.RuntimeError_ as exc:
                raise ApiError(409, str(exc)) from None
            finally:
                os.close(lock)
            stored = self.stored_policies()
            if normalized:
                stored[name] = normalized
            else:
                stored.pop(name, None)
            self.save_policies(stored)
            state = self.state()
            state["users"][name] = policy.start_period(self.stats(), name, self.clock())
            state["slots"].pop(name, None)
            if normalized.get("speedLimit"):
                self._allocate_slot(state, name)
            self.save_state(state)
            self.webhooks.emit("user.created", name, {"message": message}, self.clock())
            self.apply_now()
            return self.overview(name)[0]

    def delete_user(self, name: str, reason: str | None = None) -> dict:
        with self.lock:
            lock = self._spool_locked()
            try:
                message = rt.cmd_users_rm(self.spec, self.spool, name)
            except rt.RuntimeError_ as exc:
                status = 404 if "Unknown" in str(exc) else 409
                raise ApiError(status, str(exc)) from None
            finally:
                os.close(lock)
            self.forget(name)
            self.webhooks.emit("user.deleted", name, {"reason": reason} if reason else {}, self.clock())
            self.apply_now()
            return {"deleted": name, "message": message}

    def forget(self, name: str) -> None:
        stored = self.stored_policies()
        if stored.pop(name, None) is not None:
            self.save_policies(stored)
        state = self.state()
        for key in ("users", "slots", "seen", "subscriptions"):
            state[key].pop(name, None)
        self.save_state(state)

    def set_listeners(self, name: str, wanted: list[str]) -> dict:
        if not isinstance(wanted, list) or not all(isinstance(t, str) for t in wanted):
            raise ApiError(400, "listeners must be a list of tags")
        with self.lock:
            lock = self._spool_locked()
            changed = False
            try:
                runtime_state = rt.load_spool(self.spool)[0]
                self.require_user(name, runtime_state)
                current = {row["name"]: set(row["listeners"]) for row in rt.users_view(self.spec, runtime_state)}.get(name, set())
                for tag in sorted(current - set(wanted)):
                    rt.cmd_bind(self.spec, self.spool, name, tag, False)
                    changed = True
                for tag in sorted(set(wanted) - current):
                    rt.cmd_bind(self.spec, self.spool, name, tag, True)
                    changed = True
            except rt.RuntimeError_ as exc:
                os.close(lock)
                lock = -1
                # What was done before the refusal is saved: it runs too.
                if changed:
                    self.apply_now()
                raise ApiError(409, str(exc)) from None
            finally:
                if lock != -1:
                    os.close(lock)
            self.webhooks.emit("user.updated", name, {"listeners": wanted}, self.clock())
            self.apply_now()
            return self.overview(name)[0]

    def reset_traffic(self, name: str, apply: bool = True) -> dict:
        with self.lock:
            self.require_user(name)
            state = self.state()
            fresh = policy.start_period(self.stats(), name, self.clock())
            old = state["users"].get(name) or {}
            state["users"][name] = {**fresh, "notified": {k: v for k, v in (old.get("notified") or {}).items()
                                                         if not k.startswith("traffic")}}
            self.save_state(state)
            self.webhooks.emit("user.reset", name, {}, self.clock())
            if apply:
                self.apply_now()
            return self.overview(name)[0]

    def rotate_subscription(self, name: str) -> dict:
        """A new subscription URL for the user, their credentials left as they are: the old one
        stops answering, for whoever else has it. Clients that hold it need the new one."""
        with self.lock:
            self.require_user(name)
            state = self.state()
            state["subscriptions"][name] = secrets.token_hex(16)
            self.save_state(state)
            self.webhooks.emit("user.updated", name, {"subscription": "rotated"}, self.clock())
            self.apply_now()
            return self.overview(name)[0]

    def extend(self, name: str, by: str | None = None, until=None, reset: bool = False) -> dict:
        """expiresAt moved on by a span ("30d"), from now or from the current expiry if that is
        later, or set to a time. A user on hold has their term lengthened instead, until
        they come. With reset, their traffic starts over too: a renewal, paid for."""
        now = self.clock()
        if (by is None) == (until is None):
            raise ApiError(400, "give one of by or until")
        row = self.overview(name)[0]
        current = row["expiresAt"]
        try:
            if by is not None:
                span = str(by).strip().lstrip("+")
                if row["onHold"]:
                    fields = {"expiresAfter": policy.parse_time(f"+{span}", row["policy"]["expiresAfter"])}
                else:
                    fields = {"expiresAt": policy.parse_time(f"+{span}", max(now, current or now))}
            else:
                fields = {"expiresAt": policy.parse_time(until, now)}
        except policy.PolicyError as exc:
            raise ApiError(400, str(exc)) from None
        if reset:
            with self.lock:
                self.reset_traffic(name, apply=False)
                return self.set_policy(name, fields)
        return self.set_policy(name, fields)

    # --- applying ---------------------------------------------------------------------

    def apply_now(self) -> list[str]:
        """Bring the running inbounds to what the policies say now, and tell the webhooks
        who was switched off or back on by it."""
        with self.lock:
            before = self.applied
            done = inbound_apply.apply(self.config["apply"], self.spec)
            now = self.clock()
            self.applied = self.view(now)
            for line in done:
                _log(f"applied: {line}")
            self.sync_speed()
            if before is not None:
                for name, (active, _) in sorted(self.applied.items()):
                    was = before.get(name, (True, 0))[0]
                    if was and not active:
                        reasons = next(iter(self.overview(name)), {}).get("reasons", [])
                        self.webhooks.emit("user.disabled", name, {"reasons": reasons}, now)
                    elif not was and active:
                        self.webhooks.emit("user.enabled", name, {}, now)
            return done

    def collect(self) -> None:
        collector = self.config.get("collector")
        if collector:
            try:
                self.runner([collector], capture_output=True, text=True, timeout=60)
            except (OSError, subprocess.TimeoutExpired) as exc:
                _log(f"collector: {exc}")

    def tick(self) -> None:
        with self.lock:
            self.collect()
            if self.netfilter.enabled:
                # nftables.service flushes the ruleset when it reloads: the bans need the table
                # back as much as the speed limits do.
                try:
                    self.netfilter.ensure()
                except RuntimeError as exc:
                    _log(f"nftables: {exc}")
            now = self.clock()
            runtime_state = self.runtime_state()
            names = self.names(runtime_state)
            declared = policy.declared_policies(self.spec)
            stored = self.stored_policies()
            state = self.state()
            stats = self.stats()
            changed = False
            for name in names:
                effective = policy.effective(declared.get(name), stored.get(name))
                user_state = state["users"].get(name)
                if user_state is None:
                    state["users"][name] = policy.start_period(stats, name, now)
                    changed = True
                elif policy.roll_period(effective, user_state, now):
                    user_state["notified"] = {k: v for k, v in (user_state.get("notified") or {}).items()
                                              if not k.startswith("traffic")}
                    changed = True
                if effective.get("speedLimit") and name not in state["slots"]:
                    try:
                        self._allocate_slot(state, name)
                        changed = True
                    except ApiError as exc:
                        _log(f"{name}: {exc.message}")
                elif not effective.get("speedLimit") and name in state["slots"]:
                    # Level 0 without a limit anyway: the slot goes back for another.
                    del state["slots"][name]
                    changed = True
            for key in ("users", "slots", "seen", "subscriptions"):
                for name in [n for n in state[key] if n not in names]:
                    del state[key][name]
                    changed = True
            changed |= self.notify(state, declared, stored, stats, now)
            changed |= self.enforce_ip_limits(state, declared, stored, stats, now)
            if changed:
                self.save_state(state)
            self.activate(names, declared, stored, state, stats, now)
            self.purge(runtime_state, declared, now)
            if self.view(now) != self.applied:
                self.apply_now()
            else:
                self.sync_speed()
            self.last_tick = now

    def activate(self, names: list[str], declared: dict, stored: dict, state: dict, stats: dict, now: float) -> None:
        """Users on hold who have connected (traffic counted, or online now): their term
        starts, an expiresAt from now. expiresAfter stays, so unsetting the expiry puts them
        back on hold."""
        online = {entry.get("email") for entry in stats.get("online") or [] if entry.get("ips")}
        started = {}
        for name in names:
            effective = policy.effective(declared.get(name), stored.get(name))
            if not policy.on_hold(effective):
                continue
            user_state = state["users"].get(name) or {}
            if name not in online and not policy.used_bytes(stats, user_state, name):
                continue
            # Short of the year 9999, or the policy file would refuse the entry whole.
            started[name] = min(int(now) + effective["expiresAfter"], policy.MAX_TIME - 1)
        if not started:
            return
        for name, expires in started.items():
            stored.setdefault(name, {})["expiresAt"] = expires
        self.save_policies(stored)
        for name, expires in sorted(started.items()):
            self.webhooks.emit("user.activated", name, {"expiresAt": expires}, now)

    def purge(self, runtime_state: dict, declared: dict, now: float) -> None:
        """Runtime users expired for longer than deleteExpiredAfter: deleted, as by hand.
        Declared ones stay: the config holds them."""
        after = policy.parse_duration(self.config.get("deleteExpiredAfter"))
        if after is None:
            return
        stored = self.stored_policies()
        for name in sorted(runtime_state["users"]):
            expires = policy.effective(declared.get(name), stored.get(name)).get("expiresAt")
            if expires is None or now < expires + after:
                continue
            try:
                self.delete_user(name, reason="expired")
            except ApiError as exc:
                _log(f"{name}: expired, but cannot be deleted: {exc.message}")

    def notify(self, state: dict, declared: dict, stored: dict, stats: dict, now: float) -> bool:
        """Traffic thresholds and coming expiries, each once per period or expiry."""
        settings = self.config.get("notify") or {}
        changed = False
        for name, user_state in state["users"].items():
            effective = policy.effective(declared.get(name), stored.get(name))
            notified = user_state.setdefault("notified", {})
            limit = effective.get("trafficLimit")
            if limit:
                used = policy.used_bytes(stats, user_state, name)
                for percent in settings.get("trafficPercent", [80, 100]):
                    key = f"traffic{percent}"
                    if used * 100 >= limit * percent and notified.get(key) != user_state.get("periodStart"):
                        notified[key] = user_state.get("periodStart")
                        self.webhooks.emit("user.traffic", name, {"percent": percent, "used": used, "limit": limit}, now)
                        changed = True
            expires = effective.get("expiresAt")
            if expires:
                for days in settings.get("expiryDays", [3, 1]):
                    key = f"expiring{days}"
                    if 0 < expires - now <= days * 86400 and notified.get(key) != expires:
                        notified[key] = expires
                        self.webhooks.emit("user.expiring", name, {"days": days, "expiresAt": expires}, now)
                        changed = True
        return changed

    def ban_ports(self) -> dict[str, list[int]]:
        """Each user's ports where an address can be banned: their listeners', except those
        on loopback or behind a PROXY-protocol front, which see the front's address."""
        unbannable = {listener["tag"] for listener in self.spec.get("listeners") or []
                      if listener.get("acceptProxyProtocol") or _loopback(listener.get("listen", ""))}
        ports: dict[str, list[int]] = {}
        for inbound in self.rendered().get("inbounds") or []:
            if inbound.get("tag") in unbannable or _loopback(str(inbound.get("listen", ""))):
                continue
            for client in (inbound.get("settings") or {}).get("clients") or []:
                ports.setdefault(client.get("email"), []).append(int(inbound["port"]))
        return ports

    def enforce_ip_limits(self, state: dict, declared: dict, stored: dict, stats: dict, now: float) -> bool:
        """Past a user's ipLimit, the addresses that came last are banned for a while from that
        user's ports, and what they hold open there is closed."""
        online = {entry.get("email"): [ip.get("ip") for ip in entry.get("ips") or []] for entry in stats.get("online") or []}
        seen = state["seen"]
        changed = False
        ports = None
        for name in list(online) + [n for n in seen if n not in online]:
            ips = [ip for ip in online.get(name, []) if ip]
            first = seen.setdefault(name, {})
            for ip in ips:
                if ip not in first:
                    first[ip] = int(now)
                    changed = True
            for ip in [ip for ip in first if ip not in ips]:
                del first[ip]
                changed = True
            if not first:
                del seen[name]
            limit = policy.effective(declared.get(name), stored.get(name)).get("ipLimit")
            if not limit or len(ips) <= limit or not self.netfilter.enabled:
                continue
            ordered = sorted(ips, key=lambda ip: (first.get(ip, now), ip))
            extra = ordered[limit:]
            if ports is None:
                ports = self.ban_ports()
            user_ports = ports.get(name) or []
            if not user_ports:
                continue
            seconds = int((self.config.get("ipLimit") or {}).get("banSeconds", 600))
            for ip in extra:
                try:
                    self.netfilter.ban(ip, user_ports, seconds)
                except RuntimeError as exc:
                    _log(f"{name}: cannot ban {ip}: {exc}")
                    continue
                inbound_apply.cut(inbound_apply.Tools(self.config["apply"]), [ip], set(user_ports), set())
                first.pop(ip, None)
                changed = True
                self.webhooks.emit("user.ip-limit", name, {"ip": ip, "limit": limit, "online": len(ips), "seconds": seconds}, now)
        return changed

    def speed_targets(self) -> tuple[dict, list]:
        """The limits nftables should hold: XRay users by slot, AmneziaWG peers by address."""
        now = self.clock()
        statuses = policy.statuses(self.spec, self.runtime_state()["users"], now)
        declared = policy.declared_policies(self.spec)
        stored = self.stored_policies()
        users: dict[int, dict] = {}
        speeds = {}
        for name, view in statuses.items():
            speed = policy.effective(declared.get(name), stored.get(name)).get("speedLimit")
            if speed and view["active"]:
                speeds[name] = speed
                if view["level"]:
                    users[view["level"]] = speed
        peers = []
        for listener in self.spec.get("listeners") or []:
            if listener.get("type") != "amneziawg":
                continue
            awg = listener.get("amneziaWg") or {}
            if not awg.get("stateFile"):
                continue
            awg_state = policy.read_json(awg["stateFile"], {})
            for name, entry in (awg_state.get("users") or {}).items():
                if name not in speeds or not isinstance(entry.get("offset"), int):
                    continue
                import awg_inbound

                for address in awg_inbound._addresses(awg, entry["offset"], prefix=False):
                    peers.append({"interface": awg["interfaceName"], "address": address.split("/")[0],
                                  "up": speeds[name].get("up"), "down": speeds[name].get("down")})
        return users, peers

    def sync_speed(self) -> None:
        if not (self.netfilter.enabled and self.config.get("speedLimits")):
            return
        try:
            self.netfilter.ensure()
            users, peers = self.speed_targets()
            self.netfilter.sync_limits(users, peers)
        except (RuntimeError, OSError, ValueError) as exc:
            _log(f"speed limits: {exc}")

    # --- bans -------------------------------------------------------------------------

    def bans(self) -> list[dict]:
        try:
            return self.netfilter.bans()
        except RuntimeError as exc:
            raise ApiError(500, str(exc)) from None

    def unban(self, ip: str) -> dict:
        try:
            ipaddress.ip_address(ip)
        except ValueError:
            raise ApiError(400, f"'{ip}' is not an address") from None
        try:
            return {"ip": ip, "lifted": self.netfilter.unban(ip)}
        except RuntimeError as exc:
            raise ApiError(500, str(exc)) from None

    # --- export and import ------------------------------------------------------------

    # Keys proxy-suite generates for a listener and keeps in its state directory, by file name.
    GENERATED_KEYS = ("vless-encryption-key.x25519", "vless-encryption-key.mlkem768", "shadowsocks-server-key")

    def _key_path(self, tag: str, name: str) -> str | None:
        """Where a listener's generated key is kept: as the spec says for a declared one,
        under the runtime state directory for any other."""
        for listener in self.spec.get("listeners") or []:
            if listener["tag"] != tag:
                continue
            if name == "shadowsocks-server-key":
                return listener.get("serverPasswordStateFile")
            base = listener.get("encryptionStateFile")
            return f"{base}.{name.rsplit('.', 1)[1]}" if base else None
        state_dir = (self.spec.get("runtime") or {}).get("salamanderStateDir")
        return os.path.join(state_dir, tag, name) if state_dir else None

    def _awg_listeners(self) -> dict[str, dict]:
        return {listener["tag"]: listener for listener in self.spec.get("listeners") or []
                if listener.get("type") == "amneziawg" and (listener.get("amneziaWg") or {}).get("stateFile")}

    def export(self, with_stats: bool = True) -> dict:
        """Everything that makes this server's users who they are, beyond the Nix config:
        the runtime users and listeners (their secrets and REALITY keys), the policies and
        what they are measured against, the AmneziaWG keys and addresses, the Salamander
        passwords, VLESS Encryption and shadowtls keys proxy-suite generated, and the traffic
        counted. Secrets the config names
        by file (sops and the like) are not in it."""
        with self.lock:
            bundle: dict = {"format": BUNDLE_FORMAT, "version": BUNDLE_VERSION, "exportedAt": int(self.clock())}
            bundle["runtime"] = self.runtime_state() if self.spool else None
            bundle["policies"] = self.stored_policies()
            state = self.state()
            bundle["state"] = {"users": state["users"], "slots": state["slots"], "subscriptions": state["subscriptions"]}
            bundle["amneziaWg"] = {}
            for tag, listener in self._awg_listeners().items():
                value = policy.read_json(listener["amneziaWg"].get("stateFile", ""), {})
                if value:
                    bundle["amneziaWg"][tag] = value
            bundle["salamander"] = {}
            salamander_dir = (self.spec.get("runtime") or {}).get("salamanderStateDir")
            for listener in self.spec.get("listeners") or []:
                path = listener.get("salamanderStateFile")
                bundle_key = listener["tag"]
                if path and os.path.isfile(path):
                    with open(path, encoding="utf-8") as handle:
                        bundle["salamander"][bundle_key] = handle.read().strip()
            if salamander_dir and self.spool:
                for tag in self.runtime_state()["listeners"]:
                    path = os.path.join(salamander_dir, tag, "salamander-password")
                    if os.path.isfile(path):
                        with open(path, encoding="utf-8") as handle:
                            bundle["salamander"][tag] = handle.read().strip()
            # VLESS Encryption keys and shadowtls server keys proxy-suite generated: without
            # them every link to those listeners changes.
            bundle["keys"] = {}
            tags = [listener["tag"] for listener in self.spec.get("listeners") or []]
            if self.spool:
                tags += [tag for tag in self.runtime_state()["listeners"] if tag not in tags]
            for tag in tags:
                for name in self.GENERATED_KEYS:
                    path = self._key_path(tag, name)
                    if path and os.path.isfile(path):
                        with open(path, encoding="utf-8") as handle:
                            bundle["keys"].setdefault(tag, {})[name] = handle.read().strip()
            # The subscription key proxy-suite generated: without it every URL changes on the
            # server this goes to. One the config names by file stays with the config.
            bundle["subscriptionKey"] = None
            key_path = self.spec.get("subscriptionKeyStateFile")
            if key_path and not self.spec.get("subscriptionKeyFile") and os.path.isfile(key_path):
                with open(key_path, encoding="utf-8") as handle:
                    bundle["subscriptionKey"] = handle.read().strip() or None
            bundle["stats"] = self.stats() if with_stats else None
            return bundle

    @staticmethod
    def _check_awg_state(tag: str, value) -> None:
        """An AmneziaWG listener's state from a bundle: its keys end up in the configs awg-quick
        runs as root, where a line break would start a line of the bundle's choosing."""

        def key(item, where: str, optional: bool = False) -> None:
            if optional and item is None:
                return
            try:
                ok = isinstance(item, str) and len(base64.b64decode(item, validate=True)) == 32
            except ValueError:
                ok = False
            if not ok:
                raise ApiError(400, f"amneziaWg {tag}: {where} is not a WireGuard key")

        import awg_inbound

        if not isinstance(value, dict) or not isinstance(value.get("server", {}), dict) \
                or not isinstance(value.get("users", {}), dict) or not isinstance(value.get("obfuscation", {}), dict):
            raise ApiError(400, f"amneziaWg {tag}: not a listener's state")
        # Another version's keys would be thrown away and made anew: every client cut off.
        if value.get("version") != awg_inbound.STATE_VERSION:
            raise ApiError(400, f"amneziaWg {tag}: state version {value.get('version')} is not {awg_inbound.STATE_VERSION}")
        server = value.get("server") or {}
        for field in ("privateKey", "publicKey"):
            key(server.get(field), f"server.{field}", optional=True)
        for name, entry in (value.get("users") or {}).items():
            if not isinstance(entry, dict) or type(entry.get("offset")) is not int:
                raise ApiError(400, f"amneziaWg {tag}: user '{name}' is malformed")
            for field in ("publicKey", "privateKey", "presharedKey"):
                key(entry.get(field), f"users.{name}.{field}", optional=True)
        for field, item in (value.get("obfuscation") or {}).items():
            if type(item) is not int:
                raise ApiError(400, f"amneziaWg {tag}: obfuscation.{field} is not a number")

    def _check_bundle(self, bundle: dict) -> None:
        """Every part of a bundle that goes into a file, checked before any is written: names
        become paths, and the state and the traffic are read by the renderers and the
        collector, which a malformed entry would stop."""
        if not isinstance(bundle, dict) or bundle.get("format") != BUNDLE_FORMAT:
            raise ApiError(400, "not a proxy-suite inbounds export")
        if bundle.get("version") != BUNDLE_VERSION:
            raise ApiError(400, f"export version {bundle.get('version')} is not {BUNDLE_VERSION}")
        for section in ("runtime", "policies", "state", "amneziaWg", "salamander", "keys", "stats"):
            if bundle.get(section) is not None and not isinstance(bundle[section], dict):
                raise ApiError(400, f"{section} must be an object")
        runtime = bundle.get("runtime") or {}
        for kind in ("users", "listeners"):
            if not isinstance(runtime.get(kind) or {}, dict):
                raise ApiError(400, f"runtime.{kind} must be an object")
        state = bundle.get("state") or {}
        for key in ("users", "slots", "subscriptions"):
            if not isinstance(state.get(key) or {}, dict):
                raise ApiError(400, f"state.{key} must be an object")
        for name, salt in (state.get("subscriptions") or {}).items():
            if not policy.is_subscription_salt(salt):
                raise ApiError(400, f"state.subscriptions of '{name}': not a salt")
        for name, entry in (state.get("users") or {}).items():
            try:
                policy.check_user_state(entry)
            except policy.PolicyError as exc:
                raise ApiError(400, f"state of '{name}': {exc}") from None
        for tag, value in (bundle.get("amneziaWg") or {}).items():
            self._check_awg_state(tag, value)
        declared_paths = {listener["tag"]: listener.get("salamanderStateFile") for listener in self.spec.get("listeners") or []}
        for tag, password in (bundle.get("salamander") or {}).items():
            # A declared listener's file is the config's; any other tag becomes a directory under
            # the runtime ones', which it must not climb out of.
            if not declared_paths.get(tag) and not rt.NAME.fullmatch(tag):
                raise ApiError(400, f"salamander: '{tag}' is not a listener tag")
            if not isinstance(password, str) or not re.fullmatch(r"[!-~]{1,256}", password):
                raise ApiError(400, f"salamander {tag}: not a password")
        for tag, keys in (bundle.get("keys") or {}).items():
            if not declared_paths.get(tag) and not rt.NAME.fullmatch(tag):
                raise ApiError(400, f"keys: '{tag}' is not a listener tag")
            if not isinstance(keys, dict):
                raise ApiError(400, f"keys {tag}: must be an object")
            for name, key in keys.items():
                if name not in self.GENERATED_KEYS:
                    raise ApiError(400, f"keys {tag}: '{name}' is no key proxy-suite generates")
                if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9_+/=-]{1,256}", key):
                    raise ApiError(400, f"keys {tag}: {name} is not a key")
        key = bundle.get("subscriptionKey")
        if key is not None and not (isinstance(key, str) and re.fullmatch(r"[!-~]{16,512}", key)):
            raise ApiError(400, "subscriptionKey: not a key")
        stats = bundle.get("stats") or {}
        days = stats.get("days") or {}
        if not isinstance(days, dict):
            raise ApiError(400, "stats.days must be an object")
        for day, buckets in days.items():
            if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", day) or not isinstance(buckets, dict):
                raise ApiError(400, f"stats.days: '{day}' is not a day of counters")
            for kind, entries in buckets.items():
                if kind not in ("user", "inbound", "outbound") or not isinstance(entries, dict):
                    raise ApiError(400, f"stats.days.{day}: '{kind}' is not user, inbound or outbound")
                for name, counters in entries.items():
                    if not isinstance(counters, dict) or set(counters) - {"up", "down"} or not all(
                            type(v) in (int, float) and 0 <= v < float("inf") for v in counters.values()):
                        raise ApiError(400, f"stats.days.{day}.{kind}.{name}: up and down, in bytes")

    def import_bundle(self, bundle: dict, replace: bool = False) -> dict:
        """Take a bundle in. Names already here are refused, unless replace; then the bundle's
        win. AmneziaWG listeners take the bundle's server key only with replace or when they
        have none yet: their clients' configs name it."""
        self._check_bundle(bundle)
        report: dict = {"users": [], "listeners": [], "policies": [], "amneziaWg": [], "salamander": [], "keys": [], "skipped": []}
        with self.lock:
            incoming = bundle.get("runtime") or {"users": {}, "listeners": {}}
            if (incoming.get("users") or incoming.get("listeners")) and not self.spool:
                raise ApiError(409, "the export has runtime users or listeners; enable inbounds.runtime first")
            if self.spool:
                lock = self._spool_locked()
                try:
                    current = rt.load_spool(self.spool)[0]
                    # As `users add` refuses them: a runtime user may not take a declared one's name.
                    declared = [f"user {n}" for n in incoming.get("users") or {} if n in (self.spec.get("users") or {})]
                    if declared:
                        raise ApiError(409, "declared in the configuration here: " + ", ".join(declared))
                    conflicts = [f"user {n}" for n in incoming.get("users") or {} if n in current["users"]]
                    conflicts += [f"listener {t}" for t in incoming.get("listeners") or {} if t in current["listeners"]]
                    if conflicts and not replace:
                        raise ApiError(409, "already here: " + ", ".join(conflicts) + " (import with replace)")
                    for kind, check in (("listeners", rt.check_listener_shape), ("users", rt.check_user_shape)):
                        for name, entry in sorted((incoming.get(kind) or {}).items()):
                            try:
                                rt._require_name(name, kind[:-1])
                                check(entry)
                            except rt.RuntimeError_ as exc:
                                raise ApiError(400, f"{kind[:-1]} '{name}': {exc}") from None
                    for kind in ("listeners", "users"):
                        for name, entry in sorted((incoming.get(kind) or {}).items()):
                            rt.write_entry(self.spool, kind, name, entry)
                            report[kind].append(name)
                finally:
                    os.close(lock)
            stored = self.stored_policies()
            for name, entry in sorted((bundle.get("policies") or {}).items()):
                try:
                    policy.check_stored(entry)
                except policy.PolicyError as exc:
                    report["skipped"].append(f"policy {name}: {exc}")
                    continue
                if name in stored and not replace:
                    report["skipped"].append(f"policy {name}: already here")
                    continue
                stored[name] = entry
                report["policies"].append(name)
            self.save_policies(stored)
            state = self.state()
            incoming_state = (bundle.get("state") or {}).get("users") or {}
            for name, entry in incoming_state.items():
                if replace or name not in state["users"]:
                    state["users"][name] = entry
            declared_policies = policy.declared_policies(self.spec)
            for name in (bundle.get("state") or {}).get("slots") or {}:
                if name not in state["slots"] and policy.effective(declared_policies.get(name), stored.get(name)).get("speedLimit"):
                    self._allocate_slot(state, name)
            # The subscription URLs moved on there stay moved on here.
            for name, salt in ((bundle.get("state") or {}).get("subscriptions") or {}).items():
                if replace or name not in state["subscriptions"]:
                    state["subscriptions"][name] = salt
            self.save_state(state)
            for tag, value in sorted((bundle.get("amneziaWg") or {}).items()):
                listener = self._awg_listeners().get(tag)
                if listener is None:
                    report["skipped"].append(f"amneziaWg {tag}: no such listener here")
                    continue
                path = listener["amneziaWg"]["stateFile"]
                existing = policy.read_json(path, {})
                if existing and not replace:
                    merged = copy.deepcopy(existing)
                    for name, entry in (value.get("users") or {}).items():
                        merged.setdefault("users", {}).setdefault(name, entry)
                    if (existing.get("server") or {}).get("publicKey") != (value.get("server") or {}).get("publicKey"):
                        report["skipped"].append(f"amneziaWg {tag}: kept this server's key; imported clients need new configs")
                    value = merged
                os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
                policy.write_json(path, value)
                report["amneziaWg"].append(tag)
            salamander_dir = (self.spec.get("runtime") or {}).get("salamanderStateDir")
            declared_paths = {listener["tag"]: listener.get("salamanderStateFile") for listener in self.spec.get("listeners") or []}
            for tag, password in sorted((bundle.get("salamander") or {}).items()):
                path = declared_paths.get(tag) or (os.path.join(salamander_dir, tag, "salamander-password") if salamander_dir else None)
                if not path:
                    continue
                if os.path.exists(path) and not replace:
                    continue
                os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    handle.write(password + "\n")
                report["salamander"].append(tag)
            for tag, keys in sorted((bundle.get("keys") or {}).items()):
                for name, key in sorted(keys.items()):
                    path = self._key_path(tag, name)
                    if not path or (os.path.exists(path) and not replace):
                        continue
                    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
                    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(fd, "w", encoding="utf-8") as handle:
                        handle.write(key + "\n")
                    report["keys"].append(f"{tag}/{name}")
            self._import_subscription_key(bundle.get("subscriptionKey"), replace, report)
            incoming_stats = bundle.get("stats")
            if isinstance(incoming_stats, dict):
                with policy.Locked(self.config["statsFile"]):
                    stats = self.stats()
                    days = stats.setdefault("days", {})
                    for day, buckets in (incoming_stats.get("days") or {}).items():
                        for kind, entries in buckets.items():
                            for name, counters in entries.items():
                                days.setdefault(day, {}).setdefault(kind, {}).setdefault(name, counters)
                    policy.write_json(self.config["statsFile"], stats, mode=0o640)
            report["applied"] = self.apply_now()
            return report

    def _import_subscription_key(self, key: str | None, replace: bool, report: dict) -> None:
        """The exported server's generated key, so its users' URLs keep working here: taken when
        this server has none yet, or with replace. Never over a key the config names."""
        if not key:
            return
        path = self.spec.get("subscriptionKeyStateFile")
        if self.spec.get("subscriptionKeyFile"):
            report["skipped"].append("subscription key: this server's is subscriptions.keyFile; not taken")
            return
        if not path:
            report["skipped"].append("subscription key: subscriptions.keyFile is false here; imported users' URLs change")
            return
        existing = ""
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as handle:
                existing = handle.read().strip()
        if existing == key:
            return
        if existing and not replace:
            report["skipped"].append("subscription key: kept this server's; imported users' URLs change (import with replace)")
            return
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(key + "\n")
        report["subscriptionKey"] = True

    # --- subscriptions ----------------------------------------------------------------

    def subscription(self, token: str, fmt: str | None = None, user_agent: str = "", accept: str = "",
                     accept_language: str = "", url: str | None = None) -> tuple[bytes, dict] | None:
        """A user's subscription, in the format their client reads (inbound_subscription.py).
        url: where it was asked for, for the page's QR code when baseUrl is not set."""
        rendered = self.rendered()
        # By a hash table's lookup, keyed by a hash of its own: no time that says how near a guess came.
        entry = {s.get("token"): s for s in rendered.get("subscriptions") or []}.get(token)
        if entry is None:
            return None
        name = entry["user"]
        settings = self.config.get("subscriptions") or {}
        headers = dict(inbound_subscription.HEADERS)
        row = None
        try:
            row = self.overview(name)[0]
            traffic = row["traffic"]
            expire = row["expiresAt"] or 0
            headers["subscription-userinfo"] = (
                f"upload={traffic['up']}; download={traffic['down']}; total={traffic['limit'] or 0}; expire={expire}"
            )
        except ApiError:
            pass
        title = (settings.get("profileTitle") or "{user}").replace("{user}", name)
        fmt = inbound_subscription.pick_format(fmt, user_agent, accept)
        if fmt == "html" and row is None:
            fmt = "base64"
        base_url = settings.get("baseUrl")
        sub_url = f"{base_url.rstrip('/')}/{token}" if base_url else (url or token)
        body, headers["Content-Type"] = inbound_subscription.render(
            fmt, rendered, name, entry["body"], row, sub_url, title, settings, accept_language, user_agent)
        if fmt == "html":
            headers.update(inbound_subscription.PAGE_HEADERS)
            return body, headers
        headers["profile-title"] = "base64:" + base64.b64encode(title.encode("utf-8")).decode("ascii")
        headers["content-disposition"] = f'attachment; filename="{re.sub(r"[^A-Za-z0-9._-]", "_", title)}"'
        if settings.get("updateInterval"):
            headers["profile-update-interval"] = str(settings["updateInterval"])
        if settings.get("supportUrl"):
            headers["support-url"] = settings["supportUrl"]
        if settings.get("webPageUrl"):
            headers["profile-web-page-url"] = settings["webPageUrl"]
        return body, headers

    def health(self) -> dict:
        return {"ok": True, "lastTick": self.last_tick, "lastError": self.last_error,
                "netfilter": self.netfilter.enabled, "speedLimits": bool(self.config.get("speedLimits")),
                "runtime": bool(self.spool)}


def _loopback(address: str) -> bool:
    try:
        return ipaddress.ip_address(address.strip("[]")).is_loopback
    except ValueError:
        return address == "localhost"


class Misses:
    """Subscriptions asked for that are not there: one journal line per address a minute at
    most, with how many came since, so fail2ban sees someone guessing and the journal no flood.
    The token asked for stays out of it."""

    def __init__(self, every: float = 60, clock=time.monotonic):
        self.every = every
        self.clock = clock
        self.lock = threading.Lock()
        self.seen: dict[str, tuple[float, int]] = {}

    def note(self, address: str) -> None:
        now = self.clock()
        with self.lock:
            last, count = self.seen.get(address, (None, 0))
            if last is not None and now - last < self.every:
                self.seen[address] = (last, count + 1)
                return
            if len(self.seen) >= 4096:
                self.seen = {a: v for a, v in self.seen.items() if now - v[0] < self.every}
            self.seen[address] = (now, 0)
        more = f" ({count} more since the last line)" if count else ""
        _log(f"subscription: unknown token from {address}{more}")


# --- HTTP -----------------------------------------------------------------------------


ROUTES = [
    ("GET", r"/health", "health"),
    ("GET", r"/users", "users"),
    ("POST", r"/users", "create"),
    ("GET", r"/users/(?P<name>[^/]+)", "user"),
    ("PATCH", r"/users/(?P<name>[^/]+)", "patch"),
    ("DELETE", r"/users/(?P<name>[^/]+)", "delete"),
    ("POST", r"/users/(?P<name>[^/]+)/enable", "enable"),
    ("POST", r"/users/(?P<name>[^/]+)/disable", "disable"),
    ("POST", r"/users/(?P<name>[^/]+)/reset-traffic", "reset"),
    ("POST", r"/users/(?P<name>[^/]+)/extend", "extend"),
    ("POST", r"/users/(?P<name>[^/]+)/rotate-subscription", "rotate"),
    ("PUT", r"/users/(?P<name>[^/]+)/listeners", "listeners"),
    ("GET", r"/users/(?P<name>[^/]+)/links", "links"),
    ("GET", r"/listeners", "list_listeners"),
    ("GET", r"/online", "online"),
    ("GET", r"/bans", "bans"),
    ("DELETE", r"/bans/(?P<ip>[^/]+)", "unban"),
    ("GET", r"/events", "events"),
    ("GET", r"/export", "export"),
    ("POST", r"/import", "import_"),
    ("POST", r"/apply", "apply"),
]


def handle_api(manager: Manager, method: str, path: str, query: dict, body) -> tuple[int, object]:
    """One API call: (status, JSON value). Raises ApiError."""
    if not path.startswith(API + "/") and path != API:
        raise ApiError(404, "not found")
    sub = path[len(API):] or "/"
    for route_method, pattern, action in ROUTES:
        match = re.fullmatch(pattern, sub)
        if not match:
            continue
        if route_method != method:
            continue
        args = {k: urllib.parse.unquote(v) for k, v in match.groupdict().items()}
        body = body if isinstance(body, dict) else {}
        if action == "health":
            return 200, manager.health()
        if action == "users":
            return 200, manager.overview()
        if action == "create":
            return 201, manager.create_user(body)
        if action == "user":
            return 200, manager.overview(args["name"])[0]
        if action == "patch":
            fields = {k: v for k, v in body.items() if k != "unset"}
            unset = body.get("unset") or []
            if not isinstance(unset, list):
                raise ApiError(400, "unset must be a list of fields")
            return 200, manager.set_policy(args["name"], fields, unset)
        if action == "delete":
            return 200, manager.delete_user(args["name"])
        if action == "enable":
            return 200, manager.set_policy(args["name"], {"enabled": True}, event="user.updated")
        if action == "disable":
            return 200, manager.set_policy(args["name"], {"enabled": False}, event="user.updated")
        if action == "reset":
            return 200, manager.reset_traffic(args["name"])
        if action == "extend":
            return 200, manager.extend(args["name"], body.get("by"), body.get("until"), bool(body.get("resetTraffic")))
        if action == "rotate":
            return 200, manager.rotate_subscription(args["name"])
        if action == "listeners":
            return 200, manager.set_listeners(args["name"], body.get("listeners"))
        if action == "links":
            return 200, manager.links(args["name"])
        if action == "list_listeners":
            return 200, rt.listeners_view(manager.spec, manager.runtime_state()) if manager.spec.get("runtime") else [
                {"tag": l["tag"], "type": l.get("type"), "port": l.get("port"), "via": l.get("via"),
                 "users": [u["name"] for u in l.get("users") or []], "source": "nix", "problems": []}
                for l in manager.spec.get("listeners") or []]
        if action == "online":
            return 200, [{"name": r["name"], **r["online"]} for r in manager.overview() if r["online"]["ips"]]
        if action == "bans":
            return 200, manager.bans()
        if action == "unban":
            return 200, manager.unban(args["ip"])
        if action == "events":
            try:
                limit = int(query.get("limit", ["50"])[0])
            except ValueError:
                raise ApiError(400, "limit must be a number") from None
            return 200, manager.webhooks.sent[-limit:] if limit > 0 else []
        if action == "export":
            return 200, manager.export(with_stats=query.get("stats", ["1"])[0] not in ("0", "false", "no"))
        if action == "import_":
            return 200, manager.import_bundle(body.get("bundle"), bool(body.get("replace")))
        if action == "apply":
            return 200, {"applied": manager.apply_now()}
    if any(re.fullmatch(pattern, sub) for _, pattern, _ in ROUTES):
        raise ApiError(405, f"{method} is not allowed here")
    raise ApiError(404, "not found")


def read_tokens(path: str | None) -> list[bytes]:
    """Bearer tokens for the TCP API: one per line, "name:token" or the token alone."""
    if not path:
        return []
    tokens = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#"):
                tokens.append(line.rsplit(":", 1)[-1].strip().encode("utf-8"))
    return [t for t in tokens if t]


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "proxy-suite-inbounds-manager"
    protocol_version = "HTTP/1.1"
    manager: Manager
    mode = "api"  # "api" or "sub"
    tokens: list[bytes] = []
    misses: Misses | None = None
    # A client that opens a connection and says nothing must not hold a thread for good: the
    # subscriptions' TCP listener takes anyone.
    timeout = 60

    def address_string(self) -> str:
        return self.client_address[0] if isinstance(self.client_address, tuple) and self.client_address else "unix"

    def client(self) -> str:
        """Who asked: the web server's word for it when the web server is the one asking (on
        the socket, or from loopback), as an address or not at all."""
        own = self.address_string()
        if own == "unix" or _loopback(own):
            forwarded = self.headers.get("X-Real-IP") or (self.headers.get("X-Forwarded-For") or "").split(",")[-1]
            try:
                return str(ipaddress.ip_address(forwarded.strip()))
            except ValueError:
                pass
        return own

    def log_message(self, fmt: str, *args) -> None:
        pass

    def _send(self, status: int, body: bytes, headers: dict | None = None) -> None:
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, value) -> None:
        self._send(status, (json.dumps(value, indent=2) + "\n").encode("utf-8"), {"Content-Type": "application/json"})

    def _authorized(self) -> bool:
        if not self.tokens:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        given = header[len("Bearer "):].strip().encode("utf-8")
        return any(hmac.compare_digest(given, token) for token in self.tokens)

    def _dispatch(self) -> None:
        url = urllib.parse.urlsplit(self.path)
        if self.mode == "sub":
            if self.command not in ("GET", "HEAD"):
                self.close_connection = True
                return self._send(405, b"", inbound_subscription.HEADERS)
            token = url.path.rstrip("/").rsplit("/", 1)[-1]
            query = urllib.parse.parse_qs(url.query)
            # Behind the web server: the address the browser asked for, for the page's QR code.
            host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host")
            scheme = self.headers.get("X-Forwarded-Proto") or "https"
            here = f"{scheme}://{host}{url.path}" if host and re.fullmatch(r"[A-Za-z0-9.:\[\]-]+", host) \
                and scheme in ("http", "https") else None
            found = self.manager.subscription(
                token, (query.get("format") or [None])[0], self.headers.get("User-Agent") or "",
                self.headers.get("Accept") or "", self.headers.get("Accept-Language") or "", here,
            ) if re.fullmatch(r"[0-9a-f]{32}", token) else None
            if found is None:
                if self.misses is not None:
                    self.misses.note(self.client())
                return self._send(404, b"not found\n", {**inbound_subscription.HEADERS, "Content-Type": "text/plain"})
            body, headers = found
            return self._send(200, body, headers)
        if not self._authorized():
            # The body stays unread: the connection cannot carry another request.
            self.close_connection = True
            return self._json(401, {"error": "a valid bearer token is needed"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0:
            self.close_connection = True
            return self._json(400, {"error": "a bad Content-Length"})
        limit = MAX_IMPORT_BODY if url.path.endswith("/import") else MAX_BODY
        if length > limit:
            self.close_connection = True
            return self._json(413, {"error": f"the body is larger than {limit} bytes"})
        body = None
        if length:
            try:
                body = json.loads(self.rfile.read(length).decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                return self._json(400, {"error": "the body is not JSON"})
        try:
            status, value = handle_api(self.manager, self.command, url.path, urllib.parse.parse_qs(url.query), body)
        except ApiError as exc:
            return self._json(exc.status, {"error": exc.message})
        except Exception as exc:  # noqa: BLE001 - the daemon answers, whatever broke
            traceback.print_exc()
            return self._json(500, {"error": f"{type(exc).__name__}: {exc}"})
        self._json(status, value)

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = do_HEAD = _dispatch


class UnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def get_request(self):
        request, _ = super().get_request()
        return request, ("unix", 0)


class TCPHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def _handler(manager: Manager, mode: str, tokens: list[bytes], misses: Misses | None = None):
    return type(f"{mode.title()}Handler", (Handler,), {"manager": manager, "mode": mode, "tokens": tokens, "misses": misses})


def unix_server(path: str, handler, group: str | None, mode: int):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    old = os.umask(0o177)
    try:
        server = UnixHTTPServer(path, handler)
    finally:
        os.umask(old)
    if group:
        try:
            os.chown(path, -1, grp.getgrnam(group).gr_gid)
        except (KeyError, PermissionError) as exc:
            _log(f"{path}: cannot give it to group {group}: {exc}")
    os.chmod(path, mode)
    return server


def tcp_server(listen: str, handler):
    host, _, port = listen.rpartition(":")
    host = host.strip("[]")
    server_class = TCPHTTPServer
    if ":" in host:
        server_class = type("TCP6HTTPServer", (TCPHTTPServer,), {"address_family": socket.AF_INET6})
    return server_class((host, int(port)), handler)


def serve(config: dict, spec: dict) -> int:
    manager = Manager(config, spec)
    servers = []
    api = config.get("api") or {}
    servers.append(unix_server(api["socket"], _handler(manager, "api", []), api.get("group"), int(api.get("mode", "0660"), 8)))
    if api.get("listen"):
        tokens = read_tokens(api.get("tokensFile"))
        if not tokens:
            _log("the TCP API has no tokens (inbounds.manager.api.tokensFile): not listening")
        else:
            servers.append(tcp_server(api["listen"], _handler(manager, "api", tokens)))
    subs = config.get("subscriptions") or {}
    misses = Misses()
    if subs.get("socket"):
        servers.append(unix_server(subs["socket"], _handler(manager, "sub", [], misses), subs.get("group"), 0o660))
    # The TCP listener serves them too, when they are served at all.
    if subs.get("socket") and subs.get("listen"):
        servers.append(tcp_server(subs["listen"], _handler(manager, "sub", [], misses)))
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    if manager.netfilter.enabled:
        try:
            manager.netfilter.ensure()
        except RuntimeError as exc:
            _log(f"nftables: {exc}")
    interval = max(int(config.get("interval", 30)), 5)
    while True:
        try:
            # The first applies whatever the inbounds run now (nothing is applied yet), after it
            # has measured the users it sees for the first time.
            manager.tick()
            manager.last_error = None
        except Exception as exc:  # noqa: BLE001 - one bad tick must not end the daemon
            manager.last_error = f"{type(exc).__name__}: {exc}"
            traceback.print_exc()
        time.sleep(interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--config", required=True, help="manager.json, from the module")
    parser.add_argument("--spec", required=True)
    parser.add_argument("command", choices=["serve", "tick", "apply"])
    args = parser.parse_args(argv)
    with open(args.config, encoding="utf-8") as handle:
        config = json.load(handle)
    with open(args.spec, encoding="utf-8") as handle:
        spec = json.load(handle)
    if args.command == "serve":
        return serve(config, spec)
    manager = Manager(config, spec)
    if args.command == "tick":
        manager.tick()
    else:
        for line in manager.apply_now():
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
