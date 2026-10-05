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
function standard_failure_detector() return "standard" end
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
function z2k_fail_tls_alert() return "z2k" end

-- detect.lua's public suffixes, loaded before it as nfqws2 does.
dofile(os.getenv("PSL"))
dofile(os.getenv("DETECT"))

local auto = work .. "/auto.txt"
local excl = work .. "/exclude.txt"
local f = io.open(excl, "w")
f:write("bank.example\n")
f:close()
io.open(auto, "w"):close()
local arg = { auto = auto, exclude = excl, fails = "3", time = "300", inseq = "4096", win = "32", exclude_domains = "skip.example" }

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

-- works: a connection that got through, by the site key, with its protocol.
local wrec = { ps_cycle = 4 }
automate_failure_check({ arg = { key = "rkn_tcp" }, track = { hostname = "www.notion.so" }, dis = { tcp = {} } }, wrec, {})
assert(verdicts()["notion.so tcp"] == "works" and wrec.ps_cycle == 0, "works recorded, the cycle count reset")

-- unfixable: a whole cycle of strategies without one success stops the rotation.
local qrec = { nstrategy = 2, ctstrategy = 2 }
autostate = { rkn_quic = { ["discord.com"] = qrec } }
automate_failure_counter(qrec, {}, 1)
assert(not qrec.final)
automate_failure_counter(qrec, {}, 1)
assert(qrec.final == 2 and verdicts()["discord.com udp"] == "unfixable", "unfixable after a full cycle, QUIC only")

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
print("detect.lua ok")
