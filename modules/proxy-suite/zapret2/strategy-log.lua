-- One journal line per counted failure and per strategy switch. nfqws2 logs them
-- only with --debug, among every packet's lines. Loaded after z2k-state-persist.lua,
-- so the switch it reports is the one that stuck, after its sticky-success revert.

local count, rotate = automate_failure_counter, circular
-- host record -> its strategy when the failure count was reached: circular, or
-- z2k's QUIC silence timer, switches it right after.
local pending = setmetatable({}, { __mode = "k" })

-- "<circular key> <host>": the record knows neither, autostate maps them to it.
local function name(hrec)
  for askey, hosts in pairs(autostate or {}) do
    for host, rec in pairs(hosts) do
      if rec == hrec then return tostring(askey) .. " " .. tostring(host) end
    end
  end
  return "?"
end

local function log(hrec, text)
  -- The host comes off the wire (a SNI): no control character, so no forged journal line.
  io.stderr:write("zapret2: ", (tostring(name(hrec)):gsub("%c", "?")), ": ", (tostring(text):gsub("%c", "?")), "\n")
end

local function of(hrec)
  return tostring(hrec.nstrategy or 1) .. "/" .. tostring(hrec.ctstrategy or "?")
end

function automate_failure_counter(hrec, crec, fails, maxtime)
  local duplicate = crec and crec.failure
  local reached = count(hrec, crec, fails, maxtime)
  if reached then
    pending[hrec] = hrec.nstrategy or 1
  elseif not duplicate and hrec.failure_counter then
    log(hrec, "failure " .. tostring(hrec.failure_counter) .. "/" .. tostring(fails) .. " on strategy " .. of(hrec))
  end
  return reached
end

local function report()
  for hrec, before in pairs(pending) do
    pending[hrec] = nil
    if (hrec.nstrategy or 1) ~= before then
      log(hrec, "switched from strategy " .. tostring(before) .. " to " .. of(hrec))
    else
      log(hrec, "failed enough to switch, but stays on strategy " .. of(hrec) .. ": it worked moments ago, or that strategy is final")
    end
  end
end

if type(rotate) == "function" then
  function circular(ctx, desync)
    local verdict = rotate(ctx, desync)
    -- Also what the QUIC timer switched since the last packet.
    if next(pending) then report() end
    return verdict
  end
end
