local api = require("api")
local settings = require("PlayerDB/settings")

-- Sound test panel: two rows, each a category dropdown, a sound dropdown and a Play button, plus a
-- Play both button. The game's dropdown list does not scroll, so the sounds are split into categories
-- of at most 8 (the way WorldSatNav's Dawnsdrop window pairs a task and a type dropdown).
-- The rows start on WorldSatNav's alert sounds (core/constants.lua alertSounds); the picks are remembered.
-- Drag the panel to move it.
local panel = {}

local IMAGE_DIR = api.baseDir .. "/PlayerDB/images/"
local BACKGROUND = IMAGE_DIR .. "settingsbackground.png"
-- position and picks kept in the addon settings (settings.lua)
local POSITION_X = "SoundTestX"
local POSITION_Y = "SoundTestY"
local PICK_KEYS = { "SoundTestSound1", "SoundTestSound2" }
local DEFAULT_X = 400
local DEFAULT_Y = 540

local DEFAULT_SOUNDS = { "ranking", "skill_book" }

-- the SetSounds keys listed in API_DOCUMENTATION.md, grouped as it groups them
local GROUPS = {
	{ name = "Window", sounds = { "dialog_common", "ability_change", "character_info", "achievement",
		"battlefield_entrance", "option", "config", "tutorial" } },
	{ name = "Web", sounds = { "web_wiki", "web_play_diary", "web_messenger", "web_note", "web_market" } },
	{ name = "Trade", sounds = { "trade", "auction", "auction_put_up", "store", "store_drain", "loot" } },
	{ name = "Mail", sounds = { "mail", "mail_read", "mail_write" } },
	{ name = "Inventory", sounds = { "bag", "bank", "coffer" } },
	{ name = "Customization", sounds = { "cosmetic_details", "dialog_enter_beautyshop", "dyeing", "wash",
		"dialog_gender_transfer" } },
	{ name = "Crafting", sounds = { "craft", "skill_book", "item_enchant", "composition_score" } },
	{ name = "Social", sounds = { "raid_team", "ranking", "ranking_reward", "community" } },
	{ name = "Map", sounds = { "world_map", "portal" } },
	{ name = "Quest", sounds = { "quest_context_list", "quest_directing_mode", "crime_records", "ruling_status" } },
	{ name = "Pet/farm", sounds = { "pet_info", "my_farm_info", "common_farm_info" } },
	{ name = "UI", sounds = { "edit_box", "default", "default_r", "submenu", "ucc" } },
}

local GROUP_NAMES = {}
for index, group in ipairs(GROUPS) do
	GROUP_NAMES[index] = group.name
end

local WINDOW_WIDTH = 420
local PADDING = 25
local TITLE_Y = 10
local DIVIDER_Y = 40
local ROW_TOP = 52
local ROW_HEIGHT = 34
local CONTROL_HEIGHT = 26
local COMBO_HEIGHT = 24
local GROUP_WIDTH = 120
local SOUND_WIDTH = 160
local GAP = 8
local SOUND_X = PADDING + GROUP_WIDTH + GAP
local PLAY_X = SOUND_X + SOUND_WIDTH + GAP
local PLAY_WIDTH = WINDOW_WIDTH - PADDING - PLAY_X
local BOTH_Y = ROW_TOP + 2 * ROW_HEIGHT + 4
local STATUS_Y = BOTH_Y + CONTROL_HEIGHT + 8
local WINDOW_HEIGHT = STATUS_Y + 20 + PADDING / 2

local window = nil
-- per row: { group = combo, sound = combo, groupIndex = n }
local rows = {}
local buttons = {}
local statusLabel = nil
-- true while the panel itself selects entries, so only the player's picks are acted on
local quiet = false

local function loadPosition()
	local x, y = tonumber(settings.Get(POSITION_X)), tonumber(settings.Get(POSITION_Y))
	if x ~= nil and y ~= nil then
		return x, y
	end
	return DEFAULT_X, DEFAULT_Y
end

local function savePosition()
	local x, y = window:GetEffectiveOffset()
	if x == nil or y == nil then
		return
	end
	settings.Update(POSITION_X, math.floor(x + 0.5))
	settings.Update(POSITION_Y, math.floor(y + 0.5))
end

local function attachDrag(widget)
	function widget:OnDragStart()
		window:StartMoving()
		api.Cursor:ClearCursor()
		api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
	end
	widget:SetHandler("OnDragStart", widget.OnDragStart)
	function widget:OnDragStop()
		window:StopMovingOrSizing()
		api.Cursor:ClearCursor()
		savePosition()
	end
	widget:SetHandler("OnDragStop", widget.OnDragStop)
	if widget.RegisterForDrag ~= nil then
		widget:RegisterForDrag("LeftButton")
	end
	widget:EnableDrag(true)
end

local function createLabel(id, text, offsetX, offsetY, width, fontSize, color)
	local label = api.Interface:CreateWidget("label", id, window)
	label:AddAnchor("TOPLEFT", window, offsetX, offsetY)
	label:SetExtent(width, 20)
	label:SetText(text)
	label.style:SetAlign(ALIGN.LEFT)
	label.style:SetFontSize(fontSize)
	label.style:SetColor(color[1], color[2], color[3], 1)
	label:Show(true)
	return label
end

local function createFrame()
	local background = window:CreateImageDrawable("PlayerDBSoundTestBackground", "background")
	background:SetExtent(WINDOW_WIDTH, WINDOW_HEIGHT)
	background:AddAnchor("TOPLEFT", window, "TOPLEFT", 0, 0)
	background:SetTexture(BACKGROUND)
	background:Show(true)
	if background.Lower then
		background:Lower()
	end

	createLabel("PlayerDBSoundTestTitle", "Sound test", PADDING, TITLE_Y + 5, WINDOW_WIDTH - 2 * PADDING, 20,
		FONT_COLOR.TITLE)

	local divider = window:CreateImageDrawable("PlayerDBSoundTestDivider", "background")
	divider:SetExtent(WINDOW_WIDTH - 2 * PADDING, 3)
	divider:AddAnchor("TOPLEFT", window, "TOPLEFT", PADDING, DIVIDER_Y)
	divider:SetTexture("bg_quest")
	divider:SetColor(0, 0, 0, 0.5)
	divider:Show(true)
end

-- group index and sound index of a key, or nil when it is not listed
local function findSound(key)
	for groupIndex, group in ipairs(GROUPS) do
		for soundIndex, sound in ipairs(group.sounds) do
			if sound == key then
				return groupIndex, soundIndex
			end
		end
	end
	return nil
end

-- the remembered pick, or the alert sound when none (or an unknown one) was saved
local function savedPick(index)
	local groupIndex, soundIndex = findSound(settings.Get(PICK_KEYS[index]))
	if groupIndex == nil then
		groupIndex, soundIndex = findSound(DEFAULT_SOUNDS[index])
	end
	return groupIndex or 1, soundIndex or 1
end

-- runs fn while the panel's own Select calls are ignored
local function selectQuietly(fn)
	quiet = true
	local ok, err = pcall(fn)
	quiet = false
	if not ok then
		error(err)
	end
end

-- Calls onPick when the player picks an entry. WorldSatNav's Dawnsdrop window wraps Select,
-- AAC-TnT-RaidTools uses SelectedProc; both are hooked, and onPick is safe to run twice.
local function hookPick(combo, onPick)
	local originalSelect = combo.Select
	function combo:Select(index)
		originalSelect(self, index)
		if not quiet then
			onPick()
		end
	end
	function combo:SelectedProc()
		if not quiet then
			onPick()
		end
	end
end

local function createCombo(offsetX, offsetY, width, items)
	local combo = W_CTRL.CreateComboBox(window)
	combo:AddAnchor("TOPLEFT", window, offsetX, offsetY + (CONTROL_HEIGHT - COMBO_HEIGHT) / 2)
	combo:SetExtent(width, COMBO_HEIGHT)
	combo.dropdownItem = items
	combo:Show(true)
	return combo
end

local function keyOf(index)
	local row = rows[index]
	if row == nil then
		return ""
	end
	local group = GROUPS[row.groupIndex]
	if group == nil then
		return ""
	end
	return group.sounds[row.sound:GetSelectedIndex()] or ""
end

local function savePick(index)
	local key = keyOf(index)
	if key ~= "" then
		settings.Update(PICK_KEYS[index], key)
	end
end

-- fills the row's sound dropdown with one category and selects soundIndex in it
local function showGroup(row, groupIndex, soundIndex)
	row.groupIndex = groupIndex
	selectQuietly(function()
		row.sound.dropdownItem = GROUPS[groupIndex].sounds
		row.sound:Select(soundIndex)
	end)
end

local function createRow(index, offsetY)
	local groupIndex, soundIndex = savedPick(index)
	local row = {
		group = createCombo(PADDING, offsetY, GROUP_WIDTH, GROUP_NAMES),
		sound = createCombo(SOUND_X, offsetY, SOUND_WIDTH, GROUPS[groupIndex].sounds),
		groupIndex = groupIndex,
	}
	rows[index] = row
	selectQuietly(function()
		row.group:Select(groupIndex)
		row.sound:Select(soundIndex)
	end)

	hookPick(row.group, function()
		local picked = row.group:GetSelectedIndex()
		if GROUPS[picked] == nil or picked == row.groupIndex then
			return
		end
		showGroup(row, picked, 1)
		savePick(index)
	end)
	hookPick(row.sound, function()
		savePick(index)
	end)
end

-- the buttons carry no sound of their own, so only the tested key is heard
local function createButton(id, text, offsetX, offsetY, width, onClick)
	local button = api.Interface:CreateWidget("button", id, window)
	button:AddAnchor("TOPLEFT", window, offsetX, offsetY)
	-- the skin sets its own size, so size the button after applying it
	api.Interface:ApplyButtonSkin(button, BUTTON_BASIC.DEFAULT)
	button:SetExtent(width, CONTROL_HEIGHT)
	button:SetText(text)
	if button.SetSounds ~= nil then
		button:SetSounds("")
	end
	button:SetHandler("OnClick", onClick)
	button:Show(true)
	buttons[#buttons + 1] = button
end

local function setStatus(text)
	if statusLabel ~= nil then
		statusLabel:SetText(text)
	end
end

local function describe(key, played)
	if key == "" then
		return "(empty)"
	end
	return key .. (played and "" or " (failed)")
end

-- play(slot, key) and playBoth(keyA, keyB) return whether each sound was started
function panel.Create(play, playBoth)
	if window ~= nil then
		return
	end
	local x, y = loadPosition()
	window = api.Interface:CreateEmptyWindow("PlayerDBSoundTest")
	window:AddAnchor("TOPLEFT", "UIParent", x, y)
	window:SetExtent(WINDOW_WIDTH, WINDOW_HEIGHT)
	window:SetCloseOnEscape(false)

	createFrame()
	for index = 1, 2 do
		local rowY = ROW_TOP + (index - 1) * ROW_HEIGHT
		createRow(index, rowY)
		createButton("PlayerDBSoundTestPlay" .. index, "Play " .. index, PLAY_X, rowY, PLAY_WIDTH, function()
			local key = keyOf(index)
			setStatus("Played: " .. describe(key, play(index, key)))
		end)
	end
	createButton("PlayerDBSoundTestPlayBoth", "Play both", PADDING, BOTH_Y, WINDOW_WIDTH - 2 * PADDING, function()
		local keyA, keyB = keyOf(1), keyOf(2)
		local playedA, playedB = playBoth(keyA, keyB)
		setStatus("Played: " .. describe(keyA, playedA) .. " + " .. describe(keyB, playedB))
	end)
	statusLabel = createLabel("PlayerDBSoundTestStatus", "Pick a sound and click Play", PADDING, STATUS_Y,
		WINDOW_WIDTH - 2 * PADDING, 12, { 0, 0, 0 })
	attachDrag(window)

	window:Show(true)
end

-- combos are freed on their own, as AAC-TnT-RaidTools does
local function freeCombo(combo)
	combo.SelectedProc = nil
	pcall(function()
		combo:Show(false)
	end)
	pcall(function()
		api.Interface:Free(combo)
	end)
end

function panel.Free()
	if window == nil then
		return
	end
	for _, button in ipairs(buttons) do
		pcall(function()
			button:ReleaseHandler("OnClick")
			button:Show(false)
		end)
	end
	buttons = {}
	for index, row in pairs(rows) do
		freeCombo(row.sound)
		freeCombo(row.group)
		rows[index] = nil
	end
	statusLabel = nil
	quiet = false
	pcall(function()
		window:ReleaseHandler("OnDragStart")
		window:ReleaseHandler("OnDragStop")
	end)
	window:Show(false)
	api.Interface:Free(window)
	window = nil
end

return panel
