-- Regrades: logs every regrade broadcast, with a light for losses.
local api = require("api")
local logbook = require("PlayerDB/features/regrades/logbook")
local statusdot = require("PlayerDB/features/regrades/statusdot")

local feature = {
	id = "regrades",
	label = "Regrades",
	events = { "GRADE_ENCHANT_BROADCAST" },
}

local enabled = false

-- errors never reach chat; they are kept in PlayerDB/regrade_errors.dat
local function runSafe(fn)
	local ok, result = pcall(fn)
	if not ok then
		pcall(logbook.LogError, result)
		return nil
	end
	return result
end

local function onRegrade(characterName, resultCode, itemLink, oldGrade, newGrade)
	local entry = runSafe(function()
		return logbook.LogRegrade(characterName, resultCode, itemLink, oldGrade, newGrade)
	end)
	if entry == nil then
		return -- not saved (error already logged, or a repeated broadcast)
	end
	if not logbook.IsLoss(entry) then
		return -- successes are logged but leave the light alone
	end
	-- a UI problem must never stop logging
	runSafe(function()
		local state = statusdot.LOST
		if entry.result == logbook.DESTROYED then
			state = statusdot.DESTROYED
		end
		statusdot.MarkLoss(state, logbook.Describe(entry))
	end)
end

-- regrade totals for the startup line, e.g. ", 158 regrades logged (40 losses)"
function feature.StartupInfo()
	local counts = runSafe(logbook.Counts)
	if counts == nil then
		return nil
	end
	return counts.regrades .. " regrades logged (" .. counts.losses .. " losses)"
end

function feature.Enable()
	if enabled then
		return
	end
	enabled = true
	runSafe(function()
		statusdot.Create(logbook.Counts)
	end)
end

function feature.Disable()
	if not enabled then
		return
	end
	enabled = false
	runSafe(statusdot.Free)
end

function feature.OnEvent(event, ...)
	if not enabled then
		return
	end
	if event == "GRADE_ENCHANT_BROADCAST" then
		-- same arguments loss_porn reads
		local characterName, resultCode, itemLink, oldGrade, newGrade = ...
		onRegrade(characterName, resultCode, itemLink, oldGrade, newGrade)
	end
end

return feature
