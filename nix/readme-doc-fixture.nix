{
  system.stateVersion = "26.05";

  services.proxy-suite = {
    enable = true;

    singBox.outbounds = [
      {
        tag = "primary";
        url = "http://proxy.example.com:8080";
      }
    ];
  };
}
