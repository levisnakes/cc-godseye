--[[
  GOD'S EYE  //  remote injector  (pocket computer)
  Reports a player to the base by hand: they get logged, alerted on
  Discord and drawn on the monitor exactly like a detector contact.

  Needs a wireless or ender modem in the pocket computer.
  Position can be typed as:
    2700 85 15     exact x y z
    2700 15        x z
    NW 60          60 blocks north-west of the base centre
    NW             just a direction (no dot on the radar)
    (blank)        your own GPS position, if a GPS network is up
]]

CHANNEL = 4245        -- must match remoteChannel in the base config
KEY = ""              -- must match remoteKey in the base config
SOURCE = nil          -- name shown in the log/Discord; nil = this pocket's label

------------------------------------------------------------------
local REPLY = 20000 + os.getComputerID() % 40000
local DIRS = { N = true, NE = true, E = true, SE = true, S = true, SW = true, W = true, NW = true }
local source = SOURCE or os.getComputerLabel() or ("Pocket" .. os.getComputerID())

local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
if not modem then
  printError("No wireless/ender modem found.")
  return
end
modem.open(REPLY)

local color = term.isColor()
local function say(text, c)
  if color and c then term.setTextColor(c) end
  print(text)
  if color then term.setTextColor(colors.white) end
end

local function header()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  say("GOD'S EYE INJECTOR", colors.red)
  say(("ch %d  key %s"):format(CHANNEL, KEY == "" and "none" or "set"), colors.gray)
  print()
end

-- "2700 85 15" / "2700 15" / "NW 60" / "NW" / "" -> packet fields, or nil + error
local function parsePos(s)
  local words = {}
  for w in s:gmatch("%S+") do words[#words + 1] = w end
  if #words == 0 then
    local x, y, z = gps.locate(2)
    if x then return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }, "your GPS position" end
    return {}, "no position (GPS not available)"
  end
  local dir = words[1]:upper()
  if DIRS[dir] then
    local dist = tonumber(words[2])
    if words[2] and not dist then return nil, "distance must be a number" end
    return { dir = dir, dist = dist }
  end
  local n = {}
  for i, w in ipairs(words) do
    n[i] = tonumber(w)
    if not n[i] then return nil, "'" .. w .. "' is not a number or direction" end
  end
  if #n == 3 then return { x = n[1], y = n[2], z = n[3] } end
  if #n == 2 then return { x = n[1], z = n[2] } end
  return nil, "type x y z, x z, or a direction like NW 60"
end

-- send and wait up to 3 seconds for the base to answer
local function send(packet)
  packet.key = KEY ~= "" and KEY or nil
  packet.source = source
  modem.transmit(CHANNEL, REPLY, packet)
  local timer = os.startTimer(3)
  while true do
    local ev, a1, a2, _, a4 = os.pullEvent()
    if ev == "modem_message" and a2 == REPLY and type(a4) == "table"
       and a4.action == "INJECT_ACK" and a4.name == packet.name then
      os.cancelTimer(timer)
      if a4.ok then say("SENT: " .. tostring(a4.msg), colors.lime)
      else say("REJECTED: " .. tostring(a4.msg), colors.red) end
      return
    elseif ev == "timer" and a1 == timer then
      say("SENT to ch " .. CHANNEL .. ",", colors.yellow)
      say("but the base didn't answer (out of range or not running?)", colors.yellow)
      return
    end
  end
end

local names, last = {}, nil
while true do
  header()
  write("Player: ")
  local name = read(nil, names)
  if name == "" and last then name = last.name end
  if not name:match("^[%w_]+$") or #name > 16 then
    say("Not a valid player name.", colors.red)
    sleep(1.5)
  else
    table.insert(names, name)
    say("Pos: x y z | x z | NW 60 | blank=GPS", colors.gray)
    write("Pos: ")
    local pos, note = parsePos(read())
    if not pos then
      say(note, colors.red)
      sleep(2)
    else
      if note then say("Using " .. note, colors.gray) end
      last = { action = "INJECT_PLAYER", name = name,
               x = pos.x, y = pos.y, z = pos.z, dir = pos.dir, dist = pos.dist }
      send(last)
      while true do
        print()
        say("[Enter] new  [R] resend", colors.lightGray)
        say("[X] remove   [Q] quit", colors.lightGray)
        local ev, p = os.pullEvent()
        local c = ev == "char" and p:lower()
        if ev == "key" and p == keys.enter then break
        elseif c == "r" then send(last)
        elseif c == "x" then send({ action = "REMOVE_PLAYER", name = last.name })
        elseif c == "q" then
          term.clear() term.setCursorPos(1, 1)
          return
        end
      end
    end
  end
end
