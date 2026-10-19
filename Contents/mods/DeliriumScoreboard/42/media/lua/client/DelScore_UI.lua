-- Delirium-Scoreboard: sidebar button, boards window, backups window.
if isServer() then return end
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextBox"
require "ISUI/ISModalDialog"
require "DelScore_Client"

DelScoreUI = {}
local UI = DelScoreUI
local C = DelScoreClient

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local PAD = 10
local BTN_H = FONT_HGT_SMALL + 8
local ROW_H = FONT_HGT_SMALL + 8

local RANK_COLORS = {
	{ r = 1.0, g = 0.84, b = 0.2 },
	{ r = 0.8, g = 0.8, b = 0.85 },
	{ r = 0.85, g = 0.55, b = 0.3 },
}

local function centered(w, h)
	return (getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2
end

local function confirm(text, target, onYes, p1, p2)
	local w, h = 380, 150
	local x, y = centered(w, h)
	local modal = ISModalDialog:new(x, y, w, h, text, true, target, onYes, 0, p1, p2)
	modal:initialise()
	modal:addToUIManager()
	modal:bringToTop()
end

local function prompt(text, default, target, onOk, p1, p2)
	local w, h = 320, 180
	local x, y = centered(w, h)
	local box = ISTextBox:new(x, y, w, h, text, default or "", target, onOk, 0, p1, p2)
	box:initialise()
	box:addToUIManager()
	box:bringToTop()
end

local function num(n)
	return string.format("%d", math.floor(tonumber(n) or 0))
end

local function elapsedText(fromHours, toHours)
	local hours = math.max(0, (toHours or 0) - (fromHours or 0))
	return getText("IGUI_DelScore_Elapsed", num(hours / 24), num(hours % 24))
end

---- boards window ------------------------------------------------------------

DelScoreWindow = ISPanel:derive("DelScoreWindow")

local function drawBoardRow(list, y, item, alt)
	local h = item.height or list.itemheight
	if y + list:getYScroll() + h < 0 or y + list:getYScroll() >= list.height then return y + h end
	local row = item.item
	local w = list:getWidth()
	if row.mine then
		list:drawRect(0, y, w, h, 0.25, 0.9, 0.7, 0.2)
	elseif list.mouseoverselected == item.itemindex and list:isMouseOver() then
		list:drawRect(0, y, w, h, 0.08, 1, 1, 1)
	end
	list:drawRectBorder(0, y, w, h, 0.25, 0.4, 0.4, 0.4)
	local c = RANK_COLORS[row.rank] or { r = 0.75, g = 0.75, b = 0.75 }
	local ty = y + (h - FONT_HGT_SMALL) / 2
	list:drawTextRight(num(row.rank), 30, ty, c.r, c.g, c.b, 1, UIFont.Small)
	list:drawText(row.name, 44, ty, 1, 1, 1, 1, UIFont.Small)
	list:drawTextRight(num(row.kills), w - 20, ty, c.r, c.g, c.b, 1, UIFont.Small)
	return y + h
end

local function listRightClick(list, x, y)
	local win = list.window
	if not win or not C.isAdmin() then return end
	local index = list:rowAt(x, y)
	local item = index and list.items[index]
	if not item then return end
	local row = item.item
	local context = ISContextMenu.get(0, getMouseX(), getMouseY())
	context:addOption(getText("IGUI_DelScore_SetValue"), win, DelScoreWindow.askSetValue, row)
	context:addOption(getText("IGUI_DelScore_Remove"), win, DelScoreWindow.askRemove, row)
end

function DelScoreWindow:createChildren()
	local w = self.width
	local tabW = (w - PAD * 3) / 2
	local tabY = PAD + FONT_HGT_MEDIUM + 8
	self.tabTotal = ISButton:new(PAD, tabY, tabW, BTN_H, getText("IGUI_DelScore_TabTotal"), self, DelScoreWindow.onTab)
	self.tabTotal.internal = "total"
	self.tabEvent = ISButton:new(PAD * 2 + tabW, tabY, tabW, BTN_H, getText("IGUI_DelScore_TabEvent"), self, DelScoreWindow.onTab)
	self.tabEvent.internal = "event"
	for _, b in ipairs({ self.tabTotal, self.tabEvent }) do
		b:initialise()
		self:addChild(b)
	end

	self.infoY = tabY + BTN_H + 6
	self.listY = self.infoY + FONT_HGT_SMALL * 2 + 10
	self.list = ISScrollingListBox:new(PAD, self.listY, w - PAD * 2, 100)
	self.list:initialise()
	self.list:instantiate()
	self.list.font = UIFont.Small
	self.list.itemheight = ROW_H
	self.list.drawBorder = true
	self.list.doDrawItem = drawBoardRow
	self.list.onRightMouseUp = listRightClick
	self.list.window = self
	self:addChild(self.list)

	local function button(key, onClick)
		local b = ISButton:new(0, 0, 100, BTN_H, getText(key), self, onClick)
		b:initialise()
		self:addChild(b)
		return b
	end
	self.btnNew = button("IGUI_DelScore_NewEvent", DelScoreWindow.askNewEvent)
	self.btnStop = button("IGUI_DelScore_Stop", DelScoreWindow.onStopResume)
	self.btnBackups = button("IGUI_DelScore_Backups", DelScoreWindow.onBackups)
	self.btnClose = button("IGUI_DelScore_Close", DelScoreWindow.onClose)
	self:layout()
end

function DelScoreWindow:layout()
	local w, h = self.width, self.height
	local admin = C.isAdmin()
	self.admin = admin
	local bottom = h - PAD - BTN_H
	local listBottom = bottom - 6
	if admin then listBottom = listBottom - BTN_H - 6 end
	self.list:setHeight(math.max(ROW_H * 3, listBottom - self.listY))

	self.btnClose:setX(w - PAD - 100)
	self.btnClose:setY(bottom)
	local adminY = bottom - BTN_H - 6
	local bw = (w - PAD * 4) / 3
	for i, b in ipairs({ self.btnNew, self.btnStop, self.btnBackups }) do
		b:setWidth(bw)
		b:setX(PAD + (i - 1) * (bw + PAD))
		b:setY(adminY)
		b:setVisible(admin)
	end
	self:refresh()
end

function DelScoreWindow:refresh()
	local data = C.data
	local event = data and data.event or {}
	local map = nil
	if data then map = self.tab == "event" and event.kills or data.totals end
	local me = getPlayer() and getPlayer():getUsername()

	local scroll = self.list:getYScroll()
	self.list:clear()
	for i, row in ipairs(C.rows(map)) do
		row.rank = i
		row.mine = row.name == me
		self.list:addItem(row.name, row)
	end
	self.list:setYScroll(scroll)

	for _, b in ipairs({ self.tabTotal, self.tabEvent }) do
		local on = b.internal == self.tab
		b.backgroundColor = on and { r = 0.45, g = 0.3, b = 0.1, a = 0.9 } or { r = 0, g = 0, b = 0, a = 0.6 }
	end
	if self.admin then
		local onEvent = self.tab == "event"
		self.btnNew:setVisible(onEvent)
		self.btnStop:setVisible(onEvent and event.startHours ~= nil)
		self.btnStop:setTitle(getText(event.active and "IGUI_DelScore_Stop" or "IGUI_DelScore_Resume"))
	end
end

function DelScoreWindow:prerender()
	ISPanel.prerender(self)
	self:drawTextCentre(getText("IGUI_DelScore_Title"), self.width / 2, PAD, 1, 1, 1, 1, UIFont.Medium)

	local y = self.infoY
	local data = C.data
	if not data then
		self:drawText(getText("IGUI_DelScore_Loading"), PAD, y, 0.7, 0.7, 0.7, 1, UIFont.Small)
		return
	end
	if self.tab == "total" then
		self:drawText(getText("IGUI_DelScore_TotalInfo"), PAD, y, 0.8, 0.8, 0.8, 1, UIFont.Small)
		return
	end
	local event = data.event or {}
	if not event.startHours then
		self:drawText(getText("IGUI_DelScore_NoEvent"), PAD, y, 0.8, 0.8, 0.8, 1, UIFont.Small)
		return
	end
	self:drawText(getText("IGUI_DelScore_EventName", event.name or ""), PAD, y, 1, 0.85, 0.4, 1, UIFont.Small)
	y = y + FONT_HGT_SMALL + 2
	if event.active then
		local now = getGameTime():getWorldAgeHours()
		self:drawText(getText("IGUI_DelScore_EventRunning", event.startDate or "", elapsedText(event.startHours, now)),
			PAD, y, 0.5, 1, 0.5, 1, UIFont.Small)
	else
		self:drawText(getText("IGUI_DelScore_EventStopped", event.startDate or "", elapsedText(event.startHours, event.stopHours)),
			PAD, y, 1, 0.5, 0.5, 1, UIFont.Small)
	end
end

function DelScoreWindow:render()
	ISPanel.render(self)
	if C.data and self.list:size() == 0 then
		self:drawTextCentre(getText("IGUI_DelScore_Empty"), self.width / 2, self.listY + 20, 0.6, 0.6, 0.6, 1, UIFont.Small)
	end
	-- Admin rights can arrive after the window was opened.
	if self.admin ~= C.isAdmin() then self:layout() end
end

function DelScoreWindow:onTab(button)
	self.tab = button.internal
	self.list:setYScroll(0)
	self:refresh()
end

function DelScoreWindow:onClose()
	self:setVisible(false)
	if UI.backupsWindow then UI.backupsWindow:setVisible(false) end
end

-- Admin actions. ISTextBox / ISModalDialog call onclick(target, button, param1, param2).

function DelScoreWindow:askNewEvent()
	prompt(getText("IGUI_DelScore_NewEventPrompt"), "", self, DelScoreWindow.onNewEventName)
end

function DelScoreWindow:onNewEventName(button)
	if button.internal ~= "OK" then return end
	local name = button.parent.entry:getText()
	name = name and string.gsub(string.gsub(name, "^%s+", ""), "%s+$", "") or ""
	if name == "" then return end
	confirm(getText("IGUI_DelScore_NewEventConfirm", name), self, DelScoreWindow.onNewEventConfirm, name)
end

function DelScoreWindow:onNewEventConfirm(button, name)
	if button.internal == "YES" then C.send("eventNew", { name = name }) end
end

function DelScoreWindow:onStopResume()
	local event = C.data and C.data.event
	if not event then return end
	C.send(event.active and "eventStop" or "eventResume")
end

function DelScoreWindow:askSetValue(row)
	prompt(getText("IGUI_DelScore_SetValuePrompt", row.name), num(row.kills), self, DelScoreWindow.onSetValue, self.tab, row.name)
end

function DelScoreWindow:onSetValue(button, board, name)
	if button.internal ~= "OK" then return end
	local value = tonumber(button.parent.entry:getText())
	if not value or value < 0 then return end
	C.send("set", { board = board, name = name, value = math.floor(value) })
end

function DelScoreWindow:askRemove(row)
	confirm(getText("IGUI_DelScore_RemoveConfirm", row.name), self, DelScoreWindow.onRemove, self.tab, row.name)
end

function DelScoreWindow:onRemove(button, board, name)
	if button.internal == "YES" then C.send("remove", { board = board, name = name }) end
end

function DelScoreWindow:onBackups()
	UI.openBackups()
end

function DelScoreWindow:new()
	local w, h = 400, 540
	local x, y = centered(w, h)
	local o = ISPanel:new(x, y, w, h)
	setmetatable(o, self)
	self.__index = self
	o.backgroundColor = { r = 0.1, g = 0.1, b = 0.1, a = 0.95 }
	o.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
	o.moveWithMouse = true
	o.tab = "total"
	return o
end

---- backups window -----------------------------------------------------------

DelScoreBackupsWindow = ISPanel:derive("DelScoreBackupsWindow")

local function drawBackupRow(list, y, item, alt)
	local h = item.height or list.itemheight
	if y + list:getYScroll() + h < 0 or y + list:getYScroll() >= list.height then return y + h end
	local b = item.item
	local w = list:getWidth()
	if list.selected == item.itemindex then
		list:drawRect(0, y, w, h, 0.35, 0.7, 0.35, 0.15)
	elseif list.mouseoverselected == item.itemindex and list:isMouseOver() then
		list:drawRect(0, y, w, h, 0.08, 1, 1, 1)
	end
	list:drawRectBorder(0, y, w, h, 0.25, 0.4, 0.4, 0.4)
	local reason = getText("IGUI_DelScore_Reason_" .. tostring(b.reason), b.arg or "")
	local by = (b.by and b.by ~= "") and (" - " .. b.by) or ""
	local auto = b.kind == "auto" and 0.6 or 1
	list:drawText("#" .. num(b.id) .. "  " .. tostring(b.date) .. by, 8, y + 4, 1, 1, auto, 1, UIFont.Small)
	list:drawText(reason, 8, y + 4 + FONT_HGT_SMALL, 0.85, 0.85, 0.85, 1, UIFont.Small)
	list:drawText(getText("IGUI_DelScore_BackupInfo", num(b.players), b.eventName or "", num(b.eventPlayers)),
		8, y + 4 + FONT_HGT_SMALL * 2, 0.6, 0.6, 0.6, 1, UIFont.Small)
	return y + h
end

function DelScoreBackupsWindow:createChildren()
	local w, h = self.width, self.height
	local top = PAD + FONT_HGT_MEDIUM + 8
	local bottom = h - PAD - BTN_H
	self.list = ISScrollingListBox:new(PAD, top, w - PAD * 2, bottom - 8 - top)
	self.list:initialise()
	self.list:instantiate()
	self.list.font = UIFont.Small
	self.list.itemheight = FONT_HGT_SMALL * 3 + 10
	self.list.drawBorder = true
	self.list.doDrawItem = drawBackupRow
	self:addChild(self.list)

	local bw = (w - PAD * 4) / 3
	local function button(i, key, onClick)
		local b = ISButton:new(PAD + (i - 1) * (bw + PAD), bottom, bw, BTN_H, getText(key), self, onClick)
		b:initialise()
		self:addChild(b)
		return b
	end
	button(1, "IGUI_DelScore_BackupNow", DelScoreBackupsWindow.onBackupNow)
	button(2, "IGUI_DelScore_Restore", DelScoreBackupsWindow.onRestore)
	button(3, "IGUI_DelScore_Close", DelScoreBackupsWindow.onClose)
end

function DelScoreBackupsWindow:refresh()
	self.list:clear()
	for _, b in ipairs(C.backups or {}) do
		self.list:addItem(tostring(b.id), b)
	end
end

function DelScoreBackupsWindow:prerender()
	ISPanel.prerender(self)
	self:drawTextCentre(getText("IGUI_DelScore_BackupsTitle"), self.width / 2, PAD, 1, 1, 1, 1, UIFont.Medium)
end

function DelScoreBackupsWindow:render()
	ISPanel.render(self)
	if self.list:size() == 0 then
		local key = C.backups and "IGUI_DelScore_NoBackups" or "IGUI_DelScore_Loading"
		self:drawTextCentre(getText(key), self.width / 2, self.list:getY() + 20, 0.6, 0.6, 0.6, 1, UIFont.Small)
	end
end

function DelScoreBackupsWindow:onBackupNow()
	C.send("backupNow")
end

function DelScoreBackupsWindow:onRestore()
	local item = self.list.items[self.list.selected]
	if not item then return end
	confirm(getText("IGUI_DelScore_RestoreConfirm", num(item.item.id)), self, DelScoreBackupsWindow.onRestoreConfirm, item.item.id)
end

function DelScoreBackupsWindow:onRestoreConfirm(button, id)
	if button.internal == "YES" then C.send("restore", { id = id }) end
end

function DelScoreBackupsWindow:onClose()
	self:setVisible(false)
end

function DelScoreBackupsWindow:new()
	local w, h = 460, 480
	local x, y = centered(w, h)
	local o = ISPanel:new(x, y, w, h)
	setmetatable(o, self)
	self.__index = self
	o.backgroundColor = { r = 0.1, g = 0.1, b = 0.1, a = 0.95 }
	o.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
	o.moveWithMouse = true
	return o
end

---- open / close -------------------------------------------------------------

function UI.toggle()
	if UI.window and UI.window:getIsVisible() then
		UI.window:onClose()
		return
	end
	if not UI.window then
		UI.window = DelScoreWindow:new()
		UI.window:initialise()
		UI.window:addToUIManager()
	end
	UI.window:setVisible(true)
	UI.window:bringToTop()
	UI.window:layout()
	C.send("get")
end

function UI.openBackups()
	if not UI.backupsWindow then
		UI.backupsWindow = DelScoreBackupsWindow:new()
		UI.backupsWindow:initialise()
		UI.backupsWindow:addToUIManager()
	end
	UI.backupsWindow:setVisible(true)
	UI.backupsWindow:bringToTop()
	UI.backupsWindow:refresh()
	C.send("backups")
end

function UI.onData()
	if UI.window and UI.window:getIsVisible() then UI.window:refresh() end
end

function UI.onBackups()
	if UI.backupsWindow and UI.backupsWindow:getIsVisible() then UI.backupsWindow:refresh() end
end

---- sidebar button -----------------------------------------------------------

-- Under the vanilla left sidebar, one slot below the Delirium News button.
-- Players can drag it anywhere; right click puts it back (same as the news
-- button, see Delirium-NewsBoard).
-- Not a child of the sidebar: vanilla rebuilds it and its shrinkWrap() would
-- take our button as its own. Always on top, or the chat window covers it.
DelScoreButton = ISButton:derive("DelScoreButton")

local SIDEBAR_GAP = 15
local SLOT = 1           -- 0 is taken by Delirium News
local DRAG_THRESHOLD = 6
local POS_FILE = "DelScore_button.txt"   -- client Zomboid/Lua, per player machine

local customPos = nil    -- { x, y } once dragged, nil = follow the sidebar

local function loadPos()
	local r = getFileReader(POS_FILE, false)
	if not r then return end
	local line = r:readLine()
	r:close()
	local x, y = string.match(line or "", "^(%-?%d+),(%-?%d+)$")
	if x then customPos = { x = tonumber(x), y = tonumber(y) } end
end

local function savePos()
	local w = getFileWriter(POS_FILE, true, false)
	if not w then return end
	if customPos then
		w:write(string.format("%d,%d", customPos.x, customPos.y))
	else
		w:write("auto")
	end
	w:close()
end

local function clampToScreen(x, y, size)
	x = math.max(0, math.min(x, getCore():getScreenWidth() - size))
	y = math.max(0, math.min(y, getCore():getScreenHeight() - size))
	return math.floor(x), math.floor(y)
end

local function placeButton()
	local b = UI.button
	if not b or b.dragging then return end
	local bar = ISEquippedItem and ISEquippedItem.instance
	-- Vanilla icons are TEXTURE_WIDTH wide and 0.75 of that high.
	local size = 36
	if bar and bar:getWidth() >= 16 then size = math.floor(bar:getWidth() * 0.75) end
	if b.width ~= size then b:setWidth(size); b:setHeight(size) end

	local x, y
	if customPos then
		x, y = clampToScreen(customPos.x, customPos.y, size)
	elseif bar and bar:getIsVisible() then
		x = bar:getAbsoluteX() + (bar:getWidth() - size) / 2
		y = bar:getAbsoluteY() + bar:getHeight() + SIDEBAR_GAP + SLOT * (size + SIDEBAR_GAP)
	else
		if b:getIsVisible() then b:setVisible(false) end
		return
	end
	b:setX(x)
	b:setY(y)
	if not b:getIsVisible() then b:setVisible(true) end
end

function DelScoreButton:prerender()
	local a = (self:isMouseOver() or self.dragging) and 1 or 0.85
	self:drawTextureScaled(self.tex, 0, 0, self.width, self.height, a, 1, 1, 1)
end

function DelScoreButton:render()
end

function DelScoreButton:onMouseDown(x, y)
	self.dragStart = { mx = getMouseX(), my = getMouseY(), x = self:getAbsoluteX(), y = self:getAbsoluteY() }
	self.dragging = false
	return ISButton.onMouseDown(self, x, y)
end

local function dragMove(self)
	local s = self.dragStart
	if not s or not self.pressed then return end
	local dx, dy = getMouseX() - s.mx, getMouseY() - s.my
	if not self.dragging and math.abs(dx) + math.abs(dy) >= DRAG_THRESHOLD then
		self.dragging = true
	end
	if self.dragging then
		local x, y = clampToScreen(s.x + dx, s.y + dy, self.width)
		customPos = { x = x, y = y }
		self:setX(x)
		self:setY(y)
	end
end

function DelScoreButton:onMouseMove(dx, dy)
	ISButton.onMouseMove(self, dx, dy)
	dragMove(self)
end

-- A fast drag leaves the button's rectangle; keep following the mouse.
function DelScoreButton:onMouseMoveOutside(dx, dy)
	ISButton.onMouseMoveOutside(self, dx, dy)
	dragMove(self)
end

local function endDrag(self)
	local dragged = self.dragging
	self.dragStart = nil
	self.dragging = false
	if dragged then savePos() end
	return dragged
end

function DelScoreButton:onMouseUp(x, y)
	if endDrag(self) then
		self.pressed = false   -- a drag is not a click
		return
	end
	ISButton.onMouseUp(self, x, y)
end

function DelScoreButton:onMouseUpOutside(x, y)
	endDrag(self)
	ISButton.onMouseUpOutside(self, x, y)
end

function DelScoreButton:onRightMouseUp(x, y)
	customPos = nil
	savePos()
	return true
end

local function createButton()
	if UI.button then return end
	loadPos()
	UI.button = DelScoreButton:new(0, 0, 36, 36, "", nil, function() UI.toggle() end)
	UI.button.tex = getTexture("media/ui/DelScore_Btn.png")
	UI.button:initialise()
	UI.button:setDisplayBackground(false)
	UI.button:setTooltip(getText("IGUI_DelScore_ButtonTip"))
	UI.button:addToUIManager()
	UI.button:setAlwaysOnTop(true)   -- needs the java object, so after addToUIManager
	placeButton()
end

Events.OnCreatePlayer.Add(function() createButton() end)
Events.OnPreUIDraw.Add(placeButton)
Events.OnResolutionChange.Add(placeButton)
