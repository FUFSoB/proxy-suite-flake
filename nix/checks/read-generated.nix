# Inspect writeText/writeShellScript output without import-from-derivation.
{
  readDerivation =
    derivation:
    if derivation ? drvAttrs && derivation.drvAttrs ? text then
      derivation.drvAttrs.text
    else
      throw "proxy-suite checks: expected a writeText/writeShellScript derivation";
}
