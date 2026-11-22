local api = require("api")

-- Plays sound keys the way WorldSatNav's helpers/sound.lua does. The addon API has no "play this
-- sound" call: a widget only plays a sound when the engine drives it (a button when clicked, a
-- window when it opens). So a sound is played by re-opening a hidden 1x1 window that carries the
-- key. Two slots opened in the same call give two stacked sounds.
local sound = {}

local SLOT_COUNT = 2
local slots = {}

local function getSlot(index)
	if slots[index] ~= nil then
		return slots[index]
	end
	local window = api.Interface:CreateEmptyWindow("PlayerDBSoundSlot" .. index)
	if window == nil then
		return nil
	end
	window:AddAnchor("TOPLEFT", "UIParent", 0, 0)
	window:SetExtent(1, 1)
	window:SetCloseOnEscape(false)
	window:Show(false)
	slots[index] = window
	return window
end

-- Plays one sound key on slot 1 or 2. The slot is silenced while it is hidden and re-shown, so
-- repeating the same key plays it again and hiding never plays a close sound.
-- Returns true when the slot was opened with the key.
function sound.Play(slotIndex, key)
	if key == nil or key == "" then
		return false
	end
	if slotIndex < 1 or slotIndex > SLOT_COUNT then
		return false
	end
	local window = getSlot(slotIndex)
	if window == nil or window.SetSounds == nil then
		return false
	end
	window:SetSounds("")
	if window:IsVisible() then
		window:Show(false)
	end
	window:SetSounds(key)
	window:Show(true)
	return true
end

-- Opens both slots in the same call so the two sounds overlap.
function sound.PlayStacked(keyA, keyB)
	local playedA = sound.Play(1, keyA)
	local playedB = sound.Play(2, keyB)
	return playedA, playedB
end

function sound.Release()
	for index, window in pairs(slots) do
		if window.SetSounds ~= nil then
			window:SetSounds("")
		end
		window:Show(false)
		api.Interface:Free(window)
		slots[index] = nil
	end
end

return sound
