{
  pkgs,
  optionDocs,
  defaultConfigText,
  groupSummaries,
}:

let
  fillTemplate = import ../../modules/proxy-suite/lib/fill-template.nix;
  # Type, Default and Example as one short paragraph per option instead of three
  # headed blocks each; short values inline, the rest as code after it.
  compactFields = pkgs.writeText "compact-fields.py" (builtins.readFile ./compact-fields.py);

  summaryTsv = pkgs.writeText "group-summaries.tsv" (
    pkgs.lib.concatMapStrings (group: "${group.name}\t${group.summary}\n") groupSummaries
  );
in
# One file per top-level option group, plus an index. The single 6k-line page was
# not navigable.
pkgs.runCommand "proxy-suite-options-doc" { nativeBuildInputs = [ pkgs.python3 ]; } (
  fillTemplate ./render-options-markdown.template.sh {
    optionsCommonMark = optionDocs.optionsCommonMark;
    inherit compactFields summaryTsv;
    defaultConfig = pkgs.lib.escapeShellArg defaultConfigText;
  }
)
