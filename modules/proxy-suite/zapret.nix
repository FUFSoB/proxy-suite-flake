# zapret DPI bypass configuration + optional CIDR exemption from NFQUEUE
{
  lib,
  pkgs,
  cfg,
  zapret,
}:

let
  z = cfg.zapret;

  iptables = "${pkgs.iptables}/bin/iptables";

  runtimeDeps = lib.attrValues {
    inherit (pkgs)
      iptables
      ipset
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

  hostlistRuleNames = map (rule: rule.name) z.hostlistRules;

  upstreamZapretPackage =
    let
      upstreamPackages = zapret.packages.${pkgs.system};
    in
    if upstreamPackages ? zapret then upstreamPackages.zapret else upstreamPackages.default;

  listGeneralFile =
    if z.listGeneral != [ ] then pkgs.writeText "proxy-suite-zapret-list-general-user.txt" (
      lib.concatStringsSep "\n" z.listGeneral + "\n"
    ) else null;

  listExcludeFile =
    if z.listExclude != [ ] then pkgs.writeText "proxy-suite-zapret-list-exclude-user.txt" (
      lib.concatStringsSep "\n" z.listExclude + "\n"
    ) else null;

  ipsetAllFile =
    if z.ipsetAll != [ ] then pkgs.writeText "proxy-suite-zapret-ipset-all.txt" (
      lib.concatStringsSep "\n" z.ipsetAll + "\n"
    ) else null;

  ipsetExcludeFile =
    if z.ipsetExclude != [ ] then pkgs.writeText "proxy-suite-zapret-ipset-exclude-user.txt" (
      lib.concatStringsSep "\n" z.ipsetExclude + "\n"
    ) else null;

  hostlistRuleSpec = pkgs.writeText "proxy-suite-zapret-hostlist-rules.json" (builtins.toJSON {
    includeExtraUpstreamLists = z.includeExtraUpstreamLists;
    entries = map (rule: {
      inherit (rule)
        name
        preset
        nfqwsArgs
        ;
    }) z.hostlistRules;
  });

  selectedConfigName = lib.strings.sanitizeDerivationName z.configName;
  patchConfigScriptSrc = builtins.path {
    path = ../../scripts/patch-zapret-config.py;
    name = "patch-zapret-config.py";
  };
  patchConfigScript = "${pkgs.python3}/bin/python3 ${patchConfigScriptSrc}";

  customZapretPackage = pkgs.runCommand "proxy-suite-zapret-${selectedConfigName}" {
    nativeBuildInputs = with pkgs; [
      coreutils
      gnused
      python3
    ];
  } ''
    set -euo pipefail

    mkdir -p "$out"
    cp -a ${upstreamZapretPackage}/. "$out/"
    chmod -R u+w "$out/opt/zapret" "$out/bin"

    find "$out/opt/zapret/configs" -type f -exec ${pkgs.gnused}/bin/sed -i \
      -e 's|${upstreamZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
      {} \;

    if [ -f "$out/opt/zapret/configs/${z.configName}" ]; then
      cp "$out/opt/zapret/configs/${z.configName}" "$out/opt/zapret/config"
    else
      echo "proxy-suite: zapret config '${z.configName}' not found in upstream package" >&2
      ls -la "$out/opt/zapret/configs" >&2 || true
      exit 1
    fi

    ${pkgs.gnused}/bin/sed -i \
      -e 's|${upstreamZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
      "$out/opt/zapret/config"

    append_list_file() {
      local target="$1"
      local extra_file="$2"
      local tmp="$out/opt/zapret/hostlists/$target.tmp"
      cat "$out/opt/zapret/hostlists/$target" > "$tmp"
      ${pkgs.gnused}/bin/sed -i -e '$a\' "$tmp"
      cat "$extra_file" >> "$tmp"
      mv "$tmp" "$out/opt/zapret/hostlists/$target"
    }

    ${lib.optionalString (listGeneralFile != null) ''
      append_list_file list-general-user.txt ${listGeneralFile}
    ''}

    ${lib.optionalString (listExcludeFile != null) ''
      append_list_file list-exclude-user.txt ${listExcludeFile}
    ''}

    ${lib.optionalString (ipsetAllFile != null) ''
      append_list_file ipset-all.txt ${ipsetAllFile}
    ''}

    ${lib.optionalString (ipsetExcludeFile != null) ''
      append_list_file ipset-exclude-user.txt ${ipsetExcludeFile}
    ''}

    rm -f "$out/opt/zapret/hostlists/.game_filter.enabled"
    ${lib.optionalString (z.gameFilter != "null") ''
      echo "${z.gameFilter}" > "$out/opt/zapret/hostlists/.game_filter.enabled"
    ''}

    ${lib.concatMapStrings (rule:
      let
        domainsFile = pkgs.writeText "proxy-suite-zapret-hostlist-${rule.name}.txt" (
          lib.concatStringsSep "\n" (lib.unique rule.domains) + "\n"
        );
      in
      ''
        cp ${domainsFile} "$out/opt/zapret/hostlists/list-${rule.name}.txt"
      ''
    ) z.hostlistRules}

    ${patchConfigScript} --config "$out/opt/zapret/config" --spec ${hostlistRuleSpec}
  '';

  exemptStart = lib.concatMapStrings (cidr: ''
    ${iptables} -t mangle -I FORWARD     1 -d ${cidr} -j RETURN
    ${iptables} -t mangle -I POSTROUTING 1 -s ${cidr} -j RETURN
  '') z.cidrExemption.cidrs;

  exemptStop = lib.concatMapStrings (cidr: ''
    ${iptables} -t mangle -D FORWARD     -d ${cidr} -j RETURN || true
    ${iptables} -t mangle -D POSTROUTING -s ${cidr} -j RETURN || true
  '') z.cidrExemption.cidrs;
in
{
  assertions = [
    {
      assertion = builtins.length hostlistRuleNames == builtins.length (lib.unique hostlistRuleNames);
      message = "proxy-suite: zapret.hostlistRules names must be unique";
    }
    {
      assertion = builtins.all (rule: rule.domains != [ ]) z.hostlistRules;
      message = "proxy-suite: each zapret.hostlistRules entry must define at least one domain";
    }
    {
      assertion = builtins.all (rule: rule.preset != null || rule.nfqwsArgs != [ ]) z.hostlistRules;
      message = "proxy-suite: each zapret.hostlistRules entry must set preset, nfqwsArgs, or both";
    }
  ];

  services.zapret-discord-youtube = {
    enable = true;
    configName = z.configName;
    gameFilter = z.gameFilter;
    listGeneral = z.listGeneral;
    listExclude = z.listExclude;
    ipsetAll = z.ipsetAll;
    ipsetExclude = z.ipsetExclude;
  };

  environment.systemPackages = lib.mkBefore [ customZapretPackage ];

  systemd.services.zapret-discord-youtube = {
    preStart = lib.mkForce ''
      ${customZapretPackage}/opt/zapret/init.d/sysv/zapret stop || true

      ${lib.getExe' pkgs.kmod "modprobe"} xt_NFQUEUE 2>/dev/null || true
      ${lib.getExe' pkgs.kmod "modprobe"} xt_connbytes 2>/dev/null || true
      ${lib.getExe' pkgs.kmod "modprobe"} xt_multiport 2>/dev/null || true

      if ! ${pkgs.ipset}/bin/ipset list nozapret >/dev/null 2>&1; then
        ${pkgs.ipset}/bin/ipset create nozapret hash:net
      fi
    '';

    serviceConfig = {
      ExecStart = lib.mkForce "${customZapretPackage}/opt/zapret/init.d/sysv/zapret start";
      ExecStop = lib.mkForce "${customZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
      ExecReload = lib.mkForce "${customZapretPackage}/opt/zapret/init.d/sysv/zapret restart";
      Environment = lib.mkForce [
        "ZAPRET_BASE=${customZapretPackage}/opt/zapret"
        "PATH=${lib.makeBinPath runtimeDeps}"
      ];
    };
  };

  systemd.services.proxy-suite-zapret-vm-exempt = lib.mkIf z.cidrExemption.enable {
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
