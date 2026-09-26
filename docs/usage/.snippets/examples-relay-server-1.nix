{ config, lib, ... }:
let
  domain = "vpn.example.com";
  certDir = config.security.acme.certs.${domain}.directory;

  users = map (name: { inherit name; uuidFile = "/run/secrets/proxy-uuid-${name}"; }) [
    "alice"
    "bob"
    "carol"
  ];

  # The listeners terminate TLS themselves, so share links honestly say security=tls.
  tls = {
    enable = true;
    certificateFile = "${certDir}/fullchain.pem";
    keyFile = "${certDir}/key.pem";
    serverName = domain;
  };

  # nginx on 443 hands a path to a loopback listener.
  fronted = port: path: extra: {
    type = "vless";
    inherit port users;
    address = "127.0.0.1";
    sharePort = 443; # share links name nginx's port, not the listener's
    transport = extra // {
      inherit path;
      # nginx sets this header, so XRay sees each client's real address (for `proxy-ctl inbounds online`). A client cannot forge it: nginx overwrites it.
      trustedXForwardedFor = [ "X-Real-IP" ];
    };
    inherit tls;
  };
  location = port: extra: {
    proxyPass = "https://127.0.0.1:${toString port}";
    extraConfig = ''
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $remote_addr;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_ssl_server_name on;
      proxy_ssl_name ${domain};
      # Tunnels idle along with their users; the 60s default would cut them.
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    ''
    + extra;
  };
in
{
  services.proxy-suite = {
    enable = true;
    proxy = {
      enable = true;
      outbounds = [ { tag = "primary"; urlFile = "/run/secrets/proxy-primary-url"; } ];
    };

    inbounds = {
      enable = true;
      serverAddress = domain;
      routing.via = "proxy";

      listeners = {
        # nginx speaks HTTP/1.1 to the listener, which only packet-up mode crosses.
        xhttp = fronted 10003 "/media" {
          type = "xhttp";
          mode = "packet-up";
        };
        ws = fronted 10002 "/media-ws" { type = "ws"; };
        # stream-one needs HTTP/2 all the way: nginx's grpc_pass provides it.
        xhttp-stream = lib.recursiveUpdate (fronted 10004 "/media-stream" {
          type = "xhttp";
          mode = "stream-one";
        }) { tls.alpn = [ "h2" ]; };

        # HTTP/3 takes UDP 443 only, beside nginx on TCP 443. No trustedXForwardedFor:
        # nothing is in front, so it already sees the real client.
        xhttp-h3 = {
          type = "vless";
          port = 443;
          inherit users;
          transport = { type = "xhttp"; path = "/media-h3"; };
          tls = tls // { alpn = [ "h3" ]; };
        };

        reality = {
          type = "vless";
          port = 2053;
          inherit users;
          flow = "xtls-rprx-vision";
          reality = {
            enable = true;
            # Probes without the key land on a real TLS 1.3 + HTTP/2 site.
            dest = "www.samsung.com:443";
            serverNames = [ "www.samsung.com" ];
            privateKeyFile = "/run/secrets/proxy-reality-key";
            publicKey = "jNXH…";
            shortIds = [ "0123abcd" ];
          };
        };
      };

      subscriptions = {
        enable = true;
        baseUrl = "https://${domain}/sub";
      };
    };

    userControl.enable = true; # passwordless proxy-ctl for the admin, see below
  };

  users.users.admin.extraGroups = [ "proxy-suite" ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
    # A renewed certificate restarts the listeners.
    certs.${domain}.reloadServices = [ "proxy-suite-inbounds.service" ];
  };
  systemd.services.proxy-suite-inbounds = {
    wants = [ "acme-${domain}.service" ];
    after = [ "acme-${domain}.service" ];
  };

  services.nginx = {
    enable = true;
    virtualHosts.${domain} = {
      forceSSL = true;
      enableACME = true;
      locations = {
        # A prefix match: XHTTP appends /<session>/<seq>.
        "/media" = location 10003 ''
          proxy_http_version 1.1;
          proxy_request_buffering off;
          proxy_buffering off;
          client_max_body_size 0;
        '';
        "= /media-ws" = location 10002 "" // { proxyWebsockets = true; };
        "/media-stream".extraConfig = ''
          grpc_pass grpcs://127.0.0.1:10004;
          grpc_set_header X-Forwarded-For $remote_addr;
          grpc_set_header X-Real-IP $remote_addr;
          grpc_ssl_server_name on;
          grpc_ssl_name ${domain};
          grpc_read_timeout 3600s;
          grpc_send_timeout 3600s;
          client_max_body_size 0;
        '';
        # Subscriptions. Some clients show profile-title and follow profile-update-interval.
        "/sub/".extraConfig = ''
          alias /run/proxy-suite-inbounds/subscriptions/;
          default_type text/plain;
          autoindex off;
          add_header profile-title "My VPN" always;
          add_header profile-update-interval "12" always;
        '';
      };
    };
  };
}