-- Tiny discrete-event CC:Tweaked mock: several computers, timers, modems.
local T = 1760000000000          -- fake os.epoch("utc") in ms
local procs, timers, nextTimer = {}, {}, 1

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {} for k, x in pairs(v) do t[deepcopy(k)] = deepcopy(x) end return t
end

local function dump(v, ind)
  ind = ind or ""
  if type(v) == "string" then return ("%q"):format(v) end
  if type(v) ~= "table" then return tostring(v) end
  local out = {}
  for k, x in pairs(v) do
    local key = type(k) == "string" and ("[%q]"):format(k) or ("[" .. tostring(k) .. "]")
    out[#out + 1] = ind .. "  " .. key .. " = " .. dump(x, ind .. "  ")
  end
  return "{\n" .. table.concat(out, ",\n") .. "\n" .. ind .. "}"
end

local function json(v)
  if type(v) == "string" then return '"' .. v:gsub('[%c"\\]', function(c)
      return c == "\n" and "\\n" or ("\\u%04x"):format(c:byte()) end) .. '"' end
  if type(v) ~= "table" then return tostring(v) end
  local out = {}
  if #v > 0 then for _, x in ipairs(v) do out[#out + 1] = json(x) end return "[" .. table.concat(out, ",") .. "]" end
  for k, x in pairs(v) do out[#out + 1] = json(tostring(k)) .. ":" .. json(x) end
  return "{" .. table.concat(out, ",") .. "}"
end

local function noopObj(extra)
  return setmetatable(extra or {}, { __index = function() return function() end end })
end

local function waitForAny(...)
  local fns, cos, filters = { ... }, {}, {}
  for i, f in ipairs(fns) do cos[i] = coroutine.create(f) end
  local ev = {}
  while true do
    for i, co in ipairs(cos) do
      if filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
        local ok, f = coroutine.resume(co, table.unpack(ev))
        if not ok then error(f, 0) end
        filters[i] = f
        if coroutine.status(co) == "dead" then return i end
      end
    end
    ev = { coroutine.yield() }
  end
end

-- make one computer; returns its proc record (env + bookkeeping)
function newComputer(id, label)
  local P = { id = id, queue = {}, open = {}, sent = {}, out = {}, files = {}, script = {} }
  local env = setmetatable({}, { __index = _G })
  P.env = env
  local function pullRaw(filter)
    while true do
      local ev = { coroutine.yield(filter) }
      if not filter or ev[1] == filter or ev[1] == "terminate" then return table.unpack(ev) end
    end
  end
  env.os = setmetatable({
    epoch = function() return T end,
    day = function() return 507 end, time = function() return 2.25 end,
    getComputerID = function() return id end, getComputerLabel = function() return label end,
    startTimer = function(s)
      local tid = nextTimer; nextTimer = nextTimer + 1
      timers[tid] = { at = T + math.max(s, 0.05) * 1000, proc = P }
      return tid
    end,
    cancelTimer = function(tid) timers[tid] = nil end,
    pullEvent = pullRaw, pullEventRaw = pullRaw,
    queueEvent = function(...) table.insert(P.queue, { ... }) end,
  }, { __index = os })
  env.sleep = function(s)
    local tid = env.os.startTimer(s or 0)
    repeat local _, t = pullRaw("timer") until t == tid
  end
  env.print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
    P.out[#P.out + 1] = table.concat(t, " ") end
  env.printError = env.print
  env.write = function(s) P.out[#P.out + 1] = tostring(s) end
  env.read = function()
    local v = table.remove(P.inputs or {}, 1)
    if not v then while true do coroutine.yield("no_more_input") end end   -- user walks away
    P.out[#P.out + 1] = "<" .. v .. ">"
    return v
  end
  env.colors = setmetatable({ toBlit = function() return "0" end }, { __index = function() return 1 end })
  env.colours = env.colors
  env.keys = { enter = 257 }
  env.term = noopObj({ isColor = function() return true end, isColour = function() return true end,
    getSize = function() return 26, 20 end, getCursorPos = function() return 1, 1 end })
  env.term.current = function() return env.term end
  env.redstone = noopObj(); env.rs = env.redstone
  env.gps = { locate = function() return nil end }
  env.parallel = { waitForAny = waitForAny }
  env.require = function(n) error("module '" .. n .. "' not found") end
  env.shell = { getRunningProgram = function() return "startup" end }
  env.textutils = {
    serialize = function(t) return dump(t) end,
    unserialize = function(s) local f = load("return " .. s) return f and f() end,
    serializeJSON = json, unserializeJSON = function() return nil end,
    formatTime = function() return "2:15 AM" end,
  }
  env.fs = {
    exists = function(p) return P.files[p] ~= nil end,
    getDir = function() return "" end, getName = function(p) return p end,
    combine = function(a, b) return a == "" and b or (a .. "/" .. b) end,
    open = function(p, m)
      if m:find("w") then local buf = {}
        return { write = function(s) buf[#buf + 1] = s end, writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
                 close = function() P.files[p] = table.concat(buf) end, flush = function() end }
      end
      if not P.files[p] then return nil end
      return { readAll = function() return P.files[p] end, close = function() end }
    end,
  }
  env.loadfile = function(p, _, e)
    if not P.files[p] then return nil, "not found" end
    return load(P.files[p], "@" .. p, "t", e or env)
  end
  -- peripherals
  P.periph = {}
  local function modem(side)
    return { isWireless = function() return true end,
      open = function(ch) P.open[ch] = true end, close = function(ch) P.open[ch] = nil end,
      isOpen = function(ch) return P.open[ch] == true end,
      transmit = function(ch, reply, msg)
        P.sent[#P.sent + 1] = { ch = ch, reply = reply, msg = deepcopy(msg) }
        for _, Q in ipairs(procs) do
          if Q ~= P and Q.open[ch] then
            table.insert(Q.queue, { "modem_message", "top", ch, reply, deepcopy(msg), 12 })
          end
        end
      end }
  end
  P.periph.top = { type = "modem", obj = modem("top") }
  env.peripheral = {
    getNames = function() local n = {} for k in pairs(P.periph) do n[#n + 1] = k end table.sort(n) return n end,
    getType = function(n) return P.periph[n] and P.periph[n].type end,
    wrap = function(n) return P.periph[n] and P.periph[n].obj end,
    find = function(ty, filter)
      local out = {}
      for _, n in ipairs(env.peripheral.getNames()) do
        local p = P.periph[n]
        if p.type == ty and (not filter or filter(n, p.obj)) then out[#out + 1] = p.obj end
      end
      return table.unpack(out)
    end,
  }
  procs[#procs + 1] = P
  return P
end

function startProgram(P, src, name)
  local fn = assert(load(src, "@" .. name, "t", P.env))
  P.co = coroutine.create(fn)
  P.filter = nil
  local ok, f = coroutine.resume(P.co)
  if not ok then error(name .. ": " .. tostring(f), 0) end
  P.filter = f
end

local function deliver(P, ev)
  if not P.co or coroutine.status(P.co) == "dead" then return end
  if P.filter and P.filter ~= ev[1] and ev[1] ~= "terminate" then return end
  local ok, f = coroutine.resume(P.co, table.unpack(ev))
  if not ok then error("computer " .. P.id .. ": " .. tostring(f), 0) end
  P.filter = f
end

local function hasTimer(P) for _, t in pairs(timers) do if t.proc == P then return true end end end

-- run until `untilMs` of simulated time has passed
function runFor(ms)
  local stop = T + ms
  while T < stop do
    local busy = false
    for _, P in ipairs(procs) do
      local ev = table.remove(P.queue, 1)
      if ev then busy = true deliver(P, ev) end
    end
    if not busy then
      for _, P in ipairs(procs) do      -- idle computer: feed its next scripted user action
        if P.co and coroutine.status(P.co) ~= "dead" and #P.queue == 0 and not hasTimer(P) and #P.script > 0
           and T >= (P.feedAt or 0) then
          table.insert(P.queue, table.remove(P.script, 1)) busy = true
          P.feedAt = T + 2000             -- humans take a moment between keypresses
        end
      end
    end
    if not busy then
      local tid, best
      for id, t in pairs(timers) do if not best or t.at < best.at then tid, best = id, t end end
      if not best then return end
      T = math.max(T, best.at)
      timers[tid] = nil
      table.insert(best.proc.queue, { "timer", tid })
    end
  end
end

function runTest(baseSrc, pocketSrc)
  local ok, err = pcall(function()
    -- BASE: detector sees nobody; webhook configured so alerts are built
    local base = newComputer(163, nil)
    base.webhooks = {}
    base.env.http = { request = function(r) base.webhooks[#base.webhooks + 1] = r.body return true end,
                      post = function() return nil, "mock" end, get = function() return nil, "mock" end }
    base.periph.player_detector_0 = { type = "playerDetector", obj = {
      getPlayersInRange = function() return {} end, getOnlinePlayers = function() return {} end,
      getPlayerPos = function() return nil end } }
    base.files["godseye.cfg"] = [[return { baseX = 2699, baseY = 85, baseZ = 15, radius = 100,
      webhookUrl = "https://discord.invalid/hook", remoteKey = "hunter2", hudChannel = 4242 }]]
    startProgram(base, baseSrc, "startup")
    runFor(3000)
    assert(base.open[4245], "base did not open channel 4245")

    -- POCKET: wrong key first, then the real flow
    local pocket = newComputer(7, "Scout")
    pocket.inputs = { "Griefer99", "2700 85 15" }
    local wrongKey = pocketSrc:gsub('KEY = ""', 'KEY = "nope"', 1)
    startProgram(pocket, wrongKey, "remote_injector.lua")
    runFor(5000)
    local text = table.concat(pocket.out, "\n")
    assert(text:find("REJECTED: wrong key"), "wrong key not rejected:\n" .. text)
    pocket.co = nil

    local pocket2 = newComputer(8, "Scout")
    pocket2.inputs = { "Griefer99", "2700 85 15", "Spy_2", "NW 60", "bad name!" }
    pocket2.script = {
      { "key", 257 },                 -- Enter -> new
      { "char", "r" },                -- resend Spy_2
      { "char", "x" },                -- remove Spy_2
      { "key", 257 },                 -- Enter -> new (bad name)
    }
    local src = pocketSrc:gsub('KEY = ""', 'KEY = "hunter2"', 1)
    startProgram(pocket2, src, "remote_injector.lua")
    runFor(10000)
    text = table.concat(pocket2.out, "\n")
    assert(text:find("SENT: Griefer99 injected at 2700 85 15"), "no ack for Griefer99:\n" .. text)
    assert(text:find("SENT: Spy_2 injected at %-?%d+ 85 %-?%d+"), "no ack for Spy_2:\n" .. text)
    assert(text:find("SENT: Spy_2 removed"), "remove not acked:\n" .. text)
    assert(text:find("Not a valid player name"), "bad name not caught:\n" .. text)

    -- base state, as saved to godseye.dat
    local data = load("return " .. base.files["godseye.dat"])()
    local byName = {}
    for _, e in ipairs(data.log) do byName[e.name] = e end
    local g, s = byName.Griefer99, byName.Spy_2
    assert(g and s, "injected players missing from log:\n" .. text .. "\nLOG " .. dump(data.log) .. "\nBASE:\n" .. table.concat(base.out, "\n"))
    assert(g.source == "Scout" and g.closest == 1, "Griefer99 entry wrong: " .. dump(g))
    assert(s.dir == "NW" and s.closest >= 59 and s.closest <= 60, "Spy_2 entry wrong: " .. dump(s))
    assert(data.known.Griefer99.visits == 1 and data.known.Spy_2.visits == 1, "known not updated / double counted")
    assert(#base.webhooks >= 2, "no Discord alerts")
    local hook = table.concat(base.webhooks, "\n")
    assert(hook:find("Griefer99") and hook:find("Reported by %*%*Scout%*%*"), "alert lacks name/source: " .. hook)
    -- HUD broadcast shows the injected contact while active
    local onHud = false
    for _, m in ipairs(base.sent) do
      if m.ch == 4242 then for _, c in ipairs(m.msg.contacts or {}) do if c.name == "Griefer99" then onHud = true end end end
    end
    assert(onHud, "Griefer99 never appeared on the HUD feed")

    -- Spy_2 was removed: visit closes after leaveAfter; Griefer99 expires after TTL + leaveAfter
    runFor(20000)
    data = load("return " .. base.files["godseye.dat"])()
    for _, e in ipairs(data.log) do byName[e.name] = e end
    assert(byName.Spy_2.leaveT, "Spy_2 visit not closed after remove")
    runFor(40000)
    data = load("return " .. base.files["godseye.dat"])()
    for _, e in ipairs(data.log) do byName[e.name] = e end
    assert(byName.Griefer99.leaveT, "Griefer99 visit not closed after TTL")
    assert(#data.log == 2, "expected exactly 2 log entries, got " .. #data.log)
  end)
  if ok then return "OK all inject checks passed" end
  return "FAIL: " .. tostring(err)
end
