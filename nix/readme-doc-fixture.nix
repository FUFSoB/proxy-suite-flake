{
  system.stateVersion = "26.05";

  services.proxy-suite = {
    enable = true;

    proxy = {
      enable = true;
      backend = "sing-box";
      outbounds = [
        {
          tag = "primary";
          url = "http://proxy.example.com:8080";
        }
      ];
    };
  };
}
