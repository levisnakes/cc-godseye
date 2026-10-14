# God's Eye: remote injection

God's Eye is a CC:Tweaked base intrusion logger (Create Radar + Advanced Peripherals Player Detector). This repo adds **remote injection**: a pocket computer can report a player to the base by hand. The base treats that player like a detector contact. It logs the visit to `godseye.dat`, plays the alert sound, posts to Discord, shows the player on the monitor, the HUD feed and the website, and closes the visit once the reports stop.

## Install

Base computer (replaces the old `startup`; your `.cfg` file is kept):

```
rm startup
wget https://raw.githubusercontent.com/levisnakes/cc-godseye/main/startup startup
```

Pocket computer (needs a wireless or ender modem):

```
wget https://raw.githubusercontent.com/levisnakes/cc-godseye/main/remote_injector.lua remote_injector.lua
```

## Settings

In the base's `.cfg` (`godseye.cfg` or `godseyeDGPU.cfg`):

```lua
remoteChannel = 4245,      -- nil turns remote injection off
remoteKey     = "pick-a-password",
remoteTTL     = 30,        -- seconds an injected player stays "seen" after the last packet
```

At the top of `remote_injector.lua`, set `KEY` to the same password. If `remoteKey` is blank, the base accepts packets from anyone on the channel, and the startup screen shows "no key set!".

## Using the pocket

Type a player name, then a position:

| Input | Meaning |
|---|---|
| `2700 85 15` | exact x y z |
| `2700 15` | x z |
| `NW 60` | 60 blocks north-west of the base centre |
| `NW` | direction only (logged, no radar dot) |
| *(blank)* | the pocket's own GPS position |

The base replies, and the pocket shows `SENT: ...` (green), `REJECTED: ...` (red), or a warning if nothing answered. After sending: **Enter** reports a new player (a blank name repeats the last one), **R** resends (keeps them "seen" for another `remoteTTL`), **X** removes them, **Q** quits.

Injected entries show a `*` before the name in the monitor log, and the Discord alert says "Reported by **<pocket label>**". If the detector or radar already sees that player, the injection is ignored so the visit doesn't get logged twice.

## Packet format (channel 4245)

```lua
{ action = "INJECT_PLAYER", name = "PlayerName", x = 2700, y = 85, z = 15,
  dir = "NW", dist = 60, source = "PocketRemote", key = "..." }
{ action = "REMOVE_PLAYER", name = "PlayerName", key = "..." }
```

The base answers on the packet's reply channel with `{ action = "INJECT_ACK", ok = true/false, name = ..., msg = ... }`.

## Tests

`python test/test_inject.py` (needs `pip install lupa`) runs the real `startup` and `remote_injector.lua` against a mocked CC environment. It checks the key, the acks, logging, Discord, the HUD, removal and TTL expiry.
