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
        description = "AmneziaWG peer public key.";
      };
      presharedKey = mkOption {
        type = optionalString;
        default = null;
        description = "Inline peer preshared key. Prefer presharedKeyFile for secrets.";
      };
      presharedKeyFile = mkOption {
        type = optionalString;
        default = null;
        description = "Runtime path containing the peer preshared key.";
      };
      allowedIPs = mkOption {
        type = types.listOf types.str;
        description = "IP prefixes routed to and accepted from this peer.";
        example = [
          "0.0.0.0/0"
          "::/0"
        ];
      };
      endpoint = mkOption {
        type = optionalString;
        default = null;
        example = "vpn.example.com:51820";
        description = "Optional peer endpoint in host:port form.";
      };
      persistentKeepalive = mkOption {
        type = optionalRange;
        default = null;
        description = "Persistent keepalive seconds, optionally expressed as an AWG 3 range.";
      };
      advancedSecurity = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Optional AWG peer AdvancedSecurity setting.";
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
        headerProtectionKey = "Inline AWG 3 header-protection key. Prefer headerProtectionKeyFile.";
        headerProtectionKeyFile = "Runtime path containing the AWG 3 header-protection key.";
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
        description = "IP prefixes assigned to the AWG interface.";
        example = [ "10.8.0.2/32" ];
      };
      dns = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "DNS servers installed while this profile is active.";
      };
      privateKey = mkOption {
        type = optionalString;
        default = null;
        description = "Inline client private key. Prefer privateKeyFile.";
      };
      privateKeyFile = mkOption {
        type = optionalString;
        default = null;
        description = "Runtime path containing the client private key.";
      };
      listenPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Optional local UDP listen port.";
      };
      mtu = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Optional interface MTU.";
      };
      table = mkOption {
        type = optionalString;
        default = null;
        description = "wg-quick routing table name/number, auto, or off.";
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
          Runtime path to a partial JSON object using the same field names and
          value types as obfuscation, excluding headerProtectionKeyFile.
          Values are combined with public obfuscation settings at service startup
          without putting the file contents in the Nix store. Omitted or null
          fields are unset; duplicate JSON keys and fields set in both sources
          are rejected. A file-provided headerProtectionKey also conflicts with
          obfuscation.headerProtectionKeyFile. Private and preshared keys use
          their existing file options. Restart the profile after secret rotation.
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
          description = "Linux interface name. It must fit Linux's 15-character limit.";
        };
        autostart = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to start this profile at boot. At most one profile may autostart.";
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
            Make the profile a proxy outbound tagged with its name instead of a global profile. It then
            always runs, leaves the host's routes and resolver alone, and is not listed by
            `proxy-ctl awg`. Requires proxy.enable.
            - "singBox": a WireGuard endpoint in its own sing-box process, reached as a loopback SOCKS
              hop. sing-box speaks plain WireGuard: AmneziaWG obfuscation is dropped with a warning.
            - "userspace": the same hop served by wireproxy on AmneziaWG's userspace implementation, so
              obfuscation works. It needs no interface or root: the only AmneziaWG mode on
              home-manager and nix-on-droid. A declared or profile ListenPort is used as is. An
              Endpoint hostname resolves through the system resolver: give an address where that
              resolver cannot reach the name.
            - "interface": the AmneziaWG interface comes up without routes (Table = off), and the
              outbound binds to it, so obfuscation works. With the sing-box backend its DNS goes
              through the interface too (proxy.dns.remote); XRay resolves as usual.
            Either way the tunnel itself reaches the peer over the uplink, past TUN and TProxy.
          '';
        };
        endpoint = endpoint "host:port (IPv6 in brackets) that replaces the first peer's Endpoint when the profile is prepared.";
        allowConfigHooks = mkOption {
          type = types.bool;
          default = false;
          description = "Allow trusted imported configs to execute wg-quick hooks or use SaveConfig.";
        };
        vpnContainer = mkOption {
          type = optionalString;
          default = null;
          description = "AWG container/protocol identifier to select when a vpn:// bundle is ambiguous.";
        };
        configFile = mkOption {
          type = optionalString;
          default = null;
          description = "Runtime path to an AmneziaWG .conf file.";
        };
        vpnFile = mkOption {
          type = optionalString;
          default = null;
          description = "Runtime path containing a self-contained vpn:// export.";
        };
        vpn = mkOption {
          type = optionalString;
          default = null;
          description = "Inline self-contained vpn:// export. This value is stored in the Nix store.";
        };
        settings = mkOption {
          type = types.nullOr settingsType;
          default = null;
          description = "Typed declarative AmneziaWG client configuration.";
        };
      };
    }
  );
in
{
  inherit profileType obfuscationType;
}
