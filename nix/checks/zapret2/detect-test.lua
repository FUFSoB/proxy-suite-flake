-- detect.lua against stubs of the nfqws2 API it uses: timers fire when the test says.
-- $DETECT: the module; $WORK: a writable directory; $PROXY_SUITE_ZAPRET2_VERDICTS in it.
local work = os.getenv("WORK")
local verdict_file = os.getenv("PROXY_SUITE_ZAPRET2_VERDICTS")
local timers = {}
function timer_set(name, func, _, _, data) timers[name] = { func = func, data = data } end
local function fire(prefix)
  for name, t in pairs(timers) do
    if name:sub(1, #prefix) == prefix then
      timers[name] = nil
      t.func(name, t.data)
    end
  end
end
TH_FIN, TH_SYN, TH_RST, TH_ACK = 1, 2, 4, 16
function ntop(ip) return ip end
function dis_ipdst(dis) return dis.dst end
function deepcopy(t) return t end
function dis_reverse() end
local resets = 0
function rawsend_dissect() resets = resets + 1 end
function is_retransmission(desync) return desync.retrans end
-- The arg the standard detector was last handed: z2k's hands it a copy without reset.
local standard_arg
function standard_failure_detector(desync)
  standard_arg = desync.arg
  return "standard"
end
function standard_hostkey(desync) return desync.track.hostname:gsub("^www%.", "") end
function automate_failure_check(_, _, crec)
  crec.nocheck = true
  return false
end
function bitand(a, b)
  local r, bit = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then r = r + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return r
end
function pos_get(desync, mode) return desync.pos[mode] end
function dis_timer_name(dis) return dis.flow end

-- rotation: what circular and z2k leave in place
local counted = {}
function automate_failure_counter(hrec, crec, fails)
  crec.failure = true
  hrec.failure_counter = (hrec.failure_counter or 0) + 1
  counted[#counted + 1] = hrec.failure_counter
  if hrec.failure_counter < fails then return false end
  hrec.failure_counter = nil
  return true
end
local hrec = { nstrategy = 1, ctstrategy = 50 }
function automate_host_record() return hrec end
function z2k_fail_tls_alert(desync, crec)
  if not desync.native then return "z2k" end
  local copy, a = {}, {}
  for k, v in pairs(desync) do copy[k] = v end
  for k, v in pairs(desync.arg) do a[k] = v end
  a.reset, a.no_http_redirect = nil, true
  copy.arg = a
  return standard_failure_detector(copy, crec)
end

-- detect.lua's public suffixes, loaded before it as nfqws2 does.
dofile(os.getenv("PSL"))
dofile(os.getenv("DETECT"))

-- The per-app instance has no verdicts file: no proxy takes a site over, so a whole cycle
-- of failed strategies leaves its rotation going.
if not verdict_file then
  local prec = { nstrategy = 2, ctstrategy = 2 }
  autostate = { quic = { ["discord.com"] = prec } }
  for _ = 1, 4 do automate_failure_counter(prec, {}, 1) end
  assert(not prec.final, "no verdicts file: rotation goes on")
  return
end

local auto = work .. "/auto.txt"
local excl = work .. "/exclude.txt"
local f = io.open(excl, "w")
f:write("bank.example\n")
f:close()
io.open(auto, "w"):close()
-- reset: a bare argument (autoHostlist.retransReset); only its presence counts.
local arg = { auto = auto, exclude = excl, fails = "3", time = "300", inseq = "4096", win = "32", exclude_domains = "skip.example", reset = "" }

local flows = 0
local function flow(host)
  flows = flows + 1
  return { hostname = host, lua_state = {}, flow = "f" .. flows, pos = { reverse = { tcp = { winsize = 64 } } } }
end
local function packet(track, outgoing, opts)
  return {
    track = track,
    outgoing = outgoing,
    arg = arg,
    l7payload = opts.l7,
    pos = { n = opts.n or 1, s = opts.s or 1 },
    dis = { flow = track.flow, tcp = { th_flags = opts.flags or 16 }, payload = opts.payload or "" },
  }
end
local function hello(track) ps_learn(nil, packet(track, true, { l7 = "tls_client_hello", payload = "hello" })) end
local function reply(track, s, data, n) ps_learn(nil, packet(track, false, { s = s, payload = data, n = n })) end
local function record(len) return string.char(23, 3, 3, math.floor(len / 256), len % 256) end
local function learned()
  local t = {}
  for line in io.lines(auto) do t[line] = true end
  return t
end

-- A site blocked some of the time: a working connection between failures no longer
-- clears them, and the third no-reply learns it.
for i = 1, 3 do
  local t = flow("www.notion.so")
  hello(t)
  fire("psln_")
  if i == 2 then
    local ok = flow("www.notion.so")
    hello(ok)
    reply(ok, 1, record(3) .. "abc")
    fire("psln_")
    fire("psls_")
  end
end
assert(learned()["www.notion.so"], "flaky site learned")

-- The 16 KB cutoff: a record announced longer than what arrived, then silence.
for _ = 1, 3 do
  local t = flow("signal.org")
  hello(t)
  reply(t, 1, record(16000) .. string.rep("x", 8000), 6)
  reply(t, 8006, string.rep("x", 4000), 9)
  fire("psln_")
  fire("psls_")
end
assert(learned()["signal.org"], "stalled site learned")
do
  local found = false
  for line in io.lines(verdict_file) do
    if line:match("^stalls\tsignal%.org\tcutoff\t") then found = true end
  end
  assert(found, "learned from a cut transfer: it keeps the proxy's route")
end

-- A whole record and silence is a finished reply; out of order bytes are put in order.
for _ = 1, 3 do
  local t = flow("fine.example")
  hello(t)
  reply(t, 9, string.rep("y", 4), 3)
  reply(t, 1, record(7) .. "yyy", 2)
  fire("psln_")
  fire("psls_")
end
assert(not learned()["fine.example"], "finished transfers are no failure")

-- Past the queue window nothing more is seen: no verdict.
for _ = 1, 3 do
  local t = flow("big.example")
  hello(t)
  reply(t, 1, record(60000) .. "z", 32)
  fire("psls_")
end
assert(not learned()["big.example"], "blind past the window")

-- A reset early in the reply counts; excluded sites never.
for _ = 1, 3 do
  local t = flow("reset.example")
  hello(t)
  ps_learn(nil, packet(t, false, { flags = TH_RST, s = 1 }))
  for _, host in ipairs({ "www.bank.example", "skip.example" }) do
    local x = flow(host)
    hello(x)
    fire("psln_")
  end
end
local got = learned()
assert(got["reset.example"] and not got["www.bank.example"] and not got["skip.example"])

-- A client that hangs up before the answer (a cancelled page) says nothing of the site.
for _ = 1, 3 do
  local t = flow("cancelled.example")
  hello(t)
  ps_learn(nil, packet(t, true, { flags = TH_FIN + 16 }))
  fire("psln_")
end
assert(not learned()["cancelled.example"], "cancelled connections are no failure")

-- Rotation: a ClientHello with no reply counts a failure; three switch the strategy.
-- A reply, or the detector's own verdict, in time leaves it be.
local function tls(outgoing, payload, crec, flags)
  return z2k_fail_tls_alert({
    outgoing = outgoing,
    l7payload = outgoing and payload ~= "" and "tls_client_hello" or nil,
    track = {},
    arg = { fails = "3", time = "60" },
    dis = { flow = "r" .. tostring(crec), tcp = { th_flags = flags }, payload = payload },
  }, crec)
end
for _ = 1, 3 do
  local crec = {}
  assert(tls(true, "hello", crec) == "z2k")
  fire("psnr_")
end
assert(hrec.nstrategy == 2 and #counted == 3, "rotated after three silent ClientHellos")
local answered, judged, cancelled = {}, { nocheck = true }, {}
tls(true, "hello", answered)
tls(false, "server hello", answered)
tls(true, "hello", judged)
tls(true, "hello", cancelled)
tls(true, "", cancelled, TH_RST)
fire("psnr_")
assert(#counted == 3, "answered, judged or cancelled flows are no failure")
assert(standard_failure_detector({ arg = {}, dis = { tcp = {} } }, {}) == "standard", "nfqws2's detector is wrapped too")
-- z2k's detector drops reset on what it hands the standard one: it is put back, and
-- stays off where the circular has none.
local function native(reset)
  standard_arg = nil
  z2k_fail_tls_alert({ native = true, track = {}, arg = { reset = reset }, dis = { flow = "n", tcp = { th_flags = 0 } } }, { ps_armed = true })
  return standard_arg
end
assert(native(true).reset == true, "reset reaches the standard detector through z2k's")
assert(native(nil).reset == nil, "no reset where the circular has none")
assert(standard_failure_detector({ arg = { no_http_redirect = true }, dis = { tcp = {} } }, {}) == "standard" and standard_arg.reset == nil, "no reset outside z2k's detector")

local function verdicts()
  local t = {}
  for line in io.lines(verdict_file) do
    local kind, name, proto = line:match("^(%w+)\t([^\t]+)\t([^\t]*)")
    t[name .. " " .. proto] = kind
  end
  return t
end

-- Fast fail: a ClientHello retransmitted into silence gets the client a reset, and counts.
local t = flow("slow.example")
hello(t)
for _ = 1, 3 do ps_learn(nil, { track = t, outgoing = true, arg = arg, retrans = true, pos = {}, dis = { flow = t.flow, tcp = { th_flags = 16 }, payload = "hello" } }) end
assert(resets == 1 and t.lua_state.ps_learn.counted, "reset after three retransmissions")
-- Without autoHostlist.retransReset it counts all the same, and the client gets no reset.
local noreset = {}
for k, v in pairs(arg) do noreset[k] = v end
noreset.reset = nil
local t2 = flow("slower.example")
hello(t2)
for _ = 1, 3 do ps_learn(nil, { track = t2, outgoing = true, arg = noreset, retrans = true, pos = {}, dis = { flow = t2.flow, tcp = { th_flags = 16 }, payload = "hello" } }) end
assert(resets == 1 and t2.lua_state.ps_learn.counted, "no reset without retransReset")

-- works: a connection that got through, by the site key, with its protocol.
local wrec = { ps_cycle = 4 }
automate_failure_check({ arg = { key = "rkn_tcp" }, track = { hostname = "www.notion.so" }, dis = { tcp = {} } }, wrec, {})
assert(verdicts()["notion.so tcp"] == "works" and wrec.ps_cycle == 0, "works recorded, the cycle count reset")

-- unfixable: a whole cycle of strategies without one success stops the rotation.
local qrec = { nstrategy = 2, ctstrategy = 2 }
autostate = { quic = { ["discord.com"] = qrec } }
automate_failure_counter(qrec, {}, 1)
assert(not qrec.final)
automate_failure_counter(qrec, {}, 1)
assert(qrec.final == 2 and verdicts()["discord.com udp"] == "unfixable", "unfixable after a full cycle, QUIC only")
-- A circular without key= (keenetic's UDP one, named by its instance) on flows without a
-- name (keyed by address): unfixable for the transport it judged, not for all of it.
local urec, trec = { nstrategy = 2, ctstrategy = 2 }, { nstrategy = 1, ctstrategy = 3 }
autostate.circular_1_1 = { ["203.0.113.5"] = urec }
autostate.circular_3_1 = { ["203.0.113.5"] = trec }
automate_failure_check({ arg = {}, track = {}, dis = { udp = {} } }, urec, { nocheck = true })
automate_failure_check({ arg = {}, track = {}, dis = { tcp = {} } }, trec, { nocheck = true })
for _ = 1, 2 do automate_failure_counter(urec, {}, 1) end
automate_failure_counter(trec, {}, 1)
assert(verdicts()["203.0.113.5 udp"] == "unfixable" and not verdicts()["203.0.113.5 tcp"], "unfixable for its UDP only")

-- Transfers cut short (stall on circular): the first 4 KB pass, which circular counts as a
-- success (its stub here marks the connection judged), and the rest never comes. Two within
-- the time switch the strategy; a cycle of strategies that each cut it is unfixable.
local srec = { nstrategy = 1, ctstrategy = 3 }
autostate.circular_3_1["discord.com"] = srec
local sarg = { key = "circular_3_1", fails = "2", time = "300", stall = "", win = "15" }
local function spacket(track, outgoing, opts)
  return {
    track = track,
    outgoing = outgoing,
    arg = opts.arg or sarg,
    l7payload = opts.l7,
    pos = { n = opts.n or 1, s = opts.s or 1 },
    dis = { flow = track.flow, tcp = { th_flags = opts.flags or 16 }, payload = opts.payload or "" },
  }
end
-- A connection that sent its ClientHello and got `body` back, judged as circular does.
local function transfer(body, opts)
  opts = opts or {}
  local t = flow("discord.com")
  local crec = {}
  automate_failure_check(spacket(t, true, { l7 = opts.nontls and "mtproto_initial" or "tls_client_hello", payload = "hello" }), srec, crec)
  automate_failure_check(spacket(t, false, { s = 1, n = opts.n or 5, payload = body }), srec, crec)
  return t, crec
end
local cut = record(9000) .. string.rep("x", 4000)
local _, c1 = transfer(cut)
assert(c1.nocheck, "the connection counted as a success meanwhile")
fire("psst_")
assert(srec.nstrategy == 1 and #srec.ps_stalls == 1, "one cut transfer only counts")
transfer(cut)
fire("psst_")
assert(srec.nstrategy == 2 and srec.ps_stall_cycle == 1 and not srec.ps_stalls, "two cut transfers switch the strategy")
-- Finished replies, ones past the queue window, ones the client hung up on, and what is not
-- TLS say nothing: whole records, a packet number past win, a reset, an unknown framing.
transfer(record(100) .. string.rep("x", 100))
transfer(cut, { n = 20 })
local hung, hung_crec = transfer(cut)
automate_failure_check(spacket(hung, true, { flags = TH_RST }), srec, hung_crec)
transfer(cut, { nontls = true })
fire("psst_")
assert(srec.nstrategy == 2 and not srec.ps_stalls, "finished, out of window, hung up or non-TLS transfers are no failure")
-- Not asked for (no stall on the circular): nothing is watched.
local plain = {}
for k, v in pairs(sarg) do plain[k] = v end
plain.stall = nil
local pt = flow("discord.com")
automate_failure_check(spacket(pt, true, { l7 = "tls_client_hello", payload = "hello", arg = plain }), srec, {})
automate_failure_check(spacket(pt, false, { s = 1, n = 5, payload = cut, arg = plain }), srec, {})
fire("psst_")
assert(srec.nstrategy == 2 and not srec.ps_stalls, "without stall nothing is watched")
-- Every strategy cut it in turn: unfixable, and the rotation stops there.
for _ = 1, 4 do
  transfer(cut)
  fire("psst_")
end
assert(srec.nstrategy == 3 and srec.final == 3 and verdicts()["discord.com tcp"] == "unfixable", "unfixable after a whole cycle of cut transfers")
transfer(cut)
transfer(cut)
fire("psst_")
assert(srec.nstrategy == 3, "no rotation once final")

-- Addresses: unanswered connections make one blocked, an answer clears it; local ones never.
local function syn(ip, answered)
  local s = flow("")
  s.hostname = nil
  local pkt = function(outgoing, flags) return { track = s, outgoing = outgoing, arg = arg, pos = {}, dis = { flow = s.flow, dst = ip, tcp = { th_flags = flags } } } end
  ps_syn(nil, pkt(true, TH_SYN))
  if answered then ps_syn(nil, pkt(false, TH_SYN + TH_ACK)) end
  fire("pssy_")
end
for _ = 1, 3 do
  syn("149.154.167.99")
  syn("192.168.1.1")
end
assert(verdicts()["149.154.167.99 ip"] == "blocked" and not verdicts()["192.168.1.1 ip"], "blocked by address")
syn("149.154.167.99", true)
assert(verdicts()["149.154.167.99 ip"] == "reachable", "an answer clears it")
-- A learned site a strategy got through, cut short past the first 4 KB since: three cut
-- transfers keep it on the proxy. Finished ones, ones the client hung up on, and ones
-- past the queue window say nothing.
local function watch(track, outgoing, opts) ps_watch(nil, packet(track, outgoing, opts)) end
for i = 1, 3 do
  local t = flow("i.scdn.co")
  watch(t, true, { l7 = "tls_client_hello", payload = "hello" })
  watch(t, false, { s = 1, payload = record(16000) .. string.rep("x", 6000), n = 5 })
  watch(t, false, { s = 6006, payload = string.rep("x", 2000), n = 7 })
  fire("psws_")
  assert((verdicts()["i.scdn.co cutoff"] == "stalls") == (i == 3), "stalls after three cut transfers")
end
for _, case in ipairs({ "whole", "hangup", "big" }) do
  for _ = 1, 3 do
    local t = flow(case .. ".example")
    if case == "whole" then
      watch(t, false, { s = 1, payload = record(3) .. "abc", n = 2 })
    elseif case == "hangup" then
      watch(t, false, { s = 1, payload = record(16000) .. "x", n = 2 })
      watch(t, true, { flags = TH_FIN + 16 })
    else
      watch(t, false, { s = 1, payload = record(60000) .. "z", n = 32 })
    end
    fire("psws_")
  end
  assert(not verdicts()[case .. ".example cutoff"], case .. ": no verdict")
end

-- A wildcard domain whose every fresh name resets: past its share of the list, the site
-- itself is learned, which covers the rest, rather than one more name of it.
local f2 = io.open(auto, "a")
for i = 1, 64 do f2:write("r" .. i .. ".wild.example\n") end
f2:close()
for _ = 1, 3 do
  hello(flow("r65.wild.example"))
  fire("psln_")
end
assert(learned()["wild.example"] and not learned()["r65.wild.example"], "a flooding site learned whole")

-- proxy-ctl's forget: a learned name taken off the list is learned again, from failures
-- counted afresh.
do
  local kept = {}
  for line in io.lines(auto) do
    if line ~= "reset.example" then kept[#kept + 1] = line .. "\n" end
  end
  local w = io.open(auto, "w")
  w:write(table.concat(kept))
  w:close()
end
for i = 1, 3 do
  local r = flow("reset.example")
  hello(r)
  ps_learn(nil, packet(r, false, { flags = TH_RST, s = 1 }))
  assert((learned()["reset.example"] == true) == (i == 3), "forgotten, learned again after three new failures")
end

-- proxy-ctl's clear: the verdicts emptied are no longer taken as given here, and what was
-- counted towards them goes with them.
for _ = 1, 3 do syn("149.154.167.99") end
assert(verdicts()["149.154.167.99 ip"] == "blocked")
io.open(verdict_file, "w"):close()
syn("149.154.167.99")
assert(qrec.ps_cycle == 0, "a whole cycle again before it is unfixable")
assert(urec.ps_cycle == 0 and trec.ps_cycle == 1, "by the transport its verdict was for")
syn("149.154.167.99")
assert(not verdicts()["149.154.167.99 ip"], "judged afresh after the clear")
syn("149.154.167.99")
assert(verdicts()["149.154.167.99 ip"] == "blocked", "blocked again, though blocked before the clear")
print("detect.lua ok")
