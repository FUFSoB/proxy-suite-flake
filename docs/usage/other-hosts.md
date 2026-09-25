# Other Linux and Android

The same `services.proxy-suite` options work outside NixOS, through a module for each
kind of host. The other guides apply as they are, within the limits below.

| Host | Module | Runs as |
|---|---|---|
| Any distribution, with [system-manager](https://github.com/numtide/system-manager) | `systemManagerModules.default` | root, in the system's systemd |
| Any distribution, with [home-manager](https://github.com/nix-community/home-manager) | `homeManagerModules.default` | your user, in your systemd user session |
| Android, with [Nix-on-Droid](https://github.com/nix-community/nix-on-droid) | `nixOnDroidModules.default` | the Nix-on-Droid app |

## system-manager

Nearly everything works as on NixOS: TUN, TProxy, zapret, the kill switch and the GUI.

```nix no-check
systemConfigs.default = system-manager.lib.makeSystemConfig {
  modules = [
    proxy-suite.systemManagerModules.default
    { services.proxy-suite = { enable = true; /* … */ }; }
  ];
};
```

- Open inbound ports in your distribution's firewall yourself. proxy-suite leaves it alone.
- AmneziaWG runs in userspace, since kernel modules cannot come from Nix here.

## home-manager

Rootless: only what an ordinary user can do.

```nix no-check
homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    proxy-suite.homeManagerModules.default
    { services.proxy-suite = { enable = true; /* … */ }; }
  ];
};
```

Available: the local proxy with its outbounds, subscriptions and routing, proxychains
per-app routing, AmneziaWG as a `"userspace"` outbound, inbounds on ports 1024 and up, the
GUI and the TUI.

Not available, since they need root: TUN, TProxy, the kill switch, zapret, per-app `tun`,
`tproxy` and `zapret`, and AmneziaWG interfaces. `userControl` has nothing to grant, since
you own the services. The build stops with a message if the config asks for any of these.

## Nix-on-Droid

What home-manager gets, without the GUI. Use `proxy-ctl` or `proxy-tui` in the app's shell.

```nix no-check
nixOnDroidConfigurations.default = nix-on-droid.lib.nixOnDroidConfiguration {
  inherit pkgs;
  modules = [
    proxy-suite.nixOnDroidModules.default
    { services.proxy-suite = { enable = true; /* … */ }; }
  ];
};
```

- Android has no boot hook for the app. The services start when a Nix-on-Droid shell opens,
  or on `proxy-suitectl boot`.
- Android stops background apps. Keep the app's wake lock on, and turn off battery
  optimisation for it.
- Point other apps at `127.0.0.1:1080`, in their own proxy settings or in the Wi-Fi proxy
  settings.

## See also

- [Keep secrets out of the Nix store](./secrets.md): secret files must be readable by your
  user on home-manager and Nix-on-Droid.
