---------------------------
-- Lua code author: R1ck --
-- Company: VICTOR HUGO PERENHA - JOGOS ON LINE --
---------------------------

ImbuementTracker = {}
ImbuementTracker.__index = ImbuementTracker

local imbuementData = nil
local sortOptions = {}
local characterConfig = {}

local sortTypes = {
	LESS_THAN_ONE = 1,
	LAST_BETWEEN = 2,
	MORE_THAN_THREE = 3,
	NO_ACTIVE = 4,
}

function ImbuementTracker.onReceiveData(items)
  imbuementData = items
  ImbuementTracker.showTrackerData()
end

function ImbuementTracker.showTrackerData()
	if not imbuementData or not g_game.isOnline() then
		return
	end

	local sortedData = {}
	imbuementTrackerWindow.contentsPanel:destroyChildren()

	for _, data in pairs(imbuementData) do
		local hasActive = false
		local hasVisibleActive = false
		for k = 1, data.totalSlots do
			local v = data.slots[k]
			if v then
				hasActive = true
				local hours = math.floor(v.duration / 3600)
				local visible = false
				if hours < 1 then
					visible = sortOptions[sortTypes.LESS_THAN_ONE]
				elseif hours >= 1 and hours <= 3 then
					visible = sortOptions[sortTypes.LAST_BETWEEN]
				else
					visible = sortOptions[sortTypes.MORE_THAN_THREE]
				end
				if visible then
					hasVisibleActive = true
				end
			end
		end

		local canShow = false
		if hasActive then
			if hasVisibleActive then
				canShow = true
			end
		else
			if sortOptions[sortTypes.NO_ACTIVE] then
				canShow = true
			end
		end

		if canShow then
			table.insert(sortedData, data)
		end
	end

	for _, data in pairs(sortedData) do
		local widget = g_ui.createWidget('ImbuePanel', imbuementTrackerWindow.contentsPanel)
		widget.itemSlot:setItem(data.item)

		local position = {x = 65535, y = data.slot, z = 0}
		local item = widget.itemSlot:getItem()
		if item then
			item:setPosition(position)
			if item:isContainer() then
				updateFlags(item, widget.itemSlot)
			end
		end

		for k = 1, 3 do
			local panel = widget:recursiveGetChildById("panel" .. k)
			local source = widget:recursiveGetChildById("imbueContainer" .. k)
			if panel and source then
				if k <= data.totalSlots then
					panel:setVisible(true)
					source:setVisible(true)
					local v = data.slots[k]
					if v then
						local total_seconds = v.duration
						local hours = math.floor(total_seconds / 3600)
						local minutes = math.floor((total_seconds % 3600) / 60)
						local seconds = total_seconds % 60

						local formatted_minutes = string.format("%02d", minutes)
						local formatted_seconds = string.format("%02d", seconds)

						source:setImageSource("/images/game/imbuing/imbuement-icons-64")
						source:setImageClip(getFramePosition(v.iconId, 64, 64, 21) .. " 64 64")
						source:setTooltip(tr("%s\n\nTime remaining: %sh %smin", v.name, hours, minutes))

						if hours >= 10 then
							source:setText(hours .. "h")
						elseif hours < 10 and hours >= 1 then
							source:setText(hours .. "h" .. formatted_minutes)
						elseif hours < 1 and minutes >= 10 then
							source:setText(formatted_minutes .. "m")
						elseif minutes < 10 and minutes >= 1 then
							source:setText(minutes .. "m" .. formatted_seconds)
							source:setTooltip(tr("%s\n\nTime remaining: %sm %sseconds", v.name, minutes, seconds))
						else
							source:setText(formatted_seconds .. "s")
							source:setTooltip(tr("%s\n\nTime remaining: %s seconds", v.name, seconds))
						end

						if hours < 1 then
							source:setColor("#d33c3c")
						elseif hours < 3 then
							source:setColor("#f8db38")
						else
							source:setColor("#a87f68")
						end
					else
						-- Empty slot
						source:setImageSource("/images/game/trackers/imbue-slot")
						source:setImageClip("0 0 32 32")
						source:setText("")
						source:setTooltip(tr("Empty slot"))
						source:setColor("#a87f68")
					end
				else
					panel:setVisible(false)
					source:setVisible(false)
				end
			end
		end
	end
end

function ImbuementTracker.initSortFields()
	sortOptions[sortTypes.LESS_THAN_ONE] = characterConfig["showAlmostGone"]
	sortOptions[sortTypes.LAST_BETWEEN] = characterConfig["showUsed"]
	sortOptions[sortTypes.MORE_THAN_THREE] = characterConfig["showAlmostNew"]
	sortOptions[sortTypes.NO_ACTIVE] = characterConfig["showEmptySlots"]
end

function ImbuementTracker.onSortButton()
	local sortMenu = g_ui.createWidget('PopupMenu')
    sortMenu:setGameMenu(true)
	sortMenu:addCheckBoxOption(tr('Show imbuements that last less than 1h'), function() ImbuementTracker.sortFilterCheck(sortTypes.LESS_THAN_ONE) end, "", sortOptions[sortTypes.LESS_THAN_ONE])
    sortMenu:addCheckBoxOption(tr('Show imbuements that last between 1h and 3h'), function() ImbuementTracker.sortFilterCheck(sortTypes.LAST_BETWEEN) end, "", sortOptions[sortTypes.LAST_BETWEEN])
    sortMenu:addCheckBoxOption(tr('Show imbuements that last more than 3h'), function() ImbuementTracker.sortFilterCheck(sortTypes.MORE_THAN_THREE) end, "", sortOptions[sortTypes.MORE_THAN_THREE])
    sortMenu:addCheckBoxOption(tr('Show items with no active imbuement'), function() ImbuementTracker.sortFilterCheck(sortTypes.NO_ACTIVE) end, "", sortOptions[sortTypes.NO_ACTIVE])
    sortMenu:display(g_window.getMousePosition())
end

function ImbuementTracker.sortFilterCheck(type)
	sortOptions[type] = not sortOptions[type]
	if type == sortTypes.LESS_THAN_ONE then
		characterConfig["showAlmostGone"] = sortOptions[type]
	elseif type == sortTypes.LAST_BETWEEN then
		characterConfig["showUsed"] = sortOptions[type]
	elseif type == sortTypes.MORE_THAN_THREE then
		characterConfig["showAlmostNew"] = sortOptions[type]
	else
		characterConfig["showEmptySlots"] = sortOptions[type]
	end
	ImbuementTracker.showTrackerData()
end

function ImbuementTracker.online()
	characterConfig = modules.game_sidebars.getImbuementTrackerConfig()
	if table.empty(characterConfig) then
		characterConfig = {
			["contentHeight"] = 0,
			["contentMaximized"] =  true,
			["showAlmostGone"] =  true,
			["showAlmostNew"] =  true,
			["showEmptySlots"] =  true,
			["showUsed"] =  true
		}
	end
end

function ImbuementTracker.offline()
	modules.game_sidebars.registerImbuementTrackerConfig(characterConfig)
end