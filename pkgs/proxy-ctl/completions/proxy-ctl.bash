# proxy-ctl knows its own verbs, tags, profiles and units: ask it.
_proxy_ctl() {
  mapfile -t COMPREPLY < <(
    compgen -W "$(proxy-ctl __complete "${COMP_WORDS[@]:1:COMP_CWORD-1}" 2>/dev/null)" \
      -- "${COMP_WORDS[COMP_CWORD]}")
}
complete -F _proxy_ctl proxy-ctl
