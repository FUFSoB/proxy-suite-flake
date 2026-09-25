# Keep secrets out of the Nix store

Everything in a Nix config is copied to `/nix/store`, which every user on the machine can
read. That includes proxy links, passwords and keys. So every option that holds a secret has
a `…File` twin, which takes a path that is read when the service starts:

| Inline (ends up in the store) | Use instead |
|---|---|
| `url` | `urlFile` |
| `password` | `passwordFile` |
| `uuid` | `uuidFile` |
| `vpn` | `vpnFile` |
| `privateKey` | `privateKeyFile` |
| `secret` | `secretFile` |

The option reference marks each inline one with "Ends up in the Nix store".

A file can stay owned by root with mode `0400`. The services read it as root when they start.
With home-manager and Nix-on-Droid, your own user must be able to read it.

## With sops-nix

```nix no-check
sops.secrets."proxy/my-vps-url" = { };

services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "my-vps"; urlFile = config.sops.secrets."proxy/my-vps-url".path; }
    ];
  };
};
```

## With agenix

```nix no-check
age.secrets.my-vps-url.file = ./secrets/my-vps-url.age;

services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "my-vps"; urlFile = config.age.secrets.my-vps-url.path; }
    ];
  };
};
```

## Without a secrets tool

Any path outside the store works, such as a root-only file you create by hand:

```sh
sudo install -D -m 0400 /dev/stdin /var/lib/proxy-secrets/my-vps-url <<< 'vless://…'
```

## Good to know

- A secret file that changes takes effect on the next restart: `proxy-ctl restart`.
- Anything added at runtime with `proxy-ctl` (outbounds, subscriptions) is kept outside the
  store, readable by root and by the `userControl` group.
- Share links, subscription URLs and running configs contain secrets too. `proxy-ctl` shows
  them only to root, and to `userControl` members with the `secrets` scope.
