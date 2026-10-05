# proxy-ctl knows its own verbs, tags, profiles and units: ask it.
# It answers word<TAB>description; bash has no room for the description.
# Not `compgen -W`: it expands its words, and a tag or list entry is whatever a member of
# the userControl groups named a file.
_proxy_ctl() {
  local cur=${COMP_WORDS[COMP_CWORD]} word
  COMPREPLY=()
  while IFS= read -r word; do
    word=${word%%$'\t'*}
    [[ $word == "$cur"* ]] && COMPREPLY+=("$word")
  done < <(proxy-ctl __complete "${COMP_WORDS[@]:1:COMP_CWORD-1}" 2>/dev/null)
}
complete -F _proxy_ctl proxy-ctl
