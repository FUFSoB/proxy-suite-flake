# AmneziaWG profile option types.
{ lib }:

let
  inherit (lib) mkOption types;
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

  obfuscationType = types.submodule {
    options = {
      jc = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Junk packet count (Jc).";
      };
      jmin = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Minimum junk packet size (Jmin).";
      };
      jmax = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Maximum junk packet size (Jmax).";
      };
      s1 = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Handshake-init padding (S1).";
      };
      s2 = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Handshake-response padding (S2).";
      };
      s3 = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Cookie-reply padding (S3).";
      };
      s4 = mkOption {
        type = optionalUnsigned;
        default = null;
        description = "Transport-message padding (S4).";
      };
      h1 = mkOption {
        type = optionalRange;
        default = null;
        description = "Handshake-init header or range (H1).";
      };
      h2 = mkOption {
        type = optionalRange;
        default = null;
        description = "Handshake-response header or range (H2).";
      };
      h3 = mkOption {
        type = optionalRange;
        default = null;
        description = "Cookie-reply header or range (H3).";
      };
      h4 = mkOption {
        type = optionalRange;
        default = null;
        description = "Transport-message header or range (H4).";
      };
      i1 = mkOption {
        type = optionalString;
        default = null;
        description = "First custom signature packet (I1).";
      };
      i2 = mkOption {
        type = optionalString;
        default = null;
        description = "Second custom signature packet (I2).";
      };
      i3 = mkOption {
        type = optionalString;
        default = null;
        description = "Third custom signature packet (I3).";
      };
      i4 = mkOption {
        type = optionalString;
        default = null;
        description = "Fourth custom signature packet (I4).";
      };
      i5 = mkOption {
        type = optionalString;
        default = null;
        description = "Fifth custom signature packet (I5).";
      };
      headerProtectionKey = mkOption {
        type = optionalString;
        default = null;
        description = "Inline AWG 3 header-protection key. Prefer headerProtectionKeyFile.";
      };
      headerProtectionKeyFile = mkOption {
        type = optionalString;
        default = null;
        description = "Runtime path containing the AWG 3 header-protection key.";
      };
      contentPaddingAddition = mkOption {
        type = optionalRange;
        default = null;
        description = "AWG 3 content-padding addition or range.";
      };
      rekeyAfterTime = mkOption {
        type = optionalRange;
        default = null;
        description = "AWG 3 rekey interval or range.";
      };
      rekeyTimeout = mkOption {
        type = optionalRange;
        default = null;
        description = "AWG 3 rekey timeout or range.";
      };
      rejectAfterTime = mkOption {
        type = optionalRange;
        default = null;
        description = "AWG 3 reject-after interval or range.";
      };
      keepaliveTimeout = mkOption {
        type = optionalRange;
        default = null;
        description = "AWG 3 keepalive timeout or range.";
      };
      maxHandshakeAttempts = mkOption {
        type = optionalRange;
        default = null;
        description = "AWG 3 maximum handshake attempts or range.";
      };
      randomTrailers = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "AWG 3 random transport trailers (RandomTrailers).";
      };
      disableCookies = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "AWG 3 cookie suppression (DisableCookies).";
      };
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
  inherit
    profileType
    settingsType
    peerType
    obfuscationType
    rangeValue
    ;
}
