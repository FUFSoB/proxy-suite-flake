# The ```nix blocks of the README and the usage guides that set services.proxy-suite, each
# as a whole module. update-docs writes them to docs/usage/.snippets, where the usage-docs
# check imports them: Nix only parses files, and `nix flake check --no-build` can't write
# one to the store. A block fenced ```nix no-check is skipped; one that starts with "{" is
# a module already, anything else is its attributes.
{ lib }:

let
  usageDir = ../docs/usage;
  markdownIn =
    dir:
    map (name: lib.removePrefix "./" "${dir}/${name}") (
      builtins.filter (lib.hasSuffix ".md") (builtins.attrNames (builtins.readDir (usageDir + "/${dir}")))
    );
  guides = markdownIn "." ++ markdownIn "examples";

  blocks =
    text:
    builtins.filter (lib.hasInfix "services.proxy-suite") (
      map (chunk: builtins.head (lib.splitString "\n```" chunk)) (
        builtins.tail (lib.splitString "```nix\n" text)
      )
    );
  module =
    block:
    if lib.hasPrefix "{" block then
      block
    else
      ''
        { config, lib, pkgs, ... }:
        {
          ${block}
        }
      '';

  docs = [
    {
      where = "README.md";
      stem = "README";
      text = builtins.readFile ../README.md;
    }
  ]
  ++ map (name: {
    where = "docs/usage/${name}";
    stem = lib.replaceStrings [ "/" ] [ "-" ] (lib.removeSuffix ".md" name);
    text = builtins.readFile (usageDir + "/${name}");
  }) guides;
in
{
  inherit guides;
  dir = "docs/usage/.snippets";
  # [ { file, where, text } ], file relative to dir.
  snippets = lib.concatMap (
    doc:
    lib.imap1 (index: block: {
      file = "${doc.stem}-${toString index}.nix";
      where = "${doc.where}, nix block ${toString index}";
      text = module block;
    }) (blocks doc.text)
  ) docs;
}
