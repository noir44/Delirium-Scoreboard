-- Delirium-Scoreboard: server side.
--
-- Two boards of zombie kills:
--   totals - kills of the player's current character; death sets it to 0
--            (a respawn in PZ is a brand new character);
--   event  - kills made while the current event runs (an admin starts it,
--            which starts this board from zero); death sets it to 0 too
--            unless the sandbox option DelScore.EventResetOnDeath is off.
--
-- Counted on Events.OnZombieDead, credited to zombie:getAttackedBy() when that
-- is a player. Not player:getZombieKills(): the server's copy of that counter
-- misses kills (20 zombies killed, 15 on the counter). In the jar it only grows
-- in IsoGameCharacter.hitConsequences, the "DoDeath" animation event of
-- ZombieHitReactionState and vehicle hits, while every death goes through
-- IsoGameCharacter.Kill(killer): setAttackedBy(killer), then
-- IsoZombie.onKilled, which fires OnZombieDead when not GameClient.client,
-- i.e. on the server, once per zombie (isOnKillDone guard).
--
-- Storage is files in Zomboid/Lua/DelScore/, NOT world ModData: ModData only
-- reaches disk when the world is saved, and a server closed without saving
-- (console window closed) came back with the events and backups of the whole
-- session gone. Files are written within seconds of every change:
--   state_a.txt / state_b.txt  live state, written in turn, highest seq wins;
--                              a file without its final "end" line is ignored
--   backup_NNNN.txt            one per backup, same format
--   backups.txt                index of the backups the admin window lists
--   restore.txt                an admin puts a backup here to load it
if not isServer() then return end
require "DelScore_Shared"

local MOD = DelScore.MODULE
local DIR = DelScore.DIR

local DEATH_CHECK_MS = 500
local BROADCAST_MS = 3000
local SAVE_MS = 2000
local RESTORE_CHECK_MS = 10000
local MAX_VALUE = 10000000

local S = nil             -- live state, see newState()
local dirty = true        -- boards changed since the last broadcast
local unsaved = false     -- state changed since the last state file write
local lastDeathCheck, lastBroadcast, lastSave, lastRestoreCheck = 0, 0, 0, 0
local alive = {}          -- username -> IsoPlayer last seen alive

local function log(msg) print("[DelScore] " .. msg) end

local function changed()
	dirty = true
	unsaved = true
end

local function newState()
	return {
		seq = 0,
		totals = {},       -- username -> kills
		event = { name = "", active = false, kills = {} },
		backups = {},      -- index, oldest first: { id, kind, reason, arg, by, date, players, eventName, eventPlayers }
		nextBackupId = 1,
	}
end

local function copyEvent(e)
	return {
		name = e.name or "", active = e.active == true,
		startHours = e.startHours, stopHours = e.stopHours, startDate = e.startDate,
		kills = DelScore.copyMap(e.kills),
	}
end

local function num(n)
	return string.format("%d", math.floor(tonumber(n) or 0))
end

-- No tabs or line breaks inside a field of a tab separated line.
local function field(s)
	return (string.gsub(tostring(s or ""), "[%c]", " "))
end

---- files --------------------------------------------------------------------

local function writeSnapshot(path, header, snap)
	local w = getFileWriter(path, true, false)
	if not w then
		log("cannot write Zomboid/Lua/" .. path)
		return false
	end
	local e = snap.event
	w:write("# " .. header .. "\r\n")
	w:write("# Copy this file to Zomboid/Lua/" .. DIR .. "restore.txt to load it back.\r\n")
	if snap.seq then w:write("seq=" .. num(snap.seq) .. "\r\n") end
	w:write("event_name=" .. field(e.name) .. "\r\n")
	w:write("event_active=" .. (e.active and "1" or "0") .. "\r\n")
	w:write("event_start=" .. tostring(e.startHours or "") .. "\r\n")
	w:write("event_stop=" .. tostring(e.stopHours or "") .. "\r\n")
	w:write("event_date=" .. field(e.startDate) .. "\r\n")
	for username, n in pairs(snap.totals) do w:write("total\t" .. username .. "\t" .. num(n) .. "\r\n") end
	for username, n in pairs(e.kills or {}) do w:write("event\t" .. username .. "\t" .. num(n) .. "\r\n") end
	w:write("end\r\n")
	w:close()
	return true
end

-- Returns { seq, totals, event, complete } or nil when the file is missing or
-- has nothing in it. Lines of other kinds ("seen", "newlife" from the
-- version that read getZombieKills) are skipped.
local function readSnapshot(path)
	local r = getFileReader(path, false)
	if not r then return nil end
	local snap = {
		seq = 0, totals = {},
		event = { name = "", active = false, kills = {} }, complete = false,
	}
	local found = false
	local line = r:readLine()
	while line ~= nil do
		line = string.gsub(line, "\r$", "")
		local kind, username, n = string.match(line, "^(%a+)\t(.-)\t(%d+)%s*$")
		if kind and username ~= "" then
			found = true
			if kind == "total" then snap.totals[username] = tonumber(n)
			elseif kind == "event" then snap.event.kills[username] = tonumber(n)
			end
		elseif line == "end" then
			snap.complete = true
		else
			local k, v = string.match(line, "^([%a_]+)=(.*)$")
			if k == "seq" then snap.seq = tonumber(v) or 0
			elseif k == "event_name" then snap.event.name = v; found = true
			elseif k == "event_active" then snap.event.active = (v == "1")
			elseif k == "event_start" then snap.event.startHours = tonumber(v)
			elseif k == "event_stop" then snap.event.stopHours = tonumber(v)
			elseif k == "event_date" and v ~= "" then snap.event.startDate = v
			end
		end
		line = r:readLine()
	end
	r:close()
	if not found then return nil end
	return snap
end

local function backupFile(id)
	return DIR .. string.format("backup_%04d.txt", id)
end

local function writeIndex()
	local w = getFileWriter(DIR .. "backups.txt", true, false)
	if not w then return end
	w:write("# id\tkind\treason\targ\tby\tgame date\tplayers\tevent\tevent players\r\n")
	for _, b in ipairs(S.backups) do
		w:write(table.concat({ num(b.id), field(b.kind), field(b.reason), field(b.arg), field(b.by),
			field(b.date), num(b.players), field(b.eventName), num(b.eventPlayers) }, "\t") .. "\r\n")
	end
	w:close()
end

local function readIndex()
	local list = {}
	local r = getFileReader(DIR .. "backups.txt", false)
	if not r then return list end
	local line = r:readLine()
	while line ~= nil do
		line = string.gsub(line, "\r$", "")
		if string.sub(line, 1, 1) ~= "#" then
			local p = {}
			for part in string.gmatch(line .. "\t", "([^\t]*)\t") do p[#p + 1] = part end
			local id = tonumber(p[1])
			if id then
				list[#list + 1] = {
					id = id, kind = p[2], reason = p[3], arg = p[4], by = p[5], date = p[6],
					players = tonumber(p[7]) or 0, eventName = p[8] or "", eventPlayers = tonumber(p[9]) or 0,
				}
			end
		end
		line = r:readLine()
	end
	r:close()
	return list
end

-- Two files written in turn: a crash in the middle of a write leaves the other
-- one whole.
local function saveState()
	S.seq = S.seq + 1
	local slot = (S.seq % 2 == 0) and "state_a.txt" or "state_b.txt"
	if writeSnapshot(DIR .. slot, "Delirium Scoreboard live state, game date " .. DelScore.gameDate(), S) then
		unsaved = false
	end
end

---- backups ------------------------------------------------------------------

local function countKeys(t)
	local n = 0
	for _, _ in pairs(t or {}) do n = n + 1 end
	return n
end

-- reason is a code (IGUI_DelScore_Reason_<code> on the client), arg its detail.
local function makeBackup(kind, reason, by, arg)
	local b = {
		id = S.nextBackupId, kind = kind, reason = reason, arg = arg or "", by = by or "",
		date = DelScore.gameDate(), players = countKeys(S.totals),
		eventName = S.event.name or "", eventPlayers = countKeys(S.event.kills),
	}
	S.nextBackupId = S.nextBackupId + 1
	local snap = { totals = S.totals, event = S.event }
	local header = string.format("Delirium Scoreboard backup %d (%s, by %s), game date %s",
		b.id, reason .. (b.arg ~= "" and " " .. b.arg or ""), b.by ~= "" and b.by or "server", b.date)
	if not writeSnapshot(backupFile(b.id), header, snap) then return nil end

	S.backups[#S.backups + 1] = b
	-- Keep the newest DelScore.MANUAL_BACKUPS manual and AUTO_BACKUPS automatic
	-- ones listed; older files stay on disk.
	local keep, manual, auto = {}, 0, 0
	for i = #S.backups, 1, -1 do
		local x = S.backups[i]
		if x.kind == "auto" then auto = auto + 1 else manual = manual + 1 end
		if (x.kind == "auto" and auto <= DelScore.AUTO_BACKUPS) or (x.kind ~= "auto" and manual <= DelScore.MANUAL_BACKUPS) then
			table.insert(keep, 1, x)
		end
	end
	S.backups = keep
	writeIndex()
	log(string.format("backup %d saved (%s) -> Zomboid/Lua/%s", b.id, reason, backupFile(b.id)))
	return b
end

local function applySnapshot(snap)
	S.totals = DelScore.copyMap(snap.totals)
	S.event = copyEvent(snap.event)
	changed()
	saveState()
end

---- loading ------------------------------------------------------------------

local function load()
	S = newState()
	local a = readSnapshot(DIR .. "state_a.txt")
	local b = readSnapshot(DIR .. "state_b.txt")
	if a and not a.complete then a = nil end
	if b and not b.complete then b = nil end
	local best = a
	if b and (not best or b.seq > best.seq) then best = b end

	if best then
		S.seq = best.seq
		S.totals, S.event = best.totals, copyEvent(best.event)
		log(string.format("loaded state seq %d: %d players, event '%s'", S.seq, countKeys(S.totals), S.event.name))
	else
		-- The first version of the mod kept everything in world ModData.
		local old = ModData.get("DelScore")
		if old and old.totals then
			S.totals = DelScore.copyMap(old.totals)
			if old.event then S.event = copyEvent(old.event) end
			log("moved state from world ModData to files")
		else
			log("no saved state, starting empty")
		end
		unsaved = true
	end

	S.backups = readIndex()
	for _, x in ipairs(S.backups) do
		if x.id >= S.nextBackupId then S.nextBackupId = x.id + 1 end
	end
	-- An index lost or older than the files: never write over a backup file.
	local r = getFileReader(backupFile(S.nextBackupId), false)
	while r do
		r:close()
		S.nextBackupId = S.nextBackupId + 1
		r = getFileReader(backupFile(S.nextBackupId), false)
	end

	makeBackup("auto", "start", "")
	if unsaved then saveState() end
end

local function state()
	if not S then load() end
	return S
end

---- counting -----------------------------------------------------------------

local function addKills(username, n)
	if n <= 0 then return end
	S.totals[username] = (S.totals[username] or 0) + n
	if S.event.active then
		S.event.kills[username] = (S.event.kills[username] or 0) + n
	end
	changed()
end

local function onZombieDead(zombie)
	local killer = zombie and zombie:getAttackedBy()
	if not killer or not instanceof(killer, "IsoPlayer") then return end
	local username = killer:getUsername()
	if not username or username == "" then return end
	state()
	addKills(username, 1)
end

-- Death resets the player's row. A dead character's IsoPlayer stays dead; the
-- respawned one is a new object. Also puts every online player on the board.
local function checkDeaths()
	for username, obj in pairs(alive) do
		if obj:isDead() then
			alive[username] = nil
			S.totals[username] = 0
			-- Read here, not cached: a file-scope read sees the schema default.
			local opts = SandboxVars.DelScore
			local resetEvent = not (opts and opts.EventResetOnDeath == false)
			if resetEvent and S.event.kills[username] then S.event.kills[username] = 0 end
			changed()
			log(username .. " died, board reset" .. (resetEvent and " (event too)" or ""))
		end
	end
	local online = {}
	local players = getOnlinePlayers()
	if players then
		for i = 0, players:size() - 1 do
			local p = players:get(i)
			local username = p and p:getUsername()
			if username then
				online[username] = true
				if not p:isDead() then alive[username] = p end
				if S.totals[username] == nil then
					S.totals[username] = 0
					changed()
				end
			end
		end
	end
	for username, _ in pairs(alive) do
		if not online[username] then alive[username] = nil end
	end
end

-- Zomboid/Lua/DelScore/restore.txt: an admin copies a backup file there and the
-- server loads it within seconds, then empties the file.
local function checkRestoreFile()
	local path = DIR .. "restore.txt"
	local snap = readSnapshot(path)
	if not snap then return end
	makeBackup("manual", "restoreFile", "")
	applySnapshot(snap)
	local w = getFileWriter(path, true, false)
	if w then w:close() end
	log("loaded Zomboid/Lua/" .. path .. " and emptied it")
	sendServerCommand(MOD, "msg", { key = "IGUI_DelScore_Msg_Restored" })
end

---- network ------------------------------------------------------------------

local function payload()
	local e = S.event
	return {
		totals = S.totals,
		event = {
			name = e.name, active = e.active, startHours = e.startHours,
			stopHours = e.stopHours, startDate = e.startDate, kills = e.kills,
		},
	}
end

local function backupList()
	local out = {}
	for i = #S.backups, 1, -1 do out[#out + 1] = S.backups[i] end
	return out
end

local function sendBackups(player)
	sendServerCommand(player, MOD, "backups", { list = backupList() })
end

local function reply(player, key, arg)
	sendServerCommand(player, MOD, "msg", { key = key, arg = arg })
end

local function cleanName(s)
	if type(s) ~= "string" then return nil end
	s = string.gsub(string.gsub(s, "[%c]", " "), "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	if s == "" then return nil end
	return string.sub(s, 1, DelScore.EVENT_NAME_MAX)
end

local function boardOf(board)
	if board == "event" then return S.event.kills end
	if board == "total" then return S.totals end
	return nil
end

-- Every admin change is on disk before the command returns.
local adminCommands = {}

function adminCommands.eventNew(player, args)
	local name = cleanName(args.name)
	if not name then return end
	makeBackup("manual", "newEvent", player:getUsername(), S.event.name)
	S.event = {
		name = name, active = true, kills = {},
		startHours = getGameTime():getWorldAgeHours(), startDate = DelScore.gameDate(),
	}
	changed()
	saveState()
	log(player:getUsername() .. " started event '" .. name .. "'")
	reply(player, "IGUI_DelScore_Msg_EventStarted", name)
end

function adminCommands.eventStop(player)
	if not S.event.active then return end
	S.event.active = false
	S.event.stopHours = getGameTime():getWorldAgeHours()
	changed()
	saveState()
	log(player:getUsername() .. " stopped event '" .. tostring(S.event.name) .. "'")
end

function adminCommands.eventResume(player)
	if S.event.active or not S.event.startHours then return end
	S.event.active = true
	S.event.stopHours = nil
	changed()
	saveState()
	log(player:getUsername() .. " resumed event '" .. tostring(S.event.name) .. "'")
end

function adminCommands.set(player, args)
	local t = boardOf(args.board)
	local username = type(args.name) == "string" and args.name or nil
	local value = math.floor(tonumber(args.value) or -1)
	if not t or not username or value < 0 or value > MAX_VALUE then return end
	makeBackup("manual", "set", player:getUsername(), string.format("%s %s=%d", args.board, username, value))
	t[username] = value
	changed()
	saveState()
	log(string.format("%s set %s %s = %d", player:getUsername(), args.board, username, value))
end

function adminCommands.remove(player, args)
	local t = boardOf(args.board)
	local username = type(args.name) == "string" and args.name or nil
	if not t or not username or t[username] == nil then return end
	makeBackup("manual", "remove", player:getUsername(), args.board .. " " .. username)
	t[username] = nil
	changed()
	saveState()
	log(string.format("%s removed %s from %s", player:getUsername(), username, args.board))
end

function adminCommands.backupNow(player)
	local b = makeBackup("manual", "manual", player:getUsername())
	if b then reply(player, "IGUI_DelScore_Msg_BackupSaved", tostring(b.id)) end
	sendBackups(player)
end

function adminCommands.backups(player)
	sendBackups(player)
end

function adminCommands.restore(player, args)
	local id = tonumber(args.id)
	if not id then return end
	local snap = readSnapshot(backupFile(id))
	if not snap then
		log("backup " .. id .. " not found in Zomboid/Lua/" .. backupFile(id))
		return
	end
	makeBackup("manual", "restore", player:getUsername(), tostring(id))
	applySnapshot(snap)
	log(player:getUsername() .. " restored backup " .. id)
	reply(player, "IGUI_DelScore_Msg_Restored")
	sendBackups(player)
end

local function onClientCommand(module, command, player, args)
	if module ~= MOD or not player then return end
	args = args or {}
	state()
	if command == "get" then
		sendServerCommand(player, MOD, "data", payload())
		return
	end
	local handler = adminCommands[command]
	if not handler then return end
	if not DelScore.isAdmin(player) then
		log("refused '" .. command .. "' from non-admin " .. tostring(player:getUsername()))
		return
	end
	handler(player, args)
end

---- events -------------------------------------------------------------------

local function onTick()
	state()
	local now = getTimestampMs()
	if now - lastDeathCheck >= DEATH_CHECK_MS then
		lastDeathCheck = now
		checkDeaths()
	end
	if now - lastRestoreCheck >= RESTORE_CHECK_MS then
		lastRestoreCheck = now
		checkRestoreFile()
	end
	if unsaved and now - lastSave >= SAVE_MS then
		lastSave = now
		saveState()
	end
	if dirty and now - lastBroadcast >= BROADCAST_MS then
		lastBroadcast = now
		dirty = false
		sendServerCommand(MOD, "data", payload())
	end
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnZombieDead.Add(onZombieDead)
Events.EveryDays.Add(function() state(); makeBackup("auto", "daily", "") end)
Events.OnTick.Add(onTick)
