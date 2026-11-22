-- SoundTest: a panel to try sound keys, one at a time or two stacked (as WorldSatNav plays its alerts).
-- Nothing is logged.
local api = require("api")
local sound = require("PlayerDB/sound")
local panel = require("PlayerDB/features/soundtest/panel")

local feature = {
	id = "soundtest",
	label = "Sound test",
}

local enabled = false

local function runSafe(fn)
	local ok, result = pcall(fn)
	if not ok then
		api.Log:Info("[PlayerDB SoundTest] error: " .. tostring(result))
		return nil
	end
	return result
end

local function play(slot, key)
	return runSafe(function()
		return sound.Play(slot, key)
	end) == true
end

local function playBoth(keyA, keyB)
	local playedA, playedB = false, false
	runSafe(function()
		playedA, playedB = sound.PlayStacked(keyA, keyB)
	end)
	return playedA == true, playedB == true
end

-- nothing logged
function feature.ResetData()
	return 0
end

function feature.Enable()
	if enabled then
		return
	end
	enabled = true
	runSafe(function()
		panel.Create(play, playBoth)
	end)
end

function feature.Disable()
	if not enabled then
		return
	end
	enabled = false
	runSafe(panel.Free)
end

return feature
