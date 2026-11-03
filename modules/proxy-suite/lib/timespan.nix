# Whole seconds in a systemd time span ("1d", "6h", "1h 30min", "90"), as systemd.time(7)
# reads one; a bare number is seconds. The same units as proxy_supervisor.py's timespan(),
# which runs the timers where there is no systemd. Throws on anything else: the span is
# also handed to systemd, which would refuse it.
let
  units = {
    us = 0.000001;
    usec = 0.000001;
    ms = 0.001;
    msec = 0.001;
    s = 1;
    sec = 1;
    second = 1;
    seconds = 1;
    m = 60;
    min = 60;
    minute = 60;
    minutes = 60;
    h = 3600;
    hr = 3600;
    hour = 3600;
    hours = 3600;
    d = 86400;
    day = 86400;
    days = 86400;
    w = 604800;
    week = 604800;
    weeks = 604800;
    M = 2629800;
    month = 2629800;
    months = 2629800;
    y = 31557600;
    year = 31557600;
    years = 31557600;
  };
in
span:
let
  text = toString span;
  parts = builtins.filter builtins.isList (
    builtins.split "([0-9]+(\\.[0-9]+)?)[[:space:]]*([a-zA-Z]*)" text
  );
  rest = builtins.replaceStrings [ " " "\t" ] [ "" "" ] (
    builtins.concatStringsSep "" (
      builtins.filter builtins.isString (builtins.split "[0-9]+(\\.[0-9]+)?[[:space:]]*[a-zA-Z]*" text)
    )
  );
  seconds =
    part:
    let
      number = builtins.fromJSON (builtins.elemAt part 0);
      unit = builtins.elemAt part 2;
    in
    if unit == "" then
      number
    else if units ? ${unit} then
      number * units.${unit}
    else
      throw "not a time span: ${text} (unknown unit \"${unit}\")";
in
if parts == [ ] || rest != "" then
  throw "not a time span: ${text}"
else
  builtins.floor (builtins.foldl' (sum: part: sum + seconds part) 0 parts)
