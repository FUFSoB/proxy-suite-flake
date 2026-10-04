-- z2k-state-persist.lua keeps a host's strategy in memory and writes it to state.tsv
-- only while the change is new: a write it skips is never retried, unless some other
-- host changes later. It skips one within 2 s of the last (for router flash) and one
-- while another writer holds the lock (the per-app instance, proxy-ctl). A restart
-- then loses the switch. Every change is written now, and a minute after a change
-- the whole state is written once more, whatever happened to the first write.

local api = z2k_state_persist
if not (api and api._set_interval and api._state and api.flush) then
  error("proxy-suite: z2k-state-persist.lua no longer exports _set_interval, _state and flush")
end
api._set_interval(0)

local RECHECK = 60 -- seconds

local function digest()
  local rows = {}
  for askey, hosts in pairs(api._state()) do
    for host, rec in pairs(hosts) do
      rows[#rows + 1] = table.concat({
        tostring(askey), tostring(host), tostring(rec.strategy), tostring(rec.mode),
        tostring(rec.sni), tostring(rec.deleted),
      }, "\t")
    end
  end
  table.sort(rows)
  return table.concat(rows, "\n")
end

-- From the start: a write that failed on the first packet is retried too.
local checked, seen = os.time(), digest()

-- Checked on traffic, not on a timer: a timer would keep nfqws2 --dry-run from exiting.
local rotate = circular
if type(rotate) == "function" then
  function circular(ctx, desync)
    local verdict = rotate(ctx, desync)
    local now = os.time()
    if now - checked >= RECHECK then
      checked = now
      local d = digest()
      if d ~= seen then api.flush() end
      seen = d
    end
    return verdict
  end
end
