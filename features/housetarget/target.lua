-- Reads the current target: is it a house (WorldSatNav's demo "+" test), and what can be found out
-- about it without knowing where it stands. Locating is in locate.lua.
local api = require("api")

local target = {}

-- a targeted building counts as a house (and locating starts) within this range.
-- WorldSatNav's own demo offer uses 10 m (features/demos.lua).
target.MAX_DISTANCE_M = 80

-- WorldSatNav's building list (helpers/buildings.lua), in the same order so building_id matches its
-- share codes (id = index - 1, and for a name listed twice the later index wins, as there).
-- size is the plot footprint from the comments in that list.
local BUILDINGS = {
	{ "Unknown", nil },
	{ "Solar Scarecrow Garden", 8 }, { "Lunar Scarecrow Garden", 8 }, { "Stellar Scarecrow Garden", 8 },
	{ "Scarecrow Garden", 8 }, { "Haranyan Private Smelter", 8 }, { "Haranyan Private Sawmill", 8 },
	{ "Haranyan Private Masonry Table", 8 }, { "Private Smelter", 8 }, { "Private Sawmill", 8 },
	{ "Private Masonry Table", 8 }, { "Private Leatherwork Table", 8 }, { "Gazebo Farm", 16 },
	{ "Solar Scarecrow Farm", 16 }, { "Lunar Scarecrow Farm", 16 }, { "Stellar Scarecrow Farm", 16 },
	{ "Scarecrow Farm", 16 }, { "Rustic Slate Cottage", 16 }, { "Raised Swept-Roof Cottage", 16 },
	{ "Improved Scarecrow Farm", 16 }, { "Improved Stellar Pavilion Farm", 24 },
	{ "Improved Solar Pavilion Farm", 24 }, { "Improved Lunar Pavilion Farm", 24 },
	{ "Improved Solar Pavilion Farm Kit", 24 }, { "Improved Lunar Pavilion Farm Kit", 24 },
	{ "Improved Stellar Pavilion Farm Kit", 24 }, { "Miner's Farmhouse", 24 },
	{ "Recovering Cherry Treehouse", 28 }, { "Desserted House", 24 }, { "Beanstalk House", 48 },
	{ "Rose Quartz Solarium", 24 }, { "Rancher's Farmhouse", 24 }, { "Harvester's Farmhouse", 24 },
	{ "Advanced Fellowship Plaza", 24 }, { "Spired Chateau", 24 }, { "Apothecary's Chalet (Terrace)", 24 },
	{ "Tradesman's Manor", 24 }, { "Armorer's Townhouse", 24 }, { "Thatched Farmhouse", 24 },
	{ "Gazebo Farm", 16 }, { "Tudor Slate Cottage", 16 }, { "Freezing Cold Icehouse", 24 },
	{ "Storage Silo", 8 }, { "Recovering Aspen Treehouse", 28 }, { "Recovering Oak Treehouse", 28 },
	{ "Private Loom", 8 }, { "Haranyan Private Leatherwork Table", 8 }, { "Raised Rose Cottage", 16 },
	{ "Raised Slate Cottage", 16 }, { "Little Witch Pinnacled House", 24 }, { "Raised Mushroom House", 24 },
	{ "Tradesman's Townhouse", 24 }, { "Swept-Roof Villa", 16 }, { "Swept-Roof Chalet", 24 },
	{ "Swept-Roof Manor", 28 }, { "Rustic Spring Cottage", 16 }, { "Stone Spring Cottage", 16 },
	{ "Tudor Spring Cottage", 16 }, { "Stone Slate Cottage", 16 }, { "Rustic Rose Cottage", 16 },
	{ "Stone Rose Cottage", 16 }, { "Tudor Rose Cottage", 16 }, { "Rustic Spring Manor", 24 },
	{ "Stone Spring Manor", 24 }, { "Tudor Spring Manor", 24 }, { "Rustic Slate Manor", 24 },
	{ "Stone Slate Manor", 24 }, { "Tudor Slate Manor", 24 }, { "Rustic Rose Manor", 24 },
	{ "Stone Rose Manor", 24 }, { "Tudor Rose Manor", 24 }, { "Rustic Spring Townhouse", 24 },
	{ "Stone Spring Townhouse", 24 }, { "Tudor Spring Townhouse", 24 }, { "Rustic Slate Townhouse", 24 },
	{ "Stone Slate Townhouse", 24 }, { "Tudor Slate Townhouse", 24 }, { "Rustic Rose Townhouse", 24 },
	{ "Stone Rose Townhouse", 24 }, { "Tudor Rose Townhouse", 24 }, { "Rustic Spring Chalet", 24 },
	{ "Stone Spring Chalet", 24 }, { "Tudor Spring Chalet", 24 }, { "Rustic Slate Chalet", 24 },
	{ "Stone Slate Chalet", 24 }, { "Tudor Slate Chalet", 24 }, { "Rustic Rose Chalet", 24 },
	{ "Stone Rose Chalet", 24 }, { "Tudor Rose Chalet", 24 }, { "Breezy Bungalow", 24 },
	{ "Tidal Bungalow", 28 }, { "Oak Treehouse", 28 }, { "Cherry Treehouse", 28 }, { "Aspen Treehouse", 28 },
	{ "Fellowship Plaza", 28 }, { "Mansion", 44 }, { "Raised Spring Cottage", 16 }, { "Armorer's Manor", 24 },
	{ "Swept-Roof Cottage", 16 }, { "Armorer's Chalet (Terrace)", 24 }, { "Apothecary's Townhouse", 24 },
}

local BUILDING_IDS = {}
local BUILDING_SIZES = {}
for index, building in ipairs(BUILDINGS) do
	BUILDING_IDS[building[1]] = index - 1
	BUILDING_SIZES[building[1]] = building[2]
end

local function safeCall(fn)
	local ok, result = pcall(fn)
	if not ok then
		return nil
	end
	return result
end

local function getTargetFrame()
	local frame = safeCall(function() return ADDON:GetContent(UIC.TARGET_UNITFRAME) end)
	if type(frame) == "table" then
		return frame
	end
	return nil
end

-- the target frame's tooltip, e.g. "Owner: Cawyn\nHealth : |p2; / |p3; (|p4;%)" (WorldSatNav reads the owner from it)
local function getTooltip()
	local frame = getTargetFrame()
	if frame == nil or type(frame.tooltipText) ~= "string" then
		-- frame not shown/populated yet: force it visible, then retry once
		pcall(function() ADDON:ShowContent(UIC.TARGET_UNITFRAME, true) end)
		frame = getTargetFrame()
	end
	if frame == nil or type(frame.tooltipText) ~= "string" then
		return nil
	end
	return frame.tooltipText
end

local function ownerFromTooltip(tooltip)
	if tooltip == nil then
		return nil
	end
	local owner = tooltip:match("Owner:%s*([^\r\n]+)")
	if owner == nil then
		return nil
	end
	owner = owner:gsub("%s+$", "")
	if owner == "" then
		return nil
	end
	return owner
end

-- The client's own classification: F_UNIT.GetUnitType (x2ui/components/func_unit.lua, a client global the
-- sandbox lets through) returns e.g. "npc", "housing" for a house target. nil, nil when unavailable.
function target.UnitKind(unit)
	local ok, unitType, kind = pcall(function()
		return F_UNIT.GetUnitType(unit or "target")
	end)
	if not ok or type(unitType) ~= "string" or type(kind) ~= "string" then
		return nil, nil
	end
	return unitType, kind
end

target.NONE = "none"
-- looks like a building but is out of range (or gives no distance): may pass once the player is closer
target.FAR = "far"
target.HOUSE = "house"

-- WorldSatNav's demo "+" test (features/demos.lua): a named target with no unit id, info, modifier
-- info or class, not targeting anything, within MAX_DISTANCE_M. Returns status, name, distance.
function target.Check()
	local U = api.Unit
	local name = safeCall(function() return U:UnitName("target") end)
	if name == nil or name == "" then
		return target.NONE
	end
	if safeCall(function() return U:GetUnitId("target") end) ~= nil
		or safeCall(function() return U:UnitInfo("target") end) ~= nil
		or safeCall(function() return U:UnitModifierInfo("target") end) ~= nil
		or safeCall(function() return U:UnitClass("target") end) ~= nil
		or safeCall(function() return U:TargetUnit("target") end) ~= nil then
		return target.NONE
	end
	-- on top of WorldSatNav's test: the client must call it housing when it says anything at all
	-- (farm objects such as Aging Larder pass the test above)
	local _, kind = target.UnitKind("target")
	if kind ~= nil and kind ~= "housing" then
		return target.NONE
	end
	local distance = tonumber(safeCall(function() return U:UnitDistance("target") end))
	if distance == nil or distance > target.MAX_DISTANCE_M then
		return target.FAR, name, distance
	end
	return target.HOUSE, name, distance
end

-- everything known about the targeted house apart from its position
function target.Details(name)
	local U = api.Unit
	local tooltip = getTooltip()
	local zoneGroup = safeCall(function() return U:GetCurrentZoneGroup() end)
	local zoneState = nil
	if zoneGroup ~= nil then
		zoneState = safeCall(function() return api.Zone:GetZoneStateInfoByZoneId(zoneGroup) end)
	end
	local unitType, kind = target.UnitKind("target")
	return {
		name = name,
		unit_type = unitType,
		kind = kind,
		owner = ownerFromTooltip(tooltip),
		faction = safeCall(function() return U:GetFactionName("target") end),
		health = tonumber(safeCall(function() return U:UnitHealth("target") end)),
		max_health = tonumber(safeCall(function() return U:UnitMaxHealth("target") end)),
		building_id = BUILDING_IDS[name],
		footprint = BUILDING_SIZES[name],
		zone_group = zoneGroup,
		zone_state = zoneState,
		tooltip = tooltip,
	}
end

-- the owner shown now; the frame can still show the previous target's owner just after a change
function target.Owner()
	return ownerFromTooltip(getTooltip())
end

return target
