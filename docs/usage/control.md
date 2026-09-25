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
| `routing` | `proxy pin`, `proxy unpin`, `proxy mode` |
| `outbounds` | adding, removing, enabling and disabling outbounds and subscriptions |
| `perApp` | `apps run` with `tun`, `tproxy` and `zapret` profiles |
| `secrets` | reading share links, subscription URLs and running configs |
| `autoProxy`, `zapret`, `stats`, `whitelistBypass` | the matching `proxy-ctl` groups |

Log out and back in after joining the group. Without `userControl`, a change asks for an
admin password, or you run `proxy-ctl` with sudo.

## Runtime changes and the Nix config

| Change | Lasts |
|---|---|
| `proxy outbounds add`, `proxy subs add` | until removed with `rm`; kept across reboots |
| `proxy outbounds disable` | until `enable`; works on outbounds from Nix too |
| `proxy pin` | until `unpin`; kept across reboots |
| `proxy mode` | until the next reboot |
| `… on` / `… off` | until the next reboot; boot state comes from the config |

Outbounds from the Nix config cannot be removed at runtime, only disabled.

## Commands

```sh
proxy-ctl status          # everything at a glance
proxy-ctl status --json   # the same, for scripts
proxy-ctl logs            # follow the logs of every proxy-suite service
proxy-ctl restart         # restart what is running
proxy-ctl where example.com
```

## See also

- [`userControl.scopes`](../options/userControl.md#services-proxy-suite-usercontrol-scopes)
- [`gui.enable`](../options/gui.md#services-proxy-suite-gui-enable)
- [`tui.enable`](../options/tui.md#services-proxy-suite-tui-enable)
- [The full `proxy-ctl help`](../../README.md), at the end of the README
