-- Failures nfqws2 and z2k do not see, and the verdicts proxy-suite routes by.
--
-- Rotation: the TLS detectors count retransmissions, resets and alerts. A ClientHello
-- DPI swallows whole can leave the client nothing to retransmit (the server only
-- acknowledges the handshake, over and over), and circular stays on a strategy that
-- never gets a reply. A ClientHello with no answer within NOREPLY_MS now counts too.
--
-- Learning (ps_learn, in the last TLS profile in place of nfqws2's own autohostlist):
-- - a success no longer wipes the failures before it, so a site DPI blocks only some
--   of the time (some connections pass, the rest are dropped) is still learned;
-- - a download that stops mid TLS record and stays stopped (the 16 KB cutoff) is a
--   failure, where nfqws2 took anything past 4 KB received for a working site;
-- - so is a ClientHello with no answer, retransmitted `retrans` times (the client gets
--   a reset then, as nfqws2 gave it, so it fails fast) or met by an early reset.
-- A site is learned at `fails` failures within `time` seconds: appended to the auto
-- hostlist, which nfqws2 reloads, so the profiles for blocked sites take it over.
--
-- Verdicts, appended to $PROXY_SUITE_ZAPRET2_VERDICTS as
-- "kind<TAB>name<TAB>proto<TAB>note<TAB>time" (the last line per name and proto wins), for
-- direct-sync.template.sh and proxy-ctl:
-- - works <site> tcp|udp: a strategy got through; only then does a learned site go direct;
-- - stalls <host> cutoff: learned from transfers cut short (the 16 KB cutoff); such a site
--   keeps the proxy's route whatever "works" says, as success is judged on the first 4 KB;
-- - unfixable <site> tcp|udp: every strategy failed in turn; the proxy carries it;
-- - blocked <ip> ip: connections to it go unanswered (blocked by address, ps_syn), and
--   reachable <ip> ip once one is answered again;
-- - retry <name> <proto>: proxy-ctl's, to give zapret2 another try.

local NOREPLY_MS = 4000
local STALL_MS = 6000
local SYN_MS = 3500

-- Names in it come off the wire (a SNI): a newline would forge journal lines of its own.
local function say(text)
  io.stderr:write("zapret2: ", (tostring(text):gsub("%c", "?")), "\n")
end

-- --- verdicts --------------------------------------------------------------------------

local VERDICTS = os.getenv("PROXY_SUITE_ZAPRET2_VERDICTS")
local status = {} -- "name proto" -> its last kind, so each change is written once
local status_count = 0
-- Names past which no new one gets a verdict: every unanswered address a page dials would
-- add one for good (and a /32 to the proxy's rules), each read back whole on the next.
local MAX_VERDICT_KEYS = 20000
local verdicts_full = false
-- Of them, addresses (ps_syn's), which a page can make by the thousand: never all of them.
local MAX_IP_VERDICT_KEYS = 2000
local ip_count = 0
local ip_full = false

-- The last verdicts, as the file has them now: proxy-ctl's retries land there too.
local function reload()
  local f = VERDICTS and io.open(VERDICTS, "r")
  if not f then return end
  status, status_count, ip_count = {}, 0, 0
  for line in f:lines() do
    local kind, name, proto = line:match("^(%w+)\t([^\t]+)\t([^\t]*)")
    if kind then
      local key = name .. " " .. proto
      if status[key] == nil then
        status_count = status_count + 1
        if proto == "ip" then ip_count = ip_count + 1 end
      end
      status[key] = kind
    end
  end
  f:close()
end
reload()

-- A name as a rule can take it: the SNI comes from the wire, raw, and a tab or newline in it
-- would forge lines of its own in the verdicts and lists.
local function plain(name)
  return type(name) == "string" and name:match("^[%w%.%-_:]+$") ~= nil
end

local function verdict(kind, name, proto, note)
  if not plain(name) then return end
  local key = name .. " " .. proto
  if not VERDICTS or status[key] == kind then return end
  reload()
  if status[key] == kind then return end
  if status[key] == nil and status_count >= MAX_VERDICT_KEYS then
    if not verdicts_full then say("no verdict for " .. name .. ": " .. VERDICTS .. " holds " .. MAX_VERDICT_KEYS .. " names already") end
    verdicts_full = true
    return
  end
  if status[key] == nil and proto == "ip" and ip_count >= MAX_IP_VERDICT_KEYS then
    if not ip_full then say("no verdict for " .. name .. ": " .. VERDICTS .. " holds " .. MAX_IP_VERDICT_KEYS .. " addresses already") end
    ip_full = true
    return
  end
  if status[key] == nil then
    status_count = status_count + 1
    if proto == "ip" then ip_count = ip_count + 1 end
  end
  status[key] = kind
  local f = io.open(VERDICTS, "a")
  if not f then return end
  f:write(kind, "\t", name, "\t", proto, "\t", note or "", "\t", os.time(), "\n")
  f:close()
end

-- "<circular key> <site>" of a host record: autostate maps them to it.
local function ident(hrec)
  for askey, hosts in pairs(autostate or {}) do
    for host, rec in pairs(hosts) do
      if rec == hrec then return askey, host end
    end
  end
end

local function udp_key(askey)
  return askey:match("quic") or askey:match("udp")
end

-- --- rotation ----------------------------------------------------------------------------

-- Every strategy failed in turn, none got through: the site is unfixable here. Its
-- rotation stops (it would only cycle on), and the proxy carries it from now on.
local count = automate_failure_counter
function automate_failure_counter(hrec, crec, fails, maxtime)
  local reached = count(hrec, crec, fails, maxtime)
  if reached and hrec.ctstrategy then
    hrec.ps_cycle = (hrec.ps_cycle or 0) + 1
    if hrec.ps_cycle >= hrec.ctstrategy and not hrec.final then
      local askey, host = ident(hrec)
      if host then
        hrec.final = hrec.nstrategy or 1
        local proto = udp_key(askey) and "udp" or "tcp"
        say(askey .. " " .. host .. ": no strategy of " .. hrec.ctstrategy .. " gets through, the proxy carries its " .. proto)
        verdict("unfixable", host, proto, askey)
      end
    end
  end
  return reached
end

-- A connection that got through: its site works with zapret2.
local check = automate_failure_check
function automate_failure_check(desync, hrec, crec)
  local judged = crec.nocheck
  local reached = check(desync, hrec, crec)
  if not judged and crec.nocheck and not crec.failure and not reached then
    hrec.ps_cycle = 0
    local hkf = desync.arg.hostkey and _G[desync.arg.hostkey] or standard_hostkey
    local ok, host = pcall(hkf, desync)
    if ok and host and desync.track and not desync.track.hostname_is_ip then
      verdict("works", host, desync.dis and desync.dis.udp and "udp" or "tcp", desync.arg.key)
    end
  end
  return reached
end

function ps_noreply_timer(_, data)
  local crec, hrec = data.crec, data.hrec
  -- Answered, already judged by the detector in place, or given up on by the client
  -- itself (a cancelled page, the loser of a connection race): no verdict on the site.
  if crec.ps_answered or crec.ps_closed or crec.nocheck or crec.failure then return end
  crec.nocheck = true
  if not automate_failure_counter(hrec, crec, tonumber(data.fails) or 3, tonumber(data.maxtime) or 60) then return end
  -- circular's own formula, as z2k's QUIC silence timer does it outside circular.
  if not hrec.ctstrategy or hrec.ctstrategy < 1 or (hrec.final and hrec.final == hrec.nstrategy) then return end
  hrec.nstrategy = ((hrec.nstrategy or 1) % hrec.ctstrategy) + 1
end

-- On top of a TCP failure detector: z2k's TLS one, and nfqws2's standard one (the
-- nfqws2-keenetic strategies). Armed once per connection, whichever runs first.
local function noreply(detector)
  return function(desync, crec)
    local dis = desync.dis
    if crec and dis and dis.tcp and desync.track then
      if not desync.outgoing then
        if #(dis.payload or "") > 0 then crec.ps_answered = true end
      elseif bitand(dis.tcp.th_flags or 0, TH_RST + TH_FIN) ~= 0 then
        crec.ps_closed = true
      elseif not crec.ps_armed and desync.l7payload == "tls_client_hello" then
        crec.ps_armed = true
        local hrec = automate_host_record(desync)
        if hrec then
          timer_set("psnr_" .. dis_timer_name(dis), ps_noreply_timer, NOREPLY_MS, true, {
            crec = crec,
            hrec = hrec,
            fails = desync.arg.fails,
            maxtime = desync.arg.time,
          })
        end
      end
    end
    return detector(desync, crec)
  end
end

if type(z2k_fail_tls_alert) == "function" then z2k_fail_tls_alert = noreply(z2k_fail_tls_alert) end
if type(standard_failure_detector) == "function" then standard_failure_detector = noreply(standard_failure_detector) end

-- --- learning ----------------------------------------------------------------------------

local failures, tracked = {}, 0 -- host -> failure times within the window
local learned = {}

local function lines(path)
  local out = {}
  local f = path and io.open(path, "r")
  if not f then return out end
  for line in f:lines() do
    line = line:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if line ~= "" and line:sub(1, 1) ~= "#" then out[#out + 1] = line:gsub("^%^", "") end
  end
  f:close()
  return out
end

-- A hostlist entry covers the name and its subdomains.
local function covered(host, entries)
  for _, e in ipairs(entries) do
    if host == e or host:sub(-(#e + 1)) == "." .. e then return true end
  end
  return false
end

local function excluded(host, arg)
  for path in (arg.exclude or ""):gmatch("[^,]+") do
    if covered(host, lines(path)) then return true end
  end
  local domains = {}
  for d in (arg.exclude_domains or ""):gmatch("[^,]+") do domains[#domains + 1] = d:lower() end
  return covered(host, domains)
end

local stalled = {} -- host -> a transfer of it was cut short, within the window

-- A name a site can have: two labels at least, none empty, and not a public suffix (com,
-- co.uk), which would take every site under it.
local function learnable(host)
  if not plain(host) or host:find("^%.") or host:find("%.$") or host:find("%.%.") or not host:find("%.") then
    return false
  end
  return not proxy_suite_is_public_suffix(host)
end

-- Learned names, and verdicts' names, past which no new one is taken: a wildcard domain's
-- fresh names would grow the lists without end. Real use stays far below.
local MAX_AUTO_LINES = 20000

local function bounded(t, count)
  if count > 4096 then return {}, 1 end
  return t, count
end
local learned_count, stalled_count = 0, 0
local auto_full = false

-- The site a name belongs to: the public suffix and one label more (example.co.uk).
local function registrable(host)
  local labels = {}
  for label in host:gmatch("[^.]+") do labels[#labels + 1] = label end
  for i = #labels - 1, 1, -1 do
    local candidate = table.concat(labels, ".", i)
    if not proxy_suite_is_public_suffix(candidate) then return candidate end
  end
  return host
end

-- Names of one site past which the site itself is learned instead, so one wildcard domain
-- cannot fill the list.
local MAX_NAMES_PER_SITE = 64

local function learn(host, arg, n)
  if not learnable(host) then return end
  local site = registrable(host)
  if site ~= host and learnable(site) then
    local same, tail = 0, "." .. site
    for _, line in ipairs(lines(arg.auto)) do
      if line:sub(-#tail) == tail then same = same + 1 end
    end
    if same >= MAX_NAMES_PER_SITE then
      say(site .. " has " .. same .. " names learned: learning the site instead of " .. host)
      host = site
    end
  end
  if not learned[host] then
    learned, learned_count = bounded(learned, learned_count + 1)
  end
  learned[host] = true
  if stalled[host] then verdict("stalls", host, "cutoff", "learned from transfers cut short") end
  local auto = lines(arg.auto)
  if covered(host, auto) then return end
  if #auto >= MAX_AUTO_LINES then
    if not auto_full then say("not learning " .. host .. ": " .. arg.auto .. " holds " .. MAX_AUTO_LINES .. " names already") end
    auto_full = true
    return
  end
  auto_full = false
  local f = io.open(arg.auto, "a")
  if not f then
    say("cannot learn " .. host .. ": " .. arg.auto .. " is not writable")
    return
  end
  f:write(host, "\n")
  f:close()
  say("learned " .. host .. " as blocked, after " .. n .. " failures")
end

-- Failure times of `key` within the window, with one more now.
local function tally(key, window)
  local now, kept = os.time(), {}
  for _, t in ipairs(failures[key] or {}) do
    if now - t <= window then kept[#kept + 1] = t end
  end
  kept[#kept + 1] = now
  if not failures[key] then
    tracked = tracked + 1
    if tracked > 4096 then failures, tracked = {}, 1 end
  end
  failures[key] = kept
  return #kept
end

local function failure(st, arg, why, stall)
  if st.counted then return end
  st.counted = true
  local host = st.host
  if learned[host] or excluded(host, arg) then return end
  if stall and not stalled[host] then
    stalled, stalled_count = bounded(stalled, stalled_count + 1)
    stalled[host] = true
  end
  local n, need = tally(host, tonumber(arg.time) or 300), tonumber(arg.fails) or 3
  if arg.log then say(host .. ": " .. why .. " (" .. n .. "/" .. need .. " to learn)") end
  if n >= need then learn(host, arg, n) end
end

-- The server's bytes in order, read as TLS records: a stall between records is a site
-- that said all it had, one inside a record is a transfer cut short.
local function feed(st, data)
  local i, n = 1, #data
  while i <= n and not st.notls do
    if st.need > 0 then
      local take = math.min(st.need, n - i + 1)
      st.need, i = st.need - take, i + take
    else
      local want = 5 - #st.hdr
      st.hdr = st.hdr .. data:sub(i, i + want - 1)
      i = i + want
      if #st.hdr == 5 then
        local kind = st.hdr:byte(1)
        if kind < 20 or kind > 24 then
          st.notls = true
        else
          st.need, st.hdr = st.hdr:byte(4) * 256 + st.hdr:byte(5), ""
        end
      end
    end
  end
end

-- nfqws2's own fast fail: a reset to the client retransmitting into silence, so it
-- gives up (and tries again) instead of waiting out its timeouts.
local function reset_client(desync)
  local dis = deepcopy(desync.dis)
  dis.payload = nil
  dis_reverse(dis)
  dis.tcp.th_flags = TH_RST
  dis.tcp.th_win = desync.track and desync.track.pos.reverse.tcp.winsize or 64
  dis.tcp.options = nil
  if dis.ip6 then
    dis.ip6.ip6_flow = (desync.track and desync.track.pos.reverse.ip6_flow) and desync.track.pos.reverse.ip6_flow or 0x60000000
  end
  rawsend_dissect(dis, { ifout = desync.ifin })
end

function ps_learn_noreply(_, data)
  -- done: the client gave up first, or a failure was counted already.
  if not data.st.answered and not data.st.done then failure(data.st, data.arg, "no reply to its ClientHello") end
end

function ps_learn_stall(_, data)
  local st = data.st
  -- Past the NFQUEUE window nothing more is seen: no telling a stall from the rest.
  if st.done or st.notls or st.inpk >= (tonumber(data.arg.win) or 15) then return end
  if st.need > 0 or #st.hdr > 0 or next(st.pending) then
    failure(st, data.arg, "transfer stalled after " .. math.floor((st.next - 1) / 1024) .. " KB", true)
  end
end

function ps_learn(_, desync)
  local track, dis = desync.track, desync.dis
  if not (track and dis and dis.tcp) or not track.hostname or track.hostname_is_ip then return end
  local st = track.lua_state.ps_learn
  if not st then
    st = { host = track.hostname:lower(), next = 1, need = 0, hdr = "", pending = {}, inpk = 0, retrans = 0 }
    track.lua_state.ps_learn = st
  end
  if st.done then return end
  local flags = dis.tcp.th_flags
  local payload = dis.payload or ""
  if desync.outgoing then
    if bitand(flags, TH_RST + TH_FIN) ~= 0 then
      st.done = true
    elseif not st.name and desync.l7payload == "tls_client_hello" then
      st.name = dis_timer_name(dis)
      timer_set("psln_" .. st.name, ps_learn_noreply, NOREPLY_MS, true, { st = st, arg = desync.arg })
    elseif st.name and not st.answered and #payload > 0 and is_retransmission(desync) then
      st.retrans = st.retrans + 1
      if st.retrans >= (tonumber(desync.arg.retrans) or 3) then
        failure(st, desync.arg, "ClientHello retransmitted " .. st.retrans .. " times")
        st.done = true
        reset_client(desync)
      end
    end
    return
  end
  st.inpk = pos_get(desync, "n") or (st.inpk + 1)
  if bitand(flags, TH_RST) ~= 0 then
    if (st.next - 1) <= (tonumber(desync.arg.inseq) or 4096) then failure(st, desync.arg, "reset by the network") end
    st.done = true
    return
  end
  if #payload > 0 then
    st.answered = true
    local s = pos_get(desync, "s")
    if s == st.next then
      feed(st, payload)
      st.next = s + #payload
      while st.pending[st.next] do
        local p = st.pending[st.next]
        st.pending[st.next] = nil
        feed(st, p)
        st.next = st.next + #p
      end
    elseif s > st.next then
      st.pending[s] = payload
    end
    if st.name then
      -- Replacing the timer restarts its countdown: it fires once the server goes quiet.
      timer_set("psls_" .. st.name, ps_learn_stall, STALL_MS, true, { st = st, arg = desync.arg })
    end
  end
  if bitand(flags, TH_FIN) ~= 0 then st.done = true end
end

-- --- addresses blocked outright ------------------------------------------------------------

-- No strategy helps where the connection itself goes unanswered: the address is blocked,
-- not the name. ps_syn, in the last profile, which every new connection meets before its
-- first data tells nfqws2 what it is, times each one; `fails` unanswered within `time`
-- seconds make it a verdict, and the proxy carries the address. One answer clears it.

-- Addresses that are never the censor's: private, loopback, link-local, CGNAT, ULA.
local function local_address(ip)
  local a, b = ip:match("^(%d+)%.(%d+)%.")
  if a then
    a, b = tonumber(a), tonumber(b)
    return a == 10 or a == 127 or a == 0 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
      or (a == 169 and b == 254) or (a == 100 and b >= 64 and b <= 127) or a >= 224
  end
  local lower = ip:lower()
  return lower == "::1" or lower:match("^f[cd]") ~= nil or lower:match("^fe[89ab]") ~= nil
end

function ps_syn_timer(_, data)
  local st = data.st
  if st.answered or st.closed then return end
  local n, need = tally("ip " .. st.ip, tonumber(data.arg.time) or 300), tonumber(data.arg.fails) or 3
  if data.arg.log then say(st.ip .. ": connection unanswered (" .. n .. "/" .. need .. ")") end
  if n >= need and status[st.ip .. " ip"] ~= "blocked" then
    say(st.ip .. " does not answer connections: blocked by address, the proxy carries it")
    verdict("blocked", st.ip, "ip", "no answer to " .. n .. " connections")
  end
end

function ps_syn(_, desync)
  local track, dis = desync.track, desync.dis
  if not (track and dis and dis.tcp) then return end
  local flags = dis.tcp.th_flags
  local st = track.lua_state.ps_syn
  if desync.outgoing then
    if not st and bitand(flags, TH_SYN) ~= 0 and bitand(flags, TH_ACK) == 0 then
      local ip = ntop(dis_ipdst(dis))
      if not ip or local_address(ip) then return end
      st = { ip = ip }
      track.lua_state.ps_syn = st
      timer_set("pssy_" .. dis_timer_name(dis), ps_syn_timer, SYN_MS, true, { st = st, arg = desync.arg })
    elseif st and bitand(flags, TH_RST + TH_FIN) ~= 0 then
      st.closed = true
    end
  elseif st and bitand(flags, TH_SYN) ~= 0 and bitand(flags, TH_ACK) ~= 0 then
    st.answered = true
    failures["ip " .. st.ip] = nil
    if status[st.ip .. " ip"] == "blocked" then
      say(st.ip .. " answers again: zapret2 has it back")
      verdict("reachable", st.ip, "ip")
    end
  end
end
