-- Delirium-Scoreboard: client side - receives the boards, talks to the server.
if isServer() then return end
require "DelScore_Shared"

DelScoreClient = {}
local C = DelScoreClient
local MOD = DelScore.MODULE

C.data = nil       -- { totals = {name = n}, event = { name, active, startHours, stopHours, startDate, kills } }
C.backups = nil    -- list from the server, newest first

local RETRY_MS = 5000
local lastAsk = 0

function C.send(command, args)
	local player = getPlayer()
	if player then sendClientCommand(player, MOD, command, args or {}) end
end

local function ask()
	if not getPlayer() then return end
	lastAsk = getTimestampMs()
	C.send("get")
end

-- Only decides which buttons are shown; the server checks every command again.
function C.isAdmin()
	if isAdmin() then return true end
	if DelScore.isAdmin(getPlayer()) then return true end
	local level = getAccessLevel and getAccessLevel()
	return level ~= nil and string.lower(level) == "admin"
end

-- Board map -> rows sorted by kills, ties by name.
function C.rows(map)
	local rows = {}
	for name, kills in pairs(map or {}) do
		rows[#rows + 1] = { name = name, kills = math.floor(tonumber(kills) or 0) }
	end
	table.sort(rows, function(a, b)
		if a.kills ~= b.kills then return a.kills > b.kills end
		return a.name < b.name
	end)
	return rows
end

local function onServerCommand(module, command, args)
	if module ~= MOD then return end
	if command == "data" then
		C.data = args
		if DelScoreUI then DelScoreUI.onData() end
	elseif command == "backups" then
		C.backups = args and args.list or {}
		if DelScoreUI then DelScoreUI.onBackups() end
	elseif command == "msg" and args and args.key then
		local player = getPlayer()
		if player then
			local text = args.arg and getText(args.key, args.arg) or getText(args.key)
			player:setHaloNote(text, 150, 220, 150, 300)
		end
	end
end

-- A single request on connect can be lost before the local player exists;
-- keep asking until the boards are really here.
local function onTick()
	if not C.data and getTimestampMs() - lastAsk > RETRY_MS then ask() end
end

if isClient() then
	Events.OnServerCommand.Add(onServerCommand)
	Events.OnGameStart.Add(ask)
	Events.OnCreatePlayer.Add(function() ask() end)
	Events.OnTick.Add(onTick)
end
