# Marks and route tables per-app routing must not share with the global backends. Each case
# names the assertion it expects, so a case that stops evaluating for another reason fails.
{ rejects }:

{
  assertions = [
    (rejects "perAppRouting.tun.fwmark must differ from proxy.tproxy.proxyMark" [
      {
        services.proxy-suite = {
          proxy.tproxy = {
            enable = true;
            proxyMark = 7;
          };
          perAppRouting = {
            enable = true;
            tun = {
              enable = true;
              fwmark = 7;
            };
          };
        };
      }
    ])
    (rejects "perAppRouting.tproxy.fwmark must differ from proxy.tproxy.proxyMark" [
      {
        services.proxy-suite = {
          proxy.tproxy = {
            enable = true;
            proxyMark = 8;
          };
          perAppRouting = {
            enable = true;
            tproxy = {
              enable = true;
              fwmark = 8;
            };
          };
        };
      }
    ])
    (rejects "perAppRouting.tun.fwmark and perAppRouting.tproxy.fwmark must differ" [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          tun = {
            enable = true;
            fwmark = 11;
          };
          tproxy = {
            enable = true;
            fwmark = 11;
          };
        };
      }
    ])
    (rejects "perAppRouting.tun.routeTable and perAppRouting.tproxy.routeTable must differ" [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          tun = {
            enable = true;
            routeTable = 100;
          };
          tproxy = {
            enable = true;
            routeTable = 100;
          };
        };
      }
    ])
    (rejects "perAppRouting.tun.fwmark and perAppRouting.zapret.filterMark must differ" [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          tun = {
            enable = true;
            fwmark = 12;
          };
          zapret = {
            enable = true;
            filterMark = 12;
          };
        };
      }
    ])
    (rejects "perAppRouting.tproxy.fwmark and perAppRouting.zapret.filterMark must differ" [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          tproxy = {
            enable = true;
            fwmark = 13;
          };
          zapret = {
            enable = true;
            filterMark = 13;
          };
        };
      }
    ])
  ];
}
