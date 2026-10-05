-- circular keys a site's strategy by the host's last nld labels (nld=2: example.com),
-- so one strategy serves a site and its subdomains. Under a public suffix of two
-- labels that lumps unrelated sites together: every *.co.uk shared one strategy, and
-- one that worked kept the failures of another from counting. nld now counts from the
-- public suffix (the list's ICANN section): foo.co.uk, not co.uk. A key the state layer
-- remembered under the old scheme is simply no longer used.

local exact, wild, except = {}, {}, {}
for rule in io.lines("@suffixes@") do
  if rule:sub(1, 1) == "!" then
    except[rule:sub(2)] = true
  elseif rule:sub(1, 2) == "*." then
    wild[rule:sub(3)] = true
  else
    exact[rule] = true
  end
end

-- How many trailing labels the public suffix spans: the longest rule that matches, an
-- exception taking one label off its rule, and a single label when no rule does.
local function suffix_labels(labels)
  local n = #labels
  for i = 1, n do
    local tail = table.concat(labels, ".", i, n)
    if except[tail] then return n - i end
    if exact[tail] or (i < n and wild[table.concat(labels, ".", i + 1, n)]) then return n - i + 1 end
  end
  return 1
end

local cache, cached = {}, 0

local function public_suffix_nld(host, nld)
  local id = nld .. " " .. host
  local key = cache[id]
  if key then return key end
  local labels = {}
  for label in host:lower():gsub("%.$", ""):gmatch("[^.]+") do labels[#labels + 1] = label end
  if #labels == 0 then return nil end
  local first = math.max(1, #labels - (suffix_labels(labels) + nld - 1) + 1)
  key = table.concat(labels, ".", first)
  if cached >= 8192 then cache, cached = {}, 0 end
  cache[id], cached = key, cached + 1
  return key
end

-- For detect.lua (a chunk of its own): whether host is itself a public suffix, or a single
-- label, which no site is.
function proxy_suite_is_public_suffix(host)
  local labels = {}
  for label in host:lower():gsub("%.$", ""):gmatch("[^.]+") do labels[#labels + 1] = label end
  return #labels <= suffix_labels(labels)
end

local standard = standard_hostkey
if type(standard) ~= "function" then
  error("proxy-suite: zapret-auto.lua no longer defines standard_hostkey")
end

function standard_hostkey(desync)
  local nld = tonumber(desync.arg.nld)
  local track = desync.track
  if nld and nld > 0 and track and track.hostname and not track.hostname_is_ip then
    local key = public_suffix_nld(track.hostname, nld)
    if key then return key end
  end
  return standard(desync)
end
