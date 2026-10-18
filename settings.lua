local api = require("api")

-- Which features are switched on, kept in PlayerDB/settings.dat.
-- Values are stored as "on"/"off" strings; anything missing counts as on.
local settings = {}

local SETTINGS_PATH = "PlayerDB/settings.dat"

local function read()
	local saved = api.File:Read(SETTINGS_PATH)
	if type(saved) ~= "table" then
		return {}
	end
	return saved
end

function settings.IsEnabled(featureId)
	return read()[featureId] ~= "off"
end

function settings.SetEnabled(featureId, isEnabled)
	local saved = read()
	saved[featureId] = isEnabled and "on" or "off"
	api.File:Write(SETTINGS_PATH, saved)
end

return settings
