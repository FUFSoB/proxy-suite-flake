{
  mkBadFixture,
  mkFailingAssertions,
}:

{
  assertions = mkFailingAssertions mkBadFixture [
    # app TUN fwmark must not collide with global TProxy proxyMark.
    [
      {
        services.proxy-suite = {
          proxy.tproxy.proxyMark = 7;
          proxy.tun.perApp = {
            enable = true;
            fwmark = 7;
          };
          perAppRouting.enable = true;
        };
      }
    ]

    # app TProxy fwmark must not collide with global TProxy proxyMark.
    [
      {
        services.proxy-suite = {
          proxy.tproxy = {
            proxyMark = 8;
            perApp = {
              enable = true;
              fwmark = 8;
            };
          };
          perAppRouting.enable = true;
        };
      }
    ]

    # app TUN and TProxy backends must use distinct marks and route tables.
    [
      {
        services.proxy-suite = {
          proxy.tun.perApp = {
            enable = true;
            fwmark = 11;
          };
          proxy.tproxy.perApp = {
            enable = true;
            fwmark = 11;
          };
          perAppRouting.enable = true;
        };
      }
    ]
    [
      {
        services.proxy-suite = {
          proxy.tun.perApp = {
            enable = true;
            routeTable = 100;
          };
          proxy.tproxy.perApp = {
            enable = true;
            routeTable = 100;
          };
          perAppRouting.enable = true;
        };
      }
    ]

    # per-app zapret marks must not collide with TUN/TProxy marks.
    [
      {
        services.proxy-suite = {
          proxy.tun.perApp = {
            enable = true;
            fwmark = 12;
          };
          zapret.perApp = {
            enable = true;
            filterMark = 12;
          };
          perAppRouting.enable = true;
        };
      }
    ]
    [
      {
        services.proxy-suite = {
          proxy.tproxy.perApp = {
            enable = true;
            fwmark = 13;
          };
          zapret.perApp = {
            enable = true;
            filterMark = 13;
          };
          perAppRouting.enable = true;
        };
      }
    ]
  ];
}
