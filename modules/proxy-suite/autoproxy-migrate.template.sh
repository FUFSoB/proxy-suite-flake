set -euo pipefail
# $1 - autoProxy's state dir, $2 - the spool members queue requests in
export PATH=@path@
dir=$1
spool=$2

# Until the spool, the autoProxy scope's group wrote to the state dir too. A no-op once done.

# Root's alone now; 0751: the group reads it, sing-box searches through to rules/.
install -d -m 0751 "$dir"

# The old queues go to the spool, read through no link (to a file only root may read)
# and never blocking on a FIFO. With no spool to take them, they are dropped.
for name in requests edits requests.taking edits.taking; do
  f="$dir/$name"
  [ -e "$f" ] || [ -L "$f" ] || continue
  if [ -d "$spool" ]; then
    # The spool is sticky: no member can swap the name in the meantime.
    tmp=$(mktemp "$spool/.migrated.XXXXXX")
    dd if="$f" iflag=nofollow,nonblock status=none > "$tmp" 2>/dev/null || true
    chmod 0640 "$tmp"
    # -T: a directory (or a link to one) a member left under that name takes nothing in.
    mv -fT "$tmp" "$spool/${name%.taking}.migrated${tmp##*/.migrated}"
  fi
  rm -rf -- "$f"
done

# Then whatever else a member left: links, files not root's, special files, and any of
# root's names holding the wrong kind of file.
find "$dir" -mindepth 1 -maxdepth 1 \( -type l -o ! -uid "$(id -u)" -o ! \( -type f -o -type d \) \) \
  -exec rm -rf -- {} +
for name in state.json lock samples; do
  [ ! -e "$dir/$name" ] || [ -f "$dir/$name" ] || rm -rf -- "${dir:?}/$name"
done
[ ! -e "$dir/rules" ] || [ -d "$dir/rules" ] || rm -f -- "$dir/rules"
