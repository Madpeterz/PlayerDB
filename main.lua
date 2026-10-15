-- PlayerDB Main Module
local api = require("api")
local logbook = require("PlayerDB/logbook")
local statusdots = require("PlayerDB/statusdots")

local PlayerDB = {
	name = "PlayerDB",
	author = "Madpeter",
	version = "1.1.1",
	desc = "Logs targeted and grouped players"
}
local function runSafe(fn)
	local ok, result = pcall(fn)
	if not ok then
		-- always in the log file; in chat only in dev mode
		api.Log:Info("[PlayerDB] error: " .. tostring(result))
		logbook.Chat(3, "[PlayerDB] error: " .. tostring(result))
		return nil
	end
	return result
end

-- flips the status dot for a scan; a UI problem must never stop logging
local function markScan(index)
	runSafe(function()
		statusdots.Toggle(index)
	end)
end

-- TEAM_MEMBERS_CHANGED fires in bursts (joining a raid, people swapping groups)
-- and member info is not always ready yet, so wait and scan once.
local RAID_SCAN_DELAY_MS = 2000
-- one more scan a while after the last change, for members who were out of range at first
local RAID_RESCAN_DELAY_MS = 3 * 60 * 1000
local raidScanPending = false
-- bumped on every queued rescan; DoIn can't be cancelled, so older rescans see a newer id and skip
local raidRescanId = 0

local function queueRaidRescan()
	raidRescanId = raidRescanId + 1
	local rescanId = raidRescanId
	api:DoIn(RAID_RESCAN_DELAY_MS, function()
		if rescanId ~= raidRescanId or PlayerDB.eventWindow == nil then
			return -- superseded by a later change, or unloaded meanwhile
		end
		runSafe(logbook.ScanRaid)
		markScan(statusdots.RAID)
	end)
end

local function queueRaidScan()
	if raidScanPending then
		return
	end
	raidScanPending = true
	api:DoIn(RAID_SCAN_DELAY_MS, function()
		raidScanPending = false
		if PlayerDB.eventWindow == nil then
			return -- unloaded meanwhile
		end
		local members = runSafe(logbook.ScanRaid)
		markScan(statusdots.RAID)
		if members ~= nil and members > 0 then
			queueRaidRescan()
		end
	end)
end

-- log our own character on load and then on a fixed interval
local SELF_LOG_FIRST_DELAY_MS = 5000
local SELF_LOG_INTERVAL_MS = 15 * 60 * 1000
-- bumped on every load; a timer chain from an earlier load sees a newer id and stops
local selfLogId = 0

local function queueSelfLog(loadId, delay)
	api:DoIn(delay, function()
		if loadId ~= selfLogId or PlayerDB.eventWindow == nil then
			return -- reloaded or unloaded meanwhile
		end
		runSafe(logbook.LogSelf)
		markScan(statusdots.PLAYER)
		queueSelfLog(loadId, SELF_LOG_INTERVAL_MS)
	end)
end

-- Addon initialization
local function OnLoad()
	api.Log:Info("[" .. PlayerDB.name .. "] Starting version " .. PlayerDB.version)
	-- hidden window, only used to receive game events
	PlayerDB.eventWindow = api.Interface:CreateEmptyWindow("PlayerDBEvents")
	PlayerDB.eventWindow:Show(false)
	runSafe(statusdots.Create)
	-- attach events
	function PlayerDB:EventListener(event, ...)
		if(event == "TARGET_CHANGED") then
			runSafe(logbook.LogTarget)
			markScan(statusdots.TARGET)
		elseif(event == "TEAM_MEMBERS_CHANGED") then
			queueRaidScan()
		end
	end
	PlayerDB.eventWindow:SetHandler("OnEvent", PlayerDB.EventListener)
	PlayerDB.eventWindow:RegisterEvent("TARGET_CHANGED")
	PlayerDB.eventWindow:RegisterEvent("TEAM_MEMBERS_CHANGED")
	-- already in a raid when the addon (re)loads
	queueRaidScan()
	selfLogId = selfLogId + 1
	queueSelfLog(selfLogId, SELF_LOG_FIRST_DELAY_MS)
end

-- Addon cleanup
local function OnUnload()
	-- Unregister events
	if PlayerDB.eventWindow ~= nil then
		PlayerDB.eventWindow:ReleaseHandler("OnEvent")
		api.Interface:Free(PlayerDB.eventWindow)
		PlayerDB.eventWindow = nil
	end
	runSafe(statusdots.Free)
end

PlayerDB.OnSettingToggle = nil

PlayerDB.OnLoad = OnLoad
PlayerDB.OnUnload = OnUnload

return PlayerDB
