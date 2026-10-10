# Control it day to day

Once the config is built, you rarely need to rebuild: most switches happen at runtime,
through one of three front ends.

- **`proxy-ctl`**: the command line. `proxy-ctl help` lists everything, and shell completion
  is included.
- **`proxy-tui`**: a terminal UI with the same controls. It works over SSH too. On by default.
- **The desktop app** (`gui.enable`): the same again, with a tray icon. It starts with your
  graphical session.

The TUI and the app run `proxy-ctl` underneath, so they can do exactly what it can.

## Without sudo

Reading status needs no privileges. Changing things does, unless you use `userControl`:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  gui.enable = true;
  userControl = {
    enable = true;
    scopes = [ "services" "routing" "outbounds" "perApp" ];
  };
};
users.users.alice.extraGroups = [ "proxy-suite" ];
```

Members of the group get the listed scopes. An empty `scopes` list grants all of them:

| Scope | Allows |
|---|---|
| `services` | turning services on, off and restarting them |
| `routing` | `proxy pin`, `proxy unpin`, `proxy mode`, `proxy rules` |
| `outbounds` | adding, removing, enabling and disabling outbounds and subscriptions, AmneziaWG outbounds included |
| `amneziaWg` | `awg add` and `awg rm`: global AmneziaWG profiles, which take over the host's routes and DNS |
| `perApp` | `apps run` with `tun`, `tproxy` and `zapret` profiles |
| `secrets` | reading share links, subscription URLs and running configs |
| `inbounds` | adding, removing and binding runtime inbound users and listeners, and their secrets |
| `autoProxy`, `zapret`, `stats`, `whitelistBypass` | the matching `proxy-ctl` groups |

Log out and back in after joining the group. Without `userControl`, a change asks for an
admin password, or you run `proxy-ctl` with sudo.

### Several groups

`userControl.groups` adds more groups, each with scopes of its own. A member gets what all
of their groups allow:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  userControl = {
    enable = true;
    scopes = [ "routing" ];
    groups = {
      proxy-admins.scopes = [ ];
      proxy-users.scopes = [ "perApp" "outbounds" ];
    };
  };
};
users.users.alice.extraGroups = [ "proxy-admins" ];
users.users.bob.extraGroups = [ "proxy-users" ];
```

`userControl.group` still owns proxy-suite's files. The other groups reach them through
POSIX ACLs, so `/var/lib/proxy-suite` and `/run` need a file system that supports ACLs. ext4,
btrfs, xfs and tmpfs all do.

The sing-box Clash API's secret stays readable by root only. Other users reach the API
through `proxy-suite-clash-api`, which decides per request. Any member can read the
outbounds and test them. Switching a selector through the API needs `routing`, and live
connections (`proxy-ctl where`) need `secrets`. Nothing else in the API is open to them.

## Runtime changes and the Nix config

| Change | Lasts |
|---|---|
| `proxy outbounds add`, `proxy subs add`, `awg add` | until removed with `rm`; kept across reboots |
| `proxy outbounds disable` | until `enable`; works on outbounds from Nix too |
| `inbounds users add`, `inbounds add`, `inbounds bind` | until removed; kept across reboots |
| `proxy pin` | until `unpin`; kept across reboots |
| `proxy rules add` | until removed with `rules rm`; kept across reboots |
| `proxy mode` | until the next reboot |
| `… on` / `… off` | until the next reboot; boot state comes from the config |

Outbounds from the Nix config cannot be removed at runtime, only disabled. The same goes for
AmneziaWG profiles: `awg rm` only removes those added with `awg add`.

In the TUI and the app, pasting a link onto a tab adds it there: a share link becomes an
outbound, a subscription URL a subscription. An AmneziaWG `vpn://` link or a whole `.conf`
becomes a global profile, or an outbound when pasted onto the Outbounds tab. See
[Use an AmneziaWG config](./amneziawg.md).

## Commands

```sh
proxy-ctl status          # everything at a glance
proxy-ctl status --json   # the same, for scripts
proxy-ctl logs            # follow the logs of every proxy-suite service, with the last 1000 lines
proxy-ctl restart         # restart what is running
```

In a terminal, `proxy-ctl logs` follows in [`lnav`](https://lnav.org): it follows while at
the bottom, scrolling back pauses it, `G` follows again, `e`/`E` jump between errors, `/`
searches, and `q` or Ctrl-C quits. `:enable-word-wrap` wraps long lines, and lnav remembers
it for the next time. Without lnav ([`tools.lnav.enable`](../options/tools.md#services-proxy-suite-tools-lnav-enable),
off on Nix-on-Droid) it follows in `less`. Piped, it is plain `journalctl -f`.

## See also

- [`userControl.scopes`](../options/userControl.md#services-proxy-suite-usercontrol-scopes)
- [`userControl.groups`](../options/userControl.md#services-proxy-suite-usercontrol-groups)
- [`gui.enable`](../options/gui.md#services-proxy-suite-gui-enable)
- [`tui.enable`](../options/tui.md#services-proxy-suite-tui-enable)
- [The full `proxy-ctl help`](../../README.md), at the end of the README
