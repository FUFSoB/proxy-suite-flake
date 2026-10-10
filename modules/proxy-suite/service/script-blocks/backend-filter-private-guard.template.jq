# inbounds.routing.blockPrivate (or, without it, this host's loopback), enforced here because
# the listener passes names unresolved.
# Just before the first direct rule of the configuration (or last, for a direct final), and
# scoped to each runtime direct rule above that (insert_guard), so names that the
# proxy rules above take stay unresolved and none reaches a direct dial unchecked. Local
# mixed-in clients lose names that resolve private. Rules for other inbounds do not count:
# autoProxy's direct probe pin would put the guard first, resolving every name, .onion too.
# This host's own addresses too, its public one among them, on every port but those its
# clients may reach there (inbounds.serverPorts and the like): dialed from here, a service the
# firewall keeps from the internet would answer (the start script lists them).
| [{inbound: ["mixed-in"], action: "resolve"@resolveStrategy@},
   {inbound: ["mixed-in"]@rejectMatch@, action: "reject"}]
  + (($ARGS.named.host_addresses // []) as $own
     | if $own == [] or @hostPortsAllOpen@ then [] else [{inbound: ["mixed-in"], ip_cidr: $own@hostPortMatch@, action: "reject"}] end) as $guard
| insert_guard($guard)
