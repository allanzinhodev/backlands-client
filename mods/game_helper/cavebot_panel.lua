local cavebot = {}

modules.game_helper = modules.game_helper or {}
modules.game_helper.cavebot = cavebot

local cavebotPanel = nil
-- Helper window reference from init
local helperWindow = nil

local listPanel = nil
local waypointList = nil
local waypoints = {}
local mapTexts = {}
local walkEvent = nil

local oldUse = nil
local oldUseWith = nil
local function clearMapTexts()
  if g_map then
    for _, text in ipairs(mapTexts) do
      pcall(function()
        g_map.removeThing(text)
      end)
    end
  end
  mapTexts = {}
end

local function addMapText(pos, label)
  -- Astra's 8.60 client can fatal in C++ when StaticText is pushed through
  -- g_map.addThing. The minimap marker path remains supported and safe.
end

local function tileHasFloorChange(tile)
  return tile and tile.hasFloorChange and tile:hasFloorChange()
end

-- Forward declaration para doClearWaypoints (definida mais abaixo)
local doClearWaypoints

-- ============================================================================
-- WAYPOINT_TYPE - Enum para tipos de waypoint (evita strings hardcoded)
-- ============================================================================
local WAYPOINT_TYPE = {
  NODE = "Node",     -- Waypoint de passagem (usa nodeDistance)
  STAND = "Stand",   -- Waypoint exato (precisa estar no sqm)
  WALK = "Walk",     -- Waypoint de caminhada simples
  USE = "Use",       -- Usar item/objeto no tile
  ROPE = "Rope",     -- Usar rope no tile
  SHOVEL = "Shovel", -- Usar shovel no tile
}

-- Mapeamento de tipo para iconId (usado no minimap)
local WAYPOINT_ICON = {
  [WAYPOINT_TYPE.WALK] = 11,
  [WAYPOINT_TYPE.NODE] = 11,
  [WAYPOINT_TYPE.STAND] = 12,
  [WAYPOINT_TYPE.USE] = 14,
  [WAYPOINT_TYPE.ROPE] = 15,
  [WAYPOINT_TYPE.SHOVEL] = 16,
}


-- ============================================================================
-- MACHINE_STATE - Estado centralizado do Cavebot (inspirado no ZeroBot)
-- ============================================================================
local MACHINE_STATE = {
  isRunning = false, -- Bot ligado/desligado
  currentIndex = 1,  -- Índice do waypoint atual

  -- Controle de Pausa
  pausedByMonsters = false, -- Pausado por limite de monstros (killing box)

  -- Detecção de Stuck/Freeze
  lastFreeze = 0,     -- Timestamp quando ficou parado
  lastMove = 0,       -- Timestamp do último movimento real
  lastPosition = nil, -- Última posição conhecida
  isStuck = false,    -- Flag de stuck ativo

  -- Configurações de Timeout
  stuckMaxTime = 15,  -- Segundos máximo parado antes de skip
  freezeMaxTime = 30, -- Segundos máximo freeze antes de reset

  -- Contadores de Tentativas
  walkAttempts = {
    pathfind = 0, -- Tentativas de pathfinding
    autoWalk = 0, -- Tentativas de autoWalk
  },

  -- Status para HUD
  lastStatus = "Idle",

  -- Controle de ações que precisam de delay (Use/Rope/Shovel/mudança de floor)
  actionWaitUntil = 0, -- os.clock() até quando deve esperar

  -- Controle de timeout para wait lure
  lureWaitStart = 0,   -- Timestamp quando começou a esperar monstros
  lureWaitMaxTime = 2, -- Segundos máximo esperando monstros (2s)
}

-- ============================================================================
-- MACHINE_TIMERS - Controle de tempos para delay dinâmico
-- ============================================================================
local MACHINE_TIMERS = {
  lastWalk = 0,                -- Timestamp (os.clock) do último passo
  lastWalkPos = nil,           -- Posição quando o último passo foi enviado
  serverConfirmedWalk = false, -- Flag setada pelo onPositionChange quando servidor confirma movimento
  walkInterval = 50,           -- Intervalo base do walker (ms)

  -- Delay dinâmico calculado
  currentDelay = 0, -- Delay atual em ms
  baseDelay = 50,   -- Delay base mínimo
  maxDelay = 500,   -- Delay máximo
}

-- ============================================================================
-- MACHINE_UTILS - Utilidades e dados em tempo real
-- ============================================================================
local MACHINE_UTILS = {
  monsterCount = 0,   -- Contagem atual de monstros
  monsters = {},      -- Lista de monstros detectados
  lifePercentage = 0, -- Vida média dos monstros (%)

  -- Cache de ping
  lastPing = 50,      -- Último ping conhecido
  pingUpdateTime = 0, -- Quando atualizou o ping
}

-- Funções auxiliares (definidas após a tabela para poder referenciá-la)
function MACHINE_UTILS.getPing()
  local now = os.time()
  -- Atualiza ping a cada 2 segundos
  if now - MACHINE_UTILS.pingUpdateTime >= 2 then
    MACHINE_UTILS.pingUpdateTime = now
    if g_game and g_game.getPing then
      local ping = g_game.getPing()
      if ping and ping > 0 then
        MACHINE_UTILS.lastPing = ping
      end
    end
  end
  return MACHINE_UTILS.lastPing
end

-- Minimap icon constants
local cavebotMap = nil
local editingIndex = nil
local currentTab = 'waypoints'
local sessionList = {}
local defaultConfig = {
  monsterLimit = 2,
  resumeLimit = 0,
  minMonstersToWait = 2,
  avoidTrap = 4,
  walkMethod = 'Map Click',
  walkDelay = 0,
  recordType = WAYPOINT_TYPE.NODE,
  recordDist = 3,
  nodeDistance = 1
}
local settingsWindow = nil
local recordingEvent = nil
local lastRecordPos = nil
local currentDirection = 'dirC'
local directionOffsets = {
  dirNW = { x = -1, y = -1 },
  dirN  = { x = 0, y = -1 },
  dirNE = { x = 1, y = -1 },
  dirW  = { x = -1, y = 0 },
  dirC  = { x = 0, y = 0 },
  dirE  = { x = 1, y = 0 },
  dirSW = { x = -1, y = 1 },
  dirS  = { x = 0, y = 1 },
  dirSE = { x = 1, y = 1 }
}
local ropes = { 3003, 646, 9594, 9596, 9598 }
local shovels = { 3457, 5710, 9594, 9596, 9598 }
local cavebotMarkerWidgets = {}
local selectedCavebotMarkerIndex = nil
local draggingCavebotMarkerIndex = nil

local function getCavebotMinimap()
  if cavebotMap and (not cavebotMap.isDestroyed or not cavebotMap:isDestroyed()) and cavebotMap.addWidget then
    return cavebotMap
  end
  if minimapWidget and minimapWidget.addWidget then
    return minimapWidget
  end
  return nil
end

local function getCavebotMarkerWidget(entry)
  if not entry or not entry.map or not entry.id then
    return nil
  end
  return entry.map._minimapWidgets and entry.map._minimapWidgets[entry.id] or nil
end

local function updateCavebotMarkerState(index)
  local entry = cavebotMarkerWidgets[index]
  local widget = getCavebotMarkerWidget(entry)
  if not widget or not widget.setImageColor then
    return
  end

  if index == draggingCavebotMarkerIndex then
    widget:setImageColor('#ff7777ff')
  elseif index == selectedCavebotMarkerIndex then
    widget:setImageColor('#ffff66ff')
  else
    widget:setImageColor('#ffffffff')
  end
end

local function updateAllCavebotMarkerStates()
  for index in pairs(cavebotMarkerWidgets) do
    updateCavebotMarkerState(index)
  end
end

local function addCavebotMarker(pos, iconId, tooltip)
  local map = getCavebotMinimap()
  if not map or not map.addWidget or not pos then
    return nil
  end

  local markerIndex = #cavebotMarkerWidgets + 1
  local icon = tonumber(iconId) or WAYPOINT_ICON[WAYPOINT_TYPE.WALK]
  local widgetId = map:addWidget('/data/images/game/minimap/flag' .. icon .. '.png', { width = 11, height = 11 },
    { x = pos.x, y = pos.y, z = pos.z }, tooltip or ('Waypoint ' .. markerIndex))
  cavebotMarkerWidgets[markerIndex] = { map = map, id = widgetId }

  local widget = getCavebotMarkerWidget(cavebotMarkerWidgets[markerIndex])
  if widget then
    if widget.setPhantom then
      widget:setPhantom(true)
    end
    if widget.setTooltip then
      widget:setTooltip(tooltip or ('Waypoint ' .. markerIndex))
    end
  end

  updateCavebotMarkerState(markerIndex)
  return widgetId
end

local function clearCavebotMarkers()
  for _, entry in pairs(cavebotMarkerWidgets) do
    if entry.map and entry.map.removeWidget and entry.id then
      entry.map:removeWidget(entry.id)
    end
  end
  cavebotMarkerWidgets = {}
  selectedCavebotMarkerIndex = nil
  draggingCavebotMarkerIndex = nil
end

local function setCavebotMarkerPosition(index, pos)
  local markerIndex = (tonumber(index) or -1) + 1
  local entry = cavebotMarkerWidgets[markerIndex]
  if entry and entry.map and entry.map.moveWidget and pos then
    entry.map:moveWidget(entry.id, { x = pos.x, y = pos.y, z = pos.z })
  end
end

local function setSelectedCavebotMarker(index)
  local markerIndex = tonumber(index)
  selectedCavebotMarkerIndex = markerIndex and markerIndex >= 0 and markerIndex + 1 or nil
  updateAllCavebotMarkerStates()
end

local function setDraggingCavebotMarker(index)
  local markerIndex = tonumber(index)
  draggingCavebotMarkerIndex = markerIndex and markerIndex >= 0 and markerIndex + 1 or nil
  updateAllCavebotMarkerStates()
end

if g_minimap then
  g_minimap.addCavebotMarker = g_minimap.addCavebotMarker or addCavebotMarker
  g_minimap.clearCavebotMarkers = g_minimap.clearCavebotMarkers or clearCavebotMarkers
  g_minimap.setCavebotMarkerPosition = g_minimap.setCavebotMarkerPosition or setCavebotMarkerPosition
  g_minimap.setSelectedCavebotMarker = g_minimap.setSelectedCavebotMarker or setSelectedCavebotMarker
  g_minimap.setDraggingCavebotMarker = g_minimap.setDraggingCavebotMarker or setDraggingCavebotMarker
end

-- Lookup table para offsets de direção (substitui cadeia de if/elseif)
local DIR_OFFSETS = {
  [North]     = { x = 0, y = -1 },
  [East]      = { x = 1, y = 0 },
  [South]     = { x = 0, y = 1 },
  [West]      = { x = -1, y = 0 },
  [NorthEast] = { x = 1, y = -1 },
  [SouthEast] = { x = 1, y = 1 },
  [SouthWest] = { x = -1, y = 1 },
  [NorthWest] = { x = -1, y = -1 },
}

-- Aplica um offset de direção a uma posição e retorna a nova posição
function cavebot.applyDirection(pos, dir)
  local off = DIR_OFFSETS[dir]
  if not off then return pos end
  return { x = pos.x + off.x, y = pos.y + off.y, z = pos.z }
end

-- Verifica se um tile tem criaturas bloqueando (ignora local player e mortos)
function cavebot.hasCreatureBlocking(pos)
  local tile = g_map.getTile(pos)
  if not tile then return false end
  local creatures = tile:getCreatures()
  if not creatures then return false end
  for _, c in ipairs(creatures) do
    if c and not c:isLocalPlayer() and not c:isDead() then
      return true
    end
  end
  return false
end

-- UI Widgets
local ui = {}

-- Public state accessors. Other scripts (and the test suite) inspect cavebot
-- state via these instead of reaching into file-local variables.
function cavebot.getWaypoints() return waypoints end

function cavebot.getEditingIndex() return editingIndex end

function cavebot.init(helper)
  -- Grab UI references
  helperWindow = helper
  local rootWidget = g_ui.getRootWidget()
  if rootWidget then
    local helperWindow = rootWidget:recursiveGetChildById('helperWindow')
    if helperWindow then
      cavebotPanel = helperWindow:recursiveGetChildById('cavebotPanel')
      if cavebotPanel then
        -- Map
        cavebotMap = cavebotPanel:recursiveGetChildById('cavebotMap')
        if cavebotMap then
          local player = g_game.getLocalPlayer()
          if player and player:getPosition() then
            cavebotMap:setCameraPosition(player:getPosition())
            cavebotMap:setCrossPosition(player:getPosition())
          end

          cavebotMap.onMouseRelease = function(widget, mousePos, mouseButton)
            return cavebot.onMapClick(widget, mousePos, mouseButton)
          end

          -- Drag handlers: only drag the currently selected (editingIndex) waypoint
          cavebotMap.onDragEnter = function(widget, pos)
            if editingIndex and waypoints[editingIndex] then
              local tilePos = widget:getTilePosition(pos)
              if tilePos then
                local wp = waypoints[editingIndex]
                if wp.x == tilePos.x and wp.y == tilePos.y and wp.z == tilePos.z then
                  widget.draggingWpIndex = editingIndex
                  widget.draggingWpOrigPos = { x = wp.x, y = wp.y, z = wp.z }
                  -- Red highlight during drag
                  g_minimap.setDraggingCavebotMarker(editingIndex - 1)
                  return true
                end
              end
            end
            -- No selected waypoint hit: default map pan
            widget.draggingWpIndex = nil
            return UIMinimap.onDragEnter(widget, pos)
          end

          cavebotMap.onDragMove = function(widget, pos, moved)
            if widget.draggingWpIndex then
              local tilePos = widget:getTilePosition(pos)
              if tilePos then
                g_minimap.setCavebotMarkerPosition(widget.draggingWpIndex - 1, tilePos)
              end
              return true
            end
            return UIMinimap.onDragMove(widget, pos, moved)
          end

          cavebotMap.onDragLeave = function(widget, droppedWidget, pos)
            if widget.draggingWpIndex then
              local idx = widget.draggingWpIndex
              local tilePos = widget:getTilePosition(pos)
              if tilePos and idx >= 1 and idx <= #waypoints then
                waypoints[idx].x = tilePos.x
                waypoints[idx].y = tilePos.y
                waypoints[idx].z = tilePos.z
              else
                -- Revert to original position
                local orig = widget.draggingWpOrigPos
                if orig and idx >= 1 and idx <= #waypoints then
                  waypoints[idx].x = orig.x
                  waypoints[idx].y = orig.y
                  waypoints[idx].z = orig.z
                end
              end
              widget.draggingWpIndex = nil
              widget.draggingWpOrigPos = nil
              -- Clear red dragging highlight
              g_minimap.setDraggingCavebotMarker(-1)
              -- Rebuild markers and scroll to the edited waypoint
              cavebot.removeAllFlags()
              cavebot.addAllFlags()
              cavebot.refreshList()
              cavebot.scrollToWaypoint(idx)
              return true
            end
            return UIMinimap.onDragLeave(widget, droppedWidget, pos)
          end
        end

        -- Widgets lookup
        ui.waypointList = cavebotPanel:recursiveGetChildById('waypointList')
        ui.waypointsContent = cavebotPanel:recursiveGetChildById('waypointsContent')
        ui.configContent = cavebotPanel:recursiveGetChildById('configContent')
        ui.stopLimit = cavebotPanel:recursiveGetChildById('stopLimit')
        ui.resumeLimit = cavebotPanel:recursiveGetChildById('resumeLimit')
        ui.editingLabel = cavebotPanel:recursiveGetChildById('editingLabel')
        ui.sessionsList = cavebotPanel:recursiveGetChildById('sessionsList')
        ui.sessionName = cavebotPanel:recursiveGetChildById('sessionName')
        ui.toggleButton = cavebotPanel:recursiveGetChildById('toggleButton')
        ui.recordButton = cavebotPanel:recursiveGetChildById('recordButton')
        ui.deleteSessionButton = cavebotPanel:recursiveGetChildById('deleteSessionButton')
        ui.saveSessionButton = cavebotPanel:recursiveGetChildById('saveSessionButton')

        -- Disable delete and save buttons by default
        if ui.deleteSessionButton then
          ui.deleteSessionButton:setEnabled(false)
        end
        if ui.saveSessionButton then
          ui.saveSessionButton:setEnabled(false)
        end

        -- Enable save button only when sessionName has 2+ characters AND waypoints > 0
        if ui.sessionName then
          ui.sessionName.onTextChange = function(widget, text)
            if ui.saveSessionButton then
              ui.saveSessionButton:setEnabled(text and #text >= 2 and #waypoints > 0)
            end
          end
          ui.sessionName.onFocusChange = function(widget, focused)
            if focused then
              widget:setCursorPos(-1)
            end
          end
        end

        -- Initialize UI state
        cavebot.loadSessionList()
        cavebot.refreshList()
        cavebot.selectTab('waypoints')

        if ui.toggleButton then
          cavebot.toggle(false)
        end
      end
    end
  end

  if not cavebot.connected then
    connect(LocalPlayer, {
      onPositionChange = function(creature, newPos, oldPos)
        -- Player se moveu: servidor confirmou o passo → libera próximo walk
        if MACHINE_STATE.isRunning and oldPos and newPos then
          MACHINE_STATE.walkAttempts.pathfind = 0
          MACHINE_STATE.walkAttempts.autoWalk = 0
          MACHINE_TIMERS.serverConfirmedWalk = true
        end

        if cavebotMap and not cavebotMap:isDragging() then
          cavebotMap:setCameraPosition(newPos)
          cavebotMap:setCrossPosition(newPos)
        end

        if recordingEvent and oldPos and newPos and oldPos.z ~= newPos.z then
          -- Pula Stand+Node se o último waypoint é Use/Rope/Shovel (a ação já causa a mudança de andar)
          local lastWp = #waypoints > 0 and waypoints[#waypoints] or nil
          local lastIsAction = lastWp and (lastWp.action == WAYPOINT_TYPE.USE
            or lastWp.action == WAYPOINT_TYPE.ROPE
            or lastWp.action == WAYPOINT_TYPE.SHOVEL)
          if not lastIsAction then
            cavebot.addWaypoint(WAYPOINT_TYPE.STAND, oldPos)
          end
          cavebot.addWaypoint(WAYPOINT_TYPE.NODE, newPos)
          lastRecordPos = { x = newPos.x, y = newPos.y, z = newPos.z }
        end
      end
    })
    cavebot.connected = true
  end

  connect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd
  })

  if g_game.isOnline() then
    onGameStart()
  end

  -- Hooking Game Actions for Auto-Recording
  if not oldUse then
    oldUse = g_game.use
    g_game.use = function(thing)
      if not MACHINE_STATE.isRunning and recordingEvent and thing and thing.isItem and thing:isItem() then
        local pos = thing:getPosition()
        if pos and pos.x < 65535 then
          cavebot.addWaypoint(WAYPOINT_TYPE.USE, pos)
          lastRecordPos = { x = pos.x, y = pos.y, z = pos.z }
        end
      end
      return oldUse(thing)
    end
  end

  if not oldUseWith then
    oldUseWith = g_game.useWith
    g_game.useWith = function(item, target)
      if not MACHINE_STATE.isRunning and recordingEvent and item and target then
        local pos = nil
        if target.getPosition then
          pos = target:getPosition()
        elseif target.x then
          pos = target
        end

        if pos and pos.x < 65535 then
          local itemId = item:getId()
          local isRope = false
          for _, id in ipairs(ropes) do
            if id == itemId then
              isRope = true
              break
            end
          end

          local isShovel = false
          for _, id in ipairs(shovels) do
            if id == itemId then
              isShovel = true
              break
            end
          end

          if isRope then
            cavebot.addWaypoint(WAYPOINT_TYPE.ROPE, pos)
            lastRecordPos = { x = pos.x, y = pos.y, z = pos.z }
          elseif isShovel then
            cavebot.addWaypoint(WAYPOINT_TYPE.SHOVEL, pos)
            lastRecordPos = { x = pos.x, y = pos.y, z = pos.z }
          end
        end
      end
      return oldUseWith(item, target)
    end
  end
end

function cavebot.terminate()
  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd
  })

  cavebot.stopWalking()

  if LocalPlayer then
    -- Remove position change listener (handled by closure above, actually hard to disconnect generically)
    -- But module reload usually handles re-init.
  end

  -- Remove cavebot markers nativos do C++
  g_minimap.clearCavebotMarkers()

  -- Clear map texts
  clearMapTexts()

  -- Restore original game functions
  if oldUse then
    g_game.use = oldUse
    oldUse = nil
  end
  if oldUseWith then
    g_game.useWith = oldUseWith
    oldUseWith = nil
  end

  if cavebotPanel then
    cavebotPanel:destroy()
    cavebotPanel = nil
  end
end

function onGameStart()
  local player = g_game.getLocalPlayer()

  if player and cavebotMap then
    local pos = player:getPosition()
    if pos then
      cavebotMap:setCameraPosition(pos)
      cavebotMap:setCrossPosition(pos)
    end
  end
end

function onGameEnd()
  cavebot.stopWalking()
  sessionList = {}
  selectedSession = nil
  if ui.sessionName then ui.sessionName:setText('') end
  if recordingEvent then
    removeEvent(recordingEvent)
    recordingEvent = nil
  end
  if ui.recordButton then
    ui.recordButton:setText(tr('Rec: Off'))
    ui.recordButton:setColor('$var-text-cip-color-white')
    ui.recordButton:setBackgroundColor('#AA3333')
  end
  cavebot.refreshSessionList()
end

function cavebot.findRope()
  for _, container in pairs(g_game.getContainers()) do
    for i, item in ipairs(container:getItems()) do
      for _, id in ipairs(ropes) do
        if item:getId() == id then return item end
      end
    end
  end
  return nil
end

function cavebot.findShovel()
  for _, container in pairs(g_game.getContainers()) do
    for i, item in ipairs(container:getItems()) do
      for _, id in ipairs(shovels) do
        if item:getId() == id then return item end
      end
    end
  end
  return nil
end

function cavebot.stopRecording()
  if recordingEvent then
    removeEvent(recordingEvent)
    recordingEvent = nil
    local btn = ui.recordButton
    if btn then
      btn:setText(tr('Rec: Off'))
      btn:setColor('$var-text-cip-color-white')
      btn:setBackgroundColor('#AA3333')
    end
    modules.game_textmessage.displayStatusMessage(tr('Cavebot recording stopped.'))
    cavebot.updateMinimapProgress()
  end
end

function cavebot.isRecording()
  return recordingEvent ~= nil
end

function cavebot.toggleRecording()
  local btn = ui.recordButton
  if recordingEvent then
    cavebot.stopRecording()
  else
    if btn then
      btn:setText(tr('Rec: On'))
      btn:setColor('$var-text-cip-color-white')
      btn:setBackgroundColor('#33AA33')
    end
    modules.game_textmessage.displayStatusMessage(tr('Cavebot recording started.'))
    cavebot.autoRecord()
  end
end

function cavebot.autoRecord()
  local player = g_game.getLocalPlayer()
  if not player then
    recordingEvent = scheduleEvent(cavebot.autoRecord, 1000)
    return
  end

  local pos = player:getPosition()
  if not pos then
    recordingEvent = scheduleEvent(cavebot.autoRecord, 1000)
    return
  end

  local shouldRecord = false
  local floorChanged = false

  if not lastRecordPos then
    shouldRecord = true
  else
    local dist = math.max(math.abs(pos.x - lastRecordPos.x), math.abs(pos.y - lastRecordPos.y))
    if pos.z ~= lastRecordPos.z then
      local lastWp = #waypoints > 0 and waypoints[#waypoints] or nil
      local lastIsAction = lastWp and (lastWp.action == WAYPOINT_TYPE.USE
        or lastWp.action == WAYPOINT_TYPE.ROPE
        or lastWp.action == WAYPOINT_TYPE.SHOVEL)
      if lastIsAction then
        lastRecordPos = { x = pos.x, y = pos.y, z = pos.z }
      else
        shouldRecord = true
        floorChanged = true
      end
    elseif dist >= (defaultConfig.recordDist or 3) then
      shouldRecord = true
    end
  end

  -- Check against last waypoint in list to avoid duplicates at same spot
  if shouldRecord and #waypoints > 0 then
    local lastWp = waypoints[#waypoints]
    if lastWp.x == pos.x and lastWp.y == pos.y and lastWp.z == pos.z then
      shouldRecord = false
    end
  end

  if shouldRecord then
    lastRecordPos = { x = pos.x, y = pos.y, z = pos.z }
    local waypointType = floorChanged and WAYPOINT_TYPE.STAND or (defaultConfig.recordType or WAYPOINT_TYPE.NODE)

    -- Nunca grava Stand se o waypoint anterior é Use/Rope/Shovel
    if waypointType == WAYPOINT_TYPE.STAND and #waypoints > 0 then
      local lastWp = waypoints[#waypoints]
      if lastWp.action == WAYPOINT_TYPE.USE or lastWp.action == WAYPOINT_TYPE.ROPE or lastWp.action == WAYPOINT_TYPE.SHOVEL then
        waypointType = nil
      end
    end

    if waypointType then
      cavebot.addWaypoint(waypointType, pos)
    end
  end

  -- Define recordingEvent antes de atualizar o minimap
  local isFirstRun = (recordingEvent == nil)
  recordingEvent = scheduleEvent(cavebot.autoRecord, 500)

  -- Atualiza minimap na primeira execução
  if isFirstRun then
    cavebot.updateMinimapProgress()
  end
end

function cavebot.toggleButtonPress()
  cavebot.toggle(not MACHINE_STATE.isRunning)
end

function cavebot.selectTab(tab)
  currentTab = tab

  -- Salva posição do scroll antes de mudar de aba
  local scrollPos = 0
  local scrollBar = cavebotPanel and cavebotPanel:recursiveGetChildById('listScrollbar')
  if scrollBar then
    scrollPos = scrollBar:getValue()
  end

  if ui.waypointsContent then ui.waypointsContent:setVisible(tab == 'waypoints') end
  if ui.configContent then ui.configContent:setVisible(tab == 'config') end

  if tab == 'config' then
    cavebot.updateConfigEditor()
  end

  -- Restaura posição do scroll após mudar de aba
  if tab == 'waypoints' and scrollBar then
    scrollBar:setValue(scrollPos)
  end
end

function cavebot.updateDirection(widget)
  if not widget:isChecked() then
    if currentDirection == widget:getId() then
      widget:setChecked(true)
    end
    return
  end

  currentDirection = widget:getId()
  local parent = widget:getParent()
  local children = parent:getChildren()
  for _, child in pairs(children) do
    if child ~= widget and child:isChecked() then
      child:setChecked(false)
    end
  end
end

-- Atualiza o highlight do waypoint selecionado no C++ (renderização nativa)
function cavebot.updateFlagSelection()
  if editingIndex then
    g_minimap.setSelectedCavebotMarker(editingIndex - 1) -- C++ é 0-indexed
  else
    g_minimap.setSelectedCavebotMarker(-1)
  end
end

function cavebot.addWaypoint(arg1, arg2)
  local player = g_game.getLocalPlayer()
  if not player then return end

  local action = WAYPOINT_TYPE.WALK
  local pos = nil

  if type(arg1) == "string" then
    action = arg1
    pos = arg2
  else
    pos = arg1
  end

  if not pos then
    pos = player:getPosition()
    if not pos then return end
    local offset = directionOffsets[currentDirection]
    if offset then
      pos.x = pos.x + offset.x
      pos.y = pos.y + offset.y
    end
  end

  local iconId = WAYPOINT_ICON[action] or WAYPOINT_ICON[WAYPOINT_TYPE.WALK]

  local waypoint = {
    x = pos.x,
    y = pos.y,
    z = pos.z,
    action = action,
    iconId = iconId,
    monsterLimit = defaultConfig
        .monsterLimit,
    resumeLimit = defaultConfig.resumeLimit
  }
  table.insert(waypoints, waypoint)

  local waypointIndex = #waypoints

  -- Add marker nativo no C++ (renderizado diretamente no draw pool, sem UIWidgets)
  g_minimap.addCavebotMarker(pos, iconId, "Waypoint " .. waypointIndex)

  addMapText(pos, string.format("Waypoint %d", waypointIndex))

  cavebot.refreshList()
end

-- Insere waypoint em posição específica (before/after)
function cavebot.insertWaypoint(action, pos, insertIndex)
  local iconId = WAYPOINT_ICON[action] or WAYPOINT_ICON[WAYPOINT_TYPE.WALK]

  local waypoint = {
    x = pos.x,
    y = pos.y,
    z = pos.z,
    action = action,
    iconId = iconId,
    monsterLimit = defaultConfig.monsterLimit,
    resumeLimit = defaultConfig.resumeLimit
  }
  table.insert(waypoints, insertIndex, waypoint)

  -- Ajusta editingIndex se necessário
  if editingIndex and editingIndex >= insertIndex then
    editingIndex = editingIndex + 1
  end

  -- Rebuild completo (markers + world map texts + lista)
  cavebot.removeAllFlags()
  cavebot.addAllFlags()
  cavebot.refreshList()
  cavebot.selectWaypoint(insertIndex)
end

-- Função interna que realmente limpa os waypoints
function doClearWaypoints()
  -- Desliga o cavebot se estiver ligado
  if MACHINE_STATE.isRunning then
    cavebot.toggle(false)
  end

  -- Desliga o recorder se estiver ligado
  if cavebot.isRecording() then
    cavebot.stopRecording()
  end

  -- Remove cavebot markers nativos do C++
  g_minimap.clearCavebotMarkers()

  -- Remove StaticText do mapa
  clearMapTexts()

  waypoints = {}
  MACHINE_STATE.currentIndex = 1
  editingIndex = nil
  cavebot.refreshList()
end

function cavebot.clearWaypoints()
  -- Se não há waypoints, não faz nada
  if #waypoints == 0 then
    return
  end

  -- Modal de confirmação usando displayGeneralBox
  local messageBox
  local yesCallback = function()
    doClearWaypoints()
    if messageBox then messageBox:destroy() end
  end
  local noCallback = function()
    if messageBox then messageBox:destroy() end
  end

  messageBox = displayGeneralBox(tr('Clear Waypoints'),
    tr('Are you sure you want to clear all waypoints?'),
    {
      { text = tr('Yes'), callback = yesCallback },
      { text = tr('No'),  callback = noCallback },
      anchor = AnchorHorizontalCenter
    },
    yesCallback, noCallback, helperWindow)
end

function cavebot.selectWaypoint(index)
  editingIndex = index
  -- Usa updateListColors() em vez de refreshList() para preservar scroll
  cavebot.updateListColors()
  -- Atualiza borda amarela no flag do minimap
  cavebot.updateFlagSelection()
  -- Centraliza o minimap na posição do waypoint selecionado
  cavebot.centerMapOnWaypoint(index)
  -- Faz scroll da lista até o waypoint selecionado
  cavebot.scrollToWaypoint(index)
  -- If currently on config tab, update editor
  if currentTab == 'config' then
    cavebot.updateConfigEditor()
  end
end

-- Centraliza o minimap do cavebot e o minimap global na posição do waypoint
function cavebot.centerMapOnWaypoint(index)
  if not index or not waypoints[index] then return end

  local wp = waypoints[index]
  local pos = { x = tonumber(wp.x), y = tonumber(wp.y), z = tonumber(wp.z) }

  -- Centraliza o minimap do cavebot
  if cavebotMap and cavebotMap.setCameraPosition then
    cavebotMap:setCameraPosition(pos)
  end

  -- Centraliza o minimap global
  if modules.game_minimap and modules.game_minimap.minimapWidget then
    modules.game_minimap.minimapWidget:setCameraPosition(pos)
  end
end

-- Faz scroll da lista de waypoints até o waypoint especificado
function cavebot.scrollToWaypoint(index)
  if not index or not ui.waypointList then return end

  local scrollBar = cavebotPanel and cavebotPanel:recursiveGetChildById('listScrollbar')
  if not scrollBar then return end

  -- Cada item tem altura de 14 + margem de 2 = 16 pixels
  local itemHeight = 16
  local targetScrollPos = (index - 1) * itemHeight

  -- Obtém a altura visível da lista
  local listHeight = ui.waypointList:getHeight()

  -- Centraliza o item na área visível (coloca no meio da lista)
  local centeredPos = targetScrollPos - (listHeight / 2) + (itemHeight / 2)

  -- Clamp entre 0 e o máximo do scrollbar
  local maxAllowed = math.max(0, scrollBar:getMaximum())
  centeredPos = math.max(0, math.min(centeredPos, maxAllowed))

  -- Define a posição do scroll
  scrollBar:setValue(centeredPos)
end

function cavebot.updateConfigEditor()
  if not editingIndex or not waypoints[editingIndex] then
    if ui.editingLabel then ui.editingLabel:setText(tr("Default Settings")) end
    if ui.stopLimit then
      ui.stopLimit:setEnabled(true)
      ui.stopLimit:setText(tostring(defaultConfig.monsterLimit))
    end
    if ui.resumeLimit then
      ui.resumeLimit:setEnabled(true)
      ui.resumeLimit:setText(tostring(defaultConfig.resumeLimit))
    end
    return
  end

  local wp = waypoints[editingIndex]
  if ui.editingLabel then ui.editingLabel:setText(tr("Editing Waypoint: #") .. editingIndex) end
  if ui.stopLimit then
    ui.stopLimit:setEnabled(true)
    ui.stopLimit:setText(tostring(wp.monsterLimit or 0))
  end
  if ui.resumeLimit then
    ui.resumeLimit:setEnabled(true)
    ui.resumeLimit:setText(tostring(wp.resumeLimit or 0))
  end
end

function cavebot.onSettingChange(key, value)
  local val = tonumber(value) or 0

  -- Global settings (always go to defaultConfig)
  if key == 'walkMethod' then
    defaultConfig[key] = value
    -- Reinicia walker para aplicar novo tick interval
    if MACHINE_STATE.isRunning then
      cavebot.stopWalking()
      cavebot.startWalking()
    end
    return
  end

  if key == 'walkDelay' or key == 'minMonstersToWait' or key == 'avoidTrap' then
    defaultConfig[key] = val
    return
  end

  -- Per-waypoint settings
  if not editingIndex or not waypoints[editingIndex] then
    defaultConfig[key] = val
    return
  end
  waypoints[editingIndex][key] = val
  cavebot.refreshList() -- Logic update
end

function cavebot.onRecordTypeChange(value)
  defaultConfig.recordType = value or WAYPOINT_TYPE.NODE
end

function cavebot.onRecordDistChange(value)
  local val = tonumber(value) or 3
  if val < 1 then val = 1 end
  if val > 8 then val = 8 end
  defaultConfig.recordDist = val
end

function cavebot.onNodeDistanceChange(value)
  local val = tonumber(value) or 1
  if val < 1 then val = 1 end
  if val > 5 then val = 5 end
  defaultConfig.nodeDistance = val
end

function cavebot.openSettings()
  if settingsWindow then
    settingsWindow:destroy()
    settingsWindow = nil
  end

  settingsWindow = g_ui.createWidget('CavebotSettingsWindow', rootWidget)
  if not settingsWindow then
    return
  end

  -- Auto Recorder Settings
  local recorderDistance = settingsWindow:recursiveGetChildById('recorderDistance')
  if recorderDistance then
    recorderDistance:setValue(defaultConfig.recordDist or 3)
    recorderDistance.onValueChange = function(widget, value)
      cavebot.onRecordDistChange(value)
    end
  end

  local typeStand = settingsWindow:recursiveGetChildById('typeStand')
  local typeNode = settingsWindow:recursiveGetChildById('typeNode')

  if typeStand and typeNode then
    -- Set initial state
    if defaultConfig.recordType == WAYPOINT_TYPE.STAND then
      typeStand:setChecked(true)
      typeNode:setChecked(false)
    else
      typeStand:setChecked(false)
      typeNode:setChecked(true)
    end

    -- Radio button behavior - sempre deve ter um selecionado
    typeStand.onCheckChange = function(widget, checked)
      if checked then
        typeNode:setChecked(false)
        cavebot.onRecordTypeChange(WAYPOINT_TYPE.STAND)
      else
        -- Não permite desmarcar se já está marcado (comportamento radio)
        if not typeNode:isChecked() then
          widget:setChecked(true)
        end
      end
    end

    typeNode.onCheckChange = function(widget, checked)
      if checked then
        typeStand:setChecked(false)
        cavebot.onRecordTypeChange(WAYPOINT_TYPE.NODE)
      else
        -- Não permite desmarcar se já está marcado (comportamento radio)
        if not typeStand:isChecked() then
          widget:setChecked(true)
        end
      end
    end
  end

  -- Node Settings
  local nodeDistance = settingsWindow:recursiveGetChildById('nodeDistance')
  if nodeDistance then
    nodeDistance:setValue(defaultConfig.nodeDistance or 1)
    nodeDistance.onValueChange = function(widget, value)
      cavebot.onNodeDistanceChange(value)
    end
  end

  -- Safety Lure Settings
  local minMonstersToWait = settingsWindow:recursiveGetChildById('minMonstersToWait')
  if minMonstersToWait then
    minMonstersToWait:setValue(defaultConfig.minMonstersToWait or 2)
    minMonstersToWait.onValueChange = function(widget, value)
      cavebot.onSettingChange('minMonstersToWait', tostring(value))
    end
  end

  local avoidTrap = settingsWindow:recursiveGetChildById('avoidTrap')
  if avoidTrap then
    avoidTrap:setValue(defaultConfig.avoidTrap or 4)
    avoidTrap.onValueChange = function(widget, value)
      cavebot.onSettingChange('avoidTrap', tostring(value))
    end
  end

  -- Walking Settings
  local walkMapWalk = settingsWindow:recursiveGetChildById('walkMapWalk')
  local walkArrowKeys = settingsWindow:recursiveGetChildById('walkArrowKeys')

  if walkMapWalk and walkArrowKeys then
    -- Set initial state
    if defaultConfig.walkMethod == 'Keyboard' then
      walkMapWalk:setChecked(false)
      walkArrowKeys:setChecked(true)
    else
      walkMapWalk:setChecked(true)
      walkArrowKeys:setChecked(false)
    end

    -- Radio button behavior
    walkMapWalk.onCheckChange = function(widget, checked)
      if checked then
        walkArrowKeys:setChecked(false)
        cavebot.onSettingChange('walkMethod', 'Map Click')
      else
        if not walkArrowKeys:isChecked() then
          widget:setChecked(true)
        end
      end
    end

    walkArrowKeys.onCheckChange = function(widget, checked)
      if checked then
        walkMapWalk:setChecked(false)
        cavebot.onSettingChange('walkMethod', 'Keyboard')
      else
        if not walkMapWalk:isChecked() then
          widget:setChecked(true)
        end
      end
    end
  end

  local walkDelay = settingsWindow:recursiveGetChildById('walkDelay')
  if walkDelay then
    walkDelay:setText(tostring(defaultConfig.walkDelay or 0))
    walkDelay.onTextChange = function(widget, text)
      -- Remove non-numeric characters
      local numericOnly = text:gsub('[^0-9]', '')
      if numericOnly ~= text then
        widget:setText(numericOnly)
        return
      end
      local val = tonumber(numericOnly) or 0
      widget:setText(tostring(val))
      cavebot.onSettingChange('walkDelay', tostring(val))
    end
  end

  -- Close button
  local closeButton = settingsWindow:recursiveGetChildById('closeButton')
  if closeButton then
    closeButton.onClick = function()
      if settingsWindow then
        settingsWindow:destroy()
        settingsWindow = nil
      end
    end
  end

  settingsWindow:show()
  settingsWindow:raise()
  settingsWindow:focus()
end

function cavebot.hideSettingsWindow()
  if settingsWindow and not settingsWindow:isDestroyed() then
    settingsWindow:hide()
  end
end

function cavebot.showSettingsWindow()
  if settingsWindow and not settingsWindow:isDestroyed() then
    settingsWindow:show()
    settingsWindow:raise()
    settingsWindow:focus()
  end
end

function cavebot.closeSettingsWindow()
  if settingsWindow and not settingsWindow:isDestroyed() then
    settingsWindow:destroy()
    settingsWindow = nil
  end
end

function cavebot.applyToAllNode()
  local template = defaultConfig
  if editingIndex and waypoints[editingIndex] then
    template = waypoints[editingIndex]
  end

  local count = 0
  for _, wp in ipairs(waypoints) do
    if wp.action == WAYPOINT_TYPE.NODE then
      wp.monsterLimit = template.monsterLimit
      wp.resumeLimit = template.resumeLimit
      count = count + 1
    end
  end
  modules.game_textmessage.displayStatusMessage(tr('Settings applied to ' .. count .. ' Node waypoints.'))
end

function cavebot.applyToAllStand()
  local template = defaultConfig
  if editingIndex and waypoints[editingIndex] then
    template = waypoints[editingIndex]
  end

  local count = 0
  for _, wp in ipairs(waypoints) do
    if wp.action == WAYPOINT_TYPE.STAND then
      wp.monsterLimit = template.monsterLimit
      wp.resumeLimit = template.resumeLimit
      count = count + 1
    end
  end
  modules.game_textmessage.displayStatusMessage(tr('Settings applied to ' .. count .. ' Stand waypoints.'))
end

function cavebot.applyToAll()
  local template = defaultConfig
  if editingIndex and waypoints[editingIndex] then
    template = waypoints[editingIndex]
  end

  local doApply = function()
    for _, wp in ipairs(waypoints) do
      wp.monsterLimit = template.monsterLimit
      wp.resumeLimit = template.resumeLimit
    end
    modules.game_textmessage.displayStatusMessage(tr('Settings applied to all waypoints.'))
  end

  -- Modal de confirmação
  local messageBox
  local yesCallback = function()
    doApply()
    if messageBox then messageBox:destroy() end
  end
  local noCallback = function()
    if messageBox then messageBox:destroy() end
  end

  messageBox = displayGeneralBox(tr('Apply to All'),
    tr('Are you sure you want to apply settings to all waypoints?'),
    {
      { text = tr('Yes'), callback = yesCallback },
      { text = tr('No'),  callback = noCallback },
      anchor = AnchorHorizontalCenter
    },
    yesCallback, noCallback, helperWindow)
end

function cavebot.removeAllFlags()
  -- Remove cavebot markers nativos do C++
  g_minimap.clearCavebotMarkers()

  -- Remove StaticText do mapa
  clearMapTexts()
end

function cavebot.addAllFlags()
  -- Recria todos os markers nativos com índices atualizados
  for i, wp in ipairs(waypoints) do
    local pos = { x = wp.x, y = wp.y, z = wp.z }
    local iconId = wp.iconId or 11
    g_minimap.addCavebotMarker(pos, iconId, "Waypoint " .. i)

    addMapText(pos, string.format("Waypoint %d", i))
  end

  -- Atualiza seleção visual
  cavebot.updateFlagSelection()
end

function cavebot.deleteWaypoint(index)
  if index < 1 or index > #waypoints then return end

  cavebot.removeAllFlags()
  table.remove(waypoints, index)

  -- Atualiza editingIndex se necessário
  if editingIndex then
    if editingIndex == index then
      editingIndex = nil
    elseif editingIndex > index then
      editingIndex = editingIndex - 1
    end
  end

  cavebot.addAllFlags()
  cavebot.refreshList()
  cavebot.scrollToWaypoint(math.min(index, #waypoints))
end

function cavebot.changeWaypointType(index, newType)
  cavebot.removeAllFlags()
  local wp = waypoints[index]
  if wp then
    wp.action = newType
    wp.iconId = WAYPOINT_ICON[newType] or WAYPOINT_ICON[WAYPOINT_TYPE.WALK]
  end
  cavebot.addAllFlags()
  cavebot.refreshList()
  cavebot.scrollToWaypoint(index)
end

function cavebot.changeWaypointFloor(index, delta)
  cavebot.removeAllFlags()
  local wp = waypoints[index]
  if wp then
    local newZ = wp.z + delta
    if newZ >= 0 and newZ <= 15 then
      wp.z = newZ
    end
  end
  cavebot.addAllFlags()
  cavebot.selectWaypoint(index)
end

function cavebot.onWaypointMenu(index, pos, button)
  if button ~= MouseRightButton then return end

  local menu = g_ui.createWidget('PopupMenu')
  menu:setGameMenu(true)

  local wp = waypoints[index]
  local wpPos = { x = wp.x, y = wp.y, z = wp.z }

  menu:addOption(tr('Add Node Before'), function() cavebot.insertWaypoint(WAYPOINT_TYPE.NODE, wpPos, index) end)
  menu:addOption(tr('Add Node After'), function() cavebot.insertWaypoint(WAYPOINT_TYPE.NODE, wpPos, index + 1) end)
  menu:addSeparator()
  menu:addOption(tr('Delete'), function() cavebot.deleteWaypoint(index) end)
  menu:addSeparator()
  menu:addOption(tr('Type: Walk'), function() cavebot.changeWaypointType(index, WAYPOINT_TYPE.WALK) end)
  menu:addOption(tr('Type: Node'), function() cavebot.changeWaypointType(index, WAYPOINT_TYPE.NODE) end)
  menu:addOption(tr('Type: Stand'), function() cavebot.changeWaypointType(index, WAYPOINT_TYPE.STAND) end)
  menu:addOption(tr('Type: Use'), function() cavebot.changeWaypointType(index, WAYPOINT_TYPE.USE) end)
  menu:addOption(tr('Type: Rope'), function() cavebot.changeWaypointType(index, WAYPOINT_TYPE.ROPE) end)
  menu:addOption(tr('Type: Shovel'), function() cavebot.changeWaypointType(index, WAYPOINT_TYPE.SHOVEL) end)
  menu:addSeparator()
  if wp.z > 0 then
    menu:addOption(tr('Floor Up (z-1)'), function() cavebot.changeWaypointFloor(index, -1) end)
  end
  if wp.z < 15 then
    menu:addOption(tr('Floor Down (z+1)'), function() cavebot.changeWaypointFloor(index, 1) end)
  end

  menu:display(pos)
end

function cavebot.onMapClick(widget, mousePos, mouseButton)
  local mapPos = widget:getTilePosition(mousePos)
  if not mapPos then return end

  -- Verifica se clicou em um waypoint marker nativo
  -- Coleta todos os waypoints nesta posição (pode haver sobrepostos)
  local markersAtPos = {}
  for i, wp in ipairs(waypoints) do
    if wp.x == mapPos.x and wp.y == mapPos.y and wp.z == mapPos.z then
      table.insert(markersAtPos, i)
    end
  end

  if #markersAtPos > 0 then
    if mouseButton == MouseLeftButton then
      -- Cicla entre waypoints sobrepostos: seleciona o próximo após editingIndex
      local targetIndex = markersAtPos[1]
      if editingIndex then
        for j, idx in ipairs(markersAtPos) do
          if idx == editingIndex and markersAtPos[j + 1] then
            targetIndex = markersAtPos[j + 1]
            break
          end
        end
      end
      cavebot.selectWaypoint(targetIndex)
      return true
    elseif mouseButton == MouseRightButton then
      -- Menu do waypoint selecionado (se estiver nesta posição), senão do primeiro
      local menuIndex = markersAtPos[1]
      if editingIndex then
        for _, idx in ipairs(markersAtPos) do
          if idx == editingIndex then
            menuIndex = editingIndex
            break
          end
        end
      end
      cavebot.onWaypointMenu(menuIndex, mousePos, mouseButton)
      return true
    end
  end

  -- Clique direito no mapa vazio: menu de adicionar waypoint
  if mouseButton ~= MouseRightButton then return true end

  local menu = g_ui.createWidget('PopupMenu')
  menu:setGameMenu(true)

  menu:addOption(tr('Add Walk'), function() cavebot.addWaypoint(WAYPOINT_TYPE.WALK, mapPos) end)
  menu:addOption(tr('Add Node'), function() cavebot.addWaypoint(WAYPOINT_TYPE.NODE, mapPos) end)
  menu:addOption(tr('Add Stand'), function() cavebot.addWaypoint(WAYPOINT_TYPE.STAND, mapPos) end)
  menu:addSeparator()
  menu:addOption(tr('Add Use'), function() cavebot.addWaypoint(WAYPOINT_TYPE.USE, mapPos) end)
  menu:addOption(tr('Add Rope'), function() cavebot.addWaypoint(WAYPOINT_TYPE.ROPE, mapPos) end)
  menu:addOption(tr('Add Shovel'), function() cavebot.addWaypoint(WAYPOINT_TYPE.SHOVEL, mapPos) end)

  menu:display(mousePos)

  return true
end

function cavebot.refreshList()
  if not ui.waypointList then return end

  ui.waypointList:destroyChildren()

  for i, wp in ipairs(waypoints) do
    local item = g_ui.createWidget('UIWidget', ui.waypointList)
    item:setHeight(14)
    item:setMarginTop(2)
    item.id = i
    item.onMouseRelease = function(widget, mousePos, mouseButton)
      cavebot.onWaypointMenu(i, mousePos, mouseButton)
    end

    local idLabel = g_ui.createWidget('Label', item)
    idLabel:setText(string.format("%03d", i))
    idLabel:setWidth(30)
    idLabel:setTextAlign(AlignCenter)
    idLabel:addAnchor(AnchorTop, 'parent', AnchorTop)
    idLabel:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    idLabel:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    idLabel:setPhantom(true)

    local typeName = wp.action or WAYPOINT_TYPE.WALK
    local typeLabel = g_ui.createWidget('Label', item)
    typeLabel:setText(typeName)
    typeLabel:setWidth(50)
    typeLabel:setTextAlign(AlignCenter)
    typeLabel:addAnchor(AnchorTop, 'parent', AnchorTop)
    typeLabel:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    typeLabel:setMarginLeft(30)
    typeLabel:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    typeLabel:setPhantom(true)

    local coordText = string.format("x:%d, y:%d, z:%d", wp.x, wp.y, wp.z)
    if wp.monsterLimit and wp.monsterLimit > 0 then
      coordText = coordText .. string.format(" [M:%d]", wp.monsterLimit)
    end

    local coordLabel = g_ui.createWidget('Label', item)
    coordLabel:setText(coordText)
    coordLabel:setTextAlign(AlignCenter)
    coordLabel:addAnchor(AnchorTop, 'parent', AnchorTop)
    coordLabel:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    coordLabel:setMarginLeft(80)
    coordLabel:addAnchor(AnchorRight, 'parent', AnchorRight)
    coordLabel:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    coordLabel:setPhantom(true)

    local isWalkingCurrent = (MACHINE_STATE.isRunning and i == MACHINE_STATE.currentIndex)
    local isEditing = (i == editingIndex)

    local color = "white"
    if isWalkingCurrent then
      color = "green"
    elseif isEditing then
      color = "$var-text-cip-color-white"
    end

    idLabel:setColor(color)
    typeLabel:setColor(color)
    coordLabel:setColor(color)

    -- Borda branca no item selecionado
    if isEditing then
      item:setBorderWidth(1)
      item:setBorderColor("$var-text-cip-color-white")
    else
      item:setBorderWidth(0)
    end

    item.onClick = function()
      cavebot.selectWaypoint(i)
      -- Não muda automaticamente para aba config - usuário decide quando ir
    end
  end

  -- Atualiza progresso no minimap
  cavebot.updateMinimapProgress()

  -- Atualiza estado do botão Save baseado em waypoints e texto
  if ui.saveSessionButton and ui.sessionName then
    local text = ui.sessionName:getText() or ''
    ui.saveSessionButton:setEnabled(#text >= 2 and #waypoints > 0)
  end
end

-- Função leve para atualizar apenas as cores dos waypoints (sem reconstruir UI)
function cavebot.updateListColors()
  if not ui.waypointList then return end

  local children = ui.waypointList:getChildren()
  for i, item in ipairs(children) do
    local isWalkingCurrent = (MACHINE_STATE.isRunning and i == MACHINE_STATE.currentIndex)
    local isEditing = (i == editingIndex)

    local color = "white"
    if isWalkingCurrent then
      color = "green"
    elseif isEditing then
      color = "$var-text-cip-color-white"
    end

    -- Atualiza cor dos labels filhos
    local itemChildren = item:getChildren()
    for _, label in ipairs(itemChildren) do
      if label.setColor then
        label:setColor(color)
      end
    end

    -- Borda branca no item selecionado
    if isEditing then
      item:setBorderWidth(1)
      item:setBorderColor("$var-text-cip-color-white")
    else
      item:setBorderWidth(0)
    end
  end

  -- Atualiza progresso no minimap
  cavebot.updateMinimapProgress()
end

-- JSON Persistence Helpers
-- Pasta compartilhada para todos os personagens da conta
function cavebot.getProfileDir()
  return "/cavebots"
end

function cavebot.ensureProfileDir()
  local profileDir = cavebot.getProfileDir()
  if not g_resources.directoryExists(profileDir) then
    g_resources.makeDir(profileDir)
  end
end

-- Migra scripts antigos de /characterdata/{player_id}/ para /cavebots/
function cavebot.migrateOldScripts()
  cavebot.ensureProfileDir()

  local targetDir = cavebot.getProfileDir()
  local migratedCount = 0
  local writeDir = g_resources.getWriteDir()

  -- Verifica se a pasta characterdata existe
  local charDataExists = g_resources.directoryExists("/characterdata")

  if not charDataExists then
    return 0
  end

  -- Lista todas as pastas de personagens
  local dirs = g_resources.listDirectoryFiles("/characterdata")

  if not dirs or #dirs == 0 then
    return 0
  end

  for _, dir in ipairs(dirs) do
    local charPath = "/characterdata/" .. dir

    -- Lista arquivos de cavebot nessa pasta
    local files = g_resources.listDirectoryFiles(charPath)

    if files and #files > 0 then
      for _, file in ipairs(files) do
        if file:match("^cavebot_.*%.json$") then
          local sourceRealPath = writeDir .. charPath .. "/" .. file
          local targetRealPath = writeDir .. targetDir .. "/" .. file

          -- Verifica se arquivo fonte existe
          local sourceFile = io.open(sourceRealPath, "r")
          if sourceFile then
            -- Verifica se já existe no destino
            local targetFile = io.open(targetRealPath, "r")
            if targetFile then
              targetFile:close()
              sourceFile:close()
            else
              -- Lê conteúdo
              local content = sourceFile:read("*all")
              sourceFile:close()

              if content and #content > 0 then
                -- Escreve no destino
                local outFile = io.open(targetRealPath, "w")
                if outFile then
                  outFile:write(content)
                  outFile:close()
                  -- Remove arquivo original (cut, não copy)
                  os.remove(sourceRealPath)
                  migratedCount = migratedCount + 1
                end
              end
            end
          end
        end
      end
    end
  end

  if migratedCount > 0 then
    modules.game_textmessage.displayStatusMessage(tr('Migrated ' .. migratedCount .. ' cavebot scripts to shared folder.'))
  end

  return migratedCount
end

function cavebot.saveFile(filename, data)
  cavebot.ensureProfileDir()

  local fullPath = filename
  if not filename:find("^/") then
    fullPath = filename
  end

  local content = json.encode(data, 2)
  if g_resources.writeFileContents then
    return g_resources.writeFileContents(fullPath, content)
  else
    -- Fallback to IO
    local realPath = g_resources.getWriteDir() .. fullPath
    local file = io.open(realPath, "w")
    if file then
      file:write(content)
      file:close()
      return true
    end
  end
  return false
end

function cavebot.readFile(filename)
  if g_resources.readFileContents then
    if g_resources.fileExists(filename) then
      local content = g_resources.readFileContents(filename)
      return json.decode(content)
    else
    end
  else
    -- Fallback to IO
    local realPath = g_resources.getWriteDir() .. filename
    local file = io.open(realPath, "r")
    if file then
      local content = file:read("*all")
      file:close()
      return json.decode(content)
    else
    end
  end
  return nil
end

function cavebot.refreshSessionList()
  if not ui.sessionsList then return end
  local scrollBar = ui.sessionsList:getParent() and ui.sessionsList:getParent():getChildById('sessionsScrollBar')
  local scrollValue = scrollBar and scrollBar:getValue() or 0
  ui.sessionsList:destroyChildren()

  for _, name in ipairs(sessionList) do
    local label = g_ui.createWidget('Label', ui.sessionsList)
    label:setText(name)
    label:setMarginTop(2)
    label:setPhantom(false) -- Clickable

    if name == selectedSession then
      label:setColor('yellow')
      label:setFont('$var-cip-font-mono-rounded')
    else
      label:setColor("#ebbf90")
      label:setFont('$var-main-font')
    end

    label.onClick = function()
      if ui.sessionName then
        ui.sessionName:setText(name)
        ui.sessionName:setCursorPos(-1)
      end
      selectedSession = name
      -- Enable delete button when a session is selected
      if ui.deleteSessionButton then
        ui.deleteSessionButton:setEnabled(true)
      end
      cavebot.refreshSessionList()
    end
  end

  -- Disable delete button if no session is selected
  if not selectedSession or selectedSession == '' then
    if ui.deleteSessionButton then
      ui.deleteSessionButton:setEnabled(false)
    end
  end

  -- Restore scroll position after rebuilding the list
  if scrollBar and scrollValue > 0 then
    scrollBar:setValue(scrollValue)
  end
end

-- Função interna que realmente salva a sessão
local function doSaveSession()
  local name = "default"
  if ui.sessionName then name = ui.sessionName:getText() end
  -- Trim spaces
  name = name:match("^%s*(.-)%s*$")

  -- Strip "ID: " or "Global: " prefix if present (copying from other/global)
  local foreignId, foreignName = name:match("^(%d+):%s*(.+)")
  if foreignId and foreignName then
    name = foreignName
  else
    local globalName = name:match("^Global:%s*(.+)")
    if globalName then
      name = globalName
    end
  end

  if name ~= ui.sessionName:getText() then
    if ui.sessionName then ui.sessionName:setText(name) end
  end

  if name == "" then name = "default" end

  local config = { waypoints = waypoints, settings = defaultConfig }
  local filename = "cavebot_" .. name .. ".json"
  local relativePath = cavebot.getProfileDir() .. "/" .. filename

  if cavebot.saveFile(relativePath, config) then
    -- Refresh list to include new file
    cavebot.loadSessionList()

    selectedSession = name
    cavebot.refreshSessionList()
    modules.game_textmessage.displayStatusMessage(tr('Session saved: ' .. name))

    -- Keep session name in input so user sees which session is active
  else
    modules.game_textmessage.displayStatusMessage(tr('Failed to save session to ' .. relativePath))
  end
end

function cavebot.saveSession()
  local name = "default"
  if ui.sessionName then name = ui.sessionName:getText() end
  name = name:match("^%s*(.-)%s*$")
  if name == "" then return end

  -- Modal de confirmação usando displayGeneralBox
  local messageBox
  local yesCallback = function()
    doSaveSession()
    if messageBox then messageBox:destroy() end
  end
  local noCallback = function()
    if messageBox then messageBox:destroy() end
  end

  messageBox = displayGeneralBox(tr('Save Script'),
    tr('Are you sure you want to save the script "' .. name .. '"?'),
    {
      { text = tr('Yes'), callback = yesCallback },
      { text = tr('No'),  callback = noCallback },
      anchor = AnchorHorizontalCenter
    },
    yesCallback, noCallback, helperWindow)
end

-- Função interna que realmente deleta a sessão
local function doDeleteSession()
  local name = "default"
  if ui.sessionName then name = ui.sessionName:getText() end
  name = name:match("^%s*(.-)%s*$")

  if name == "" then return end

  local filename = "cavebot_" .. name .. ".json"
  local relativePath = cavebot.getProfileDir() .. "/" .. filename

  if g_resources.fileExists(relativePath) then
    local success = false
    if g_resources.deleteFile then
      success = g_resources.deleteFile(relativePath)
    else
      -- Fallback
      local realPath = g_resources.getWriteDir() .. relativePath
      success = os.remove(realPath)
    end

    if success then
      modules.game_textmessage.displayStatusMessage(tr('Script deleted: ' .. name))
      ui.sessionName:setText('')
      selectedSession = nil
      -- Disable delete button after deletion
      if ui.deleteSessionButton then
        ui.deleteSessionButton:setEnabled(false)
      end
      cavebot.loadSessionList()
      cavebot.refreshSessionList()
    else
      modules.game_textmessage.displayStatusMessage(tr('Failed to delete script.'))
    end
  else
    modules.game_textmessage.displayStatusMessage(tr('File not found: ' .. relativePath))
  end
end

function cavebot.deleteSession()
  local name = "default"
  if ui.sessionName then name = ui.sessionName:getText() end
  name = name:match("^%s*(.-)%s*$")

  -- Se não há nome selecionado, não faz nada
  if name == "" then
    return
  end

  -- Modal de confirmação usando displayGeneralBox
  local messageBox
  local yesCallback = function()
    doDeleteSession()
    if messageBox then messageBox:destroy() end
  end
  local noCallback = function()
    if messageBox then messageBox:destroy() end
  end

  messageBox = displayGeneralBox(tr('Delete Script'),
    tr('Are you sure you want to delete the script "' .. name .. '"?'),
    {
      { text = tr('Yes'), callback = yesCallback },
      { text = tr('No'),  callback = noCallback },
      anchor = AnchorHorizontalCenter
    },
    yesCallback, noCallback, helperWindow)
end

function cavebot.loadSessionList()
  if not g_game.isOnline() then return end

  sessionList = {}
  local profileDir = cavebot.getProfileDir()

  -- Garante que a pasta existe
  cavebot.ensureProfileDir()

  local files = g_resources.listDirectoryFiles(profileDir)
  if files then
    for _, file in ipairs(files) do
      -- Filter only files starting with cavebot_ and ending in .json
      if file:match("^cavebot_.*%.json$") then
        -- Extract name: cavebot_NAME.json -> NAME
        local name = file:match("^cavebot_(.+)%.json$")
        if name then
          table.insert(sessionList, name)
        end
      end
    end
  end

  cavebot.refreshSessionList()
end

function cavebot.loadSession()
  local name = "default"
  if ui.sessionName then name = ui.sessionName:getText() end
  -- Trim spaces
  name = name:match("^%s*(.-)%s*$")
  if name == "" then
    -- If name is empty, refresh the list instead of erroring
    cavebot.loadSessionList()
    modules.game_textmessage.displayStatusMessage(tr('Script list refreshed.'))
    return
  end

  local filename = "cavebot_" .. name .. ".json"
  local relativePath = cavebot.getProfileDir() .. "/" .. filename

  local config = cavebot.readFile(relativePath)

  if config and config.waypoints then
    doClearWaypoints() -- Clear current sem pedir confirmação

    local loadedParams = config.waypoints
    if config.settings then
      if config.settings.walkMethod then defaultConfig.walkMethod = config.settings.walkMethod end
      if config.settings.monsterLimit then defaultConfig.monsterLimit = config.settings.monsterLimit end
      if config.settings.resumeLimit then defaultConfig.resumeLimit = config.settings.resumeLimit end
      if config.settings.minMonstersToWait then defaultConfig.minMonstersToWait = config.settings.minMonstersToWait end
      if config.settings.avoidTrap then defaultConfig.avoidTrap = config.settings.avoidTrap end
      if config.settings.walkDelay then defaultConfig.walkDelay = config.settings.walkDelay end
      if config.settings.recordType then defaultConfig.recordType = config.settings.recordType end
      if config.settings.recordDist then defaultConfig.recordDist = config.settings.recordDist end
      if config.settings.nodeDistance then defaultConfig.nodeDistance = config.settings.nodeDistance end
    end

    local newWaypoints = {}

    -- Reconstruct waypoints list
    for k, v in pairs(loadedParams) do
      if v and v.x and v.y and v.z then
        if type(k) == 'number' then
          newWaypoints[k] = v
        else
          table.insert(newWaypoints, v)
        end
      end
    end

    -- Sort / Reindex
    waypoints = {}
    local keys = {}
    for k in pairs(newWaypoints) do table.insert(keys, k) end
    table.sort(keys)

    for _, k in ipairs(keys) do
      table.insert(waypoints, newWaypoints[k])
    end


    -- Re-add flags usando o novo sistema customizado
    cavebot.addAllFlags()

    cavebot.refreshList()
    cavebot.updateConfigEditor() -- Atualiza a UI da tab config
    modules.game_textmessage.displayStatusMessage(tr('Script loaded: ' .. name .. ' (' .. #waypoints .. ' WPs)'))
  else
    modules.game_textmessage.displayStatusMessage(tr('Script not found: ' .. name))
  end
end

-- Walking Logic
function cavebot.doToggle(state)
  -- Desliga o recorder se estiver ligado ao mudar status do cavebot
  if cavebot.isRecording() then
    cavebot.stopRecording()
  end

  -- Bloqueio mútuo: ao ligar cavebot, desligar smart follow
  if state then
    if _Helper and _Helper.SmartFollow and _Helper.SmartFollow.isEnabled() then
      _Helper.SmartFollow.resetCheckbox()
    end
  end

  MACHINE_STATE.isRunning = state

  -- Notify server about cavebot state change via Extended Opcode
  local protocolGame = g_game.getProtocolGame()
  if protocolGame then
    protocolGame:sendExtendedOpcode(ExtendedIds.Cavebot, state and "1" or "0")
  end

  local btn = nil
  if helperWindow then
    btn = helperWindow:recursiveGetChildById('cavebotToggleButton')
  end
  if btn then
    if MACHINE_STATE.isRunning then
      btn:setText(tr('On'))
      btn:setColor('#AAFFAA') -- Greenish
    else
      btn:setText(tr('Off'))
      btn:setColor('#FFAAAA') -- Reddish
    end
  end

  -- Sincronizar com shortcut panel
  if _Helper and _Helper.Shortcut and _Helper.Shortcut.syncButton then
    _Helper.Shortcut.syncButton('shortcutCavebot', MACHINE_STATE.isRunning)
  end

  if MACHINE_STATE.isRunning then
    cavebot.resetState()
    -- Encontra o waypoint mais próximo ao iniciar
    MACHINE_STATE.currentIndex = cavebot.findNearestWaypoint()
    cavebot.updateListColors() -- Só atualiza cores (verde no atual), sem reconstruir a lista
    cavebot.startWalking()
  else
    cavebot.stopWalking()
    cavebot.updateListColors() -- Só atualiza cores, sem reconstruir a lista
  end
end

function cavebot.toggle(state)
  -- Ao ativar, mostra aviso de checagem (se ainda não foi ocultado)
  if state and _Helper and _Helper.showToolWarning then
    _Helper.showToolWarning(function()
      cavebot.doToggle(state)
    end)
  else
    cavebot.doToggle(state)
  end
end

-- ============================================================================
-- FUNÇÕES DE CONTROLE DE ESTADO
-- ============================================================================

-- Encontra o waypoint mais próximo do player
function cavebot.findNearestWaypoint()
  if #waypoints == 0 then return 1 end

  local player = g_game.getLocalPlayer()
  if not player then return 1 end

  local playerPos = player:getPosition()
  local nearestIndex = 1
  local nearestDist = 999999

  for i, wpt in ipairs(waypoints) do
    local wptPos = {
      x = tonumber(wpt.x),
      y = tonumber(wpt.y),
      z = tonumber(wpt.z)
    }

    -- Só considera waypoints no mesmo floor
    if wptPos.z == playerPos.z then
      local dist = cavebot.getDistance(playerPos, wptPos)
      if dist < nearestDist then
        nearestDist = dist
        nearestIndex = i
      end
    end
  end

  -- Se não achou nenhum no mesmo floor, procura em qualquer floor
  if nearestDist == 999999 then
    for i, wpt in ipairs(waypoints) do
      local wptPos = {
        x = tonumber(wpt.x),
        y = tonumber(wpt.y),
        z = tonumber(wpt.z)
      }
      local dist = cavebot.getDistance(playerPos, wptPos)
      if dist < nearestDist then
        nearestDist = dist
        nearestIndex = i
      end
    end
  end

  return nearestIndex
end

-- Reseta o estado da máquina (ao iniciar/reiniciar)
function cavebot.resetState()
  MACHINE_STATE.pausedByMonsters = false
  MACHINE_STATE.lastFreeze = 0
  MACHINE_STATE.lastMove = 0
  MACHINE_STATE.lastPosition = nil
  MACHINE_STATE.isStuck = false
  MACHINE_STATE.lastStatus = "Starting"
  MACHINE_STATE.walkAttempts.pathfind = 0
  MACHINE_STATE.walkAttempts.autoWalk = 0
  MACHINE_STATE.actionWaitUntil = 0

  MACHINE_TIMERS.lastWalk = 0
  MACHINE_TIMERS.lastWalkPos = nil
  MACHINE_TIMERS.serverConfirmedWalk = false
  MACHINE_TIMERS.currentDelay = MACHINE_TIMERS.baseDelay

  MACHINE_UTILS.monsterCount = 0
  MACHINE_UTILS.monsters = {}
  MACHINE_UTILS.lifePercentage = 0
end

-- Atualiza dados de monstros (como getMonstersData do ZeroBot)
function cavebot.updateMonstersData(playerPos, range)
  range = range or 7
  local specs = g_map.getSpectators(playerPos, false) or {}
  local monsters = {}
  local totalLife = 0

  -- Try to get ignore table from helper
  local ignoreTable = {}
  if _Helper and _Helper.getIgnoreMonsterTable then
    ignoreTable = _Helper.getIgnoreMonsterTable() or {}
  end

  for _, creature in ipairs(specs) do
    if creature:isMonster() and not creature:isDead() then
      local cPos = creature:getPosition()

      if cPos and cPos.z == playerPos.z then
        local name = creature:getName()
        if not (name and ignoreTable[name:lower()]) then
          local dist = math.max(math.abs(playerPos.x - cPos.x), math.abs(playerPos.y - cPos.y))
          if dist <= range then
            if g_map.isSightClear(playerPos, cPos) then
              local hp = creature:getHealthPercent() or 100
              table.insert(monsters, {
                creature = creature,
                position = cPos,
                distance = dist,
                life = hp,
                name = name
              })
              totalLife = totalLife + hp
            end
          end
        end
      end
    end
  end

  MACHINE_UTILS.monsters = monsters
  MACHINE_UTILS.monsterCount = #monsters
  MACHINE_UTILS.lifePercentage = #monsters > 0 and (totalLife / #monsters) or 0

  return #monsters
end

-- ============================================================================
-- SISTEMA DE DELAY DINÂMICO (inspirado no canWalkAgain do ZeroBot)
-- ============================================================================

-- Calcula delay baseado em ping, velocidade, monstros e método de walk
function cavebot.calculateWalkDelay(isMapClick)
  local ping = MACHINE_UTILS.getPing()
  local monsterCount = MACHINE_UTILS.monsterCount

  -- Usa getStepDuration() do player para cálculo preciso do tile speed
  local tileSpeed = 100 -- fallback
  local player = g_game.getLocalPlayer()
  if player and player.getStepDuration then
    tileSpeed = player:getStepDuration() or 100
  end

  local delay

  -- Map Click: delay é apenas o ping (o servidor controla a velocidade)
  if isMapClick then
    -- Sem monstros: velocidade máxima possível (apenas ping)
    -- Com monstros: adiciona pequeno delay para kiting
    if monsterCount == 0 then
      delay = math.max(ping, 20) -- mínimo 20ms para estabilidade
    else
      delay = math.max(ping, 50)
      -- Cada monstro adiciona delay proporcional (kiting suave)
      local monsterDelay = math.min(monsterCount * 20, 100)
      delay = delay + monsterDelay
    end
  else
    -- Keyboard: canWalk() do C++ já garante o timing correto (stepDuration)
    -- Aqui só precisamos do delay customizado do walkDelay (kiting manual)
    -- Sem delay extra por monstros — canWalk() já sincroniza com o servidor
    delay = 0
  end

  -- Add custom walk delay if configured (only when luring with enough monsters)
  local walkDelay = defaultConfig.walkDelay or 0
  local minMonstersToWait = defaultConfig.minMonstersToWait or 2
  if walkDelay > 0 and monsterCount >= minMonstersToWait then
    delay = delay + walkDelay
  end

  -- Garante delay máximo absoluto para evitar travamentos
  -- Respeita o walkDelay configurado pelo player se for maior que 2000
  local maxAllowedDelay = math.max(2000, walkDelay + 500)
  delay = math.min(delay, maxAllowedDelay)

  MACHINE_TIMERS.currentDelay = delay
  return delay
end

-- Verifica se pode andar novamente (como canWalkAgain do ZeroBot)
function cavebot.canWalkAgain()
  local now = os.clock()
  -- Usa o método de walk configurado para calcular delay correto
  local isMapClick = (defaultConfig.walkMethod == 'Map Click')
  local delay = cavebot.calculateWalkDelay(isMapClick)
  local elapsed = (now - MACHINE_TIMERS.lastWalk) * 1000 -- Converter para ms

  return elapsed >= delay
end

-- Registra que um passo foi dado
function cavebot.registerWalkStep()
  MACHINE_TIMERS.lastWalk = os.clock()
  -- Salva posição atual para detectar quando o servidor confirmar o movimento
  local player = g_game.getLocalPlayer()
  if player then
    local pos = player:getPosition()
    MACHINE_TIMERS.lastWalkPos = { x = pos.x, y = pos.y, z = pos.z }
  end
  MACHINE_STATE.walkAttempts.pathfind = 0
  MACHINE_STATE.walkAttempts.autoWalk = 0
end

-- ============================================================================
-- SISTEMA DE DETECÇÃO DE FREEZE/STUCK (inspirado no HandleFreeze do ZeroBot)
-- ============================================================================

-- Atualiza estado de freeze/stuck
-- IMPORTANTE: Freeze só é detectado quando:
-- 1. O player está em um andar diferente do waypoint atual, OU
-- 2. O player pode andar (tem tiles livres) mas não está andando
-- Se o player não consegue ir do ponto A ao B por estar trapado, NÃO é freeze
function cavebot.updateFreezeState(currentPos, targetPos)
  local now = os.time()

  -- Se não tem posição anterior, inicializa
  if not MACHINE_STATE.lastPosition then
    MACHINE_STATE.lastPosition = currentPos
    MACHINE_STATE.lastMove = now
    MACHINE_STATE.lastFreeze = 0
    return false
  end

  -- Verifica se moveu
  local moved = (currentPos.x ~= MACHINE_STATE.lastPosition.x or
    currentPos.y ~= MACHINE_STATE.lastPosition.y or
    currentPos.z ~= MACHINE_STATE.lastPosition.z)

  if moved then
    -- Moveu! Reseta timers
    MACHINE_STATE.lastPosition = currentPos
    MACHINE_STATE.lastMove = now
    MACHINE_STATE.lastFreeze = 0
    MACHINE_STATE.isStuck = false
    return false
  end

  -- Não moveu - verifica se devemos considerar freeze
  local player = g_game.getLocalPlayer()
  if not player then return false end

  -- CASO 1: Player está em andar diferente do waypoint - SEMPRE é freeze
  local wrongFloor = targetPos and currentPos.z ~= targetPos.z

  -- CASO 2: Player pode andar mas não está andando
  local canMove = cavebot.canPlayerMove(player)

  -- Se trapado (não pode andar), reseta contadores mas ainda conta o tempo
  -- Isso evita que o script fique preso, mas dá mais tempo antes de considerar stuck
  if not canMove and not wrongFloor then
    -- Reseta contadores de tentativas para não travar o script
    MACHINE_STATE.walkAttempts.pathfind = 0
    MACHINE_STATE.walkAttempts.autoWalk = 0
  end

  -- Conta o tempo parado
  if MACHINE_STATE.lastFreeze == 0 then
    MACHINE_STATE.lastFreeze = now
  end

  local freezeTime = now - MACHINE_STATE.lastFreeze

  -- Se está em andar errado, considera stuck mais rápido
  if wrongFloor then
    if freezeTime >= 5 then
      MACHINE_STATE.isStuck = true
      return true, "wrong_floor"
    elseif freezeTime >= 2 then
      return true, "floor_change"
    end
  end

  -- Se pode andar: níveis normais de stuck
  if canMove then
    if freezeTime >= MACHINE_STATE.stuckMaxTime then
      MACHINE_STATE.isStuck = true
      return true, "stuck"
    elseif freezeTime >= 5 then
      return true, "freezing"
    elseif freezeTime >= 2 then
      return true, "slow"
    end
  else
    -- Se não pode andar (trapado): só considera stuck após tempo muito maior
    -- Isso dá tempo para monstros saírem do caminho
    if freezeTime >= 30 then
      -- Após 30s trapado, força restart para tentar encontrar outro caminho
      MACHINE_STATE.isStuck = true
      return true, "trapped_timeout"
    end
  end

  return false
end

-- Trata situação de stuck
-- Retorna: "wait", "retry", "alternate", "restart"
-- NOTA: Esta função só é chamada quando updateFreezeState já confirmou que é um freeze real
-- (player pode andar mas não está andando, ou está em andar errado)
function cavebot.handleStuck(freezeLevel)
  -- Se está parado por killing box ou esperando monstros, não é stuck real
  if MACHINE_STATE.pausedByMonsters then
    return "wait"
  end

  -- Tratamento para andar errado
  if freezeLevel == "floor_change" then
    -- 2-5s em andar errado - tenta encontrar caminho
    MACHINE_STATE.lastStatus = "Wrong floor, finding path..."
    return "retry"
  elseif freezeLevel == "wrong_floor" then
    -- 5s+ em andar errado - reinicia script para encontrar waypoint mais próximo
    MACHINE_STATE.lastStatus = "Stuck on wrong floor! Restarting..."
    cavebot.restartScript()
    return "restart"
  end

  -- Nível 1 (2-5s): Incrementa tentativas
  if freezeLevel == "slow" then
    MACHINE_STATE.walkAttempts.pathfind = MACHINE_STATE.walkAttempts.pathfind + 1
    MACHINE_STATE.lastStatus = "Retrying..."
    return "retry"
  end

  -- Nível 2 (5-15s): Tenta autoWalk
  if freezeLevel == "freezing" then
    MACHINE_STATE.walkAttempts.autoWalk = MACHINE_STATE.walkAttempts.autoWalk + 1
    MACHINE_STATE.lastStatus = "Trying alternate path..."
    return "alternate"
  end

  -- Nível 3 (15s+): Reinicia script
  if freezeLevel == "stuck" then
    MACHINE_STATE.lastStatus = "Stuck! Restarting..."
    cavebot.restartScript()
    return "restart"
  end

  -- Timeout de trapado (30s+): Força restart
  if freezeLevel == "trapped_timeout" then
    MACHINE_STATE.lastStatus = "Trapped too long! Restarting..."
    cavebot.restartScript()
    return "restart"
  end

  return "wait"
end

-- Verifica se o player pode se mover (não está trapado por monstros ou paredes)
-- Retorna true se existe pelo menos 1 direção onde o player pode andar
-- IMPORTANTE: Verifica as 8 direções (N, NE, E, SE, S, SW, W, NW), não apenas as 4 cardinais.
-- Player só é considerado "trapado" se TODAS as 8 posições ao redor estiverem bloqueadas.
function cavebot.canPlayerMove(player)
  if not player then return false end

  local playerPos = player:getPosition()
  if not playerPos then return false end

  -- Lista de offsets para as 8 direções (não usar directionOffsets que é um hash)
  local directions = {
    { x = 0,  y = -1 }, -- Norte
    { x = 1,  y = -1 }, -- Nordeste
    { x = 1,  y = 0 },  -- Leste
    { x = 1,  y = 1 },  -- Sudeste
    { x = 0,  y = 1 },  -- Sul
    { x = -1, y = 1 },  -- Sudoeste
    { x = -1, y = 0 },  -- Oeste
    { x = -1, y = -1 }, -- Noroeste
  }

  for _, dir in ipairs(directions) do
    local checkPos = { x = playerPos.x + dir.x, y = playerPos.y + dir.y, z = playerPos.z }
    local tile = g_map.getTile(checkPos)
    if tile and tile:isWalkable() and not cavebot.hasCreatureBlocking(checkPos) then
      return true
    end
  end

  return false
end

-- Reinicia o script (toggle off/on) para que findNearest encontre o waypoint mais próximo
function cavebot.restartScript()
  -- Para o script
  cavebot.toggle(false)

  -- Pequeno delay e reinicia
  scheduleEvent(function()
    if #waypoints > 0 then
      cavebot.toggle(true)
    end
  end, 500)
end

-- ============================================================================
-- WALKER HELPERS
-- ============================================================================
function cavebot.getDistance(pos1, pos2)
  if not pos1 or not pos2 then return 99999 end
  return math.max(math.abs(pos1.x - pos2.x), math.abs(pos1.y - pos2.y))
end

-- Conta tiles ao redor do player que são ACESSÍVEIS por monstros
-- Um tile é considerado acessível se:
-- 1. É walkable (ignora criaturas atuais)
-- 2. Tem pelo menos uma entrada livre (não bloqueada por monstros nas diagonais)
--
-- Exemplo: Se um monstro está em x+1,y-1 e outro em x+1,y+1, o tile x+1,y está
-- bloqueado porque monstros não conseguem passar entre dois monstros diagonais
function cavebot.countFreeTiles(pos)
  if not pos then return 0 end

  -- Primeiro, mapeia onde estão os monstros adjacentes (distância 1-2)
  local monsterPositions = {}
  local specs = g_map.getSpectators(pos, false) or {}

  for _, creature in ipairs(specs) do
    if creature:isMonster() and not creature:isDead() then
      local cPos = creature:getPosition()
      if cPos and cPos.z == pos.z then
        local dist = math.max(math.abs(pos.x - cPos.x), math.abs(pos.y - cPos.y))
        if dist <= 2 then
          -- Usa string como chave para facilitar lookup
          local key = cPos.x .. "," .. cPos.y
          monsterPositions[key] = true
        end
      end
    end
  end

  -- Função auxiliar para verificar se há monstro numa posição
  local function hasMonster(x, y)
    return monsterPositions[x .. "," .. y] == true
  end

  -- Define os 8 tiles adjacentes e suas "entradas" possíveis
  -- Para um monstro entrar num tile adjacente ao player, ele precisa vir de fora
  -- Se as duas posições que dão acesso a esse tile têm monstros, está bloqueado
  local adjacentTiles = {
    -- Norte (y-1): entrada por NW(x-1,y-1), N(x,y-2), NE(x+1,y-1)
    { x = 0,  y = -1, entries = { { -1, -1 }, { 0, -2 }, { 1, -1 } } },
    -- Nordeste (x+1,y-1): entrada por N(x,y-1), NE(x+1,y-2), E(x+1,y), ou diagonal externa
    { x = 1,  y = -1, entries = { { 0, -1 }, { 1, -2 }, { 2, -1 }, { 1, 0 } } },
    -- Leste (x+1): entrada por NE(x+1,y-1), E(x+2,y), SE(x+1,y+1)
    { x = 1,  y = 0,  entries = { { 1, -1 }, { 2, 0 }, { 1, 1 } } },
    -- Sudeste (x+1,y+1): entrada por E(x+1,y), SE(x+2,y+1), S(x,y+1), ou diagonal externa
    { x = 1,  y = 1,  entries = { { 1, 0 }, { 2, 1 }, { 1, 2 }, { 0, 1 } } },
    -- Sul (y+1): entrada por SE(x+1,y+1), S(x,y+2), SW(x-1,y+1)
    { x = 0,  y = 1,  entries = { { 1, 1 }, { 0, 2 }, { -1, 1 } } },
    -- Sudoeste (x-1,y+1): entrada por S(x,y+1), SW(x-2,y+1), W(x-1,y), ou diagonal externa
    { x = -1, y = 1,  entries = { { 0, 1 }, { -2, 1 }, { -1, 2 }, { -1, 0 } } },
    -- Oeste (x-1): entrada por SW(x-1,y+1), W(x-2,y), NW(x-1,y-1)
    { x = -1, y = 0,  entries = { { -1, 1 }, { -2, 0 }, { -1, -1 } } },
    -- Noroeste (x-1,y-1): entrada por W(x-1,y), NW(x-2,y-1), N(x,y-1), ou diagonal externa
    { x = -1, y = -1, entries = { { -1, 0 }, { -2, -1 }, { -1, -2 }, { 0, -1 } } },
  }

  local count = 0

  for _, adj in ipairs(adjacentTiles) do
    local checkPos = { x = pos.x + adj.x, y = pos.y + adj.y, z = pos.z }
    local tile = g_map.getTile(checkPos)

    -- Primeiro verifica se o tile é walkable (ignora criaturas)
    if tile and tile:isWalkable(true) then
      -- Agora verifica se pelo menos uma entrada está livre
      local hasAccessibleEntry = false

      for _, entry in ipairs(adj.entries) do
        local entryX = pos.x + entry[1]
        local entryY = pos.y + entry[2]

        -- Verifica se a entrada está livre de monstros
        if not hasMonster(entryX, entryY) then
          -- Verifica também se o tile de entrada é walkable
          local entryPos = { x = entryX, y = entryY, z = pos.z }
          local entryTile = g_map.getTile(entryPos)
          if entryTile and entryTile:isWalkable(true) then
            hasAccessibleEntry = true
            break
          end
        end
      end

      if hasAccessibleEntry then
        count = count + 1
      end
    end
  end

  return count
end

-- Verifica se monstros estão ficando para trás e precisa esperar
-- Retorna true se deve parar de andar e esperar os monstros
function cavebot.avoidLostInMonsters(playerPos, monsters, minMonsters, avoidTrap)
  local safeMonsters = monsters or {}
  local safeMinMonsters = minMonsters or 2
  local safeAvoidTrap = avoidTrap or 4 -- monstros próximos suficientes para não precisar esperar

  -- Se minMonsters é 0 ou menor, desativa o avoidLost
  if safeMinMonsters <= 0 then
    return false
  end

  -- Se tem menos monstros que o mínimo, não precisa esperar
  if #safeMonsters < safeMinMonsters then
    return false
  end

  local player = g_game.getLocalPlayer()
  if not player then return false end

  local nearMonsters = 0
  local nearWalls = 0
  local lostMonsters = {}

  -- Conta monstros próximos e paredes ao redor
  for _, monster in ipairs(safeMonsters) do
    local monsterPos = monster.position
    if monsterPos and g_map.isSightClear(playerPos, monsterPos) then
      local dist = cavebot.getDistance(playerPos, monsterPos)

      -- Monstro próximo (distância <= 2)
      if dist <= 2 then
        nearMonsters = nearMonsters + 1
      end

      -- Verifica se monstro está ficando para trás baseado na direção do player
      local playerDir = player:getDirection()
      local distY = monsterPos.y - playerPos.y
      local distX = monsterPos.x - playerPos.x

      local isLost = false
      if playerDir == North then     -- Norte
        if distY >= 4 then isLost = true end
      elseif playerDir == East then  -- Leste
        if distX <= -6 then isLost = true end
      elseif playerDir == South then -- Sul
        if distY <= -4 then isLost = true end
      elseif playerDir == West then  -- Oeste
        if distX >= 6 then isLost = true end
      end

      if isLost then
        table.insert(lostMonsters, monster)
      end
    end
  end

  -- Conta paredes/tiles não walkable ao redor
  local neighbors = {
    { x = -1, y = -1 }, { x = 0, y = -1 }, { x = 1, y = -1 },
    { x = -1, y = 0 }, { x = 1, y = 0 },
    { x = -1, y = 1 }, { x = 0, y = 1 }, { x = 1, y = 1 }
  }

  for _, offset in ipairs(neighbors) do
    local checkPos = { x = playerPos.x + offset.x, y = playerPos.y + offset.y, z = playerPos.z }
    local tile = g_map.getTile(checkPos)
    if not tile or not tile:isWalkable(true) then
      nearWalls = nearWalls + 1
    end
  end

  -- Se já tem monstros + paredes suficientes perto, não precisa esperar (não está em trap)
  if (nearMonsters + nearWalls) >= safeAvoidTrap then
    return false
  end

  -- Se tem monstros ficando para trás, deve esperar
  return #lostMonsters > 0
end

-- NOTA: countMonsters foi substituída por updateMonstersData() que atualiza MACHINE_UTILS
-- Mantida como wrapper para compatibilidade externa
function cavebot.countMonsters(playerPos, range)
  cavebot.updateMonstersData(playerPos, range)
  return MACHINE_UTILS.monsterCount
end

function cavebot.findNearestPosition(from, positions, extras)
  extras = extras or {}
  local prop = extras.prop or nil
  local retries = tonumber(extras.retries) or 0

  local shortestDistance = 999999
  local nextPath = nil
  local index = 0

  for i, point in ipairs(positions) do
    local currentPoint = point
    if prop ~= nil then
      currentPoint = point[prop]
    end

    -- Ensure coords are numbers
    local posZ = tonumber(currentPoint.z)

    if from.z == posZ then
      local p = { x = tonumber(currentPoint.x), y = tonumber(currentPoint.y), z = posZ }
      local distance = cavebot.getDistance(from, p)
      if distance < shortestDistance then
        shortestDistance = distance
        nextPath = point
        index = i

        if retries > 0 then
          return index, nextPath, distance
        end
      end
    end
  end

  return index, nextPath, shortestDistance
end

-- Função principal do walker - roda como cycleEvent a cada 500ms
function cavebot.walkerTick()
  -- ========================================================================
  -- FASE 1: VERIFICAÇÕES BÁSICAS
  -- ========================================================================

  -- Verificações básicas de estado
  if not MACHINE_STATE.isRunning then return end
  if #waypoints == 0 then return end

  local player = g_game.getLocalPlayer()
  if not player then return end

  -- Verifica se está aguardando uma ação (Use/Rope/Shovel/mudança de floor)
  if MACHINE_STATE.actionWaitUntil > 0 then
    if os.clock() < MACHINE_STATE.actionWaitUntil then
      return
    end
    MACHINE_STATE.actionWaitUntil = 0
  end

  -- Garante índice válido
  if MACHINE_STATE.currentIndex > #waypoints then MACHINE_STATE.currentIndex = 1 end

  local target = waypoints[MACHINE_STATE.currentIndex]
  target.x = tonumber(target.x)
  target.y = tonumber(target.y)
  target.z = tonumber(target.z)

  local playerPos = player:getPosition()
  if not playerPos then
    return
  end

  -- ========================================================================
  -- FASE 2: ATUALIZAR DADOS DE MONSTROS (como getMonstersData do ZeroBot)
  -- ========================================================================
  cavebot.updateMonstersData(playerPos, 7)

  -- NOTA: canWalkAgain() removido daqui - delay só é aplicado na FASE 9 ao andar

  -- ========================================================================
  -- FASE 2.5: DETECTAR MUDANÇA DE FLOOR (antes do freeze detection)
  -- Isso evita que o sistema detecte "wrong_floor" logo após mudar de andar
  -- ========================================================================
  if MACHINE_STATE.lastPosition and MACHINE_STATE.lastPosition.z ~= playerPos.z then
    local nextIndex = MACHINE_STATE.currentIndex + 1
    if nextIndex > #waypoints then nextIndex = 1 end

    local nextWp = waypoints[nextIndex]
    local shouldAdvance = false

    if nextWp then
      local nextZ = tonumber(nextWp.z)
      -- Só avança se o próximo waypoint está no floor atual do player
      if nextZ == playerPos.z then
        shouldAdvance = true
      end
    end

    if shouldAdvance then
      MACHINE_STATE.currentIndex = nextIndex
      cavebot.updateListColors()
      cavebot.scrollToWaypoint(MACHINE_STATE.currentIndex)
      -- Atualiza target para o novo waypoint
      target = waypoints[MACHINE_STATE.currentIndex]
      target.x = tonumber(target.x)
      target.y = tonumber(target.y)
      target.z = tonumber(target.z)
    end

    -- Reseta o freeze e atualiza posição ao mudar de floor
    MACHINE_STATE.lastFreeze = 0
    MACHINE_STATE.lastPosition = playerPos
    -- Continua sem delay - não faz return, deixa o tick continuar normalmente
  end

  -- ========================================================================
  -- FASE 3: DETECÇÃO DE FREEZE/STUCK (como HandleFreeze do ZeroBot)
  -- Passa targetPos para verificar se está em andar diferente
  -- ========================================================================
  local targetPos = { x = target.x, y = target.y, z = target.z }
  local isFrozen, freezeLevel = cavebot.updateFreezeState(playerPos, targetPos)

  if isFrozen then
    local stuckAction = cavebot.handleStuck(freezeLevel)

    if stuckAction == "restart" then
      return
    end
  end

  -- ========================================================================
  -- FASE 4: PROXIMITY SKIP (Anti-Backtrack) - DESATIVADO
  -- Esta lógica foi desativada porque causava problemas ao entrar em salas:
  -- Se a rota passa por uma sala (entra e sai), o sistema detectava que o
  -- player estava próximo do waypoint de saída e pulava os waypoints internos,
  -- fazendo o bot nunca entrar na sala.
  --
  -- Para reativar com segurança, seria necessário verificar se os waypoints
  -- intermediários estão "no caminho" (mesma direção geral) e não em áreas
  -- separadas como salas laterais.
  -- ========================================================================
  -- CÓDIGO ORIGINAL COMENTADO:
  --[[
  if #waypoints > 1 and MACHINE_STATE.currentIndex > 1 then
    for i = 1, 3 do
      local checkIndex = MACHINE_STATE.currentIndex + i
      -- Não permite wrap-around para o início durante proximity skip
      if checkIndex > #waypoints then
        break
      end

      local checkWpt = waypoints[checkIndex]
      local checkPos = { x = tonumber(checkWpt.x), y = tonumber(checkWpt.y), z = tonumber(checkWpt.z) }

      if checkPos.z == playerPos.z then
        local dist = cavebot.getDistance(playerPos, checkPos)
        if dist <= 3 then
          MACHINE_STATE.currentIndex = checkIndex
          MACHINE_STATE.lastFreeze = 0 -- Reset freeze ao pular
          cavebot.updateListColors()
          cavebot.scrollToWaypoint(MACHINE_STATE.currentIndex)
          target = waypoints[MACHINE_STATE.currentIndex]
          target.x = tonumber(target.x)
          target.y = tonumber(target.y)
          target.z = tonumber(target.z)
          break
        end
      end
    end
  end
  --]]

  -- ========================================================================
  -- FASE 5: LÓGICA DE KILLING BOX (como killingBox do ZeroBot)
  -- Ignorada em Protection Zone (não há monstros)
  -- ========================================================================
  local inProtectionZone = player:isInProtectionZone()

  if not inProtectionZone and target.monsterLimit and target.monsterLimit > 0 then
    local pauseLimit = target.monsterLimit
    local resumeLimit = target.resumeLimit or 0

    -- Calcula distância ao waypoint para verificar proximidade
    local targetDx = math.abs(playerPos.x - target.x)
    local targetDy = math.abs(playerPos.y - target.y)
    local targetDz = math.abs(playerPos.z - target.z)

    -- Distância necessária para ativar killing box (mesmo critério de chegada)
    local killboxDist = 1
    if target.action == WAYPOINT_TYPE.STAND then
      killboxDist = 0
    elseif target.action == WAYPOINT_TYPE.NODE then
      killboxDist = defaultConfig.nodeDistance or 1
    end

    -- Só ativa killing box se estiver próximo do waypoint
    local isNearTarget = targetDx <= killboxDist and targetDy <= killboxDist and targetDz == 0

    -- Entrar no killing box
    if not MACHINE_STATE.pausedByMonsters then
      if isNearTarget and MACHINE_UTILS.monsterCount >= pauseLimit then
        -- Se monsterLimit >= 8, precisa ter 8 tiles livres ao redor para parar
        local canStop = true
        if pauseLimit >= 8 then
          local freeTiles = cavebot.countFreeTiles(playerPos)
          if freeTiles < 8 then
            canStop = false
            MACHINE_STATE.lastStatus = "Finding safe spot (" .. freeTiles .. "/8)"
            -- Não tem espaço suficiente: continua andando (vai para FASE 8)
            -- NÃO avança o index - deixa o walker continuar no mesmo waypoint
          end
        end

        if canStop then
          MACHINE_STATE.pausedByMonsters = true
          MACHINE_STATE.lastStatus = "Killing Box"
          MACHINE_STATE.lastFreeze = 0 -- Reset freeze enquanto mata
          player:stopAutoWalk()
        end
      end
    else
      -- Sair do killing box
      if MACHINE_UTILS.monsterCount <= resumeLimit then
        MACHINE_STATE.pausedByMonsters = false
        MACHINE_STATE.lastStatus = "Walking"
      end
    end

    if MACHINE_STATE.pausedByMonsters then
      return
    end
  end

  -- ========================================================================
  -- FASE 6: AVOID LOST IN MONSTERS
  -- Verifica se monstros estão ficando para trás e precisa esperar
  -- Ignorada em Protection Zone
  -- ========================================================================
  if not inProtectionZone and target.monsterLimit and target.monsterLimit > 0 then
    local minMonstersToWait = defaultConfig.minMonstersToWait or 2
    local avoidTrap = defaultConfig.avoidTrap or 4
    if cavebot.avoidLostInMonsters(playerPos, MACHINE_UTILS.monsters, minMonstersToWait, avoidTrap) then
      local now = os.clock()

      -- Inicia contagem se ainda não estava esperando
      if MACHINE_STATE.lureWaitStart == 0 then
        MACHINE_STATE.lureWaitStart = now
      end

      -- Verifica se passou do timeout máximo (2 segundos)
      local waitTime = now - MACHINE_STATE.lureWaitStart
      if waitTime < MACHINE_STATE.lureWaitMaxTime then
        MACHINE_STATE.lastStatus = "Waiting monsters"
        player:stopAutoWalk()
        return
      end
      -- Timeout atingido, continua andando
      MACHINE_STATE.lureWaitStart = 0
    else
      -- Não precisa esperar, reseta o contador
      MACHINE_STATE.lureWaitStart = 0
    end
  end

  -- ========================================================================
  -- FASE 7: VERIFICAR SE CHEGOU NO WAYPOINT (como isNearToContinue do ZeroBot)
  -- NOTA: Detecção de mudança de floor foi movida para FASE 2.5
  -- ========================================================================
  local dx = math.abs(playerPos.x - target.x)
  local dy = math.abs(playerPos.y - target.y)
  local dz = math.abs(playerPos.z - target.z)

  local reachDist = 1
  if target.action == WAYPOINT_TYPE.STAND then
    reachDist = 0
  elseif target.action == WAYPOINT_TYPE.NODE then
    reachDist = defaultConfig.nodeDistance or 1
  end

  if dx <= reachDist and dy <= reachDist and dz == 0 then
    -- CHEGOU no waypoint!
    local reachedAction = target.action

    MACHINE_STATE.currentIndex = MACHINE_STATE.currentIndex + 1
    if MACHINE_STATE.currentIndex > #waypoints then
      MACHINE_STATE.currentIndex = 1
    end

    -- Reseta estados
    MACHINE_STATE.lastFreeze = 0
    -- Usa updateListColors() em vez de refreshList() para evitar lag
    cavebot.updateListColors()
    cavebot.scrollToWaypoint(MACHINE_STATE.currentIndex)

    -- Executa ação do waypoint que acabou de chegar
    -- Node/Walk: continua direto para FASE 8 (sem return)
    -- Stand: pequeno delay
    -- Use/Rope/Shovel: delay maior para esperar ação

    if reachedAction == WAYPOINT_TYPE.USE then
      if g_map then
        local tPos = { x = target.x, y = target.y, z = target.z }
        local tile = g_map.getTile(tPos)
        if tile then
          local thing = tile:getTopUseThing()
          if thing then
            g_game.use(thing)
          end
        end
      end
      MACHINE_STATE.actionWaitUntil = os.clock() + 1.0 -- Espera 1000ms
      return
    end

    if reachedAction == WAYPOINT_TYPE.ROPE then
      if g_map then
        local tPos = { x = target.x, y = target.y, z = target.z }
        local tile = g_map.getTile(tPos)
        if tile then
          local rope = cavebot.findRope()
          if rope then
            g_game.useWith(rope, tile:getTopUseThing() or tile:getTopThing() or tile)
          end
        end
      end
      MACHINE_STATE.actionWaitUntil = os.clock() + 1.0 -- Espera 1000ms
      return
    end

    if reachedAction == WAYPOINT_TYPE.SHOVEL then
      if g_map then
        local tPos = { x = target.x, y = target.y, z = target.z }
        local tile = g_map.getTile(tPos)
        if tile then
          local shovel = cavebot.findShovel()
          if shovel then
            g_game.useWith(shovel, tile:getTopUseThing() or tile:getTopThing() or tile)
          end
        end
      end
      MACHINE_STATE.actionWaitUntil = os.clock() + 1.0 -- Espera 1000ms
      return
    end

    -- Stand e outros: sem delay, continua direto
    -- Node e Walk: continua direto para FASE 8

    -- Node e Walk: continua direto para FASE 8 sem delay
    -- Atualiza o target para o novo waypoint
    target = waypoints[MACHINE_STATE.currentIndex]
    target.x = tonumber(target.x)
    target.y = tonumber(target.y)
    target.z = tonumber(target.z)
  end

  -- ========================================================================
  -- FASE 8: MOVIMENTAÇÃO (com sistema de tentativas como ZeroBot)
  -- ========================================================================
  target = waypoints[MACHINE_STATE.currentIndex]
  local targetPos = { x = tonumber(target.x), y = tonumber(target.y), z = tonumber(target.z) }

  -- Atualiza status
  if MACHINE_UTILS.monsterCount > 0 then
    MACHINE_STATE.lastStatus = "Kiting"
  else
    MACHINE_STATE.lastStatus = "Walking"
  end

  -- Smart Retargeting para NODE bloqueado
  local effectiveTarget = targetPos
  if target.action == WAYPOINT_TYPE.NODE then
    local tile = g_map.getTile(targetPos)
    local isBlocked = false

    if not tile or not tile:isWalkable() or tileHasFloorChange(tile) then
      isBlocked = true
    else
      local creatures = tile:getCreatures()
      if creatures and #creatures > 0 then
        for _, c in ipairs(creatures) do
          if c:isMonster() and not c:isDead() then
            isBlocked = true
            break
          end
        end
      end
    end

    if isBlocked then
      local neighbors = {
        { x = 0, y = -1 }, { x = 1, y = -1 }, { x = 1, y = 0 }, { x = 1, y = 1 },
        { x = 0, y = 1 }, { x = -1, y = 1 }, { x = -1, y = 0 }, { x = -1, y = -1 }
      }
      local bestDist = 99999
      local bestPos = nil

      for _, n in ipairs(neighbors) do
        local candidate = { x = targetPos.x + n.x, y = targetPos.y + n.y, z = targetPos.z }
        local cTile = g_map.getTile(candidate)
        if cTile and cTile:isWalkable() and not tileHasFloorChange(cTile) then
          local d = cavebot.getDistance(playerPos, candidate)
          if d < bestDist then
            bestDist = d
            bestPos = candidate
          end
        end
      end

      if bestPos then
        effectiveTarget = bestPos
      end
    end
  end

  -- Decide método de movimento baseado na configuração walkMethod
  local walkMethod = defaultConfig.walkMethod or 'Map Click'

  -- canWalk e canWalkAgain só são necessários para keyboard (passo a passo)
  -- Map Click usa autoWalk que tem controle interno de timing
  if walkMethod == 'Keyboard' then
    -- Keyboard: usa onPositionChange (evento do servidor) para liberar próximo passo.
    -- serverConfirmedWalk é setado true pelo onPositionChange do LocalPlayer.
    local now = os.clock()
    local elapsed = (now - MACHINE_TIMERS.lastWalk) * 1000

    if MACHINE_TIMERS.lastWalkPos and not MACHINE_TIMERS.serverConfirmedWalk then
      -- Servidor ainda não confirmou o passo anterior
      -- Safety: se passou muito tempo (>500ms), tenta novamente (anti-stuck)
      if elapsed < 500 then
        return
      end
    end

    -- Servidor confirmou (ou primeiro passo). Aplica walkDelay de kiting se necessário.
    if MACHINE_TIMERS.serverConfirmedWalk then
      local walkDelay = defaultConfig.walkDelay or 0
      local minMonstersToWait = defaultConfig.minMonstersToWait or 2
      if walkDelay > 0 and MACHINE_UTILS.monsterCount >= minMonstersToWait then
        if elapsed < walkDelay then
          return
        end
      end
    end

    -- Reseta flag para o próximo passo
    MACHINE_TIMERS.serverConfirmedWalk = false
  end

  -- PathFindFlags (const.h):
  --   1  = AllowNotSeenTiles
  --   2  = AllowCreatures
  --   4  = AllowNonPathable (fields/avoid)
  --   16 = IgnoreCreatures (criaturas não tornam tile unwalkable, mas hasCreature ainda detecta)
  --   32 = BlockFloorChange (bloqueia escadas no PATH, nao no goal)

  -- Flags base: AllowNotSeenTiles + AllowNonPathable + IgnoreCreatures + BlockFloorChange
  -- IgnoreCreatures(16) faz isWalkable() ignorar criaturas, permitindo achar caminho em caves
  -- A detecção de criaturas é feita manualmente no Lua (primeiros tiles do path)
  -- BlockFloorChange(32) impede o A* de rotear por escadas/rampas (floorchange)
  -- Tiles com floorchange só são usados se forem o destino (waypoint configurado no sqm)
  local pathFlags = 53 -- 1 + 4 + 16 + 32 (AllowNotSeenTiles + AllowNonPathable + IgnoreCreatures + BlockFloorChange)

  local useKeyboard = (walkMethod == 'Keyboard')

  if useKeyboard then
    -- KEYBOARD: Anda tecla por tecla, desviando de criaturas

    -- Flags SEM IgnoreCreatures: criaturas bloqueiam tiles (desvio real)
    local strictFlags = bit.band(pathFlags, bit.bnot(16)) -- Remove IgnoreCreatures(16)
    local dir = nil

    -- 1) Tenta findPath sem IgnoreCreatures (complexidade baixa) — desvia de criaturas
    local success, path = pcall(function()
      return g_map.findPath(playerPos, effectiveTarget, 1000, strictFlags)
    end)
    if success and path and #path > 0 then
      dir = path[1]
    end

    -- 2) Se falhou, tenta com IgnoreCreatures (complexidade alta) — rota longa ignorando criaturas
    if not dir then
      success, path = pcall(function()
        return g_map.findPath(playerPos, effectiveTarget, 40000, pathFlags)
      end)
      if success and path and #path > 0 then
        -- Verifica se o primeiro tile está livre de criaturas
        local nextPos = cavebot.applyDirection(playerPos, path[1])

        if not cavebot.hasCreatureBlocking(nextPos) then
          dir = path[1]
        end
      end
    end

    -- 3) Executa o passo
    if dir then
      g_game.walk(dir)
      cavebot.registerWalkStep()
    end
    return
  else
    -- MAP CLICK: Usa autoWalk diretamente (clica no mapa)
    local isWalking = player.isAutoWalking and player:isAutoWalking()

    -- Verifica se há criatura bloqueando os PRÓXIMOS tiles do caminho (até 3 tiles)
    -- Criaturas distantes se movem e não precisam ser evitadas agora
    -- findPath usa IgnoreCreatures(16), então encontra caminho ignorando criaturas
    local creatureInPath = false
    local success, path = pcall(function()
      return g_map.findPath(playerPos, effectiveTarget, 40000, pathFlags)
    end)
    if success and path and #path > 0 then
      local checkPos = { x = playerPos.x, y = playerPos.y, z = playerPos.z }
      local maxCheck = math.min(#path, 3) -- Só verifica os primeiros 3 tiles
      for step = 1, maxCheck do
        checkPos = cavebot.applyDirection(checkPos, path[step])
        if cavebot.hasCreatureBlocking(checkPos) then
          creatureInPath = true
          break
        end
      end
    end

    if not isWalking or creatureInPath then
      if creatureInPath and isWalking then
        player:stopAutoWalk()
      end

      if player.autoWalk then
        player:autoWalk(effectiveTarget, false, false, pathFlags)
      else
        g_game.autoWalk(effectiveTarget)
      end
    end

    MACHINE_TIMERS.lastWalk = os.clock()
    return
  end
end

-- Retorna o intervalo do tick do walker
function cavebot.getTickInterval()
  return 10
end

-- Inicia o walker como cycleEvent
function cavebot.startWalking()
  if walkEvent then
    removeEvent(walkEvent)
    walkEvent = nil
  end
  walkEvent = cycleEvent(cavebot.walkerTick, cavebot.getTickInterval())
end

function cavebot.stopWalking()
  if walkEvent then
    removeEvent(walkEvent)
    walkEvent = nil
  end
  local player = g_game.getLocalPlayer()
  if player then
    player:stopAutoWalk()
  end
  g_game.stop()

  -- Reseta estados do MACHINE_STATE
  MACHINE_STATE.pausedByMonsters = false
  MACHINE_STATE.lastFreeze = 0
  MACHINE_STATE.isStuck = false
  MACHINE_STATE.lastStatus = "Stopped"
end

-- ============================================================================
-- FUNÇÕES DE ACESSO PARA COMPATIBILIDADE E UI
-- ============================================================================

-- Retorna se o cavebot está habilitado
function cavebot.isEnabled()
  return MACHINE_STATE.isRunning
end

-- Retorna o índice atual
function cavebot.getCurrentIndex()
  return MACHINE_STATE.currentIndex
end

-- Retorna o status atual
function cavebot.getStatus()
  return MACHINE_STATE.lastStatus
end

-- Retorna dados de monstros
function cavebot.getMonsterData()
  return {
    count = MACHINE_UTILS.monsterCount,
    lifePercentage = MACHINE_UTILS.lifePercentage,
    monsters = MACHINE_UTILS.monsters
  }
end

-- Retorna dados de delay
function cavebot.getDelayInfo()
  local player = g_game.getLocalPlayer()
  local stepDuration = 100
  if player and player.getStepDuration then
    stepDuration = player:getStepDuration() or 100
  end
  return {
    currentDelay = MACHINE_TIMERS.currentDelay,
    ping = MACHINE_UTILS.getPing(),
    stepDuration = stepDuration
  }
end

-- Atualiza o progresso do cavebot no minimap
function cavebot.updateMinimapProgress()
  local minimapWindow = modules.game_minimap and modules.game_minimap.getMinimapWindow and
      modules.game_minimap.getMinimapWindow()
  if not minimapWindow then
    minimapWindow = g_ui.getRootWidget():recursiveGetChildById('minimapWindow')
  end
  if not minimapWindow then return end

  local progressLabel = minimapWindow:recursiveGetChildById('cavebotProgress')
  local minimapWidget = minimapWindow:recursiveGetChildById('minimap')
  local waypointMarker = minimapWidget and minimapWidget:getChildById('currentWaypointMarker')

  if cavebot.isRecording() then
    -- Mostra "Recording" quando estiver gravando
    if progressLabel then
      progressLabel:setText(tr('Recording'))
      progressLabel:show()
    end
    if waypointMarker then
      waypointMarker:hide()
    end
  elseif MACHINE_STATE.isRunning and #waypoints > 0 then
    -- Atualiza label de progresso
    if progressLabel then
      progressLabel:setText(string.format("%d/%d", MACHINE_STATE.currentIndex, #waypoints))
      progressLabel:show()
    end

    -- Atualiza marcador do waypoint atual
    if waypointMarker and minimapWidget and minimapWidget.centerInPosition then
      local currentWp = waypoints[MACHINE_STATE.currentIndex]
      if currentWp then
        local pos = {
          x = tonumber(currentWp.x),
          y = tonumber(currentWp.y),
          z = tonumber(currentWp.z)
        }
        minimapWidget:centerInPosition(waypointMarker, pos)
        waypointMarker:show()
      else
        waypointMarker:hide()
      end
    end
  else
    if progressLabel then
      progressLabel:hide()
    end
    if waypointMarker then
      waypointMarker:hide()
    end
  end
end
