# sing-box's geoip rule sets, and the tags XRay's geoip.dat has besides countries (telegram,
# google, cloudflare, private, …): sing-geoip carries countries only, so "geoip:telegram"
# works on XRay and not on sing-box. Each tag of geoip.dat with no rule set here is compiled
# into one, from the same data XRay reads; sing-geoip's own files are left as they are.
{
  pkgs,
  singGeoip ? pkgs.sing-geoip,
  geoipDat ? "${pkgs.v2ray-rules-dat}/share/v2ray/geoip.dat",
  singBox ? pkgs.sing-box,
}:

pkgs.runCommand "sing-geoip-extended-${singGeoip.version or "0"}"
  {
    nativeBuildInputs = [
      pkgs.python3
      singBox
    ];
    passthru = { inherit singGeoip geoipDat; };
    meta.description = "sing-geoip with the non-country tags of XRay's geoip.dat";
  }
  ''
    dir=share/sing-box/rule-set
    mkdir -p "$out/$dir" sources
    for f in ${singGeoip}/$dir/*; do
      ln -s "$f" "$out/$dir/"
    done
    added=$(python3 ${./sing-geoip-extended.py} ${geoipDat} "$out/$dir" sources)
    for tag in $added; do
      sing-box rule-set compile --output "$out/$dir/geoip-$tag.srs" "sources/geoip-$tag.json"
    done
    echo "added: $added"
  ''
