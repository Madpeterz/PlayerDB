local api = require("api")

local logbook = {}

local PLAYERS_DIR = "PlayerDB/Players/"
local COUNT_PATH = PLAYERS_DIR .. "_count.dat"
-- dev mode: chat messages (new players, changes, errors) and debug output; off = silent
local DEBUG = false

-- the only way the addon writes to chat, so nothing reaches chat unless DEBUG is on
function logbook.Chat(filter, message)
	if not DEBUG then
		return
	end
	api.Chat:DispatchChatMessage(filter, message)
end

local function debugLog(message)
	if not DEBUG then
		return
	end
	api.Log:Info("[PlayerDB] DEBUG " .. message)
	logbook.Chat(3, "[PlayerDB] DEBUG " .. message)
end

local function numberToString(value)
	if value == math.floor(value) then
		return string.format("%.0f", value)
	end
	return string.format("%.14g", value)
end

local function copyPlain(value, visited)
	local valueType = type(value)
	if valueType ~= "table" then
		if valueType == "number" then
			return numberToString(value)
		elseif valueType == "string" or valueType == "boolean" then
			return value
		end
		return nil
	end
	visited = visited or {}
	if visited[value] then
		return nil
	end
	visited[value] = true
	local out = {}
	for key, nestedValue in pairs(value) do
		out[key] = copyPlain(nestedValue, visited)
	end
	return out
end

-- returns the first non-empty string field found in info under any of the given keys
local function pickField(info, keys)
	if type(info) ~= "table" then
		return nil
	end
	for _, key in ipairs(keys) do
		local value = info[key]
		if type(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

local function dumpInfo(info)
	if not DEBUG or type(info) ~= "table" then
		return
	end
	local parts = {}
	for key, value in pairs(info) do
		parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
	end
	debugLog("unit info: " .. table.concat(parts, ", "))
end

local function isPlayer(info)
	if type(info) ~= "table" then
		return false
	end
	return info.type == "character"
end

local function getFaction(info)
	local ok, faction = pcall(function()
		return api.Unit:GetFactionName("target")
	end)
	if ok and type(faction) == "string" and faction ~= "" then
		return faction
	end
	return pickField(info, {"faction", "factionName", "faction_name"})
end

-- Faction names as returned by GetFactionName (lowercased), mapped to a side.
-- Same table as WorldSatNav, plus pirates.
local FACTION_SIDE = {
	-- Nuia (West)
	["dreamwaker exiles"]  = "West", -- Elves (in-game spelling)
	["dreamwalker exiles"] = "West", -- Elves (alt spelling)
	["queen's crown"]      = "West", -- Nuians
	["crescent throne"]    = "West", -- Human
	["andelph"]            = "West", -- Dwarves
	-- Haranya (East)
	["west ishvara"]       = "East", -- Harani (in-game spelling)
	["west ishvaran"]      = "East", -- Harani (alt spelling)
	["wandering winds"]    = "East", -- Firran
	["repentant shadows"]  = "East", -- Warborn
}

-- Substring fallbacks, in case GetFactionName returns a variant spelling.
local FACTION_SIDE_HINTS = {
	{ "pirate", "Pirate" },
	{ "exile", "West" }, { "queen", "West" }, { "andelph", "West" }, { "nuia", "West" },
	{ "ishvara", "East" }, { "wandering wind", "East" }, { "repentant", "East" }, { "haranya", "East" },
}

-- Returns "East", "West", "Pirate" or nil when the faction is unrecognised.
local function getSide(faction)
	if type(faction) ~= "string" then
		return nil
	end
	local f = string.lower(faction)
	local side = FACTION_SIDE[f]
	if side ~= nil then
		return side
	end
	for _, hint in ipairs(FACTION_SIDE_HINTS) do
		if string.find(f, hint[1], 1, true) then
			return hint[2]
		end
	end
	debugLog("no side for faction '" .. faction .. "'")
	return nil
end

local function getGuild(info)
	return pickField(info, {"expeditionName", "expedition_name", "expedition", "guild", "guildName"})
end

local function getClass()
	local ok, class = pcall(function()
		-- Unit:UnitClass only returns a base type (e.g. "mage"), this gives the real class name
		return api.Ability:GetUnitClassName("target")
	end)
	if not ok or class == nil then
		return nil
	end
	if type(class) == "table" then
		return pickField(class, {"name", "className", "class_name"}) or copyPlain(class)
	end
	return copyPlain(class)
end

local GEAR_SCORE_KEYS = {"gearScore", "gear_score", "gearscore", "total", "score", "value"}

-- Turns a number, numeric string or table holding one into a positive number.
local function toGearScore(value)
	if type(value) == "table" then
		for _, key in ipairs(GEAR_SCORE_KEYS) do
			local found = toGearScore(value[key])
			if found ~= nil then
				return found
			end
		end
		return nil
	end
	local number = tonumber(value)
	if number == nil or number <= 0 then
		return nil
	end
	return number
end

local function getGearScore(info)
	local ok, raw = pcall(function()
		return api.Unit:UnitGearScore("target")
	end)
	if not ok then
		debugLog("UnitGearScore error: " .. tostring(raw))
		raw = nil
	end
	debugLog("UnitGearScore returned " .. type(raw) .. " '" .. tostring(raw) .. "'")
	if type(raw) == "table" then
		local parts = {}
		for key, value in pairs(raw) do
			parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
		end
		debugLog("UnitGearScore table: " .. table.concat(parts, ", "))
	end
	local gearScore = toGearScore(raw) or toGearScore(info)
	if gearScore == nil then
		return nil
	end
	return copyPlain(gearScore)
end

local function findPlayer(log, name)
	for _, entry in ipairs(log) do
		if entry.name == name then
			return entry
		end
	end
	return nil
end

-- Players are split into one file per first two letters of their name,
-- e.g. "Madpeter" -> PlayerDB/Players/ma.dat
local function playerPath(name)
	local prefix = string.lower(string.sub(name, 1, 2))
	if not string.find(prefix, "^%w%w$") then
		prefix = "_other"
	end
	return PLAYERS_DIR .. prefix .. ".dat"
end

local function readList(path)
	local log = api.File:Read(path)
	if type(log) ~= "table" then
		return {}
	end
	return log
end

local function readCount()
	local stats = api.File:Read(COUNT_PATH)
	if type(stats) ~= "table" then
		return 0
	end
	return tonumber(stats.players) or 0
end

local function writeCount(count)
	api.File:Write(COUNT_PATH, { players = copyPlain(count) })
end

function logbook.LogTarget()
	local targetId = api.Unit:GetUnitId("target")
	if targetId == nil then
		debugLog("no target id")
		return
	end

	local info = api.Unit:GetUnitInfoById(targetId)
	dumpInfo(info)
	if not isPlayer(info) then
		debugLog("target " .. tostring(targetId) .. " is not a player")
		return
	end

	local name = api.Unit:UnitName("target")
	if name == nil or name == "" then
		debugLog("player has no name")
		return
	end

	local guild = getGuild(info)
	local faction = getFaction(info)
	local side = getSide(faction)
	local class = getClass()
	local gearScore = getGearScore(info)
	local seen = copyPlain(api.Time:GetLocalTime())
	debugLog("player '" .. name .. "' guild '" .. tostring(guild) .. "' faction '" .. tostring(faction)
		.. "' side '" .. tostring(side) .. "' class '" .. tostring(class) .. "' gs '" .. tostring(gearScore) .. "'")

	local path = playerPath(name)
	local log = readList(path)
	debugLog(path .. " has " .. #log .. " entries")

	local existing = findPlayer(log, name)
	if existing == nil then
		log[#log + 1] = {
			name = name,
			guild = guild,
			faction = faction,
			side = side,
			class = class,
			gear_score = gearScore,
			first_seen = seen,
			last_seen = seen,
		}
		api.File:Write(path, log)
		local count = readCount() + 1
		writeCount(count)
		logbook.Chat(11, "[PlayerDB] New player " .. name
			.. " <" .. tostring(guild or "no guild") .. "> (" .. tostring(faction or "unknown")
			.. ", " .. tostring(side or "unknown side") .. ") "
			.. tostring(class or "unknown class") .. " GS " .. tostring(gearScore or "?") .. "."
			.. " You now have " .. count .. " players logged")
		return
	end

	local changes = {}
	if guild ~= existing.guild then
		changes[#changes + 1] = "guild " .. tostring(existing.guild or "none") .. " -> " .. tostring(guild or "none")
		existing.guild = guild
	end
	if faction ~= nil and faction ~= existing.faction then
		changes[#changes + 1] = "faction " .. tostring(existing.faction or "unknown") .. " -> " .. faction
		existing.faction = faction
	end
	if side ~= nil and side ~= existing.side then
		if existing.side ~= nil then
			changes[#changes + 1] = "side " .. existing.side .. " -> " .. side
		end
		existing.side = side
	end
	-- class (skillset swaps) and gear score change often, update silently
	if class ~= nil then
		existing.class = class
	end
	if gearScore ~= nil then
		existing.gear_score = gearScore
	end
	existing.last_seen = seen
	api.File:Write(path, log)

	if #changes > 0 then
		logbook.Chat(3, "[PlayerDB] " .. name .. " changed: " .. table.concat(changes, ", "))
	end
end

return logbook
