# A script kept in its own file beside the Nix that runs it, with its @name@ placeholders
# filled from `vars`: replaceVars, but at eval time, so the text still goes to
# writeShellScript, runCommand and the like. Each value is spliced in as "${value}" would
# be, so a path lands in the store. Every name given must be a placeholder in the file and
# every placeholder must be given, so neither side can drift from the other unnoticed.
file: vars:
let
  text = builtins.readFile file;
  names = builtins.attrNames vars;
  placeholders = builtins.concatMap (part: if builtins.isList part then part else [ ]) (
    builtins.split "@([A-Za-z_][A-Za-z0-9_]*)@" text
  );
  unused = builtins.filter (name: !builtins.elem name placeholders) names;
  unfilled = builtins.filter (name: !(vars ? ${name})) placeholders;
in
if unused != [ ] then
  throw "${toString file}: no @${builtins.head unused}@ placeholder to fill"
else if unfilled != [ ] then
  throw "${toString file}: @${builtins.head unfilled}@ is not given a value"
else
  builtins.replaceStrings (map (name: "@${name}@") names) (map (name: "${vars.${name}}") names) text
