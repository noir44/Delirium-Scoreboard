-- Delirium-Scoreboard: server side.
--
-- Two boards of zombie kills:
--   totals - kills of the player's current character; death sets it to 0
--            (a respawn in PZ is a brand new character);
--   event  - kills made while the current event runs (an admin starts it,
--            which starts this board from zero); death sets it to 0 too
--            unless the sandbox option DelScore.EventResetOnDeath is off.
--
-- The source is vanilla's own per-character counter player:getZombieKills()
-- (the "Zombies killed" line of the character screen). The server reads it for
-- every online player once a game minute and adds the growth since the last
-- reading to both boards, so a player is never counted twice.
--
-- Everything lives in global ModData "DelScore" (never in player ModData: the
-- client pushes its copy back and would overwrite server counts). Before every
-- change an admin makes a copy goes to the backup list and to a file in
-- Zomboid/Lua/DelScore/; Zomboid/Lua/DelScore/current.txt follows the boards.
if not isServer() then return end
require "DelScore_Shared"

local MOD = DelScore.MODULE
local DIR = DelScore.DIR

local DEATH_CHECK_MS = 500
local BROADCAST_MS = 3000
local FILE_SAVE_MS = 60000
local RESTORE_CHECK_MS = 10000
local MAX_VALUE = 10000000

local dirty = true        -- boards changed since the last broadcast
local fileDirty = true    -- boards changed since current.txt was written
local lastDeathCheck, lastBroadcast, lastFileSave, lastRestoreCheck = 0, 0, 0, 0
local alive = {}          -- username -> IsoPlayer last seen alive
local warned = {}         -- username -> counter value already reported as going down

local function log(msg) print("[DelScore] " .. msg) end

local function state()
	local d = ModData.getOrCreate("DelScore")
	d.totals = d.totals or {}          -- username -> kills
	d.seen = d.seen or {}              -- username -> last getZombieKills() read
	d.newLife = d.newLife or {}        -- username -> true once the character died
	d.event = d.event or { name = "", active = false }
	d.event.kills = d.event.kills or {}
	d.backups = d.backups or {}        -- before admin changes, oldest first
	d.autoBackups = d.autoBackups or {}
	d.nextBackupId = d.nextBackupId or 1
	return d
end

local function changed()
	dirty = true
	fileDirty = true
end

local function copyEvent(e)
	return {
		name = e.name or "", active = e.active == true,
		startHours = e.startHours, stopHours = e.stopHours, startDate = e.startDate,
		kills = DelScore.copyMap(e.kills),
	}
end

---- counting -----------------------------------------------------------------

local function addKills(d, username, n)
	if n <= 0 then return end
	d.totals[username] = (d.totals[username] or 0) + n
	if d.event.active then
		d.event.kills[username] = (d.event.kills[username] or 0) + n
	end
	changed()
end

-- One reading of a character's counter.
local function account(d, username, cur)
	cur = math.floor(tonumber(cur) or 0)
	local last = d.seen[username]
	if d.newLife[username] then
		-- First reading of a new character: everything on its counter is new.
		d.newLife[username] = nil
		d.seen[username] = cur
		addKills(d, username, cur)
	elseif last == nil then
		-- Account seen for the first time: the character's kills so far go to
		-- its board only, never to an event that is already running.
		d.seen[username] = cur
		d.totals[username] = cur
		changed()
	elseif cur > last then
		d.seen[username] = cur
		addKills(d, username, cur - last)
	elseif cur < last and warned[username] ~= cur then
		-- Counter went down without a death we saw. Not counted and the old
		-- reading is kept, so a counter that briefly reads 0 on login cannot
		-- add the whole value a second time. A new character whose death was
		-- missed adds again once it passes the old value.
		warned[username] = cur
		log(string.format("%s: zombie kills went down %d -> %d without a death, ignored", username, last, cur))
	end
	if d.totals[username] == nil then
		d.totals[username] = 0
		changed()
	end
end

local function pollPlayer(d, player)
	if not player or player:isDead() then return end
	local username = player:getUsername()
	if not username or username == "" then return end
	account(d, username, player:getZombieKills())
end

local function pollAll(d)
	local players = getOnlinePlayers()
	if not players then return end
	for i = 0, players:size() - 1 do
		pollPlayer(d, players:get(i))
	end
end

-- A dead character's IsoPlayer stays dead; the respawned one is a new object
-- with its counter at 0. Seeing the death is what tells a new character from a
-- counter that went down for some other reason.
local function checkDeaths(d)
	for username, obj in pairs(alive) do
		if obj:isDead() then
			account(d, username, obj:getZombieKills())   -- kills since the last minute
			d.newLife[username] = true
			alive[username] = nil
			d.totals[username] = 0
			-- Read here, not cached: a file-scope read sees the schema default.
			local opts = SandboxVars.DelScore
			local resetEvent = not (opts and opts.EventResetOnDeath == false)
			if resetEvent and d.event.kills[username] then d.event.kills[username] = 0 end
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
			end
		end
	end
	for username, _ in pairs(alive) do
		if not online[username] then alive[username] = nil end
	end
end

---- backups ------------------------------------------------------------------

local function num(n)
	return string.format("%d", math.floor(tonumber(n) or 0))
end

local function writeStateFile(path, header, totals, event)
	local w = getFileWriter(path, true, false)
	if not w then
		log("cannot write Zomboid/Lua/" .. path)
		return
	end
	w:write("# " .. header .. "\r\n")
	w:write("# Copy this file to Zomboid/Lua/" .. DIR .. "restore.txt to load it back.\r\n")
	w:write("event_name=" .. (event.name or "") .. "\r\n")
	w:write("event_active=" .. (event.active and "1" or "0") .. "\r\n")
	w:write("event_start=" .. tostring(event.startHours or "") .. "\r\n")
	w:write("event_stop=" .. tostring(event.stopHours or "") .. "\r\n")
	w:write("event_date=" .. (event.startDate or "") .. "\r\n")
	for username, n in pairs(totals) do w:write("total\t" .. username .. "\t" .. num(n) .. "\r\n") end
	for username, n in pairs(event.kills or {}) do w:write("event\t" .. username .. "\t" .. num(n) .. "\r\n") end
	w:close()
end

-- reason is a code (IGUI_DelScore_Reason_<code> on the client), arg its detail.
local function makeBackup(d, kind, reason, by, arg)
	local b = {
		id = d.nextBackupId, kind = kind, reason = reason, arg = arg or "", by = by or "",
		date = DelScore.gameDate(),
		totals = DelScore.copyMap(d.totals), event = copyEvent(d.event),
	}
	d.nextBackupId = d.nextBackupId + 1
	local list, cap = d.backups, DelScore.MANUAL_BACKUPS
	if kind == "auto" then list, cap = d.autoBackups, DelScore.AUTO_BACKUPS end
	list[#list + 1] = b
	while #list > cap do table.remove(list, 1) end
	local file = DIR .. string.format("backup_%04d.txt", b.id)
	writeStateFile(file, string.format("Delirium Scoreboard backup %d (%s, by %s), game date %s",
		b.id, reason .. (b.arg ~= "" and " " .. b.arg or ""), b.by ~= "" and b.by or "server", b.date), b.totals, b.event)
	log(string.format("backup %d saved (%s) -> Zomboid/Lua/%s", b.id, reason, file))
	return b
end

local function findBackup(d, id)
	for _, list in ipairs({ d.backups, d.autoBackups }) do
		for _, b in ipairs(list) do
			if b.id == id then return b end
		end
	end
	return nil
end

local function applySnapshot(d, totals, event)
	d.totals = DelScore.copyMap(totals)
	d.event = copyEvent(event)
	changed()
end

-- Zomboid/Lua/DelScore/restore.txt: an admin copies a backup file there and the
-- server loads it within seconds, then empties the file. Works even when the
-- in-world backup list is gone (world rolled back or replaced).
local function readRestoreFile(d)
	local path = DIR .. "restore.txt"
	local r = getFileReader(path, false)
	if not r then return end
	local totals, event = {}, { name = "", active = false, kills = {} }
	local found = false
	local line = r:readLine()
	while line ~= nil do
		line = string.gsub(line, "\r$", "")
		local board, username, n = string.match(line, "^(%a+)\t(.-)\t(%d+)%s*$")
		if board == "total" and username ~= "" then
			totals[username] = tonumber(n); found = true
		elseif board == "event" and username ~= "" then
			event.kills[username] = tonumber(n); found = true
		else
			local k, v = string.match(line, "^(event_%a+)=(.*)$")
			if k == "event_name" then event.name = v; found = true
			elseif k == "event_active" then event.active = (v == "1")
			elseif k == "event_start" then event.startHours = tonumber(v)
			elseif k == "event_stop" then event.stopHours = tonumber(v)
			elseif k == "event_date" and v ~= "" then event.startDate = v
			end
		end
		line = r:readLine()
	end
	r:close()
	if not found then return end
	makeBackup(d, "manual", "restoreFile", "")
	applySnapshot(d, totals, event)
	local w = getFileWriter(path, true, false)
	if w then w:close() end
	log("loaded Zomboid/Lua/" .. path .. " and emptied it")
	sendServerCommand(MOD, "msg", { key = "IGUI_DelScore_Msg_Restored" })
end

---- network ------------------------------------------------------------------

local function payload(d)
	local e = d.event
	return {
		totals = d.totals,
		event = {
			name = e.name, active = e.active, startHours = e.startHours,
			stopHours = e.stopHours, startDate = e.startDate, kills = e.kills,
		},
	}
end

local function backupList(d)
	local out = {}
	for _, list in ipairs({ d.backups, d.autoBackups }) do
		for _, b in ipairs(list) do
			local players, eventPlayers = 0, 0
			for _, _ in pairs(b.totals or {}) do players = players + 1 end
			for _, _ in pairs(b.event and b.event.kills or {}) do eventPlayers = eventPlayers + 1 end
			out[#out + 1] = {
				id = b.id, kind = b.kind, reason = b.reason, arg = b.arg or "", by = b.by, date = b.date,
				players = players, eventName = b.event and b.event.name or "", eventPlayers = eventPlayers,
			}
		end
	end
	table.sort(out, function(a, b) return a.id > b.id end)
	return out
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

local function boardOf(d, board)
	if board == "event" then return d.event.kills end
	if board == "total" then return d.totals end
	return nil
end

local adminCommands = {}

function adminCommands.eventNew(d, player, args)
	local name = cleanName(args.name)
	if not name then return end
	pollAll(d)   -- kills made before the start go to the old event, not the new one
	makeBackup(d, "manual", "newEvent", player:getUsername(), d.event.name)
	d.event = {
		name = name, active = true, kills = {},
		startHours = getGameTime():getWorldAgeHours(), startDate = DelScore.gameDate(),
	}
	changed()
	log(player:getUsername() .. " started event '" .. name .. "'")
	reply(player, "IGUI_DelScore_Msg_EventStarted", name)
end

function adminCommands.eventStop(d, player)
	if not d.event.active then return end
	pollAll(d)
	d.event.active = false
	d.event.stopHours = getGameTime():getWorldAgeHours()
	changed()
	log(player:getUsername() .. " stopped event '" .. tostring(d.event.name) .. "'")
end

function adminCommands.eventResume(d, player)
	if d.event.active or not d.event.startHours then return end
	pollAll(d)   -- kills made while stopped stay out of the event
	d.event.active = true
	d.event.stopHours = nil
	changed()
	log(player:getUsername() .. " resumed event '" .. tostring(d.event.name) .. "'")
end

function adminCommands.set(d, player, args)
	local t = boardOf(d, args.board)
	local username = type(args.name) == "string" and args.name or nil
	local value = math.floor(tonumber(args.value) or -1)
	if not t or not username or value < 0 or value > MAX_VALUE then return end
	makeBackup(d, "manual", "set", player:getUsername(), string.format("%s %s=%d", args.board, username, value))
	t[username] = value
	changed()
	log(string.format("%s set %s %s = %d", player:getUsername(), args.board, username, value))
end

function adminCommands.remove(d, player, args)
	local t = boardOf(d, args.board)
	local username = type(args.name) == "string" and args.name or nil
	if not t or not username or t[username] == nil then return end
	makeBackup(d, "manual", "remove", player:getUsername(), args.board .. " " .. username)
	t[username] = nil
	changed()
	log(string.format("%s removed %s from %s", player:getUsername(), username, args.board))
end

function adminCommands.backupNow(d, player)
	local b = makeBackup(d, "manual", "manual", player:getUsername())
	reply(player, "IGUI_DelScore_Msg_BackupSaved", tostring(b.id))
	sendServerCommand(player, MOD, "backups", { list = backupList(d) })
end

function adminCommands.backups(d, player)
	sendServerCommand(player, MOD, "backups", { list = backupList(d) })
end

function adminCommands.restore(d, player, args)
	local b = findBackup(d, tonumber(args.id))
	if not b then return end
	makeBackup(d, "manual", "restore", player:getUsername(), tostring(b.id))
	applySnapshot(d, b.totals, b.event)
	log(player:getUsername() .. " restored backup " .. b.id)
	reply(player, "IGUI_DelScore_Msg_Restored")
	sendServerCommand(player, MOD, "backups", { list = backupList(d) })
end

local function onClientCommand(module, command, player, args)
	if module ~= MOD or not player then return end
	args = args or {}
	local d = state()
	if command == "get" then
		sendServerCommand(player, MOD, "data", payload(d))
		return
	end
	local handler = adminCommands[command]
	if not handler then return end
	if not DelScore.isAdmin(player) then
		log("refused '" .. command .. "' from non-admin " .. tostring(player:getUsername()))
		return
	end
	handler(d, player, args)
end

---- events -------------------------------------------------------------------

local function onTick()
	local now = getTimestampMs()
	local d = nil
	if now - lastDeathCheck >= DEATH_CHECK_MS then
		lastDeathCheck = now
		d = state()
		checkDeaths(d)
	end
	if now - lastRestoreCheck >= RESTORE_CHECK_MS then
		lastRestoreCheck = now
		d = d or state()
		readRestoreFile(d)
	end
	if dirty and now - lastBroadcast >= BROADCAST_MS then
		lastBroadcast = now
		dirty = false
		d = d or state()
		sendServerCommand(MOD, "data", payload(d))
	end
	if fileDirty and now - lastFileSave >= FILE_SAVE_MS then
		lastFileSave = now
		fileDirty = false
		d = d or state()
		writeStateFile(DIR .. "current.txt", "Delirium Scoreboard, game date " .. DelScore.gameDate(), d.totals, d.event)
	end
end

Events.OnClientCommand.Add(onClientCommand)
Events.EveryOneMinute.Add(function() pollAll(state()) end)
Events.EveryDays.Add(function() makeBackup(state(), "auto", "daily", "") end)
Events.OnTick.Add(onTick)
