{
  evalProxySuite,
  mkBadFixtureRaw,
  mkFailingAssertions,
}:

let
  proxyWithSubscriptions =
    subscriptions:
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          inherit subscriptions;
        };
      };
    };

  subscriptionUrlFileFixture = evalProxySuite [
    (proxyWithSubscriptions [
      {
        tag = "private";
        urlFile = "/run/secrets/sub-url";
      }
    ])
  ];
in
{
  assertions =
    (mkFailingAssertions mkBadFixtureRaw [
      # Tags are cache keys and tag prefixes, so duplicates are invalid.
      [
        (proxyWithSubscriptions [
          {
            tag = "dup";
            url = "https://example.com/sub/one";
          }
          {
            tag = "dup";
            url = "https://example.com/sub/two";
          }
        ])
      ]

      # Tags must be safe for generated names.
      [
        (proxyWithSubscriptions [
          {
            tag = "bad/tag";
            url = "https://example.com/sub/token";
          }
        ])
      ]

      # A subscription source must be either url or urlFile, not both.
      [
        (proxyWithSubscriptions [
          {
            tag = "bad";
            url = "https://example.com/sub/token";
            urlFile = "/run/secrets/sub-url";
          }
        ])
      ]

      # A subscription with no source is invalid.
      [
        (proxyWithSubscriptions [ { tag = "bad"; } ])
      ]
    ])
    ++ [
      # urlFile form is accepted.
      (
        assert subscriptionUrlFileFixture.config.services.proxy-suite.proxy.subscriptions != [ ];
        true
      )
    ];
}
