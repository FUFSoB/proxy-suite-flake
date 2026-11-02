# The sites the strategy source's own profiles handle from the start (sources.nix
# siteLists), for directSync. Read from the pinned inputs at evaluation, like
# zapret-discord-youtube's lists; your own `profiles` use none of them.
{
  lib,
  pkgs,
  cfg,
  zapret2Sources,
}:

let
  zapret2Cfg = cfg.zapret.zapret2;
  sourceName = zapret2Cfg.strategySource;
  # The checks and the docs may assemble without the inputs: no lists then.
  available = zapret2Sources ? ${sourceName};
  source =
    (import ./sources.nix {
      inherit lib pkgs;
      sources = zapret2Sources;
    }).${sourceName};

  # nfqws hostlists: one host per line, "#" comments, "^" for the name alone, which no
  # proxy backend has: as a plain suffix it covers the name itself, which is the point.
  parse =
    path:
    map (line: lib.toLower (lib.removePrefix "^" line)) (
      builtins.filter (line: line != "" && !(lib.hasPrefix "#" line)) (
        map lib.strings.trim (
          lib.splitString "\n" (builtins.replaceStrings [ "\r" ] [ "" ] (builtins.readFile path))
        )
      )
    );
  excluded = lib.concatMap parse source.siteExcludes ++ map lib.toLower zapret2Cfg.excludeDomains;
in
if !available || zapret2Cfg.profiles != null then
  [ ]
else
  builtins.filter (domain: !(builtins.elem domain excluded)) (
    lib.unique (lib.concatMap parse source.siteLists)
  )
