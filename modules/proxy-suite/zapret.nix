# zapret DPI bypass configuration + optional CIDR exemption from NFQUEUE
{
  lib,
  pkgs,
  cfg,
  zapret,
  perAppZapretRulesFile,
  nft,
}:

let
  zapretCfg = cfg.zapret;
  perAppZapretCfg = zapretCfg.perApp;

  iptables = "${pkgs.iptables}/bin/iptables";

  runtimeDeps = lib.attrValues {
    inherit (pkgs)
      iptables
      ipset
      nftables
      coreutils
      gawk
      curl
      wget
      bash
      kmod
      findutils
      gnused
      gnugrep
      procps
      util-linux
      ;
  };

  hostlistRuleNames = map (rule: rule.name) zapretCfg.hostlistRules;

  baseZapretPackage =
    let
      upstreamPackages = zapret.packages.${pkgs.stdenv.hostPlatform.system};
    in
    if upstreamPackages ? zapret then upstreamPackages.zapret else upstreamPackages.default;
  mkOptionalHostlistFile =
    fileName: entries:
    if entries != [ ] then
      pkgs.writeText fileName (lib.concatStringsSep "\n" entries + "\n")
    else
      null;

  listGeneralFile = mkOptionalHostlistFile "proxy-suite-zapret-list-general-user.txt" zapretCfg.listGeneral;
  listExcludeFile = mkOptionalHostlistFile "proxy-suite-zapret-list-exclude-user.txt" zapretCfg.listExclude;
  ipsetAllFile = mkOptionalHostlistFile "proxy-suite-zapret-ipset-all.txt" zapretCfg.ipsetAll;
  ipsetExcludeFile = mkOptionalHostlistFile "proxy-suite-zapret-ipset-exclude-user.txt" zapretCfg.ipsetExclude;

  hostlistRuleSpec = pkgs.writeText "proxy-suite-zapret-hostlist-rules.json" (
    builtins.toJSON {
      includeExtraUpstreamLists = zapretCfg.includeExtraUpstreamLists;
      entries = map (rule: {
        inherit (rule)
          name
          preset
          nfqwsArgs
          ;
      }) zapretCfg.hostlistRules;
    }
  );

  selectedConfigName = lib.strings.sanitizeDerivationName zapretCfg.configName;
  patchConfigScriptSrc = builtins.path {
    path = ../../scripts/patch-zapret-config.py;
    name = "patch-zapret-config.py";
  };
  patchConfigScript = "${pkgs.python3}/bin/python3 ${patchConfigScriptSrc}";

  mkGlobalBypassScript =
    filterMark:
    pkgs.writeText "proxy-suite-zapret-global-bypass.sh" ''
      zapret_custom_firewall_nft() {
        nft insert rule inet $ZAPRET_NFT_TABLE postrouting mark and ${filterMark} != 0 return comment "proxy-suite per-app-zapret bypass"
        nft insert rule inet $ZAPRET_NFT_TABLE postnat mark and ${filterMark} != 0 return comment "proxy-suite per-app-zapret bypass"
        nft insert rule inet $ZAPRET_NFT_TABLE prerouting mark and ${filterMark} != 0 return comment "proxy-suite per-app-zapret bypass"
        nft insert rule inet $ZAPRET_NFT_TABLE prenat mark and ${filterMark} != 0 return comment "proxy-suite per-app-zapret bypass"
      }
    '';

  mkDerivedZapretPackage =
    {
      packageName,
      pidDir,
      configName ? zapretCfg.configName,
      gameFilter ? zapretCfg.gameFilter,
      forceDisableFilterMark ? false,
      filterMark ? null,
      qnum ? null,
      modeFilter ? null,
      desyncMark ? null,
      desyncMarkPostnat ? null,
      nftTable ? null,
      customScript ? null,
    }:
    pkgs.runCommand packageName
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnused
          python3
        ];
      }
      ''
        set -euo pipefail

        mkdir -p "$out"
        cp -a ${baseZapretPackage}/. "$out/"
        chmod -R u+w "$out/opt/zapret" "$out/bin"

        find "$out/opt/zapret/configs" -type f -exec ${pkgs.gnused}/bin/sed -i \
          -e 's|${baseZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
          {} \;
        find "$out/opt/zapret/hostlists" -type f -exec ${pkgs.gnused}/bin/sed -i \
          -e 's|${baseZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
          {} \;

        if [ -f "$out/opt/zapret/configs/${configName}" ]; then
          cp "$out/opt/zapret/configs/${configName}" "$out/opt/zapret/config"
        else
          echo "proxy-suite: zapret config '${configName}' not found in curated package" >&2
          ls -la "$out/opt/zapret/configs" >&2 || true
          exit 1
        fi

        ${pkgs.gnused}/bin/sed -i \
          -e 's|${baseZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
          "$out/opt/zapret/config"

        ${pkgs.gnused}/bin/sed -i \
          -e 's|^PIDDIR=.*$|PIDDIR=${pidDir}|' \
          "$out/opt/zapret/init.d/sysv/functions"

        append_list_file() {
          local target="$1"
          local extra_file="$2"
          local tmp="$out/opt/zapret/hostlists/$target.tmp"
          cat "$out/opt/zapret/hostlists/$target" > "$tmp"
          ${pkgs.gnused}/bin/sed -i -e '$a\' "$tmp"
          cat "$extra_file" >> "$tmp"
          mv "$tmp" "$out/opt/zapret/hostlists/$target"
        }

        set_config_var() {
          local key="$1"
          local value="$2"
          if grep -Eq "^[#[:space:]]*$key=" "$out/opt/zapret/config"; then
            ${pkgs.gnused}/bin/sed -Ei "s|^[#[:space:]]*$key=.*$|$key=$value|" "$out/opt/zapret/config"
          else
            printf '\n%s=%s\n' "$key" "$value" >> "$out/opt/zapret/config"
          fi
        }

        ${lib.concatMapStrings
          ({ name, file }: lib.optionalString (file != null) ''
            append_list_file ${name} ${file}
          '')
          [
            { name = "list-general-user.txt";  file = listGeneralFile; }
            { name = "list-exclude-user.txt";  file = listExcludeFile; }
            { name = "ipset-all.txt";          file = ipsetAllFile; }
            { name = "ipset-exclude-user.txt"; file = ipsetExcludeFile; }
          ]}

        rm -f "$out/opt/zapret/hostlists/.game_filter.enabled"
        ${lib.optionalString (gameFilter != "null") ''
          echo "${gameFilter}" > "$out/opt/zapret/hostlists/.game_filter.enabled"
        ''}

        ${lib.concatMapStrings (
          rule:
          let
            domainsFile = pkgs.writeText "proxy-suite-zapret-hostlist-${rule.name}.txt" (
              lib.concatStringsSep "\n" (lib.unique rule.domains) + "\n"
            );
          in
          ''
            cp ${domainsFile} "$out/opt/zapret/hostlists/list-${rule.name}.txt"
          ''
        ) zapretCfg.hostlistRules}

        ${patchConfigScript} --config "$out/opt/zapret/config" --spec ${hostlistRuleSpec}

        ${lib.optionalString forceDisableFilterMark ''
          set_config_var FILTER_MARK ""
        ''}
        ${lib.concatMapStrings
          ({ var, value }: lib.optionalString (value != null) ''
            hex=$(printf '0x%x' ${toString value})
            set_config_var ${var} "$hex"
          '')
          [
            { var = "FILTER_MARK";         value = filterMark; }
            { var = "DESYNC_MARK";         value = desyncMark; }
            { var = "DESYNC_MARK_POSTNAT"; value = desyncMarkPostnat; }
          ]}
        ${lib.optionalString (qnum != null) ''
          set_config_var QNUM ${toString qnum}
        ''}
        ${lib.optionalString (modeFilter != null) ''
          set_config_var MODE_FILTER ${modeFilter}
        ''}
        ${lib.optionalString (nftTable != null) ''
          set_config_var ZAPRET_NFT_TABLE ${nftTable}
        ''}

        ${lib.optionalString (customScript != null) ''
          mkdir -p "$out/opt/zapret/init.d/sysv/custom.d"
          cp ${customScript} "$out/opt/zapret/init.d/sysv/custom.d/50-proxy-suite-custom.sh"
          chmod +x "$out/opt/zapret/init.d/sysv/custom.d/50-proxy-suite-custom.sh"
        ''}
      '';

  globalZapretPackage = mkDerivedZapretPackage {
    packageName = "proxy-suite-zapret-${selectedConfigName}";
    pidDir = "/run/proxy-suite-zapret";
    gameFilter = zapretCfg.gameFilter;
    forceDisableFilterMark = true;
    customScript = if perAppZapretCfg.enable then mkGlobalBypassScript (toString perAppZapretCfg.filterMark) else null;
  };

  perAppZapretPackage = mkDerivedZapretPackage {
    packageName = "proxy-suite-per-app-zapret-${selectedConfigName}";
    pidDir = "/run/proxy-suite-per-app-zapret";
    gameFilter = "all";
    filterMark = perAppZapretCfg.filterMark;
    qnum = perAppZapretCfg.qnum;
    modeFilter = "none";
    desyncMark = 134217728;
    desyncMarkPostnat = 67108864;
    nftTable = "proxy_suite_per_app_zapret";
  };

  zapretCommonPreStart = package: ''
    ${package}/opt/zapret/init.d/sysv/zapret stop || true

    ${lib.getExe' pkgs.kmod "modprobe"} xt_NFQUEUE 2>/dev/null || true
    ${lib.getExe' pkgs.kmod "modprobe"} xt_connbytes 2>/dev/null || true
    ${lib.getExe' pkgs.kmod "modprobe"} xt_multiport 2>/dev/null || true

    if ! ${pkgs.ipset}/bin/ipset list nozapret >/dev/null 2>&1; then
      ${pkgs.ipset}/bin/ipset create nozapret hash:net
    fi
  '';

  mkZapretEnv = package: [
    "ZAPRET_BASE=${package}/opt/zapret"
    "PATH=${lib.makeBinPath runtimeDeps}"
  ];
  globalZapretEnv = mkZapretEnv globalZapretPackage;
  perAppZapretEnv    = mkZapretEnv perAppZapretPackage;

  perAppZapretMarkUpScript = pkgs.writeShellScript "proxy-suite-per-app-zapret-mark-up" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_zapret_mark 2>/dev/null || true
    ${nft} -f ${perAppZapretRulesFile}
  '';

  perAppZapretMarkDownScript = pkgs.writeShellScript "proxy-suite-per-app-zapret-mark-down" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_zapret_mark 2>/dev/null || true
  '';

  exemptStart = lib.concatMapStrings (cidr: ''
    ${iptables} -t mangle -I FORWARD     1 -d ${cidr} -j RETURN
    ${iptables} -t mangle -I POSTROUTING 1 -s ${cidr} -j RETURN
  '') zapretCfg.cidrExemption.cidrs;

  exemptStop = lib.concatMapStrings (cidr: ''
    ${iptables} -t mangle -D FORWARD     -d ${cidr} -j RETURN || true
    ${iptables} -t mangle -D POSTROUTING -s ${cidr} -j RETURN || true
  '') zapretCfg.cidrExemption.cidrs;
in
{
  assertions = [
    {
      assertion = builtins.length hostlistRuleNames == builtins.length (lib.unique hostlistRuleNames);
      message = "proxy-suite: zapret.hostlistRules names must be unique";
    }
    {
      assertion = builtins.all (rule: rule.domains != [ ]) zapretCfg.hostlistRules;
      message = "proxy-suite: each zapret.hostlistRules entry must define at least one domain";
    }
    {
      assertion = builtins.all (rule: rule.preset != null || rule.nfqwsArgs != [ ]) zapretCfg.hostlistRules;
      message = "proxy-suite: each zapret.hostlistRules entry must set preset, nfqwsArgs, or both";
    }
  ];

  environment.systemPackages =
    lib.mkBefore (
      [ globalZapretPackage ] ++ lib.optionals perAppZapretCfg.enable [ perAppZapretPackage ]
    );

  systemd.services.zapret-discord-youtube = {
    description = "zapret DPI bypass";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    preStart = zapretCommonPreStart globalZapretPackage;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "proxy-suite-zapret";
      ExecStart = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret start";
      ExecStop = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
      ExecReload = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret restart";
      Environment = globalZapretEnv;
    };
  };

  systemd.services.proxy-suite-per-app-zapret = lib.mkIf perAppZapretCfg.enable {
    description = "proxy-suite per-app-routing zapret backend";
    after = [ "network.target" ];
    conflicts = [
      "proxy-suite-tproxy.service"
      "proxy-suite-tun.service"
    ];
    preStart = zapretCommonPreStart perAppZapretPackage;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "proxy-suite-per-app-zapret";
      ExecStartPre = "${perAppZapretMarkUpScript}";
      ExecStart = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret start";
      ExecStop = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
      ExecStopPost = "${perAppZapretMarkDownScript}";
      Environment = perAppZapretEnv;
    };
  };

  systemd.services.proxy-suite-zapret-vm-exempt = lib.mkIf zapretCfg.cidrExemption.enable {
    description = "Exempt CIDRs from zapret NFQUEUE";
    after = [ "zapret-discord-youtube.service" ];
    wants = [ "zapret-discord-youtube.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "proxy-suite-zapret-vm-exempt-start" exemptStart;
      ExecStop = pkgs.writeShellScript "proxy-suite-zapret-vm-exempt-stop" exemptStop;
    };
  };
}
