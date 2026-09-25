# proxy-suite options

Generated from the `services.proxy-suite` option descriptions under
[`modules/proxy-suite/options/`](/modules/proxy-suite/options/).
Update the module option docs there instead of editing these files by hand.

## Option groups

| Group | What it covers |
|---|---|
| [proxy](./proxy.md) | The local proxy: outbounds, subscriptions, selection, routing, DNS, TUN and TProxy. |
| [killSwitch](./killSwitch.md) | Block traffic outside the global tunnel. |
| [perAppRouting](./perAppRouting.md) | Route single apps through proxychains, a per-app TUN or TProxy, or zapret. |
| [zapret](./zapret.md) | DPI bypass without a proxy: zapret-discord-youtube or zapret2. |
| [amneziaWg](./amneziaWg.md) | AmneziaWG client profiles, as a global VPN or as outbounds. |
| [warp](./warp.md) | Cloudflare WARP, as an outbound or an AmneziaWG profile. |
| [tor](./tor.md) | Tor as an outbound, with bridges, and an onion service for the inbounds. |
| [sshProxy](./sshProxy.md) | An SSH SOCKS5 tunnel, optionally as an outbound. |
| [tgWsProxy](./tgWsProxy.md) | A Telegram MTProto proxy over WebSocket. |
| [whitelistBypass](./whitelistBypass.md) | Tunnels through video-call servers, past mobile internet whitelists. |
| [inbounds](./inbounds.md) | Server side: listeners for remote clients, share links, subscriptions and stats. |
| [geodata](./geodata.md) | Geosite and geoip databases used by routing. |
| [userControl](./userControl.md) | Let a group use `proxy-ctl` without root. |
| [gui](./gui.md) | The desktop app with a tray icon. |
| [tui](./tui.md) | The `proxy-tui` terminal UI. |

<a id="services-proxy-suite-enable"></a>
## services\.proxy-suite\.enable

Whether to enable proxy-suite\.

**Type:** boolean\
**Default:** `false`

## Complete default config

<details>
<summary>Every option at its default</summary>

```nix
services.proxy-suite = {
  amneziaWg = {
    enable = false;
    kernelModulePackage = pkgs.amneziawg;
    profiles = { };
    toolsPackage = pkgs.amneziawg-tools;
    userspacePackage = pkgs.amneziawg-go;
    wireproxyPackage = pkgs.wireproxy-awg;
  };
  enable = false;
  geodata = {
    singBox = {
      geoip = pkgs.sing-geoip;
      geosite = pkgs.sing-geosite;
    };
    xray = {
      assets = pkgs.v2ray-rules-dat;
    };
  };
  gui = {
    autostart = true;
    enable = false;
    refreshInterval = 3;
  };
  inbounds = {
    enable = false;
    listeners = { };
    openFirewall = true;
    package = pkgs.xray;
    routing = {
      blockPrivate = true;
      blockRu = true;
      proxy = {
        domains = [ ];
        geoips = [ ];
        geosites = [ ];
        ips = [ ];
      };
      via = "proxy";
      zapretDirect = true;
    };
    serverAddress = null;
    shareLinks = true;
    subscriptions = {
      baseUrl = null;
      enable = false;
      group = "nginx";
    };
  };
  killSwitch = {
    enable = false;
  };
  perAppRouting = {
    createDefaultProfiles = false;
    enable = false;
    profiles = [ ];
    proxychains = {
      enable = false;
      proxyDns = true;
      quiet = true;
    };
    tproxy = {
      enable = false;
      fwmark = 17;
      localSubnets = [
        "192.168.0.0/16"
      ];
      routeTable = 102;
    };
    tun = {
      address = "172.20.0.1/30";
      enable = false;
      fwmark = 16;
      interface = "psperapptun0";
      localSubnets = [
        "192.168.0.0/16"
      ];
      mtu = 1400;
      routeTable = 101;
    };
    zapret = {
      enable = false;
      filterMark = 268435456;
      qnum = 201;
    };
  };
  proxy = {
    autoProxy = {
      enable = false;
      exclude = [ ];
      interval = "10m";
      maxExits = 12;
      probeBasePort = 18540;
      probesPerRun = 200;
      slowBelowKiBps = 150;
      ttlDays = 30;
    };
    autostart = null;
    backend = "sing-box";
    dns = {
      clientSubnet = null;
      fakeIp = {
        enable = false;
        inet4Range = "198.18.0.0/15";
      };
      local = {
        address = "1.1.1.1";
        port = 53;
        type = "tcp";
      };
      remote = {
        address = "1.1.1.1";
        port = 53;
        type = "udp";
      };
      singBox = {
        rules = [ ];
        servers = [ ];
      };
      strategy = null;
    };
    enable = false;
    ipv6 = true;
    listener = {
      address = "127.0.0.1";
      auth = {
        password = null;
        passwordFile = null;
        username = null;
      };
      port = 1080;
    };
    outbounds = [ ];
    routing = {
      block = {
        domains = [ ];
        geoips = [ ];
        geosites = [ ];
        ips = [ ];
        ruleSets = [ ];
      };
      default = "proxy";
      direct = {
        domains = [ ];
        geoips = [ ];
        geosites = [ ];
        ips = [ ];
        ruleSets = [ ];
      };
      directRu = true;
      proxy = {
        domains = [ ];
        geoips = [ ];
        geosites = [ ];
        ips = [ ];
        ruleSets = [ ];
      };
      ruleSetUpdateInterval = "1d";
      ruleSets = { };
      rules = [ ];
    };
    selection = "first";
    selectionExclude = [ ];
    singBox = {
      clashApiPort = 9090;
      package = pkgs.sing-box;
    };
    subscriptionUpdateInterval = "1d";
    subscriptions = [ ];
    tproxy = {
      enable = false;
      fwmark = 1;
      lanInterfaces = [ ];
      localSubnets = [
        "192.168.0.0/16"
      ];
      port = 1085;
      proxyMark = 2;
      routeTable = 100;
    };
    tun = {
      address = "172.19.0.1/30";
      enable = false;
      interface = "singtun0";
      mtu = 1400;
    };
    urlTest = {
      interval = "3m";
      tolerance = 50;
      url = "https://www.gstatic.com/generate_204";
    };
    xray = {
      package = pkgs.xray;
    };
  };
  sshProxy = {
    asOutbound = false;
    domainStrategy = null;
    enable = false;
    extraArgs = [ ];
    hostKey = [ ];
    hostKeyFile = null;
    identityFile = null;
    knownHostsFile = null;
    listener = {
      address = "127.0.0.1";
      port = 1091;
    };
    server = {
      host = null;
      port = 22;
      user = null;
    };
    serviceUser = "proxy-suite-daemon";
    strictHostKeyChecking = "accept-new";
  };
  tgWsProxy = {
    bufferKiB = 256;
    bypassTransparentProxy = true;
    cloudflare = {
      domains = [ ];
      fallback = true;
      workerDomains = [ ];
    };
    dcIps = { };
    enable = false;
    fakeTlsDomain = null;
    fwmark = 4;
    listener = {
      address = "127.0.0.1";
      port = 1443;
    };
    log = {
      file = null;
      keep = 1;
      maxSizeMiB = 5.0;
      verbose = false;
    };
    poolSize = 4;
    proxyProtocol = false;
    secret = null;
    secretFile = null;
  };
  tor = {
    asOutbound = false;
    bridges = {
      file = null;
      lines = [ ];
    };
    clientOnly = true;
    enable = false;
    extraConfig = "";
    lyrebirdPackage = pkgs.lyrebird;
    onionService = {
      enable = false;
      listeners = null;
      secretKeyFile = null;
    };
    package = pkgs.tor;
    routeOnion = true;
    snowflakePackage = pkgs.snowflake;
    socksPort = 18530;
    upstream = "direct";
  };
  tui = {
    enable = true;
  };
  userControl = {
    enable = false;
    group = "proxy-suite";
    scopes = [ ];
  };
  warp = {
    asAmneziaWg = false;
    asOutbound = null;
    configFile = null;
    enable = false;
    endpoint = null;
    generatorUrl = null;
  };
  whitelistBypass = {
    creators = { };
    enable = false;
    joiners = { };
    package = pkgs.whitelist-bypass;
  };
  zapret = {
    cidrExemption = {
      cidrs = [ ];
      enable = false;
    };
    directSync = {
      enable = true;
      upstreamIps = false;
      userIps = true;
    };
    enable = false;
    engine = "zapret-discord-youtube";
    zapret-discord-youtube = {
      configName = "general(ALT)";
      domains = [ ];
      excludeDomains = [ ];
      excludeIps = [ ];
      gameFilter = "null";
      hostlistRules = [ ];
      includeExtraUpstreamLists = false;
      ips = [ ];
    };
    zapret2 = {
      autoHostlist = {
        debugLog = false;
        enable = true;
        failThreshold = 3;
        failTime = 300;
        incomingMaxseq = 4096;
        retransMaxseq = 32768;
        retransReset = true;
        retransThreshold = 3;
        udpIn = 1;
        udpOut = 4;
      };
      blobs = { };
      cutoff = {
        enable = true;
        proxyFallback = true;
      };
      domains = [ ];
      excludeDomains = [ ];
      ipv6 = false;
      ports = {
        tcp = null;
        udp = null;
      };
      profiles = null;
      strategySource = "nfqws2-keenetic";
    };
  };
};
```

</details>
