-- PlayerDB Main Module
local api = require("api")
local logbook = require("PlayerDB/logbook")

local PlayerDB = {
	name = "PlayerDB",
	author = "Madpeter",
	version = "1.0.0",
	desc = "Logs players you target: name, guild and faction"
}
-- Addon initialization
local function OnLoad()
	api.Log:Info("[" .. PlayerDB.name .. "] Starting version " .. PlayerDB.version)
	-- hidden window, only used to receive game events
	PlayerDB.eventWindow = api.Interface:CreateEmptyWindow("PlayerDBEvents")
	PlayerDB.eventWindow:Show(false)
	-- attach events
	function PlayerDB:EventListener(event, ...)
		if(event == "TARGET_CHANGED") then
			local ok, err = pcall(logbook.LogTarget)
			if not ok then
				-- always in the log file; in chat only in dev mode
				api.Log:Info("[PlayerDB] error: " .. tostring(err))
				logbook.Chat(3, "[PlayerDB] error: " .. tostring(err))
			end
		end
	end
	PlayerDB.eventWindow:SetHandler("OnEvent", PlayerDB.EventListener)
	PlayerDB.eventWindow:RegisterEvent("TARGET_CHANGED")
end

-- Addon cleanup
local function OnUnload()
	-- Unregister events
	if PlayerDB.eventWindow ~= nil then
		PlayerDB.eventWindow:ReleaseHandler("OnEvent")
		api.Interface:Free(PlayerDB.eventWindow)
		PlayerDB.eventWindow = nil
	end
end

PlayerDB.OnSettingToggle = nil

PlayerDB.OnLoad = OnLoad
PlayerDB.OnUnload = OnUnload

return PlayerDB
