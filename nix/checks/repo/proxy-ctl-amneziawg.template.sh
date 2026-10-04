proxy_ctl=@proxyCtl@

mkdir -p bin
cat > bin/systemctl <<'SH'
#!@bash@/bin/bash
case "$1" in
  cat) exit 0 ;;
  is-active)
    if [ "${3:-${2:-}}" = "proxy-suite-awg-home" ] || [ "${2:-}" = "proxy-suite-awg-home" ]; then
      if [ "${2:-}" != "--quiet" ]; then
        echo active
      fi
      exit 0
    fi
    if [ "${2:-}" != "--quiet" ]; then
      echo inactive
    fi
    exit 3
    ;;
  start|stop|restart)
    printf '%s %s\n' "$1" "$2" >> "$SYSTEMCTL_LOG"
    ;;
esac
SH
chmod +x bin/systemctl

printf '%s\n' '["home","work"]' > awg-profiles.json
export PATH="$PWD/bin:$PATH"
export SYSTEMCTL_LOG="$PWD/systemctl.log"
export AWG_PROFILES_FILE="$PWD/awg-profiles.json"

python3 "$proxy_ctl" awg list > list-output
grep -q 'home.*active' list-output
grep -q 'work.*inactive' list-output
python3 "$proxy_ctl" awg on work
python3 "$proxy_ctl" awg off home
python3 "$proxy_ctl" awg restart home
grep -q '^start proxy-suite-awg-work$' "$SYSTEMCTL_LOG"
grep -q '^stop proxy-suite-awg-home$' "$SYSTEMCTL_LOG"
grep -q '^restart proxy-suite-awg-home$' "$SYSTEMCTL_LOG"

if python3 "$proxy_ctl" awg on missing 2> error-output; then
  exit 1
fi
grep -q 'Unknown AmneziaWG profile' error-output
touch "$out"
