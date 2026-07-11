{
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

{
  assertions = mkFailingAssertions mkBadProxySuiteFixture [
    # Outbound tags must be unique.
    {
      enable = true;
      proxy = {
        enable = true;
        singBox.enable = true;
        outbounds = [
          {
            tag = "dup";
            url = "http://one.example.com:8080";
          }
          {
            tag = "dup";
            url = "http://two.example.com:8080";
          }
        ];
      };
    }

    # Built-in outbound names are reserved.
    {
      enable = true;
      proxy = {
        enable = true;
        singBox.enable = true;
        outbounds = [
          {
            tag = "proxy";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }

    # Explicit routing rules must target an existing outbound.
    {
      enable = true;
      proxy = {
        enable = true;
        singBox.enable = true;
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
        routing.rules = [
          {
            outbound = "missing";
            domains = [ "example.com" ];
          }
        ];
      };
    }
  ];
}
