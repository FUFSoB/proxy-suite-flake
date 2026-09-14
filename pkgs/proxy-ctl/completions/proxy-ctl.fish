# proxy-ctl knows its own verbs, tags, profiles and units: ask it.
complete -c proxy-ctl -f -a '(proxy-ctl __complete (commandline -xpc)[2..] 2>/dev/null)'
