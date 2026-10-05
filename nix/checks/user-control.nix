{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
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
  # The primary group routes; proxy-admins may do anything, proxy-users what is listed.
  multiGroupFixture = mkFixture {
    enable = true;
    scopes = [ "routing" ];
    groups = {
      proxy-admins.scopes = [ ];
      proxy-users.scopes = [
        "perApp"
        "outbounds"
      ];
    };
  };
  disabledFixture = mkFixture { };
  scopesWithoutEnableFixture = mkFixture { scopes = [ "routing" ]; };
  groupsWithoutEnableFixture = mkFixture { groups.proxy-users.scopes = [ "routing" ]; };
  primaryInGroupsFixture = mkFixture {
    enable = true;
    groups.proxy-suite.scopes = [ "routing" ];
  };

  polkitConfig = fixture: fixture.config.security.polkit.extraConfig;
  service = fixture: name: fixture.config.systemd.services.${name}.serviceConfig;
  hasUnit = fixture: name: fixture.config.systemd.services ? ${name};
  failedAssertion =
    fixture: text: builtins.any (a: !a.assertion && hasInfix text a.message) fixture.config.assertions;
  wrapperEnv = fixture: (mkProxyCtlDerived fixture).proxyCtl.proxySuiteCheck.wrapperEnv;

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
      # No scopes listed: every one of them, spelled out.
      assert hasInfix "var groupScopes = {\"proxy-suite\":[\"services\",\"perApp\"," (
        polkitConfig allFixture
      );
      assert hasInfix "subject.isInGroup(\"proxy-suite\")" (polkitConfig allFixture);
      assert hasInfix "\"proxy-suite-zapret2-cutoff.\":\"zapret\"" (polkitConfig allFixture);
      # Declared units by name: systemd asks polkit the same question, with the same unit
      # name, for a transient unit, so a prefix match would run any command as root.
      assert hasInfix "\"proxy-suite-socks.service\"" (polkitConfig allFixture);
      assert hasInfix "\"proxy-suite-per-app-tun-user@\"" (polkitConfig allFixture);
      assert !(hasInfix "unit.indexOf(\"proxy-suite-\") === 0 ?" (polkitConfig allFixture));
      # Only start, stop and the like: not set-property, kill or clean.
      assert hasInfix "\"reload-or-try-restart\",\"reset-failed\"].indexOf(verb)" (
        polkitConfig allFixture
      );
      assert !(hasInfix "\"set-property\"" (polkitConfig allFixture));
      # A user's per-app marking is theirs alone.
      assert hasInfix "if (owner !== uid)" (polkitConfig allFixture);
      assert hasInfix ''"proxy-suite-per-app-via-user@" ? instance.split("-")[0]'' (
        polkitConfig allFixture
      );
      # What every user's apps share a member brings up, never down or through a restart:
      # that would send the other users' apps out unmarked. Their own marking, either way.
      assert hasInfix
        ''if (scope === "perApp" && !own && ["start","reset-failed"].indexOf(verb) === -1) {''
        (polkitConfig allFixture);
      assert hasInfix "    own = true;\n  }\n  known = true;" (polkitConfig allFixture);
      assert hasInfix "\"proxy-suite-per-app-\":\"perApp\"" (polkitConfig allFixture);
      assert groupReadsSecrets allFixture;
      assert hasInfix "chown proxy-suite-daemon:proxy-suite \"$backend_config\"" (socksStart allFixture);
      assert
        autoProxyGroups allFixture == [
          "proxy-suite"
          "proxy-suite"
          "proxy-suite"
        ];
      # The state is root's to write, the group's to read; what members ask for goes to a
      # sticky spool beside it, where no member takes away another's request.
      assert (service allFixture "proxy-suite-autoproxy").StateDirectoryMode == "0751";
      assert builtins.elem "d /var/lib/proxy-suite/autoproxy-requests 3770 root proxy-suite -" (
        allFixture.config.systemd.tmpfiles.rules
      );
      # Root removes what members queued in that group-writable spool: nothing else changes.
      assert builtins.all
        (
          unit:
          let
            c = service allFixture unit;
          in
          c.ProtectSystem == "strict"
          && c.ProtectHome
          && c.PrivateTmp
          && c.ReadWritePaths == [ "-/var/lib/proxy-suite/autoproxy-requests" ]
        )
        [
          "proxy-suite-autoproxy"
          "proxy-suite-autoproxy-learn"
          "proxy-suite-autoproxy-sample"
        ];
      # An install from before the spool is made root's before the socks start writes there.
      assert hasInfix
        "-proxy-suite-autoproxy-migrate \"$AUTOPROXY_DIR\" /var/lib/proxy-suite/autoproxy-requests"
        (socksStart allFixture);
      assert (wrapperEnv allFixture).AUTOPROXY_SPOOL_DIR == "/var/lib/proxy-suite/autoproxy-requests";
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
      assert hasInfix "var groupScopes = {\"proxy-suite\":[\"routing\"]};" (
        polkitConfig routingOnlyFixture
      );
      assert rootOnlySecrets routingOnlyFixture;
      assert
        autoProxyGroups routingOnlyFixture == [
          null
          null
          null
        ];
      assert (service routingOnlyFixture "proxy-suite-autoproxy").StateDirectoryMode == "0751";
      assert builtins.elem "d /var/lib/proxy-suite/autoproxy-requests 0700 root root -" (
        routingOnlyFixture.config.systemd.tmpfiles.rules
      );
      assert builtins.elem "d /var/lib/proxy-suite/outbounds.d 0700 root root -" (
        routingOnlyFixture.config.systemd.tmpfiles.rules
      );
      true
    )

    # -- userControl.groups: each group its own scopes, the files opened through ACLs --
    (
      let
        fixture = multiGroupFixture;
        polkit = polkitConfig fixture;
        start = socksStart fixture;
        acls = fixture.config.systemd.services.proxy-suite-acls.script;
        derived = import ../../modules/proxy-suite/derived.nix {
          inherit (pkgs) lib;
          cfg = fixture.config.services.proxy-suite;
        };
      in
      assert fixture.config.users.groups ? "proxy-admins";
      assert fixture.config.users.groups ? "proxy-users";
      assert hasInfix
        "subject.isInGroup(\"proxy-admins\") || subject.isInGroup(\"proxy-suite\") || subject.isInGroup(\"proxy-users\")"
        polkit;
      assert hasInfix "\"proxy-suite\":[\"routing\"],\"proxy-users\":[\"perApp\",\"outbounds\"]}" polkit;
      assert hasInfix "\"proxy-admins\":[\"services\",\"perApp\"," polkit;
      # outbounds.d: the primary group lacks the scope, so root owns it and the mode keeps
      # the ACL mask open for those that hold it.
      assert builtins.elem "d /var/lib/proxy-suite/outbounds.d 2770 root root -" (
        fixture.config.systemd.tmpfiles.rules
      );
      # -n: the mask stays each file's group bits, so a 0600 file stays closed to them.
      assert hasInfix
        "setfacl -R -P -n -m g:proxy-admins:rwX,d:g:proxy-admins:rwX,g:proxy-users:rwX,d:g:proxy-users:rwX -- /var/lib/proxy-suite/outbounds.d"
        acls;
      # What was granted before goes first: a dropped group loses its access.
      assert hasInfix "setfacl -R -P -b -- /var/lib/proxy-suite/outbounds.d" acls;
      assert (service fixture "proxy-suite-acls").ProtectSystem == "strict";
      # autoProxy: proxy-admins only, the primary group not at all.
      assert
        autoProxyGroups fixture == [
          null
          null
          null
        ];
      assert (service fixture "proxy-suite-autoproxy").StateDirectoryMode == "0751";
      assert derived.userControlExtraGroupsFor "autoProxy" == [ "proxy-admins" ];
      # The state dir read through its own unit's ACLs; the spool written through
      # proxy-suite-acls', there before any autoProxy unit has run.
      assert pkgs.lib.hasSuffix "-proxy-suite-autoproxy-acl"
        (service fixture "proxy-suite-autoproxy").ExecStartPre;
      assert builtins.elem "d /var/lib/proxy-suite/autoproxy-requests 3770 root root -" (
        fixture.config.systemd.tmpfiles.rules
      );
      assert hasInfix
        "setfacl -R -P -n -m g:proxy-admins:rwX,d:g:proxy-admins:rwX -- /var/lib/proxy-suite/autoproxy-requests"
        acls;
      # Secrets to proxy-admins alone, still 600 for the primary group.
      assert hasInfix "chmod 600 \"$SHARE_TMP\"" start;
      assert hasInfix "setfacl -m g:proxy-admins:r -- \"$SHARE_TMP\"" start;
      assert !(hasInfix "g:proxy-users:r -- \"$SHARE_TMP\"" start);
      # The Clash API's secret stays root's; the broker answers the groups.
      assert hasInfix "chmod 600 \"$RUNTIME_DIR/clash-secret.tmp\"" start;
      # Nor in config.json, which the secrets scope reads: sing-box merges it in.
      assert !(hasInfix ".experimental.clash_api.secret = " start);
      assert hasInfix "chmod 400 \"$RUNTIME_DIR/clash-api.json.tmp\"" start;
      assert hasInfix "run -c \"$RUNTIME_DIR/config.json\" \"\${BACKEND_EXTRA_CONFIG[@]}\"" start;
      assert (service fixture "proxy-suite-clash-api").CapabilityBoundingSet == [ "" ];
      assert
        builtins.fromJSON (wrapperEnv fixture).USER_CONTROL_GROUPS == {
          proxy-admins = import ../../modules/proxy-suite/options/user-control-scopes.nix;
          proxy-suite = [ "routing" ];
          proxy-users = [
            "perApp"
            "outbounds"
          ];
        };
      assert (wrapperEnv fixture).CLASH_BROKER == "/run/proxy-suite-clash/api.sock";
      true
    )

    # -- userControl.groups: refused without enable, and never the primary group again --
    (ok (failedAssertion groupsWithoutEnableFixture "userControl.groups is set"))
    (ok (failedAssertion primaryInGroupsFixture "userControl.groups names must be group names"))

    # -- userControl: off by default, with no group, polkit rule or grants --
    (
      assert !(disabledFixture.config.users.groups ? "proxy-suite");
      assert !(hasInfix "subject.isInGroup(\"proxy-suite\")" (polkitConfig disabledFixture));
      assert !(hasInfix "org.freedesktop.systemd1.manage-units" (polkitConfig disabledFixture));
      assert rootOnlySecrets disabledFixture;
      assert !(hasUnit disabledFixture "proxy-suite-clash-api");
      # Only taking away what an earlier configuration granted.
      assert hasInfix "setfacl -R -P -b -- /var/lib/proxy-suite/outbounds.d" (
        disabledFixture.config.systemd.services.proxy-suite-acls.script
      );
      assert !(hasInfix " -m " disabledFixture.config.systemd.services.proxy-suite-acls.script);
      assert !((wrapperEnv disabledFixture) ? CLASH_BROKER);
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
