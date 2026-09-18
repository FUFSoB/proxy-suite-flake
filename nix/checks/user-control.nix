{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
}:

let
  inherit (checkLib) ok;
  inherit (pkgs.lib) hasInfix;

  mkFixture =
    userControl:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          perAppRouting = {
            enable = true;
            createDefaultProfiles = true;
            tun.enable = true;
          };
          proxy.autoProxy.enable = true;
          inherit userControl;
        };
      }
    ];

  allFixture = mkFixture { enable = true; };
  routingOnlyFixture = mkFixture {
    enable = true;
    scopes = [ "routing" ];
  };
  otherGroupFixture = mkFixture {
    enable = true;
    group = "vpnops";
  };
  disabledFixture = mkFixture { };
  scopesWithoutEnableFixture = mkFixture { scopes = [ "routing" ]; };

  polkitConfig = fixture: fixture.config.security.polkit.extraConfig;
  service = fixture: name: fixture.config.systemd.services.${name}.serviceConfig;

  # Every unit declaring the autoProxy state directory must carry the group, or
  # the next start chowns it back and `proxy auto list|queue` loses its read.
  autoProxyGroups =
    fixture:
    map (unit: (service fixture unit).Group or null) [
      "proxy-suite-autoproxy"
      "proxy-suite-autoproxy-learn"
      "proxy-suite-autoproxy-sample"
    ];

  socksStart =
    fixture:
    (import ./read-generated.nix).readDerivation (service fixture "proxy-suite-socks").ExecStart;

  groupReadsSecrets =
    fixture:
    let
      start = socksStart fixture;
    in
    hasInfix "chmod 440 \"$backend_config\"" start && hasInfix "chmod 640 \"$SHARE_TMP\"" start;
  rootOnlySecrets =
    fixture:
    let
      start = socksStart fixture;
    in
    hasInfix "chmod 640 \"$backend_config\"" start
    && hasInfix "chmod 600 \"$SHARE_TMP\"" start
    && !(hasInfix "g+r" start);
in
{
  assertions = [
    # -- userControl: enabled without scopes grants every scope --
    (
      assert allFixture.config.users.groups ? "proxy-suite";
      assert hasInfix "var scopes = [];" (polkitConfig allFixture);
      assert hasInfix "subject.isInGroup(\"proxy-suite\")" (polkitConfig allFixture);
      assert hasInfix "\"proxy-suite-zapret2-cutoff.\":\"zapret\"" (polkitConfig allFixture);
      assert groupReadsSecrets allFixture;
      assert hasInfix "chown proxy-suite-daemon:proxy-suite \"$backend_config\"" (socksStart allFixture);
      assert
        autoProxyGroups allFixture == [
          "proxy-suite"
          "proxy-suite"
          "proxy-suite"
        ];
      assert (service allFixture "proxy-suite-autoproxy").StateDirectoryMode == "0771";
      assert builtins.elem "d /var/lib/proxy-suite/outbounds.d 2770 root proxy-suite -" (
        allFixture.config.systemd.tmpfiles.rules
      );
      true
    )

    # -- userControl: the group name follows userControl.group --
    (
      assert
        autoProxyGroups otherGroupFixture == [
          "vpnops"
          "vpnops"
          "vpnops"
        ];
      assert hasInfix "subject.isInGroup(\"vpnops\")" (polkitConfig otherGroupFixture);
      true
    )

    # -- userControl: a listed scope grants only itself --
    (
      assert hasInfix "var scopes = [\"routing\"];" (polkitConfig routingOnlyFixture);
      assert rootOnlySecrets routingOnlyFixture;
      assert
        autoProxyGroups routingOnlyFixture == [
          null
          null
          null
        ];
      assert (service routingOnlyFixture "proxy-suite-autoproxy").StateDirectoryMode == "0751";
      assert builtins.elem "d /var/lib/proxy-suite/outbounds.d 0700 root root -" (
        routingOnlyFixture.config.systemd.tmpfiles.rules
      );
      true
    )

    # -- userControl: off by default, with no group, polkit rule or grants --
    (
      assert !(disabledFixture.config.users.groups ? "proxy-suite");
      assert !(hasInfix "subject.isInGroup(\"proxy-suite\")" (polkitConfig disabledFixture));
      assert !(hasInfix "org.freedesktop.systemd1.manage-units" (polkitConfig disabledFixture));
      assert rootOnlySecrets disabledFixture;
      assert
        autoProxyGroups disabledFixture == [
          null
          null
          null
        ];
      true
    )

    # -- userControl: scopes without enable is refused, not silently ignored --
    (ok (
      builtins.any (
        a: !a.assertion && hasInfix "userControl.scopes is set" a.message
      ) scopesWithoutEnableFixture.config.assertions
    ))
  ];
}
