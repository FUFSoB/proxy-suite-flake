{
  mkBadFixture,
  mkFailingAssertions,
}:

{
  assertions = mkFailingAssertions mkBadFixture [
    # route=proxychains requires proxychains.enable.
    [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            {
              name = "steam-browser";
              route = "proxychains";
            }
          ];
        };
      }
    ]

    # proxychains requires proxy.enable.
    [
      {
        services.proxy-suite = {
          proxy.enable = false;
          perAppRouting = {
            enable = true;
            proxychains.enable = true;
          };
        };
      }
    ]

    # profiles require perAppRouting.enable.
    [
      { services.proxy-suite.perAppRouting.profiles = [ { name = "oops"; } ]; }
    ]

    # default proxychains profile still requires proxychains.enable.
    [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      }
    ]

    # route=tun requires perAppRouting.tun.enable.
    [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            {
              name = "game";
              route = "tun";
            }
          ];
        };
      }
    ]

    # app TUN backend requires proxy.enable.
    [
      {
        services.proxy-suite = {
          proxy.enable = false;
          perAppRouting = {
            enable = true;
            tun.enable = true;
          };
        };
      }
    ]
    [
      {
        services.proxy-suite = {
          proxy.enable = false;
          perAppRouting = {
            enable = true;
            profiles = [
              {
                name = "game";
                route = "tun";
              }
            ];
          };
        };
      }
    ]

    # route=tproxy requires perAppRouting.tproxy.enable.
    [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            {
              name = "browser";
              route = "tproxy";
            }
          ];
        };
      }
    ]

    # app TProxy backend requires proxy.enable.
    [
      {
        services.proxy-suite = {
          proxy.enable = false;
          perAppRouting = {
            enable = true;
            tproxy.enable = true;
          };
        };
      }
    ]
    [
      {
        services.proxy-suite = {
          proxy.enable = false;
          perAppRouting = {
            enable = true;
            profiles = [
              {
                name = "browser";
                route = "tproxy";
              }
            ];
          };
        };
      }
    ]

    # route=zapret requires perAppRouting.zapret.enable.
    [
      {
        services.proxy-suite = {
          zapret.enable = true;
          perAppRouting = {
            enable = true;
            profiles = [
              {
                name = "yt";
                route = "zapret";
              }
            ];
          };
        };
      }
    ]

    # profile names must be unique.
    [
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            { name = "dup"; }
            { name = "dup"; }
          ];
        };
      }
    ]
  ];
}
