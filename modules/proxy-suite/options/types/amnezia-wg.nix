# AmneziaWG profile option types.
{ lib }:

let
  inherit (lib) mkOption types;
  inherit (import ../lib.nix { inherit lib; }) endpoint;
  optionalString = types.nullOr types.str;
  optionalUnsigned = types.nullOr types.ints.unsigned;
  rangeValue = types.oneOf [
    types.ints.unsigned
    (types.strMatching "^([0-9]+|[0-9]+-[0-9]+|\\(off\\))$")
  ];
  optionalRange = types.nullOr rangeValue;

  peerType = types.submodule {
    options = {
      publicKey = mkOption {
        type = types.strMatching "[^[:space:]]+";
        description = "Peer public key.";
      };
      presharedKey = mkOption {
        type = optionalString;
        default = null;
        description = "Peer preshared key. Ends up in the Nix store; prefer `presharedKeyFile`.";
      };
      presharedKeyFile = mkOption {
        type = optionalString;
        default = null;
        description = "File with the peer preshared key.";
      };
      allowedIPs = mkOption {
        type = types.listOf types.str;
        description = "IP ranges routed to and accepted from this peer.";
        example = [
          "0.0.0.0/0"
          "::/0"
        ];
      };
      endpoint = mkOption {
        type = optionalString;
        default = null;
        example = "vpn.example.com:51820";
        description = "Peer address, as host:port.";
      };
      persistentKeepalive = mkOption {
        type = optionalRange;
        default = null;
        description = "Keepalive interval in seconds, or an AWG 3 range.";
      };
      advancedSecurity = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "AWG AdvancedSecurity setting.";
      };
    };
  };

  # Every AWG obfuscation field is an optional scalar with a one-line description, so they
  # are declared as tables per value type rather than 27 near-identical mkOption blocks.
  optional =
    type: description:
    mkOption {
      inherit type description;
      default = null;
    };
  obfuscationType = types.submodule {
    options =
      lib.mapAttrs (_: optional optionalUnsigned) {
        jc = "Junk packet count (Jc).";
        jmin = "Minimum junk packet size (Jmin).";
        jmax = "Maximum junk packet size (Jmax).";
        s1 = "Handshake-init padding (S1).";
        s2 = "Handshake-response padding (S2).";
        s3 = "Cookie-reply padding (S3).";
        s4 = "Transport-message padding (S4).";
      }
      // lib.mapAttrs (_: optional optionalRange) {
        h1 = "Handshake-init header or range (H1).";
        h2 = "Handshake-response header or range (H2).";
        h3 = "Cookie-reply header or range (H3).";
        h4 = "Transport-message header or range (H4).";
        contentPaddingAddition = "AWG 3 content-padding addition or range.";
        rekeyAfterTime = "AWG 3 rekey interval or range.";
        rekeyTimeout = "AWG 3 rekey timeout or range.";
        rejectAfterTime = "AWG 3 reject-after interval or range.";
        keepaliveTimeout = "AWG 3 keepalive timeout or range.";
        maxHandshakeAttempts = "AWG 3 maximum handshake attempts or range.";
      }
      // lib.mapAttrs (_: optional optionalString) {
        i1 = "First custom signature packet (I1).";
        i2 = "Second custom signature packet (I2).";
        i3 = "Third custom signature packet (I3).";
        i4 = "Fourth custom signature packet (I4).";
        i5 = "Fifth custom signature packet (I5).";
        headerProtectionKey = "AWG 3 header-protection key. Ends up in the Nix store; prefer `headerProtectionKeyFile`.";
        headerProtectionKeyFile = "File with the AWG 3 header-protection key.";
      }
      // lib.mapAttrs (_: optional (types.nullOr types.bool)) {
        randomTrailers = "AWG 3 random transport trailers (RandomTrailers).";
        disableCookies = "AWG 3 cookie suppression (DisableCookies).";
      };
  };

  settingsType = types.submodule {
    options = {
      addresses = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Interface addresses.";
        example = [ "10.8.0.2/32" ];
      };
      dns = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "DNS servers used while this profile is active.";
      };
      privateKey = mkOption {
        type = optionalString;
        default = null;
        description = "Client private key. Ends up in the Nix store; prefer `privateKeyFile`.";
      };
      privateKeyFile = mkOption {
        type = optionalString;
        default = null;
        description = "File with the client private key.";
      };
      listenPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Local UDP port.";
      };
      mtu = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Interface MTU.";
      };
      table = mkOption {
        type = optionalString;
        default = null;
        description = "Routing table: a name or number, \"auto\" or \"off\".";
      };
      obfuscation = mkOption {
        type = obfuscationType;
        default = { };
        description = "AmneziaWG 1.x through 3.x obfuscation parameters.";
      };
      obfuscationFile = mkOption {
        type = optionalString;
        default = null;
        example = "/run/secrets/awg-obfuscation.json";
        description = ''
          File with secret obfuscation settings as JSON, using the same fields as `obfuscation`
          (except `headerProtectionKeyFile`). It is merged with `obfuscation` at startup and never
          enters the Nix store. A field set in both places is an error. Restart the profile after
          changing the file.
        '';
      };
      peers = mkOption {
        type = types.listOf peerType;
        default = [ ];
        description = "AmneziaWG peers.";
      };
    };
  };

  profileType = types.submodule (
    { name, ... }:
    {
      options = {
        interfaceName = mkOption {
          type = types.strMatching "^[A-Za-z0-9_.-]{1,15}$";
          default = "awg-${name}";
          defaultText = lib.literalExpression ''"awg-<name>"'';
          description = "Interface name, at most 15 characters.";
        };
        autostart = mkOption {
          type = types.bool;
          default = false;
          description = "Start this profile at boot. Only one profile can autostart.";
        };
        asOutbound = mkOption {
          type = types.nullOr (
            types.enum [
              "singBox"
              "userspace"
              "interface"
            ]
          );
          default = null;
          description = ''
            Use the profile as a proxy outbound, tagged with its name, instead of a global VPN. It
            then always runs and leaves the host's routes and DNS alone. Needs `proxy.enable`.
            - "singBox": plain WireGuard in sing-box. AmneziaWG obfuscation is dropped, with a warning.
            - "userspace": wireproxy with AmneziaWG obfuscation. Needs no root, so it is the only
              mode on home-manager and Nix-on-Droid. Its endpoint is resolved by the system
              resolver, so use an IP if that resolver cannot reach the name.
            - "interface": a real AmneziaWG interface without routes, which the outbound binds to.
              On sing-box, its DNS also goes through the tunnel.
          '';
        };
        endpoint = endpoint "host:port (IPv6 in brackets) that replaces the first peer's endpoint.";
        allowConfigHooks = mkOption {
          type = types.bool;
          default = false;
          description = "Let imported configs run wg-quick hooks (PostUp etc.) or use SaveConfig. Only for trusted configs.";
        };
        vpnContainer = mkOption {
          type = optionalString;
          default = null;
          description = "Which container to take from a vpn:// export that holds several.";
        };
        configFile = mkOption {
          type = optionalString;
          default = null;
          description = "File with an AmneziaWG .conf.";
        };
        vpnFile = mkOption {
          type = optionalString;
          default = null;
          description = "File with a vpn:// export.";
        };
        vpn = mkOption {
          type = optionalString;
          default = null;
          description = "A vpn:// export. Ends up in the Nix store; prefer `vpnFile`.";
        };
        settings = mkOption {
          type = types.nullOr settingsType;
          default = null;
          description = "The client config written in Nix, instead of a file.";
        };
      };
    }
  );
in
{
  inherit profileType obfuscationType;
}
