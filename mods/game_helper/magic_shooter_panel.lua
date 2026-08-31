-- Magic Shooter Panel Module
-- Unified dynamic layout for spells and runes configuration

local magicShooter = {}

-- Export module immediately so it's available for OTUI callbacks
modules.game_helper = modules.game_helper or {}
modules.game_helper.magicShooter = magicShooter

-- Local references
local magicShooterPanel = nil
local helper = nil
local formPanel = nil
local rulesList = nil
local presetsPanel = nil
local conditionSettingsWindow = nil

-- Condition checkbox states (decoupled from modal widget lifecycle)
local conditionStates = {
  castIfTrapped = false,
  countLowerThan = false,
  selfCast = false,
  extendedArea = false,
  extendedArea2 = false,
  forceOnTarget = false,
  showSelfCast = false,
  showExtendedArea = false,
  showExtendedArea2 = false,
  showForceOnTarget = false
}

-- State variables
local editingRuleKey = nil -- nil = ADD mode, "spell_123" or "rune_456" = UPDATE mode
local currentFormData = {
  type = "spell",          -- "spell" or "rune"
  spellId = 0,
  itemId = 0,
  name = "",
  words = ""
}

-- Track the last saved value of ignore monster list
local savedIgnoreMonsterListText = ""

-- Track the last saved value of priority monster list
local savedPriorityMonsterListText = ""


-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function getHelperWindow()
  local rootWidget = g_ui.getRootWidget()
  if rootWidget then
    return rootWidget:recursiveGetChildById('helperWindow')
  end
  return nil
end

local function getMagicShooterPanel()
  if magicShooterPanel then return magicShooterPanel end
  local rootWidget = g_ui.getRootWidget()
  if rootWidget then
    local helperWindow = rootWidget:recursiveGetChildById('helperWindow')
    if helperWindow then
      local container = helperWindow:recursiveGetChildById('shooterPanel')
      if container then
        magicShooterPanel = container:recursiveGetChildById('magicShooterPanel')
        if magicShooterPanel then
          formPanel = magicShooterPanel:recursiveGetChildById('configFormPanel')
          rulesList = magicShooterPanel:recursiveGetChildById('rulesList')
          presetsPanel = magicShooterPanel:recursiveGetChildById('presetsSection')
        end
      end
    end
  end
  return magicShooterPanel
end

local function getShooterProfile()
  if _Helper and _Helper.getShooterProfile then
    return _Helper.getShooterProfile()
  end
  return nil
end

local function saveSettings()
  if _Helper and _Helper.saveSettings then
    _Helper.saveSettings()
  end
end

local function updateArrowButtonStates()
  if _RuleList then
    _RuleList.updateArrowButtonStates(rulesList)
  end
end

local function numberToOrdinal(n)
  if _Helper and _Helper.numberToOrdinal then
    return _Helper.numberToOrdinal(n)
  end
  local suffixes = { "st", "nd", "rd" }
  local suffix = suffixes[n] or "th"
  return n .. suffix
end

local function isMonkVocation()
  local player = g_game.getLocalPlayer()
  if not player then return false end
  return player:isMonk()
end

-- Generate unique key for a rule based on type and spellId/itemId
local function getRuleKey(rule)
  if rule.type == "spell" then
    return "spell_" .. tostring(rule.spellId)
  else
    return "rune_" .. tostring(rule.itemId)
  end
end

-- Sync condition checkbox widgets with conditionStates (when modal is open)
-- Sync only checked states for checkboxes that still exist in the modal
local function syncConditionWidgets()
  if not conditionSettingsWindow then return end
  local panel = conditionSettingsWindow:getChildById('checkboxPanel')
  if not panel then return end
  local castCheck = panel:recursiveGetChildById('castIfTrappedCheck')
  if castCheck then castCheck:setChecked(conditionStates.castIfTrapped) end
  local countLowerCheck = panel:recursiveGetChildById('countLowerThanCheck')
  if countLowerCheck then countLowerCheck:setChecked(conditionStates.countLowerThan) end
  local selfCastCheck = panel:recursiveGetChildById('selfCastCheck')
  if selfCastCheck then selfCastCheck:setChecked(conditionStates.selfCast) end
  local extCheck = panel:recursiveGetChildById('extendedAreaCheck')
  if extCheck then extCheck:setChecked(conditionStates.extendedArea) end
  local ext2Check = panel:recursiveGetChildById('extendedArea2Check')
  if ext2Check then ext2Check:setChecked(conditionStates.extendedArea2) end
  local forceCheck = panel:recursiveGetChildById('forceOnTargetCheck')
  if forceCheck then forceCheck:setChecked(conditionStates.forceOnTarget) end
end

local function updateHarmonyVisibility(visible)
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  local harmonyLabel = formPanel:recursiveGetChildById('harmonyLabel')
  local harmonyInput = formPanel:recursiveGetChildById('harmonyInput')

  if harmonyLabel then harmonyLabel:setVisible(visible) end
  if harmonyInput then harmonyInput:setVisible(visible) end

  -- Reanchor delayInput based on harmony visibility and current type
  -- (delayLabel follows automatically since it anchors to delayInput.left in OTUI)
  local delayInput = formPanel:recursiveGetChildById('delayInput')
  local isRune = currentFormData.type == "rune"
  if visible then
    if delayInput then
      delayInput:removeAnchor(AnchorLeft)
      delayInput:addAnchor(AnchorLeft, 'harmonyInput', AnchorRight)
      delayInput:setMarginLeft(15)
    end
  elseif isRune then
    if delayInput then
      delayInput:removeAnchor(AnchorLeft)
      delayInput:addAnchor(AnchorLeft, 'playerLabel', AnchorRight)
      delayInput:setMarginLeft(5)
    end
  else
    if delayInput then
      delayInput:removeAnchor(AnchorLeft)
      delayInput:addAnchor(AnchorLeft, 'healthPercentInput', AnchorRight)
      delayInput:setMarginLeft(15)
    end
  end
end

-- Check if a spell uses the rangedMonsterNames filter
local function isRangedMonsterSpell(spellId)
  if not spellId then return false end
  -- Dispatch via the shared modules namespace so the real HelperSpellData
  -- can be stubbed from tests running outside this sandbox. Falls back to
  -- the in-sandbox global at runtime when tests haven't stubbed anything.
  local spellData = (modules.game_helper and modules.game_helper.spellData) or HelperSpellData
  return spellData.isRangedMonsterSpell(spellId)
end

-- Enable/disable addButton and conditionSettingsButton based on spell/rune selection
local formButtonsEnabled = false

local function updateFormButtons(enabled)
  formButtonsEnabled = enabled
  if not rulesList then getMagicShooterPanel() end
  local rulesListPanel = rulesList and rulesList:getParent()
  if rulesListPanel then
    local disabledTooltip = tr('Select a new spell/rune or click a rule from the list.')
    local addButton = rulesListPanel:getChildById('addButton')
    if addButton then
      addButton:setOpacity(enabled and 1.0 or 0.4)
      addButton:setTooltip(enabled and "" or disabledTooltip)
    end
    local condBtn = rulesListPanel:getChildById('conditionSettingsButton')
    if condBtn then
      condBtn:setOpacity(enabled and 1.0 or 0.4)
      condBtn:setTooltip(enabled and tr('Condition Settings') or disabledTooltip)
    end
  end
end

-- Update visibility of the rangedMonstersRow based on selected spell
local function updateRangedMonstersVisibility(visible)
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  local rangedMonstersRow = formPanel:recursiveGetChildById('rangedMonstersRow')
  if rangedMonstersRow then rangedMonstersRow:setVisible(visible) end

  -- Adjust configFormPanel height based on visibility
  local configFormPanel = formPanel
  if configFormPanel then
    local baseHeight = configFormPanel.baseHeight or 90
    local expandedHeight = configFormPanel.expandedHeight or 116
    if visible then
      configFormPanel:setHeight(expandedHeight)
    else
      configFormPanel:setHeight(baseHeight)
    end
  end
end

-- Update visibility of the extendedAreaCheck based on selected spell
local function updateExtendedAreaVisibility(visible)
  conditionStates.showExtendedArea = visible
  if not visible then
    conditionStates.extendedArea = false
  end
  syncConditionWidgets()
end

-- Update visibility of the extendedArea2Check based on selected spell
local function updateExtendedArea2Visibility(visible)
  conditionStates.showExtendedArea2 = visible
  if not visible then
    conditionStates.extendedArea2 = false
  end
  syncConditionWidgets()
end

-- Update the Apply button enabled state based on text changes
local function updateApplyIgnoreButtonState()
  if not magicShooterPanel then getMagicShooterPanel() end
  if not magicShooterPanel then return end

  local ignoreMonsterInput = magicShooterPanel:recursiveGetChildById('ignoreMonsterInput')
  local applyIgnoreButton = magicShooterPanel:recursiveGetChildById('applyIgnoreButton')

  if not ignoreMonsterInput or not applyIgnoreButton then return end

  local currentText = ignoreMonsterInput:getText() or ""

  -- Enable button only if text differs from saved value
  if currentText ~= savedIgnoreMonsterListText then
    applyIgnoreButton:setEnabled(true)
  else
    applyIgnoreButton:setEnabled(false)
  end
end

-- Update the Apply Priority button enabled state based on text changes
local function updateApplyPriorityButtonState()
  if not magicShooterPanel then getMagicShooterPanel() end
  if not magicShooterPanel then return end

  local priorityMonsterInput = magicShooterPanel:recursiveGetChildById('priorityMonsterInput')
  local applyPriorityButton = magicShooterPanel:recursiveGetChildById('applyPriorityButton')

  if not priorityMonsterInput or not applyPriorityButton then return end

  local currentText = priorityMonsterInput:getText() or ""

  -- Enable button only if text differs from saved value
  if currentText ~= savedPriorityMonsterListText then
    applyPriorityButton:setEnabled(true)
  else
    applyPriorityButton:setEnabled(false)
  end
end

-- ============================================================
-- FORM HANDLING
-- ============================================================

function magicShooter.clearForm()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  -- Reset form data
  currentFormData = { type = "spell", spellId = 0, itemId = 0, name = "", words = "" }

  -- Reset spell button
  local spellButton = formPanel:recursiveGetChildById('spellButton')
  if spellButton then
    local spellItem = spellButton:getChildById('formSpellIcon')
    if spellItem then spellItem:destroy() end
    spellButton:setImageSource('/images/game/actionbar/actionbarslot')
    spellButton:setImageClip('0 0 0 0')
    spellButton:setTooltip("")
    spellButton:setBorderWidth(0)
  end

  -- Reset rune button
  local runeButton = formPanel:recursiveGetChildById('runeButton')
  if runeButton then
    local runeItem = runeButton:getChildById('formRuneItem')
    if runeItem then runeItem:destroy() end
    runeButton:setImageSource('/images/game/actionbar/actionbarslot')
    runeButton:setTooltip("")
  end

  -- Reset name label
  local nameLabel = formPanel:recursiveGetChildById('itemNameLabel')
  if nameLabel then
    nameLabel:setText("(select spell or rune)")
    nameLabel:setColor("#6b4d40")
  end

  -- Hide clear button
  local clearButton = formPanel:recursiveGetChildById('clearButton')
  if clearButton then clearButton:setVisible(false) end

  -- Reset mana percent
  local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')
  if manaPercentInput then manaPercentInput:setText("0") end

  -- Reset health percent
  local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')
  if healthPercentInput then healthPercentInput:setText("0") end

  -- Reset delay
  local delayInput = formPanel:recursiveGetChildById('delayInput')
  if delayInput then delayInput:setText("0") end

  -- Reset hpMin/hpMax (creature HP%)
  local hpMinInput = formPanel:recursiveGetChildById('hpMinInput')
  if hpMinInput then hpMinInput:setText("0") end
  local hpMaxInput = formPanel:recursiveGetChildById('hpMaxInput')
  if hpMaxInput then hpMaxInput:setText("0") end

  -- Reset creatures
  local creatures = formPanel:recursiveGetChildById('creaturesCombo')
  if creatures then creatures:setCurrentOption("1+") end

  -- Reset condition settings
  conditionStates.castIfTrapped = false
  conditionStates.countLowerThan = false
  conditionStates.selfCast = false
  conditionStates.extendedArea = false
  conditionStates.extendedArea2 = false
  conditionStates.forceOnTarget = false
  conditionStates.showSelfCast = false
  conditionStates.showExtendedArea = false
  conditionStates.showExtendedArea2 = false
  conditionStates.showForceOnTarget = false
  syncConditionWidgets()

  -- Reset harmony
  local harmonyInput = formPanel:recursiveGetChildById('harmonyInput')
  if harmonyInput then harmonyInput:setText("0") end
  updateHarmonyVisibility(false)

  -- Reset rangedMonstersInput
  local rangedMonstersInput = formPanel:recursiveGetChildById('rangedMonstersInput')
  if rangedMonstersInput then rangedMonstersInput:setText("") end
  updateRangedMonstersVisibility(false)

  -- Show all mana/creatures elements (default for spells)
  local manaLabel = formPanel:recursiveGetChildById('manaLabel')
  local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')
  local creaturesLabel = formPanel:recursiveGetChildById('creaturesLabel')
  local creaturesComboWidget = formPanel:recursiveGetChildById('creaturesCombo')

  if manaLabel then manaLabel:setVisible(true) end
  if manaPercentInput then manaPercentInput:setVisible(true) end

  -- Show health elements for spells
  local healthLabel = formPanel:recursiveGetChildById('healthLabel')
  local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')

  if healthLabel then healthLabel:setVisible(true) end
  if healthPercentInput then healthPercentInput:setVisible(true) end

  if creaturesLabel then creaturesLabel:setVisible(true) end
  if creaturesComboWidget then
    creaturesComboWidget:setVisible(true)
    creaturesComboWidget:setEnabled(true)
  end

  -- Reset to ADD mode
  editingRuleKey = nil
  if not rulesList then getMagicShooterPanel() end
  local rulesListPanel = rulesList and rulesList:getParent()
  if rulesListPanel then
    local addButton = rulesListPanel:getChildById('addButton')
    if addButton then addButton:setText("Add") end
  end

  -- Disable buttons when no spell/rune selected
  updateFormButtons(false)

  -- Clear visual selection in the list
  magicShooter.updateRuleSelection()
end

function magicShooter.getFormData()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return nil end

  local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')
  local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')
  local delayInput = formPanel:recursiveGetChildById('delayInput')
  local creaturesCombo = formPanel:recursiveGetChildById('creaturesCombo')
  local harmonyInput = formPanel:recursiveGetChildById('harmonyInput')
  local rangedMonstersInput = formPanel:recursiveGetChildById('rangedMonstersInput')
  local hpMinInput = formPanel:recursiveGetChildById('hpMinInput')
  local hpMaxInput = formPanel:recursiveGetChildById('hpMaxInput')

  -- Get selfCast, castIfTrapped, extendedArea and forceOnTarget from conditionStates
  local selfCast = conditionStates.selfCast
  local castIfTrapped = conditionStates.castIfTrapped
  local extendedArea = conditionStates.extendedArea
  local extendedArea2 = conditionStates.extendedArea2
  local forceOnTarget = conditionStates.forceOnTarget

  local harmonyThreshold = tonumber(harmonyInput and harmonyInput:getText() or "0") or 0

  -- For spender spells (Monk), ensure minimum harmony is 1
  if currentFormData.type == "spell" and currentFormData.spellId > 0 then
    local spell = Spells.getSpellDataById(currentFormData.spellId)
    if spell and spell.spender and harmonyThreshold < 1 then
      harmonyThreshold = 1
    end
  end

  -- Get rangedMonsterNames (only for specific spells)
  local rangedMonsterNames = ""
  if rangedMonstersInput and isRangedMonsterSpell(currentFormData.spellId) then
    rangedMonsterNames = rangedMonstersInput:getText() or ""
  end

  local rule = {
    type = currentFormData.type,
    spellId = currentFormData.spellId,
    itemId = currentFormData.itemId,
    name = currentFormData.name,
    words = currentFormData.words or "",

    manaPercent = tonumber(manaPercentInput and manaPercentInput:getText() or "0") or 0,
    healthPercent = tonumber(healthPercentInput and healthPercentInput:getText() or "0") or 0,
    extraDelay = tonumber(delayInput and delayInput:getText() or "0") or 0,
    creatures = tonumber(creaturesCombo and creaturesCombo:getCurrentOption().text:match("%d+") or "1") or 1,
    harmonyThreshold = harmonyThreshold,

    selfCast = selfCast,
    castIfTrapped = castIfTrapped,
    countLowerThan = conditionStates.countLowerThan,
    extendedArea = extendedArea,
    extendedArea2 = extendedArea2,
    forceOnTarget = forceOnTarget,
    rangedMonsterNames = rangedMonsterNames,

    hpMin = tonumber(hpMinInput and hpMinInput:getText() or "0") or 0,
    hpMax = tonumber(hpMaxInput and hpMaxInput:getText() or "0") or 0,

    enabled = true
  }

  return rule
end

function magicShooter.setFormData(rule)
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end
  if not rule then return end

  editingRuleKey = getRuleKey(rule)

  -- Set form data
  currentFormData = {
    type = rule.type,
    spellId = rule.spellId,
    itemId = rule.itemId,
    name = rule.name,
    words = rule.words or ""
  }

  -- Update buttons based on type
  if rule.type == "spell" and rule.spellId > 0 then
    local spellButton = formPanel:recursiveGetChildById('spellButton')
    if spellButton then
      local spell = Spells.getSpellDataById(rule.spellId)
      if spell then
        _Helper.setSpellIcon(spellButton, spell.id)
        spellButton:setBorderColorTop("#1b1b1b")
        spellButton:setBorderColorLeft("#1b1b1b")
        spellButton:setBorderColorRight("#757575")
        spellButton:setBorderColorBottom("#757575")
        spellButton:setBorderWidth(1)
        spellButton:setTooltip("Spell: " .. rule.name)
      end
    end

    -- Clear rune button
    local runeButton = formPanel:recursiveGetChildById('runeButton')
    if runeButton then
      local runeItem = runeButton:getChildById('formRuneItem')
      if runeItem then runeItem:destroy() end
      runeButton:setImageSource('/images/game/actionbar/actionbarslot')
      runeButton:setTooltip("")
    end

    -- Show mana elements for spells
    local manaLabel = formPanel:recursiveGetChildById('manaLabel')
    local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')

    if manaLabel then manaLabel:setVisible(true) end
    if manaPercentInput then manaPercentInput:setVisible(true) end

    -- Show health elements for spells
    local healthLabel = formPanel:recursiveGetChildById('healthLabel')
    local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')

    if healthLabel then healthLabel:setVisible(true) end
    if healthPercentInput then healthPercentInput:setVisible(true) end

    -- Make sure creatures elements are visible
    local creaturesLabel = formPanel:recursiveGetChildById('creaturesLabel')
    if creaturesLabel then creaturesLabel:setVisible(true) end

    -- Handle creatures combo enabled state for spells
    local spell = Spells.getSpellDataById(rule.spellId)
    local creaturesCombo = formPanel:recursiveGetChildById('creaturesCombo')
    if creaturesCombo then
      creaturesCombo:setVisible(true)
      creaturesCombo:setEnabled(true)
    end
  elseif rule.type == "rune" and rule.itemId > 0 then
    local runeButton = formPanel:recursiveGetChildById('runeButton')
    if runeButton then
      runeButton:setImageSource('/images/ui/item')
      local runeItem = runeButton:getChildById('formRuneItem')
      if not runeItem then
        runeItem = g_ui.createWidget('UIItem', runeButton)
        runeItem:setId('formRuneItem')
        runeItem:setSize({ width = 32, height = 32 })
        runeItem:setPhantom(true)
        runeItem:fill('parent')
        runeItem:setVirtual(true)
      end
      runeItem:setItemId(rule.itemId)
      runeButton:setTooltip("Rune: " .. rule.name)
    end

    -- Clear spell button
    local spellButton = formPanel:recursiveGetChildById('spellButton')
    if spellButton then
      local spellItem = spellButton:getChildById('formSpellIcon')
      if spellItem then spellItem:destroy() end
      spellButton:setImageSource('/images/game/actionbar/actionbarslot')
      spellButton:setImageClip('0 0 0 0')
      spellButton:setTooltip("")
      spellButton:setBorderWidth(0)
    end

    -- Hide mana elements for runes (but keep creatures visible)
    local manaLabel = formPanel:recursiveGetChildById('manaLabel')
    local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')

    if manaLabel then manaLabel:setVisible(false) end
    if manaPercentInput then manaPercentInput:setVisible(false) end

    -- Hide health elements for runes
    local healthLabel = formPanel:recursiveGetChildById('healthLabel')
    local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')

    if healthLabel then healthLabel:setVisible(false) end
    if healthPercentInput then healthPercentInput:setVisible(false) end

    -- Make sure creatures elements are visible
    local creaturesLabel = formPanel:recursiveGetChildById('creaturesLabel')
    if creaturesLabel then creaturesLabel:setVisible(true) end

    -- Handle creatures combo enabled state for runes
    local runeSpell = Spells.getRuneSpellByItem(rule.itemId)
    if not runeSpell and CustomRuneIds then runeSpell = CustomRuneIds[rule.itemId] end
    _Helper.resolveCustomRuneArea(runeSpell)
    local creaturesCombo = formPanel:recursiveGetChildById('creaturesCombo')
    if creaturesCombo then
      creaturesCombo:setVisible(true)
      if runeSpell and not runeSpell.area then
        creaturesCombo:setCurrentOption("1+")
        creaturesCombo:disable()
      else
        creaturesCombo:setEnabled(true)
      end
    end
  end

  -- Update name label
  local nameLabel = formPanel:recursiveGetChildById('itemNameLabel')
  if nameLabel then
    nameLabel:setText(rule.name)
    nameLabel:setColor("$var-text-color")
  end

  -- Show clear button (editing a rule means something is selected)
  local clearButton = formPanel:recursiveGetChildById('clearButton')
  if clearButton then clearButton:setVisible(true) end

  -- Set mana percent
  local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')
  if manaPercentInput then manaPercentInput:setText(tostring(rule.manaPercent or 0)) end

  -- Set health percent
  local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')
  if healthPercentInput then healthPercentInput:setText(tostring(rule.healthPercent or 0)) end

  -- Set delay
  local delayInput = formPanel:recursiveGetChildById('delayInput')
  if delayInput then delayInput:setText(tostring(rule.extraDelay or 0)) end

  -- Set hpMin/hpMax (creature HP%)
  local hpMinInput = formPanel:recursiveGetChildById('hpMinInput')
  if hpMinInput then hpMinInput:setText(tostring(rule.hpMin or 0)) end
  local hpMaxInput = formPanel:recursiveGetChildById('hpMaxInput')
  if hpMaxInput then hpMaxInput:setText(tostring(rule.hpMax or 0)) end

  -- Set creatures value (enabled state already handled in spell/rune specific sections above)
  local creaturesCombo = formPanel:recursiveGetChildById('creaturesCombo')
  if creaturesCombo then
    if rule.type == "spell" then
      -- Always restore creatures for spells (combo is enabled for all spell types)
      creaturesCombo:setCurrentOption(tostring(rule.creatures or 1) .. "+")
    elseif rule.type == "rune" then
      local runeSpell = Spells.getRuneSpellByItem(rule.itemId)
      if not runeSpell and CustomRuneIds then runeSpell = CustomRuneIds[rule.itemId] end
      _Helper.resolveCustomRuneArea(runeSpell)
      -- Only set custom value for area runes (single-target runes are forced to 1+ above)
      if runeSpell and runeSpell.area then
        creaturesCombo:setCurrentOption(tostring(rule.creatures or 1) .. "+")
      end
    end
  end

  -- Set selfCast condition state
  conditionStates.selfCast = rule.selfCast
  if rule.type == "spell" then
    local bothCastTypeSpells = _Helper and _Helper.MagicShooter and _Helper.MagicShooter.getBothCastTypeSpells and
        _Helper.MagicShooter.getBothCastTypeSpells() or {}
    conditionStates.showSelfCast = table.contains(bothCastTypeSpells, rule.spellId)
  else
    conditionStates.showSelfCast = false
  end

  -- Set harmony threshold (only for Monk and spells)
  local harmonyInput = formPanel:recursiveGetChildById('harmonyInput')
  if harmonyInput then
    local harmonyValue = rule.harmonyThreshold or 0
    -- For spender spells (Monk), ensure minimum harmony is 1
    if rule.type == "spell" and rule.spellId > 0 then
      local spell = Spells.getSpellDataById(rule.spellId)
      if spell and spell.spender and harmonyValue < 1 then
        harmonyValue = 1
      end
    end
    harmonyInput:setText(tostring(harmonyValue))
  end
  -- Show harmony only for Monk vocation and spell type
  updateHarmonyVisibility(isMonkVocation() and rule.type == "spell")

  -- Set rangedMonsterNames (only for specific spells)
  local rangedMonstersInput = formPanel:recursiveGetChildById('rangedMonstersInput')
  if rangedMonstersInput then
    rangedMonstersInput:setText(rule.rangedMonsterNames or "")
  end
  -- Show rangedMonstersRow only for specific spells
  updateRangedMonstersVisibility(rule.type == "spell" and isRangedMonsterSpell(rule.spellId))

  -- Set to UPDATE mode
  if not rulesList then getMagicShooterPanel() end
  local rulesListPanel = rulesList and rulesList:getParent()
  if rulesListPanel then
    local addButton = rulesListPanel:getChildById('addButton')
    if addButton then addButton:setText("Update") end
  end

  -- Set castIfTrapped, countLowerThan, extendedArea and forceOnTarget condition states
  conditionStates.castIfTrapped = rule.castIfTrapped or false
  conditionStates.countLowerThan = rule.countLowerThan or false
  conditionStates.extendedArea = rule.extendedArea or false
  conditionStates.extendedArea2 = rule.extendedArea2 or false
  conditionStates.forceOnTarget = rule.forceOnTarget or false

  -- Show extendedArea and forceOnTarget checkboxes only for spells that have those properties
  if rule.type == "spell" and rule.spellId and rule.spellId > 0 then
    local spell = Spells.getSpellDataById(rule.spellId)
    updateExtendedAreaVisibility(spell and spell.extendedArea ~= nil)
    updateExtendedArea2Visibility(spell and spell.extendedArea2 ~= nil)
    conditionStates.showForceOnTarget = spell and spell.aimAtTarget or false
  else
    updateExtendedAreaVisibility(false)
    updateExtendedArea2Visibility(false)
    conditionStates.showForceOnTarget = false
  end
  syncConditionWidgets()

  -- Enable buttons
  updateFormButtons(true)

  -- Update visual selection
  magicShooter.updateRuleSelection()
end

-- ============================================================
-- SPELL/RUNE SELECTION
-- ============================================================

local mouseGrabberWidget = nil

local function getMouseGrabber()
  if mouseGrabberWidget then return mouseGrabberWidget end
  mouseGrabberWidget = g_ui.createWidget('UIWidget')
  mouseGrabberWidget:setVisible(false)
  mouseGrabberWidget:setFocusable(false)
  return mouseGrabberWidget
end

function magicShooter.selectSpell()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  -- Open spell selector window
  local profile = getShooterProfile()
  if not profile then return end

  local spellButton = formPanel:recursiveGetChildById('spellButton')
  if not spellButton then return end

  -- Use helper's assignSpell function
  if modules.game_helper and modules.game_helper.assignSpellForMagicShooter then
    modules.game_helper.assignSpellForMagicShooter(spellButton, magicShooter.onSpellSelected)
  end
end

function magicShooter.onSpellSelected(spellData)
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  if not spellData or not spellData.id then return end

  local spell = Spells.getSpellDataById(spellData.id)
  if not spell then return end

  -- Update form data
  currentFormData = {
    type = "spell",
    spellId = spellData.id,
    itemId = 0,
    name = Spells.getSpellNameByWords(spell.words) or spell.words,
    words = spell.words
  }

  -- Update spell button
  local spellButton = formPanel:recursiveGetChildById('spellButton')
  if spellButton then
    _Helper.setSpellIcon(spellButton, spell.id)
    spellButton:setBorderColorTop("#1b1b1b")
    spellButton:setBorderColorLeft("#1b1b1b")
    spellButton:setBorderColorRight("#757575")
    spellButton:setBorderColorBottom("#757575")
    spellButton:setBorderWidth(1)
    spellButton:setTooltip("Spell: " .. currentFormData.name .. "\nWords: " .. spell.words)
  end

  -- Clear rune button
  local runeButton = formPanel:recursiveGetChildById('runeButton')
  if runeButton then
    local runeItem = runeButton:getChildById('formRuneItem')
    if runeItem then runeItem:destroy() end
    runeButton:setImageSource('/images/game/actionbar/actionbarslot')
    runeButton:setTooltip("")
  end

  -- Update name label
  local nameLabel = formPanel:recursiveGetChildById('itemNameLabel')
  if nameLabel then
    nameLabel:setText(currentFormData.name)
    nameLabel:setColor("$var-text-color")
  end

  -- Show clear button
  local clearButton = formPanel:recursiveGetChildById('clearButton')
  if clearButton then clearButton:setVisible(true) end

  -- Show mana elements for spells
  local manaLabel = formPanel:recursiveGetChildById('manaLabel')
  local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')

  if manaLabel then manaLabel:setVisible(true) end
  if manaPercentInput then manaPercentInput:setVisible(true) end

  -- Show health elements for spells
  local healthLabel = formPanel:recursiveGetChildById('healthLabel')
  local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')

  if healthLabel then healthLabel:setVisible(true) end
  if healthPercentInput then healthPercentInput:setVisible(true) end

  -- Handle creatures combo for targetable vs area spells
  local creaturesCombo = formPanel:recursiveGetChildById('creaturesCombo')
  local creaturesLabel = formPanel:recursiveGetChildById('creaturesLabel')

  -- Make sure creatures elements are visible
  if creaturesLabel then creaturesLabel:setVisible(true) end
  if creaturesCombo then creaturesCombo:setVisible(true) end

  -- Always enable creatures combo for all spell types
  if creaturesCombo then creaturesCombo:setEnabled(true) end

  -- Update self cast visibility for spells that support both cast types
  local bothCastTypeSpells = _Helper and _Helper.MagicShooter and _Helper.MagicShooter.getBothCastTypeSpells and
      _Helper.MagicShooter.getBothCastTypeSpells() or {}
  local showSelfCast = table.contains(bothCastTypeSpells, spell.id)
  conditionStates.showSelfCast = showSelfCast
  if not showSelfCast then
    conditionStates.selfCast = false
  end

  -- Show forceOnTarget for spells with aimAtTarget
  conditionStates.showForceOnTarget = spell.aimAtTarget or false
  if not spell.aimAtTarget then
    conditionStates.forceOnTarget = false
  end
  syncConditionWidgets()

  -- Show harmony controls for Monk vocation
  updateHarmonyVisibility(isMonkVocation())

  -- For spender spells (Monk), set minimum harmony threshold to 1
  if spell.spender and isMonkVocation() then
    local harmonyInput = formPanel:recursiveGetChildById('harmonyInput')
    if harmonyInput then
      harmonyInput:setText("1")
    end
  end

  -- Show rangedMonstersRow for specific spells (exana amp res, exeta amp res, exori mas res)
  updateRangedMonstersVisibility(isRangedMonsterSpell(spell.id))

  -- Show extendedArea checkbox for spells that have extendedArea property
  updateExtendedAreaVisibility(spell.extendedArea ~= nil)
  updateExtendedArea2Visibility(spell.extendedArea2 ~= nil)

  -- Enable buttons
  updateFormButtons(true)
end

function magicShooter.selectRune()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  local grabber = getMouseGrabber()
  local helperWindow = getHelperWindow()

  grabber:grabMouse()
  if helperWindow then helperWindow:hide() end
  g_mouse.pushCursor('target')

  grabber.onMouseRelease = function(self, mousePosition, mouseButton)
    magicShooter.onRuneSelected(self, mousePosition, mouseButton)
  end
end

function magicShooter.onRuneSelected(self, mousePosition, mouseButton)
  local grabber = getMouseGrabber()
  local helperWindow = getHelperWindow()

  grabber:ungrabMouse()
  if helperWindow then helperWindow:show() end
  g_mouse.popCursor('target')
  grabber.onMouseRelease = nil

  local rootWidget = g_ui.getRootWidget()
  if not rootWidget then return true end

  local clickedWidget = rootWidget:recursiveGetChildByPos(mousePosition, false)
  if not clickedWidget then return true end

  local itemId = 0
  local item = nil

  if clickedWidget:getClassName() == 'UIItem' and not clickedWidget:isVirtual() then
    item = clickedWidget:getItem()
    if item then
      itemId = item:getId()
    end
  elseif clickedWidget:getClassName() == 'UIGameMap' then
    local tile = clickedWidget:getTile(mousePosition)
    if tile then
      local topUseThing = tile:getTopUseThing()
      if topUseThing then
        itemId = topUseThing:getId()
        item = topUseThing
      end
    end
  end

  if itemId == 0 then
    modules.game_textmessage.displayFailureMessage(tr('No item selected!'))
    return true
  end

  -- Check if it's a rune (also check CustomRuneIds from init.lua)
  local runeSpell = Spells.getRuneSpellByItem(itemId)
  if not runeSpell and CustomRuneIds then
    runeSpell = CustomRuneIds[itemId]
  end
  _Helper.resolveCustomRuneArea(runeSpell)
  if not runeSpell then
    modules.game_textmessage.displayFailureMessage(tr('This item is not a rune!'))
    return true
  end

  -- Update form data
  currentFormData = {
    type = "rune",
    spellId = 0,
    itemId = itemId,
    name = runeSpell.name or ("Rune #" .. itemId),
    words = ""
  }

  -- Update rune button
  local runeButton = formPanel:recursiveGetChildById('runeButton')
  if runeButton then
    runeButton:setImageSource('/images/ui/item')
    local runeItem = runeButton:getChildById('formRuneItem')
    if not runeItem then
      runeItem = g_ui.createWidget('UIItem', runeButton)
      runeItem:setId('formRuneItem')
      runeItem:setSize({ width = 32, height = 32 })
      runeItem:setPhantom(true)
      runeItem:fill('parent')
      runeItem:setVirtual(true)
    end
    runeItem:setItemId(itemId)
    runeButton:setTooltip(string.format("%s %s", currentFormData.name, runeSpell.area and "(Area)" or "(Single)"))
  end

  -- Clear spell button
  local spellButton = formPanel:recursiveGetChildById('spellButton')
  if spellButton then
    local spellItem = spellButton:getChildById('formSpellIcon')
    if spellItem then spellItem:destroy() end
    spellButton:setImageSource('/images/game/actionbar/actionbarslot')
    spellButton:setImageClip('0 0 0 0')
    spellButton:setTooltip("")
    spellButton:setBorderWidth(0)
  end

  -- Update name label
  local nameLabel = formPanel:recursiveGetChildById('itemNameLabel')
  if nameLabel then
    nameLabel:setText(currentFormData.name)
    nameLabel:setColor("$var-text-color")
  end

  -- Show clear button
  local clearButton = formPanel:recursiveGetChildById('clearButton')
  if clearButton then clearButton:setVisible(true) end

  -- Hide mana elements for runes (but keep creatures visible)
  local manaLabel = formPanel:recursiveGetChildById('manaLabel')
  local manaPercentInput = formPanel:recursiveGetChildById('manaPercentInput')

  if manaLabel then manaLabel:setVisible(false) end
  if manaPercentInput then manaPercentInput:setVisible(false) end

  -- Hide health elements for runes
  local healthLabel = formPanel:recursiveGetChildById('healthLabel')
  local healthPercentInput = formPanel:recursiveGetChildById('healthPercentInput')

  if healthLabel then healthLabel:setVisible(false) end
  if healthPercentInput then healthPercentInput:setVisible(false) end

  -- Handle creatures combo for area vs single target runes
  local creaturesCombo = formPanel:recursiveGetChildById('creaturesCombo')
  local creaturesLabel = formPanel:recursiveGetChildById('creaturesLabel')

  -- Make sure creatures elements are visible
  if creaturesLabel then creaturesLabel:setVisible(true) end
  if creaturesCombo then creaturesCombo:setVisible(true) end

  if not runeSpell.area then
    -- Single target rune
    if creaturesCombo then
      creaturesCombo:setCurrentOption("1+")
      creaturesCombo:disable()
    end
  else
    -- Area rune
    if creaturesCombo then creaturesCombo:setEnabled(true) end
  end

  -- Hide self cast and forceOnTarget for runes
  conditionStates.showSelfCast = false
  conditionStates.selfCast = false
  conditionStates.showForceOnTarget = false
  conditionStates.forceOnTarget = false

  -- Hide harmony for runes (only visible for spells)
  updateHarmonyVisibility(false)

  -- Hide rangedMonstersRow for runes (only visible for specific spells)
  updateRangedMonstersVisibility(false)

  -- Hide extendedArea for runes (only visible for spells with extendedArea property)
  updateExtendedAreaVisibility(false)
  updateExtendedArea2Visibility(false)

  syncConditionWidgets()

  -- Enable buttons
  updateFormButtons(true)

  return true
end

-- ============================================================
-- RULES LIST MANAGEMENT
-- ============================================================

function magicShooter.addOrUpdateRule()
  if not formButtonsEnabled then return end
  local profile = getShooterProfile()
  if not profile then return end

  -- Ensure rules array exists
  if not profile.rules then
    profile.rules = {}
  end

  local rule = magicShooter.getFormData()
  if not rule then return end

  if rule.type == "spell" and rule.spellId == 0 then
    modules.game_textmessage.displayFailureMessage(tr('Please select a spell first!'))
    return
  elseif rule.type == "rune" and rule.itemId == 0 then
    modules.game_textmessage.displayFailureMessage(tr('Please select a rune first!'))
    return
  end

  if currentFormData.spellId == 0 and currentFormData.itemId == 0 then
    modules.game_textmessage.displayFailureMessage(tr('Please select a spell or rune first!'))
    return
  end

  local newRuleKey = getRuleKey(rule)

  -- Check for duplicates (same spellId or itemId already in the list)
  for _, existingRule in ipairs(profile.rules) do
    local existingKey = getRuleKey(existingRule)

    -- Skip if we're editing this same rule
    if editingRuleKey and existingKey == editingRuleKey then
      goto continue_dup_check
    end

    -- Check for duplicate
    if existingKey == newRuleKey then
      if rule.type == "spell" then
        modules.game_textmessage.displayFailureMessage(tr('This spell is already in the list!'))
      else
        modules.game_textmessage.displayFailureMessage(tr('This rune is already in the list!'))
      end
      return
    end

    ::continue_dup_check::
  end

  if editingRuleKey then
    -- Update existing rule, preserving enabled state
    for i, r in ipairs(profile.rules) do
      if getRuleKey(r) == editingRuleKey then
        rule.enabled = r.enabled
        profile.rules[i] = rule
        break
      end
    end
  else
    -- Add new rule
    table.insert(profile.rules, rule)
  end

  magicShooter.updateRulesList()

  if editingRuleKey then
    -- Update mode: keep the item selected, just refresh the editing key to the (possibly new) key
    editingRuleKey = newRuleKey
    magicShooter.updateRuleSelection()
  else
    -- Add mode: clear form after adding
    magicShooter.clearForm()
  end

  -- Rebuild cache to apply changes immediately
  if _Helper and _Helper.MagicShooter and _Helper.MagicShooter.rebuildCache then
    _Helper.MagicShooter.rebuildCache()
  end

  saveSettings()
end

function magicShooter.removeRule(ruleKey)
  local profile = getShooterProfile()
  if not profile or not profile.rules then return end

  local ruleName = "this rule"
  for _, r in ipairs(profile.rules) do
    if getRuleKey(r) == ruleKey then
      ruleName = r.name or "this rule"
      break
    end
  end

  _RuleList.confirmRemove(ruleName, function()
    for i, r in ipairs(profile.rules) do
      if getRuleKey(r) == ruleKey then
        table.remove(profile.rules, i)
        break
      end
    end
    magicShooter.updateRulesList()

    if editingRuleKey == ruleKey then
      magicShooter.clearForm()
    end

    if _Helper and _Helper.MagicShooter and _Helper.MagicShooter.rebuildCache then
      _Helper.MagicShooter.rebuildCache()
    end

    saveSettings()
  end)
end

function magicShooter.toggleRuleEnabled(ruleKey, enabled)
  local profile = getShooterProfile()
  if not profile or not profile.rules then return end

  -- Update the rule data
  for _, r in ipairs(profile.rules) do
    if getRuleKey(r) == ruleKey then
      r.enabled = enabled
      break
    end
  end

  -- Update the widget directly without rebuilding the list
  if rulesList then
    local children = rulesList:getChildren()
    for _, child in ipairs(children) do
      if child.ruleKey == ruleKey then
        -- Update background color based on enabled state
        if enabled then
          if child.ruleKey == editingRuleKey then
            child:setBackgroundColor('#3a6a3a88') -- Green for selected
          else
            child:setBackgroundColor('#00000022') -- Default
          end
        else
          child:setBackgroundColor('#6a3a3a88') -- Red for disabled
        end
        break
      end
    end
  end

  saveSettings()

  -- Rebuild cache to apply changes immediately
  if _Helper and _Helper.MagicShooter and _Helper.MagicShooter.rebuildCache then
    _Helper.MagicShooter.rebuildCache()
  end
end

function magicShooter.moveRuleUp(ruleKey)
  local profile = getShooterProfile()
  if not profile or not profile.rules then return end

  for i, r in ipairs(profile.rules) do
    if getRuleKey(r) == ruleKey then
      if _RuleList and _RuleList.swapRule(rulesList, profile.rules, i, -1) then
        if _Helper and _Helper.MagicShooter and _Helper.MagicShooter.rebuildCache then
          _Helper.MagicShooter.rebuildCache()
        end
        saveSettings()
        updateArrowButtonStates()
      end
      break
    end
  end
end

function magicShooter.moveRuleDown(ruleKey)
  local profile = getShooterProfile()
  if not profile or not profile.rules then return end

  for i, r in ipairs(profile.rules) do
    if getRuleKey(r) == ruleKey then
      if _RuleList and _RuleList.swapRule(rulesList, profile.rules, i, 1) then
        if _Helper and _Helper.MagicShooter and _Helper.MagicShooter.rebuildCache then
          _Helper.MagicShooter.rebuildCache()
        end
        saveSettings()
        updateArrowButtonStates()
      end
      break
    end
  end
end

function magicShooter.onRuleClick(ruleKey)
  local profile = getShooterProfile()
  if not profile or not profile.rules then return end

  for i, r in ipairs(profile.rules) do
    local key = getRuleKey(r)
    if key == ruleKey then
      magicShooter.setFormData(r)
      break
    end
  end

  -- Update visual selection in the list
  magicShooter.updateRuleSelection()
end

function magicShooter.updateRuleSelection()
  if not rulesList then return end

  local profile = getShooterProfile()
  if not profile or not profile.rules then return end

  -- Build a map of ruleKey -> rule.enabled for quick lookup
  local ruleEnabledMap = {}
  for _, rule in ipairs(profile.rules) do
    local key = getRuleKey(rule)
    ruleEnabledMap[key] = rule.enabled
  end

  -- Update all rule items to show/hide selection state
  local children = rulesList:getChildren()

  for i, child in ipairs(children) do
    if child.ruleKey then
      local isSelected = (child.ruleKey == editingRuleKey)
      local isEnabled = ruleEnabledMap[child.ruleKey]

      -- Apply correct background based on selection and enabled state
      if isSelected then
        child:setBackgroundColor('#3a6a3a88') -- Green for selected
      elseif not isEnabled then
        child:setBackgroundColor('#6a3a3a88') -- Red for disabled
      else
        child:setBackgroundColor('#00000022') -- Default
      end
    end
  end
end

local function getRuleSummary(rule)
  local parts = {}

  -- C: Creatures count
  local countSuffix = rule.countLowerThan and "-" or "+"
  table.insert(parts, "C:" .. (rule.creatures or 1) .. countSuffix)

  -- M: Mana percent (only for spells, only if > 0)
  if rule.type == "spell" and (rule.manaPercent or 0) > 0 then
    table.insert(parts, "MP:" .. rule.manaPercent .. "%")
  end

  -- HP: Health percent (only if > 0)
  local hp = rule.healthPercent or 0
  if hp > 0 then
    table.insert(parts, "HP:" .. hp .. "%")
  end

  -- H: Harmony threshold (only for spells and Monk vocation, always show).
  -- Dispatch via the module table so tests can stub isMonkVocation.
  if rule.type == "spell" and magicShooter.isMonkVocation() then
    table.insert(parts, "H:" .. (rule.harmonyThreshold or 0))
  end

  -- COF: Cast On Foot indicator
  if rule.selfCast then
    table.insert(parts, "COF")
  end

  -- T: Cast if trapped indicator
  if rule.castIfTrapped then
    table.insert(parts, "T")
  end

  -- E: Extended area indicator
  if rule.extendedArea2 then
    table.insert(parts, "A++")
  elseif rule.extendedArea then
    table.insert(parts, "A+")
  end

  -- F: Force on target indicator
  if rule.forceOnTarget then
    table.insert(parts, "F")
  end

  -- R: Ranged monster names indicator (only for specific spells with
  -- rangedMonsterNames set). Dispatch via the module table so tests can stub.
  if rule.type == "spell" and magicShooter.isRangedMonsterSpell(rule.spellId) and rule.rangedMonsterNames and rule.rangedMonsterNames ~= "" then
    table.insert(parts, "R")
  end

  -- HPMin/HPMax: Creature HP% range (only show each if > 0)
  local hpMin = rule.hpMin or 0
  local hpMax = rule.hpMax or 0
  if hpMin > 0 then
    table.insert(parts, "HPMin:" .. hpMin .. "%")
  end
  if hpMax > 0 then
    table.insert(parts, "HPMax:" .. hpMax .. "%")
  end

  -- D: Extra delay (only if > 0, show in seconds with max 1 decimal)
  local extraDelay = rule.extraDelay or 0
  if extraDelay > 0 then
    local delaySec = extraDelay / 1000
    if delaySec == math.floor(delaySec) then
      table.insert(parts, "D:" .. string.format("%d", delaySec))
    else
      table.insert(parts, "D:" .. string.format("%.1f", delaySec))
    end
  end

  return table.concat(parts, "  ")
end

function magicShooter.updateRulesList()
  if not rulesList then getMagicShooterPanel() end
  if not rulesList then return end

  local profile = getShooterProfile()
  if not profile then return end

  -- Ensure rules array exists
  if not profile.rules then
    profile.rules = {}
  end

  -- Clear existing items
  rulesList:destroyChildren()

  -- Add rule items
  for idx, rule in ipairs(profile.rules) do
    local ruleKey = getRuleKey(rule)

    local ruleWidget = g_ui.createWidget('MagicShooterRuleItem', rulesList)
    ruleWidget.ruleKey = ruleKey

    -- Set type indicator
    local typeIcon = ruleWidget:getChildById('typeIcon')
    if typeIcon then
      if rule.type == "spell" then
        typeIcon:setText("S")
        typeIcon:setColor("#44aaff")
      else
        typeIcon:setText("R")
        typeIcon:setColor("#ff8844")
      end
    end

    -- Set item icon
    local itemIcon = ruleWidget:getChildById('itemIcon')
    if itemIcon then
      if rule.type == "spell" and rule.spellId > 0 then
        local spell = Spells.getSpellDataById(rule.spellId)
        if spell then
          _Helper.setSpellIcon(itemIcon, spell.id)
        end
      elseif rule.type == "rune" and rule.itemId > 0 then
        itemIcon:setImageSource('/images/ui/item')
        local runeItem = g_ui.createWidget('UIItem', itemIcon)
        runeItem:setId('ruleRuneItem')
        runeItem:setSize({ width = 24, height = 24 })
        runeItem:setPhantom(true)
        runeItem:fill('parent')
        runeItem:setVirtual(true)
        runeItem:setItemId(rule.itemId)
      end
    end

    -- Set name (show words for spells, name for runes)
    local nameLabel = ruleWidget:getChildById('ruleName')
    if nameLabel then
      if rule.type == "spell" and rule.words and rule.words ~= "" then
        nameLabel:setText(rule.words)
      else
        nameLabel:setText(rule.name)
      end
    end

    -- Set summary
    local summaryLabel = ruleWidget:getChildById('ruleSummary')
    if summaryLabel then
      summaryLabel:setText(getRuleSummary(rule))
    end

    -- Set enable checkbox and disabled background
    local enableCheck = ruleWidget:getChildById('enableCheck')
    if enableCheck then
      enableCheck:setChecked(rule.enabled)
      enableCheck.onCheckChange = function(widget)
        magicShooter.toggleRuleEnabled(ruleKey, widget:isChecked())
      end
    end

    _RuleList.setupDoubleClickToggle(ruleWidget)

    -- Apply disabled background color if rule is disabled
    if not rule.enabled then
      ruleWidget:setBackgroundColor('#6a3a3a88')
    end

    -- Set move up button
    local moveUpButton = ruleWidget:getChildById('moveUpButton')
    if moveUpButton then
      moveUpButton.onClick = function()
        magicShooter.moveRuleUp(ruleKey)
      end
    end

    -- Set move down button
    local moveDownButton = ruleWidget:getChildById('moveDownButton')
    if moveDownButton then
      moveDownButton.onClick = function()
        magicShooter.moveRuleDown(ruleKey)
      end
    end

    -- Set remove button
    local removeButton = ruleWidget:getChildById('removeButton')
    if removeButton then
      removeButton.onClick = function()
        magicShooter.removeRule(ruleKey)
      end
    end

    -- Click on rule to edit (left click on any area except checkbox/remove)
    -- Capture ruleKey in closure to avoid issues with widget reference
    local capturedRuleKey = ruleKey
    local capturedRuleName = rule.name
    ruleWidget.onMouseRelease = function(widget, mousePos, mouseButton)
      if mouseButton == MouseLeftButton then
        local clickedChild = widget:getChildByPos(mousePos)
        -- If clicked on checkbox or remove button, let them handle it
        if clickedChild then
          local childId = clickedChild:getId()
          if childId == 'enableCheck' or childId == 'removeButton' or childId == 'moveUpButton' or childId == 'moveDownButton' then
            return false
          end
        end
        -- Otherwise, edit the rule (use captured value)
        magicShooter.onRuleClick(capturedRuleKey)
        return true
      elseif mouseButton == MouseRightButton then
        magicShooter.showRuleContextMenu(capturedRuleKey, capturedRuleName, mousePos)
        return true
      end
      return false
    end
  end

  updateArrowButtonStates()

  -- Re-apply selection highlight if a rule is being edited
  magicShooter.updateRuleSelection()
end

function magicShooter.showRuleContextMenu(ruleKey, ruleName, position)
  local menu = g_ui.createWidget('PopupMenu')

  menu:addOption(tr('Edit'), function()
    magicShooter.onRuleClick(ruleKey)
  end)

  menu:addSeparator()

  menu:addOption(tr('Move Up'), function()
    magicShooter.moveRuleUp(ruleKey)
  end)

  menu:addOption(tr('Move Down'), function()
    magicShooter.moveRuleDown(ruleKey)
  end)

  menu:addSeparator()

  menu:addOption(tr('Delete'), function()
    magicShooter.removeRule(ruleKey)
  end)

  menu:display(position)
end

-- Setup numeric input validation for HP% Min (0-100)
function magicShooter.setupHpMinInput()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end
  if _Helper and _Helper.setupNumericInput then
    _Helper.setupNumericInput(formPanel:recursiveGetChildById('hpMinInput'), 0, 100)
  end
end

-- Setup numeric input validation for HP% Max (0-100)
function magicShooter.setupHpMaxInput()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end
  if _Helper and _Helper.setupNumericInput then
    _Helper.setupNumericInput(formPanel:recursiveGetChildById('hpMaxInput'), 0, 100)
  end
end

-- Setup numeric input validation for mana percent (0-100)
function magicShooter.setupManaPercentInput()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end
  if _Helper and _Helper.setupNumericInput then
    _Helper.setupNumericInput(formPanel:recursiveGetChildById('manaPercentInput'), 0, 100)
  end
end

-- Setup numeric input validation for health percent (0-100)
function magicShooter.setupHealthPercentInput()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end
  if _Helper and _Helper.setupNumericInput then
    _Helper.setupNumericInput(formPanel:recursiveGetChildById('healthPercentInput'), 0, 100)
  end
end

-- Setup numeric input validation for delay (0+, in ms)
function magicShooter.setupDelayInput()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end
  if _Helper and _Helper.setupNumericInput then
    _Helper.setupNumericInput(formPanel:recursiveGetChildById('delayInput'), 0, 99999)
  end
end

-- Setup numeric input validation for harmony (0-5, or 1-5 for spender spells)
function magicShooter.setupHarmonyInput()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  local input = formPanel:recursiveGetChildById('harmonyInput')
  if input and _Helper and _Helper.setupNumericInput then
    _Helper.setupNumericInput(input, 0, 5)

    -- Override onFocusChange: for spender spells (Monk), minimum harmony is 1
    local isUpdating = false
    input.onFocusChange = function(w, focused)
      if not focused then
        if isUpdating then return end
        isUpdating = true
        local value = tonumber(w:getText()) or 0
        if value < 1 and currentFormData.type == "spell" and currentFormData.spellId > 0 then
          local spell = Spells.getSpellDataById(currentFormData.spellId)
          if spell and spell.spender then
            w:setText("1")
          end
        end
        isUpdating = false
      end
    end
  end
end

-- ============================================================
-- CONDITION SETTINGS MODAL
-- ============================================================

function magicShooter.openConditionSettings()
  if not formButtonsEnabled then return end
  if conditionSettingsWindow then
    conditionSettingsWindow:destroy()
    conditionSettingsWindow = nil
  end

  conditionSettingsWindow = g_ui.createWidget('ConditionSettingsWindow', g_ui.getRootWidget())

  -- Checkboxes are inside checkboxPanel with verticalBox layout.
  -- Destroy non-applicable ones; the layout automatically stacks the rest without gaps.
  local checkboxPanel = conditionSettingsWindow:getChildById('checkboxPanel')
  if checkboxPanel then
    local checkboxDefs = {
      { id = 'castIfTrappedCheck',  wrapperId = 'castIfTrappedRow',  show = true,                              checked = conditionStates.castIfTrapped,  stateKey = 'castIfTrapped' },
      { id = 'countLowerThanCheck', wrapperId = 'countLowerThanRow', show = true,                              checked = conditionStates.countLowerThan, stateKey = 'countLowerThan' },
      { id = 'selfCastCheck',       wrapperId = 'selfCastRow',       show = conditionStates.showSelfCast,      checked = conditionStates.selfCast,       stateKey = 'selfCast' },
      { id = 'extendedAreaCheck',   wrapperId = 'extendedAreaRow',   show = conditionStates.showExtendedArea,  checked = conditionStates.extendedArea,   stateKey = 'extendedArea' },
      { id = 'extendedArea2Check',  wrapperId = 'extendedArea2Row',  show = conditionStates.showExtendedArea2, checked = conditionStates.extendedArea2,  stateKey = 'extendedArea2' },
      { id = 'forceOnTargetCheck',  wrapperId = 'forceOnTargetRow',  show = conditionStates.showForceOnTarget, checked = conditionStates.forceOnTarget,  stateKey = 'forceOnTarget' },
    }

    for _, def in ipairs(checkboxDefs) do
      local widget = checkboxPanel:recursiveGetChildById(def.id)
      local destroyTarget = checkboxPanel:getChildById(def.wrapperId)
      if widget then
        if not def.show then
          if destroyTarget then destroyTarget:destroy() end
        else
          widget:setChecked(def.checked)
          widget.onCheckChange = function(w) conditionStates[def.stateKey] = w:isChecked() end
        end
      end
    end
  end

  -- Sync button text with Add/Update mode
  local saveBtn = conditionSettingsWindow:getChildById('saveConditionButton')
  if saveBtn then
    saveBtn:setText(editingRuleKey and "Update" or "Save")
  end
end

function magicShooter.saveConditionSettings()
  magicShooter.addOrUpdateRule()
  magicShooter.closeConditionSettings()
end

function magicShooter.closeConditionSettings()
  if conditionSettingsWindow then
    conditionSettingsWindow:destroy()
    conditionSettingsWindow = nil
  end
end

-- ============================================================
-- PRESETS MANAGEMENT (delegated to preset_manager)
-- ============================================================

function magicShooter.loadProfileOptions()
  local pm = modules.game_helper and modules.game_helper.presetManager
  if pm then
    local ctx = pm.getShooterContext()
    if ctx then
      ctx.presetsPanel = presetsPanel
      pm.loadProfileOptions(ctx)
    end
  end
end

-- ============================================================
-- INITIALIZATION & CONFIG
-- ============================================================

function magicShooter.init(helperWindow)
  helper = helperWindow

  if helper and helper.contentPanel then
    local container = helper.contentPanel:getChildById('shooterPanel')
    if container then
      magicShooterPanel = container:recursiveGetChildById('magicShooterPanel')
      if magicShooterPanel then
        formPanel = magicShooterPanel:recursiveGetChildById('configFormPanel')
        rulesList = magicShooterPanel:recursiveGetChildById('rulesList')
        presetsPanel = magicShooterPanel:recursiveGetChildById('presetsSection')
      end
    end
  end

  -- Wire preset callbacks via shared preset manager
  local pm = modules.game_helper and modules.game_helper.presetManager
  if pm and presetsPanel then
    local ctx = pm.buildShooterContext()
    if ctx then
      ctx.presetsPanel = presetsPanel
      pm.setShooterContext(ctx)
      pm.initPresets(ctx)
    end
  end

  magicShooter.setupEventHandlers()
end

function magicShooter.setupEventHandlers()
  if not formPanel then getMagicShooterPanel() end
  if not formPanel then return end

  -- Spell button click
  local spellButton = formPanel:recursiveGetChildById('spellButton')
  if spellButton then
    spellButton.onClick = function()
      magicShooter.selectSpell()
    end
  end

  -- Rune button click
  local runeButton = formPanel:recursiveGetChildById('runeButton')
  if runeButton then
    runeButton.onClick = function()
      magicShooter.selectRune()
    end
  end

  -- Setup numeric input validation
  magicShooter.setupHpMinInput()
  magicShooter.setupHpMaxInput()
  magicShooter.setupManaPercentInput()
  magicShooter.setupHealthPercentInput()
  magicShooter.setupDelayInput()
  magicShooter.setupHarmonyInput()

  -- Add button (in rulesListPanel, not configFormPanel)
  local addButton = magicShooterPanel:recursiveGetChildById('addButton')
  if addButton then
    addButton.onClick = function()
      magicShooter.addOrUpdateRule()
    end
  end

  -- Show condition settings button (hidden by default in RulesSection)
  local rulesListPanel = rulesList and rulesList:getParent()
  local condBtn = rulesListPanel and rulesListPanel:getChildById('conditionSettingsButton')
  if condBtn then
    condBtn:setVisible(true)
    condBtn:setTooltip(tr('Condition Settings'))
    condBtn.onClick = function()
      magicShooter.openConditionSettings()
    end
  end

  -- Clear button (in configFormPanel)
  local clearButton = formPanel:recursiveGetChildById('clearButton')
  if clearButton then
    clearButton.onClick = function()
      magicShooter.clearForm()
    end
  end

  -- Ignore Monster List - Apply button
  local applyIgnoreButton = magicShooterPanel:recursiveGetChildById('applyIgnoreButton')
  if applyIgnoreButton then
    applyIgnoreButton.onClick = function()
      magicShooter.applyIgnoreMonsterList()
    end
  end

  -- Ignore Monster List - Text change handler
  local ignoreMonsterInput = magicShooterPanel:recursiveGetChildById('ignoreMonsterInput')
  if ignoreMonsterInput then
    ignoreMonsterInput.onTextChange = function(widget, text)
      updateApplyIgnoreButtonState()
    end
  end

  -- Priority Monster List - Text change handler
  local priorityMonsterInput = magicShooterPanel:recursiveGetChildById('priorityMonsterInput')
  if priorityMonsterInput then
    priorityMonsterInput.onTextChange = function(widget, text)
      updateApplyPriorityButtonState()
    end
  end

  -- Load saved values on init
  magicShooter.loadIgnoreMonsterList()
  magicShooter.loadPriorityMonsterList()

  -- Disable form buttons until a spell/rune is selected
  updateFormButtons(false)
end

function magicShooter.terminate()
  if conditionSettingsWindow then
    conditionSettingsWindow:destroy()
    conditionSettingsWindow = nil
  end
  magicShooterPanel = nil
  formPanel = nil
  rulesList = nil
  presetsPanel = nil
  helper = nil
end

function magicShooter.getPanel()
  return magicShooterPanel
end

-- Load saved configuration
function magicShooter.loadConfig(savedProfile)
  if not savedProfile then return end

  -- New format: rules array - no need to manage IDs, we use spellId/itemId as unique keys
  if savedProfile.rules then
    -- Nothing special needed, spellId and itemId are inherently unique

    -- Old format: spells and runes arrays - migrate to new format
  elseif savedProfile.spells or savedProfile.runes then
    savedProfile.rules = {}

    -- Migrate spells
    if savedProfile.spells then
      for _, spell in ipairs(savedProfile.spells) do
        if spell.id and spell.id > 0 then
          local rule = {
            type = "spell",
            spellId = spell.id,
            itemId = 0,
            name = spell.name or "",
            words = "",
            manaPercent = spell.percent or 0,
            creatures = spell.creatures or 1,
            selfCast = spell.selfCast or false,
            enabled = true
          }
          table.insert(savedProfile.rules, rule)
        end
      end
    end

    -- Migrate runes
    if savedProfile.runes then
      for _, rune in ipairs(savedProfile.runes) do
        if rune.id and rune.id > 0 then
          local rule = {
            type = "rune",
            spellId = 0,
            itemId = rune.id,
            name = "",
            words = "",
            manaPercent = 0,
            creatures = rune.creatures or 1,
            selfCast = false,
            enabled = true
          }

          -- Get rune name
          local runeSpell = Spells.getRuneSpellByItem(rune.id)
          if not runeSpell and CustomRuneIds then runeSpell = CustomRuneIds[rune.id] end
          _Helper.resolveCustomRuneArea(runeSpell)
          if runeSpell then
            rule.name = runeSpell.name
          end

          table.insert(savedProfile.rules, rule)
        end
      end
    end

    -- Clear old format
    savedProfile.spells = nil
    savedProfile.runes = nil
  end

  magicShooter.updateRulesList()
end

function magicShooter.updateUI()
  magicShooter.loadProfileOptions()
  magicShooter.updateRulesList()
  magicShooter.loadIgnoreMonsterList()
end

-- ============================================================
-- IGNORE MONSTER LIST
-- ============================================================

-- Remove numbers from text (only letters, spaces and commas allowed)
local function sanitizeIgnoreList(text)
  if not text then return "" end
  -- Remove any digits from the text
  local sanitized = text:gsub("%d", "")
  return sanitized
end

-- Apply the ignore monster list (called when clicking Apply button)
function magicShooter.applyIgnoreMonsterList()
  if not magicShooterPanel then getMagicShooterPanel() end
  if not magicShooterPanel then return end

  local ignoreMonsterInput = magicShooterPanel:recursiveGetChildById('ignoreMonsterInput')
  if not ignoreMonsterInput then return end

  local text = ignoreMonsterInput:getText() or ""

  -- Remove numbers from input
  local sanitizedText = sanitizeIgnoreList(text)

  -- Update the input field with sanitized text (without numbers)
  if sanitizedText ~= text then
    ignoreMonsterInput:setText(sanitizedText)
    modules.game_textmessage.displayGameMessage("Numbers removed from ignore list.")
  end

  -- Save the sanitized list
  magicShooter.saveIgnoreMonsterList(sanitizedText)

  -- Update the saved text tracker and disable button
  savedIgnoreMonsterListText = sanitizedText
  updateApplyIgnoreButtonState()

  -- Check if current target is in the ignore list and cancel attack if so
  local currentTarget = g_game.getAttackingCreature()
  if currentTarget then
    local targetName = currentTarget:getName()
    if targetName then
      local ignoreTable = magicShooter.getIgnoreMonsterTable()
      if ignoreTable[targetName:lower()] then
        g_game.cancelAttack()
        -- Reset locked target in helperConfig
        local helperConfig = _Helper and _Helper.getHelperConfig and _Helper.getHelperConfig()
        if helperConfig then
          helperConfig.currentLockedTargetId = 0
        end
        modules.game_textmessage.displayGameMessage("Ignore monster list applied. Stopped attacking " ..
          targetName .. ".")
        return
      end
    end
  end

  modules.game_textmessage.displayGameMessage("Ignore monster list applied.")
end

-- Save the ignore monster list to helperConfig (global, not per-profile)
function magicShooter.saveIgnoreMonsterList(text)
  local helperConfig = _Helper and _Helper.getHelperConfig and _Helper.getHelperConfig()
  if not helperConfig then return end

  helperConfig.ignoreMonsterList = text or ""
  saveSettings()
end

-- Load the ignore monster list from helperConfig
function magicShooter.loadIgnoreMonsterList()
  if not magicShooterPanel then getMagicShooterPanel() end
  if not magicShooterPanel then return end

  local ignoreMonsterInput = magicShooterPanel:recursiveGetChildById('ignoreMonsterInput')
  if not ignoreMonsterInput then return end

  local helperConfig = _Helper and _Helper.getHelperConfig and _Helper.getHelperConfig()
  local loadedText = ""
  if helperConfig and helperConfig.ignoreMonsterList then
    loadedText = helperConfig.ignoreMonsterList
    ignoreMonsterInput:setText(loadedText)
  end

  -- Track the saved value and disable button initially
  savedIgnoreMonsterListText = loadedText
  updateApplyIgnoreButtonState()
end

-- Pure parser: comma-separated text -> set of lowercase monster names.
-- Empty entries and digit-only entries are dropped.
function magicShooter.parseIgnoreMonsterList(text)
  local ignoreTable = {}
  if not text or text == "" then return ignoreTable end

  for monsterName in string.gmatch(text, "([^,]+)") do
    -- Trim whitespace and convert to lowercase
    monsterName = monsterName:match("^%s*(.-)%s*$"):lower()
    -- Skip if empty or contains only numbers
    if monsterName ~= "" and not monsterName:match("^%d+$") then
      ignoreTable[monsterName] = true
    end
  end

  return ignoreTable
end

-- Reads the persisted ignore list from helperConfig and parses it.
function magicShooter.getIgnoreMonsterTable()
  local helperConfig = _Helper and _Helper.getHelperConfig and _Helper.getHelperConfig()
  if not helperConfig or not helperConfig.ignoreMonsterList then
    return {}
  end
  return magicShooter.parseIgnoreMonsterList(helperConfig.ignoreMonsterList)
end

-- Load the priority monster list from helperConfig
function magicShooter.loadPriorityMonsterList()
  if not magicShooterPanel then getMagicShooterPanel() end
  if not magicShooterPanel then return end

  local priorityMonsterInput = magicShooterPanel:recursiveGetChildById('priorityMonsterInput')
  if not priorityMonsterInput then return end

  local helperConfig = _Helper and _Helper.getHelperConfig and _Helper.getHelperConfig()
  local loadedText = ""
  if helperConfig and helperConfig.priorityMonsterList then
    loadedText = helperConfig.priorityMonsterList
    priorityMonsterInput:setText(loadedText)
  end

  -- Track the saved value and disable button initially
  savedPriorityMonsterListText = loadedText
  updateApplyPriorityButtonState()
end

-- Expose pure helpers for tests (and any external caller that needs them).
magicShooter.numberToOrdinal      = numberToOrdinal
magicShooter.getRuleKey           = getRuleKey
magicShooter.isMonkVocation       = isMonkVocation
magicShooter.isRangedMonsterSpell = isRangedMonsterSpell
magicShooter.sanitizeIgnoreList   = sanitizeIgnoreList
magicShooter.getRuleSummary       = getRuleSummary

return magicShooter
