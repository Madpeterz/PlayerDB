local api = require("api")
local settings = require("PlayerDB/settings")

-- HouseTarget's status icon: a building that is
--   gray            no target, or the target is not a house
--   blue with a pin a house is targeted: move within 6 m and walk around it
--   green with tick its location is saved to Houses/
-- Hover for details. Drag it to move it.
local icon = {}

local IMAGE_DIR = api.baseDir .. "/PlayerDB/images/"
icon.NONE = "none"
icon.LOCATING = "locating"
icon.SAVED = "saved"
local IMAGES = {
	none = IMAGE_DIR .. "house_none.png",
	locating = IMAGE_DIR .. "house_locating.png",
	saved = IMAGE_DIR .. "house_saved.png",
}
-- position kept in the addon settings (settings.lua)
local POSITION_X = "HouseTargetIconX"
local POSITION_Y = "HouseTargetIconY"
local ICON_SIZE = 32
local DEFAULT_X = 400
local DEFAULT_Y = 540

local window = nil
local images = {}
local hoverButton = nil
local hovering = false
local state = icon.NONE
local statusText = "No house targeted"

local function loadPosition()
	local x, y = tonumber(settings.Get(POSITION_X)), tonumber(settings.Get(POSITION_Y))
	if x ~= nil and y ~= nil then
		return x, y
	end
	return DEFAULT_X, DEFAULT_Y
end

local function savePosition()
	local x, y = window:GetEffectiveOffset()
	if x == nil or y == nil then
		return
	end
	settings.Update(POSITION_X, math.floor(x + 0.5))
	settings.Update(POSITION_Y, math.floor(y + 0.5))
end

local function attachDrag(widget)
	function widget:OnDragStart()
		window:StartMoving()
		api.Cursor:ClearCursor()
		api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
	end
	widget:SetHandler("OnDragStart", widget.OnDragStart)
	function widget:OnDragStop()
		window:StopMovingOrSizing()
		api.Cursor:ClearCursor()
		savePosition()
	end
	widget:SetHandler("OnDragStop", widget.OnDragStop)
	if widget.RegisterForDrag ~= nil then
		widget:RegisterForDrag("LeftButton")
	end
	widget:EnableDrag(true)
end

local function showTooltip(button)
	local x, y = button:GetEffectiveOffset()
	-- clear first so the client redraws the text instead of keeping the old tooltip
	api.Interface:SetTooltipOnPos("", button, 0, 0)
	api.Interface:SetTooltipOnPos("HouseTarget\n" .. statusText, button, x + button:GetWidth(), y)
end

-- invisible button over the icon, for the hover tooltip
local function createHoverArea()
	local button = window:CreateChildWidget("button", "PlayerDBHouseTargetIconHover", 0, true)
	button:AddAnchor("TOPLEFT", window, 0, 0)
	button:SetExtent(ICON_SIZE, ICON_SIZE)
	function button:OnEnter()
		hovering = true
		showTooltip(button)
	end
	button:SetHandler("OnEnter", button.OnEnter)
	function button:OnLeave()
		hovering = false
		api.Interface:SetTooltipOnPos("", button, 0, 0)
	end
	button:SetHandler("OnLeave", button.OnLeave)
	attachDrag(button)
	button:Show(true)
	hoverButton = button
end

function icon.Create()
	if window ~= nil then
		return
	end
	local x, y = loadPosition()
	window = api.Interface:CreateEmptyWindow("PlayerDBHouseTargetIcon")
	window:AddAnchor("TOPLEFT", "UIParent", x, y)
	window:SetExtent(ICON_SIZE, ICON_SIZE)
	window:SetCloseOnEscape(false)
	for name, path in pairs(IMAGES) do
		local image = window:CreateImageDrawable("PlayerDBHouseTargetIcon_" .. name, "artwork")
		image:AddAnchor("TOPLEFT", window, 0, 0)
		image:SetExtent(ICON_SIZE, ICON_SIZE)
		image:SetTexture(path)
		image:Show(name == state)
		images[name] = image
	end
	createHoverArea()
	attachDrag(window)
	window:Show(true)
end

-- newState: icon.NONE / icon.LOCATING / icon.SAVED; text: the tooltip's status line
function icon.SetState(newState, text)
	statusText = text or statusText
	if images[newState] ~= nil and newState ~= state then
		for name, image in pairs(images) do
			image:Show(name == newState)
		end
	end
	state = newState
	-- a tooltip that is open shows the new text right away
	if hovering and hoverButton ~= nil then
		pcall(showTooltip, hoverButton)
	end
end

function icon.Free()
	if window == nil then
		return
	end
	window:Show(false)
	api.Interface:Free(window)
	window = nil
	images = {}
	hoverButton = nil
	hovering = false
	state = icon.NONE
	statusText = "No house targeted"
end

return icon
