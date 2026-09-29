# proxy.groups and "failover" selection, as the module evaluates them. The start-time
# resolution itself is the outbound-disabled check (repo.nix); the watcher is proxy-ctl's.
{
  pkgs,
  checkLib,
  evalProxySuite,
  baseModule,
  rejects,
}:

let
  inherit (checkLib) startScript;

  grouped = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy = {
        selection = "failover";
        outbounds = [
          {
            tag = "second";
            url = "http://second.example.com:8080";
          }
        ];
        groups.pool.outbounds = [
          "primary"
          "second"
        ];
        priority.pool = 1;
        # A rule may name a group like any outbound.
        routing.rules = [
          {
            outbound = "pool";
            domains = [ "example.org" ];
          }
        ];
      };
    }
  ];
  script = startScript grouped;
in
{
  assertions = [
    # The watcher runs beside the socks backend, and the start script resolves the groups.
    (
      let
        unit = grouped.config.systemd.services.proxy-suite-outbound-groups;
      in
      assert builtins.elem "proxy-suite-socks.service" unit.bindsTo;
      assert pkgs.lib.hasInfix "proxy groups watch" unit.serviceConfig.ExecStart;
      assert pkgs.lib.hasInfix ''"outbounds":["primary","second"]'' script;
      assert pkgs.lib.hasInfix "interrupt_exist_connections:true" script;
      true
    )

    # Pure XRay has neither groups nor failover selection, nor the watcher.
    (rejects "proxy.groups requires proxy.backend" [
      {
        services.proxy-suite.proxy = {
          backend = pkgs.lib.mkForce "xray";
          groups.pool.outbounds = [ "primary" ];
        };
      }
    ])
    (rejects "proxy.selection = \"failover\" requires" [
      {
        services.proxy-suite.proxy = {
          backend = pkgs.lib.mkForce "xray";
          selection = "failover";
        };
      }
    ])
    (
      let
        xray = evalProxySuite [
          baseModule
          { services.proxy-suite.proxy.backend = pkgs.lib.mkForce "xray"; }
        ];
      in
      assert !(xray.config.systemd.services ? proxy-suite-outbound-groups);
      true
    )

    # A group takes a name of its own, and has members.
    (rejects "proxy.groups names must differ" [
      { services.proxy-suite.proxy.groups.primary.outbounds = [ "primary" ]; }
    ])
    (rejects "proxy.groups names must differ" [
      { services.proxy-suite.proxy.groups.direct.outbounds = [ "primary" ]; }
    ])
    (rejects "proxy.groups need members" [
      { services.proxy-suite.proxy.groups.empty = { }; }
    ])
    (rejects "proxy.groups names may hold only" [
      { services.proxy-suite.proxy.groups."a/b".outbounds = [ "primary" ]; }
    ])
  ];
}
