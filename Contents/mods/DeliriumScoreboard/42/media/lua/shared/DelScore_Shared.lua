-- Delirium-Scoreboard: shared constants and helpers.

DelScore = DelScore or {}

DelScore.MODULE = "DelScore"
DelScore.DIR = "DelScore/"            -- server: Zomboid/Lua/DelScore/
DelScore.MANUAL_BACKUPS = 30          -- backups made before every change by an admin
DelScore.AUTO_BACKUPS = 24            -- one per game day
DelScore.EVENT_NAME_MAX = 40

--[[
Admin check, same as DelLic.isAdmin (copied, not a dependency). Plain
isAdmin() asks about the local player, so it means nothing on the server,
where every admin command is checked again.
]]
function DelScore.isAdmin(player)
	if not player then return false end
	if player.getAccessLevel and player:getAccessLevel() == "admin" then return true end
	local role = player.getRole and player:getRole()
	if role and role.hasCapability and Capability and Capability.CanSetupNonPVPZone then
		if role:hasCapability(Capability.CanSetupNonPVPZone) then return true end
	end
	if role and role.hasAdminPower and role:hasAdminPower() then return true end
	return false
end

-- Game date as "YYYY-MM-DD HH:MM": numbers only, no locale on the server.
function DelScore.gameDate()
	local gt = getGameTime()
	return string.format("%04d-%02d-%02d %02d:%02d",
		gt:getYear(), gt:getMonth() + 1, gt:getDay() + 1, gt:getHour(), gt:getMinutes())
end

function DelScore.copyMap(t)
	local out = {}
	if t then
		for k, v in pairs(t) do out[k] = v end
	end
	return out
end
