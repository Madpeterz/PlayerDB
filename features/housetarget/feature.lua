-- HouseTarget: when the target changes to a house (WorldSatNav's demo test), reads its name, owner,
-- faction, health, building id and region, and works out where it stands (locate.lua). Results go to
-- Demos/target.dat, rewritten as the position gets better while the house stays targeted.
-- Once the location is pinned it is saved to Houses/<sextant hash>_<owner>.dat, and the status icon
-- (icon.lua) turns from blue to green.
local api = require("api")
local addoninfo = require("PlayerDB/addoninfo")
local clock = require("PlayerDB/clock")
local datafiles = require("PlayerDB/datafiles")
local target = require("PlayerDB/features/housetarget/target")
local locate = require("PlayerDB/features/housetarget/locate")
local regionmap = require("PlayerDB/features/housetarget/regionmap")
local icon = require("PlayerDB/features/housetarget/icon")

local feature = {
	id = "housetarget",
	label = "HouseTarget",
}

local TARGET_FILE = "PlayerDB/Demos/target.dat"
-- one file per saved building: <hash of its sextant>_<owner>.dat
local HOUSES_DIR = "PlayerDB/Houses/"
-- what the blue icon asks for (sightings from a few metres apart pin the building)
local WALK_TEXT = "Move within 6 m and walk around it"
-- the target frame (owner name) is filled in a moment after TARGET_CHANGED
local SCAN_DELAY_MS = 600
-- while a building is targeted but too far (or gives no distance), check again this often
local FAR_POLL_MS = 1000
-- locate loop: a distance sample every tick, the camera model and a file update every few ticks
local TICK_MS = 250
local CAMERA_EVERY_TICKS = 4
-- until the house is saved the camera runs this often: each run can add a ray, and saving waits on rays
local CAMERA_EVERY_TICKS_UNSAVED = 2
local WRITE_EVERY_TICKS = 4
-- stop sampling a house left targeted this long
local MAX_SESSION_MS = 10 * 60 * 1000

local enabled = false
-- bumped on every target change; loops for an older target see a newer id and stop
local changeId = 0

local function runSafe(fn)
	local ok, result = pcall(fn)
	if not ok then
		api.Log:Info("[PlayerDB HouseTarget] error: " .. tostring(result))
		return nil
	end
	return result
end

-- a UI problem must never stop locating
local function setIcon(state, text)
	runSafe(function()
		icon.SetState(state, text)
	end)
end

-- 8 hex digits from the sextant text (djb2, kept below 2^32 without bit operations)
local function hashText(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + text:byte(i)) % 4294967296
	end
	return string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end

local function sextantKey(s)
	return string.format("%s%d.%d.%d_%s%d.%d.%d", s.longitude, s.deg_long, s.min_long, s.sec_long,
		s.latitude, s.deg_lat, s.min_lat, s.sec_lat)
end

-- letters and digits only, so the owner is safe in a file name
local function fileSafe(text)
	local safe = tostring(text or ""):gsub("[^%w]", "")
	if safe == "" then
		return "unknown"
	end
	return safe
end

-- whole numbers stay numbers, the rest become strings (as the old Houses logbook wrote them)
local function plain(value, depth)
	local valueType = type(value)
	if valueType == "number" then
		if value == math.floor(value) then
			return value
		end
		return string.format("%.14g", value)
	elseif valueType == "string" or valueType == "boolean" then
		return value
	elseif valueType ~= "table" or (depth or 0) > 4 then
		return nil
	end
	local out = {}
	pcall(function()
		for key, nested in pairs(value) do
			local keyType = type(key)
			if keyType == "string" or keyType == "number" then
				out[key] = plain(nested, (depth or 0) + 1)
			end
		end
	end)
	return out
end

local function describe(details)
	local text = details.name
	if details.owner ~= nil then
		text = text .. " owned by " .. details.owner
	end
	if details.faction ~= nil then
		text = text .. " (" .. tostring(details.faction) .. ")"
	end
	return text
end

local function writeFile(session, status)
	local details = session.details
	local estimate = session.estimate
	local data = {
		status = status,
		time = clock.Now() ~= nil and math.floor(clock.Now()) or api.Time:GetLocalTime(),
		seen = session.seen,
		name = details.name,
		unit_type = details.unit_type,
		kind = details.kind,
		owner = details.owner,
		faction = details.faction,
		health = details.health,
		max_health = details.max_health,
		building_id = details.building_id,
		footprint = details.footprint,
		zone_group = details.zone_group,
		zone_state = details.zone_state,
		tooltip = details.tooltip,
		distance = session.locate.distance,
		player_location = locate.PlayerSextant(),
		addon_version = addoninfo.version,
	}
	if estimate ~= nil then
		data.location = estimate.sextant
		data.method = estimate.method
		data.accuracy_m = estimate.accuracy_m
		data.lon = string.format("%.6f", estimate.lon)
		data.lat = string.format("%.6f", estimate.lat)
		data.world = estimate.world
		data.edge = estimate.edge
		data.box = estimate.box
		-- e.g. "9.06 x 9.02": the building's collision box UnitDistance measures to. Not the plot size
		-- (a 28x28 treehouse plot gave 9.06 x 9.02); the plot size comes from WorldSatNav's list (footprint).
		if estimate.collision_box_m ~= nil then
			data.collision_box_m = string.format("%.2f x %.2f", estimate.collision_box_m[1],
				estimate.collision_box_m[2])
			data.collision_box_angle_deg = estimate.collision_box_angle_deg
		end
		data.rays = estimate.rays
		data.camera = estimate.camera
		data.region_code = session.regionCode
		data.region = session.regionName
	end
	runSafe(function()
		api.File:Write(TARGET_FILE, plain(data))
	end)
end

-- Writes Houses/<sextant hash>_<owner>.dat once the location is pinned (and the owner is known).
-- The same building at the same sextant overwrites its own file.
local function saveHouse(session)
	local estimate = session.estimate
	local owner = session.details.owner
	if owner == nil then
		setIcon(icon.LOCATING, "Location pinned, waiting for the owner name")
		return
	end
	local fileName = hashText(sextantKey(estimate.sextant)) .. "_" .. fileSafe(owner) .. ".dat"
	-- unix seconds, the same way DemoOCR stamps location.dat
	local now = clock.Now()
	datafiles.Write(HOUSES_DIR, HOUSES_DIR .. fileName, {
		time = now ~= nil and math.floor(now) or api.Time:GetLocalTime(),
		addon_version = addoninfo.version,
		sextent = estimate.sextant,
		buildingname = session.details.name,
		ownername = owner,
	})
	session.saved = true
	local where = locate.FormatSextant(estimate.sextant)
	setIcon(icon.SAVED, "Saved: " .. session.details.name .. " (" .. owner .. ")\n" .. where
		.. "\nHouses/" .. fileName)
end

local function updateEstimate(session)
	local estimate = locate.Estimate(session.locate, session.details.footprint)
	if estimate == nil then
		return
	end
	session.estimate = estimate
	local ok, code, name = pcall(regionmap.GetRegionForSextant, estimate.sextant)
	if ok then
		session.regionCode, session.regionName = code, name
	end
	-- pinned (sightings or a distance fit): save it once
	local rank = locate.RANK[estimate.method] or 0
	if not session.saved and rank >= locate.RANK.edge then
		saveHouse(session)
	end
end

local function refreshOwner(session)
	if target.Check() ~= target.HOUSE then
		return
	end
	local owner = target.Owner()
	if owner ~= nil and owner ~= session.details.owner then
		session.details.owner = owner
	end
end

local function runLocate(id, session, tick)
	api:DoIn(TICK_MS, function()
		if not enabled or id ~= changeId then
			return
		end
		tick = tick + 1
		local every = session.saved and CAMERA_EVERY_TICKS or CAMERA_EVERY_TICKS_UNSAVED
		local withCamera = tick % every == 1 and locate.WantCamera(session.locate)
		runSafe(function()
			locate.Sample(session.locate, withCamera)
		end)
		if tick % WRITE_EVERY_TICKS == 0 then
			runSafe(function()
				refreshOwner(session)
				updateEstimate(session)
				writeFile(session, "locating")
			end)
		end
		if tick * TICK_MS >= MAX_SESSION_MS then
			runSafe(function()
				writeFile(session, "stopped")
			end)
			return
		end
		runLocate(id, session, tick)
	end)
end

local function startHouse(id, name)
	local session = {
		details = target.Details(name),
		locate = locate.NewSession(),
		seen = clock.NowText(),
	}
	setIcon(icon.LOCATING, describe(session.details) .. "\n" .. WALK_TEXT)
	runSafe(function()
		locate.Sample(session.locate, true)
		updateEstimate(session)
		writeFile(session, "locating")
	end)
	runLocate(id, session, 0)
end

local function queueCheck(id, delay)
	api:DoIn(delay, function()
		if not enabled or id ~= changeId then
			return
		end
		local status, name, distance = target.Check()
		if status == target.HOUSE then
			runSafe(function()
				startHouse(id, name)
			end)
		elseif status == target.FAR then
			-- farm objects (Aging Larder, ...) pass the same test but never give a distance: leave those gray
			if distance ~= nil then
				setIcon(icon.LOCATING, name .. string.format(" is %.0f m away\n", distance) .. WALK_TEXT)
			end
			queueCheck(id, FAR_POLL_MS)
		else
			setIcon(icon.NONE, "No house targeted")
		end
	end)
end

-- empties the saved Houses files (target.dat only holds the current house)
function feature.ResetData()
	return datafiles.Reset(HOUSES_DIR)
end

function feature.Enable()
	enabled = true
	runSafe(icon.Create)
end

function feature.Disable()
	enabled = false
	changeId = changeId + 1
	runSafe(icon.Free)
end

-- main.lua calls this from its event window
function feature.OnTargetChanged()
	if not enabled then
		return
	end
	changeId = changeId + 1
	-- gray until the new target turns out to be a house
	setIcon(icon.NONE, "No house targeted")
	queueCheck(changeId, SCAN_DELAY_MS)
end

return feature
