# nfqws2's options in, with the extra ports (xtcp, xudp) joined to every profile that
# tells its traffic by protocol (--filter-l7). The ports to queue go to the file named
# by `ports`: the base lists (btcp, budp), the extras, and every port a profile filters
# on, since a profile port the queue lacks never sees a packet. Overlaps are merged:
# nftables refuses overlapping intervals in a set.

function mark(proto, list,   n, p, i, r, lo, hi, port) {
  n = split(list, p, ",")
  for (i = 1; i <= n; i++) {
    # ~negated, * and empty name nothing to queue.
    if (p[i] !~ /^[0-9]+(-[0-9]+)?$/) continue
    split(p[i], r, "-")
    lo = r[1] + 0
    hi = (p[i] ~ /-/) ? r[2] + 0 : lo
    if (lo < 1) lo = 1
    if (hi > 65535) hi = 65535
    for (port = lo; port <= hi; port++) queued[proto, port] = 1
  }
}

function ranges(proto,   port, lo, out) {
  out = ""
  lo = 0
  for (port = 1; port <= 65536; port++) {
    if ((proto, port) in queued) {
      if (!lo) lo = port
    } else if (lo) {
      out = out (out == "" ? "" : ",") (lo == port - 1 ? lo : lo "-" (port - 1))
      lo = 0
    }
  }
  return out
}

{
  for (i = 1; i <= NF; i++) tok[++n] = $i
}

END {
  prof = 0
  for (i = 1; i <= n; i++) {
    if (tok[i] == "--new") prof++
    else if (tok[i] ~ /^--filter-l7=/) l7[prof] = 1
  }
  prof = 0
  for (i = 1; i <= n; i++) {
    t = tok[i]
    if (t == "--new") {
      prof++
    } else if (t ~ /^--filter-tcp=/) {
      if ((prof in l7) && xtcp != "") t = t "," xtcp
      mark("tcp", substr(t, 14))
    } else if (t ~ /^--filter-udp=/) {
      if ((prof in l7) && xudp != "") t = t "," xudp
      mark("udp", substr(t, 14))
    }
    printf "%s%s", (i > 1 ? " " : ""), t
  }
  mark("tcp", btcp "," xtcp)
  mark("udp", budp "," xudp)
  printf "NFQWS2_PORTS_TCP=%s\nNFQWS2_PORTS_UDP=%s\n", ranges("tcp"), ranges("udp") >ports
}
