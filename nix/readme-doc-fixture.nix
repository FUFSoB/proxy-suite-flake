{
  system.stateVersion = "26.05";

  services.proxy-suite = {
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
    };
  };
}
