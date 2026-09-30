# What userControl's groups may be given (options/user-control.nix); derived.nix reads it
# to spell out "no scopes listed", which means all of them.
[
  "services"
  "perApp"
  "routing"
  "outbounds"
  "secrets"
  "autoProxy"
  "zapret"
  "stats"
  "inbounds"
  "whitelistBypass"
  "amneziaWg"
]
