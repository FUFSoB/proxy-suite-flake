# Ways to point programs at the local proxy without touching their settings: proxy
# variables, a proxychains wrapper, or a per-app routing profile. The module exposes them
# as config.lib.proxy-suite on NixOS and home-manager; the flake's lib.proxyHelpers builds
# the variables alone, for a proxy this config does not run or a host without config.lib.
{
  lib,
  pkgs,
  address ? "127.0.0.1",
  port ? 1080,
  username ? null,
  password ? null,
  # Set when the variables cannot name the proxy (it is off, or its password is a file).
  envUnavailable ? null,
  # From the module only: { args } for proxychains4, and { proxyCtl, profiles } for
  # per-app routing. A string instead says why the feature is unavailable.
  proxychains ? "wrapProxychains needs the proxy-suite module",
  perApp ? "wrapPerApp needs the proxy-suite module",
}:

let
  # A wildcard listener is reached on loopback.
  host =
    {
      "0.0.0.0" = "127.0.0.1";
      "::" = "::1";
    }
    .${address} or address;
  hostPort = "${if lib.hasInfix ":" host then "[${host}]" else host}:${toString port}";
  credentials = lib.optionalString (
    username != null
  ) "${lib.escapeURL username}:${lib.escapeURL password}@";
  checked =
    value: if envUnavailable != null then throw "proxy-suite helpers: ${envUnavailable}" else value;

  urls = checked {
    http = "http://${credentials}${hostPort}";
    # socks5h: names are resolved by the proxy, so they follow its routing.
    socks = "socks5h://${credentials}${hostPort}";
  };

  httpVars = [
    "http_proxy"
    "https_proxy"
    "HTTP_PROXY"
    "HTTPS_PROXY"
  ];
  socksVars = [
    "all_proxy"
    "ALL_PROXY"
  ];
  noProxy = {
    no_proxy = "localhost,127.0.0.0/8,::1";
    NO_PROXY = "localhost,127.0.0.0/8,::1";
  };
  protocolVars = {
    http = httpVars;
    socks = socksVars;
    all = httpVars ++ socksVars;
  };
  varsOf =
    protocol:
    protocolVars.${protocol}
      or (throw "proxy-suite helpers: protocol must be \"http\", \"socks\" or \"all\", not \"${protocol}\"");
  envFor =
    protocol:
    lib.genAttrs (varsOf protocol) (name: if builtins.elem name httpVars then urls.http else urls.socks)
    // noProxy;

  # A copy of `package` whose programs (all of bin/, or the named ones) are replaced by
  # what `wrap` writes, given the original as "$target" and the wrapper as "$prog".
  # .desktop files that start a program by its store path are pointed at the wrapper.
  wrapPrograms =
    suffix: programs: wrap: package:
    pkgs.symlinkJoin {
      name = "${lib.getName package}-${suffix}";
      paths = [ package ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        cd "$out/bin"
        for prog in ${if programs == null then "*" else lib.escapeShellArgs programs}; do
          target=$(readlink -f "$prog")
          rm "$prog"
          ${wrap}
        done
        for desktop in "$out"/share/applications/*.desktop; do
          [ -e "$desktop" ] && grep -q ${package}/bin/ "$desktop" || continue
          source=$(readlink -f "$desktop")
          rm "$desktop"
          sed "s|${package}/bin/|$out/bin/|g" "$source" > "$desktop"
        done
      '';
      passthru.unwrapped = package;
      # Not the whole meta: its license would make an unfree package's wrapper unfree
      # too, and refused unless the host allows unfree, which the package may not need.
      meta = lib.filterAttrs (name: _: name == "mainProgram" || name == "description") (
        package.meta or { }
      );
    };
  using =
    feature: use:
    if builtins.isString feature then throw "proxy-suite helpers: ${feature}" else use feature;
in
{
  inherit urls envFor;
  env = envFor "all";

  wrapEnv =
    {
      protocol ? "http",
      programs ? null,
    }:
    let
      vars = envFor protocol;
      others = lib.subtractLists (varsOf protocol) (httpVars ++ socksVars);
    in
    # The others are unset, so a shell's own proxy variables cannot steer the program elsewhere.
    wrapPrograms "proxied" programs ''
      makeWrapper "$target" "$prog" ${
        lib.concatStringsSep " " (
          lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") vars
          ++ map (name: "--unset ${name}") others
        )
      }
    '';

  wrapProxychains =
    {
      programs ? null,
    }:
    using proxychains (
      { args }:
      wrapPrograms "proxychains" programs ''
        makeWrapper ${pkgs.proxychains-ng}/bin/proxychains4 "$prog" \
          --add-flags ${lib.escapeShellArg "${args} "}"$target"
      ''
    );

  wrapPerApp =
    {
      profile,
      programs ? null,
    }:
    using perApp (
      { proxyCtl, profiles }:
      if !builtins.elem profile profiles then
        throw "proxy-suite helpers: no per-app routing profile named \"${profile}\" (have: ${lib.concatStringsSep ", " profiles})"
      else
        wrapPrograms profile programs ''
          makeWrapper ${proxyCtl}/bin/proxy-ctl "$prog" \
            --add-flags ${lib.escapeShellArg "apps run ${profile} -- "}"$target"
        ''
    );
}
