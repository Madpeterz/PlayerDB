-- PlayerDB Main Module
-- Hosts the features (players, houses, regrades): one event window routes game events to the
-- features that are switched on. The addon manager's settings button opens a window to switch them.
local api = require("api")
local settings = require("PlayerDB/settings")
local settingswindow = require("PlayerDB/settingswindow")

local PlayerDB = {
	name = "PlayerDB",
	author = "Madpeter",
	version = "2.0.0",
	desc = "Logs players, houses and regrades"
}

local FEATURES = {
	require("PlayerDB/features/players/feature"),
	require("PlayerDB/features/houses/feature"),
	require("PlayerDB/features/regrades/feature"),
}

local function runSafe(fn)
	local ok, result = pcall(fn)
	if not ok then
		api.Log:Info("[PlayerDB] error: " .. tostring(result))
		return nil
	end
	return result
end

local function findFeature(featureId)
	for _, feature in ipairs(FEATURES) do
		if feature.id == featureId then
			return feature
		end
	end
	return nil
end

local function isEnabled(featureId)
	return settings.IsEnabled(featureId)
end

-- switches a feature on or off right away and remembers the choice
local function setEnabled(featureId, enable)
	local feature = findFeature(featureId)
	if feature == nil then
		return
	end
	runSafe(function()
		settings.SetEnabled(featureId, enable)
	end)
	if enable then
		runSafe(feature.Enable)
	else
		runSafe(feature.Disable)
	end
	api.Log:Info("[PlayerDB] " .. feature.label .. (enable and " on" or " off"))
end

local function startupLine()
	local parts = {}
	for _, feature in ipairs(FEATURES) do
		local text = feature.label .. (isEnabled(feature.id) and " on" or " off")
		if isEnabled(feature.id) and feature.StartupInfo ~= nil then
			local info = runSafe(feature.StartupInfo)
			if info ~= nil then
				text = text .. " (" .. info .. ")"
			end
		end
		parts[#parts + 1] = text
	end
	return "[" .. PlayerDB.name .. "] Starting version " .. PlayerDB.version .. ": " .. table.concat(parts, ", ")
end

-- Addon initialization
local function OnLoad()
	api.Log:Info(startupLine())
	-- hidden window, only used to receive game events
	PlayerDB.eventWindow = api.Interface:CreateEmptyWindow("PlayerDBEvents")
	PlayerDB.eventWindow:Show(false)
	function PlayerDB:EventListener(event, ...)
		for _, feature in ipairs(FEATURES) do
			-- one feature failing must not stop the others
			local ok, err = pcall(feature.OnEvent, event, ...)
			if not ok then
				api.Log:Info("[PlayerDB] " .. feature.id .. " error: " .. tostring(err))
			end
		end
	end
	PlayerDB.eventWindow:SetHandler("OnEvent", PlayerDB.EventListener)
	-- every event any feature wants; features ignore events while switched off
	local registered = {}
	for _, feature in ipairs(FEATURES) do
		for _, event in ipairs(feature.events) do
			if not registered[event] then
				registered[event] = true
				PlayerDB.eventWindow:RegisterEvent(event)
			end
		end
	end
	for _, feature in ipairs(FEATURES) do
		if isEnabled(feature.id) then
			runSafe(feature.Enable)
		end
	end
end

-- Addon cleanup
local function OnUnload()
	for _, feature in ipairs(FEATURES) do
		runSafe(feature.Disable)
	end
	runSafe(settingswindow.Free)
	-- Unregister events
	if PlayerDB.eventWindow ~= nil then
		PlayerDB.eventWindow:ReleaseHandler("OnEvent")
		api.Interface:Free(PlayerDB.eventWindow)
		PlayerDB.eventWindow = nil
	end
end

local function OnSettingToggle()
	runSafe(function()
		settingswindow.Open(FEATURES, isEnabled, setEnabled)
	end)
end

PlayerDB.OnSettingToggle = OnSettingToggle

PlayerDB.OnLoad = OnLoad
PlayerDB.OnUnload = OnUnload

return PlayerDB
