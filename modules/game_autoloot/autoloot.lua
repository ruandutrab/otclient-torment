local Logic = dofile('autoloot_logic')

local ITEM_SLOTS = 10
local CONTAINER_SLOTS = 5
local LOOP_MS = 150
local CORPSE_MAX_AGE = 20000
local QUEUE_MAX = 20
local SETTINGS_KEY = 'autoLoot'

autoLootWindow = nil
autoLootButton = nil

local settings = {
    enabled = false,
    lootAll = false,
    walkToCorpse = false,
    maxDistance = 6,
    minCapacity = 0,
    lootDelay = 250,
    items = {},
    itemSet = {},
    containers = {},
    containerSet = {}
}

local itemSlots = {}
local containerSlots = {}
local queue = {}
local recentDeaths = {}
local connected = false
local applying = false
local loopEvent = nil
local activeContainer = nil
local waitingForId = nil
local waitUntil = 0
local statusText = 'Idle'

local function nowMs()
    if g_clock and g_clock.millis then
        return g_clock.millis()
    end
    return 0
end

local function widgetById(id)
    if not autoLootWindow then
        return nil
    end
    return autoLootWindow:recursiveGetChildById(id)
end

local function setStatus(text)
    statusText = text
    local label = widgetById('status')
    if label then
        label:setText(text)
    end
end

local function playerPos()
    local player = g_game.getLocalPlayer()
    if not player then
        return nil, player
    end
    local pos = player:getPosition()
    if not pos then
        return nil, player
    end
    return { x = pos.x, y = pos.y, z = pos.z }, player
end

local function inProtectionZone(player)
    if not player or not player.hasState or not PlayerStates then
        return false
    end
    if PlayerStates.Pz and player:hasState(PlayerStates.Pz) then
        return true
    end
    if PlayerStates.PzBlock and player:hasState(PlayerStates.PzBlock) then
        return true
    end
    return false
end

local function hasCapacity(player)
    if not player or not player.getFreeCapacity then
        return true
    end
    local free = player:getFreeCapacity()
    if free == nil then
        return true
    end
    return free >= settings.minCapacity
end

local function recentManualWalk()
    local interface = modules.game_interface
    local last = interface and interface.lastManualWalk
    if type(last) ~= 'number' or last <= 0 then
        return false
    end
    return nowMs() - last < 400
end

local function readSlots(slots)
    local list = {}
    local set = {}
    for _, widget in ipairs(slots) do
        local id = widget and widget.getItemId and widget:getItemId() or 0
        if id >= 100 and not set[id] then
            set[id] = true
            list[#list + 1] = id
        end
    end
    return list, set
end

local function saveSettings()
    if applying then
        return
    end
    settings.items, settings.itemSet = readSlots(itemSlots)
    settings.containers, settings.containerSet = readSlots(containerSlots)
    g_settings.setNode(SETTINGS_KEY, {
        enabled = settings.enabled,
        lootAll = settings.lootAll,
        walkToCorpse = settings.walkToCorpse,
        maxDistance = settings.maxDistance,
        minCapacity = settings.minCapacity,
        lootDelay = settings.lootDelay,
        items = Logic.formatIdList(settings.items),
        containers = Logic.formatIdList(settings.containers)
    })
end

local function loadSettings()
    local stored = g_settings.getNode(SETTINGS_KEY) or {}
    settings.enabled = Logic.asBool(stored.enabled)
    settings.lootAll = Logic.asBool(stored.lootAll)
    settings.walkToCorpse = Logic.asBool(stored.walkToCorpse)
    settings.maxDistance = Logic.clampNumber(stored.maxDistance, 1, 30, 6)
    settings.minCapacity = Logic.clampNumber(stored.minCapacity, 0, 10000000, 0)
    settings.lootDelay = Logic.clampNumber(stored.lootDelay, 50, 2000, 250)
    settings.items, settings.itemSet = Logic.parseIdList(stored.items)
    settings.containers, settings.containerSet = Logic.parseIdList(stored.containers)
end

local function updateItemsLabel()
    local label = widgetById('itemsLabel')
    if label then
        label:setText(settings.lootAll and tr('Items to ignore') or tr('Items to loot'))
    end
end

local function applySlotIds(slots, ids)
    for index, widget in ipairs(slots) do
        local id = ids[index] or 0
        pcall(function()
            widget:setItemId(id)
        end)
    end
end

local function applySettingsToUi()
    if not autoLootWindow then
        return
    end
    applying = true
    widgetById('enabled'):setChecked(settings.enabled)
    widgetById('lootAll'):setChecked(settings.lootAll)
    widgetById('walkToCorpse'):setChecked(settings.walkToCorpse)
    widgetById('maxDistance'):setText(tostring(settings.maxDistance))
    widgetById('lootDelay'):setText(tostring(settings.lootDelay))
    applySlotIds(itemSlots, settings.items)
    applySlotIds(containerSlots, settings.containers)
    updateItemsLabel()
    applying = false
end

local function clearQueue()
    queue = {}
    recentDeaths = {}
    activeContainer = nil
    waitingForId = nil
    waitUntil = 0
end

local function removeQueueIndex(index)
    table.remove(queue, index or 1)
end

local function queueCorpse(creature, requireCorpseFlag)
    if not settings.enabled or not creature or not creature.isMonster or not creature:isMonster() then
        return
    end
    local rawPos = creature:getPosition()
    if not rawPos then
        return
    end
    local pos = { x = rawPos.x, y = rawPos.y, z = rawPos.z }
    local key = Logic.positionKey(pos)
    if not key then
        return
    end
    local playerPosition = playerPos()
    if not playerPosition or playerPosition.z ~= pos.z then
        return
    end
    local distance = Logic.chebyshev(playerPosition, pos)
    if not distance or distance > settings.maxDistance then
        return
    end
    if #queue >= QUEUE_MAX then
        return
    end
    for _, entry in ipairs(queue) do
        if entry.key == key then
            return
        end
    end

    local position = rawPos
    scheduleEvent(function()
        if not settings.enabled or not g_game.isOnline() then
            return
        end
        for _, entry in ipairs(queue) do
            if entry.key == key then
                return
            end
        end
        local tile = g_map.getTile(position)
        if not tile then
            return
        end
        local thing = tile.getTopUseThing and tile:getTopUseThing() or nil
        if not thing or not thing.isContainer or not thing:isContainer() then
            return
        end
        if requireCorpseFlag and thing.isLyingCorpse and not thing:isLyingCorpse() then
            return
        end
        if #queue >= QUEUE_MAX then
            return
        end
        queue[#queue + 1] = {
            key = key,
            pos = pos,
            position = position,
            containerId = thing:getId(),
            added = nowMs(),
            tries = 0
        }
        if thing.setMarked then
            pcall(function()
                thing:setMarked('#000088')
            end)
        end
    end, 50)
end

local function describeContainer(container)
    local items = {}
    local contents = container:getItems() or {}
    for slot, item in ipairs(contents) do
        if item then
            items[#items + 1] = {
                id = item:getId(),
                count = item.getCount and item:getCount() or 1,
                slot = slot - 1
            }
        end
    end
    local containerItem = container.getContainerItem and container:getContainerItem() or nil
    return {
        container = container,
        items = items,
        itemsCount = container:getItemsCount(),
        capacity = container:getCapacity(),
        hasPages = container.hasPages and container:hasPages() or false,
        containerItemId = containerItem and containerItem:getId() or 0
    }
end

local function collectDestinations()
    local opened = g_game.getContainers() or {}
    local openedById = {}
    local destinations = {}
    local nested = nil

    for _, container in pairs(opened) do
        if container and container.getContainerItem then
            local containerItem = container:getContainerItem()
            if containerItem then
                local containerId = containerItem:getId()
                openedById[containerId] = true
                if settings.containerSet[containerId] and not container.autoLoot then
                    local described = describeContainer(container)
                    if described.itemsCount < described.capacity or described.hasPages then
                        destinations[#destinations + 1] = described
                    elseif not nested then
                        for _, item in ipairs(container:getItems() or {}) do
                            if item and item.isContainer and item:isContainer() and settings.containerSet[item:getId()] then
                                nested = { item = item, parent = container }
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    return destinations, nested, openedById, opened
end

local function openFallbackContainer(openedById, opened)
    for _, container in pairs(opened) do
        if container and container.getContainerItem and container.getItems then
            local containerItem = container:getContainerItem()
            if containerItem and not settings.containerSet[containerItem:getId()] and not container.autoLoot then
                for _, item in ipairs(container:getItems() or {}) do
                    if item and item.isContainer and item:isContainer() and settings.containerSet[item:getId()] then
                        g_game.open(item, container)
                        waitUntil = nowMs() + math.max(settings.lootDelay, 400)
                        setStatus('Opening backpack')
                        return true
                    end
                end
            end
        end
    end

    local player = g_game.getLocalPlayer()
    if not player or not player.getInventoryItem then
        return false
    end
    local firstSlot = InventorySlotFirst or 1
    local lastSlot = InventorySlotLast or 10
    for slot = firstSlot, lastSlot do
        local item = player:getInventoryItem(slot)
        if item and item.isContainer and item:isContainer() and settings.containerSet[item:getId()] and not openedById[item:getId()] then
            g_game.open(item)
            waitUntil = nowMs() + math.max(settings.lootDelay, 400)
            setStatus('Opening backpack')
            return true
        end
    end
    return false
end

local function finishCorpse(container)
    if container then
        container.autoLoot = false
        pcall(function()
            g_game.close(container)
        end)
    end
    if activeContainer == container then
        activeContainer = nil
    end
    waitingForId = nil
    removeQueueIndex(1)
end

local function lootOpenContainer(container, destinations)
    local describedItems = container:getItems() or {}
    local nested = nil
    for slot, item in ipairs(describedItems) do
        if item then
            local itemId = item:getId()
            local isContainer = item.isContainer and item:isContainer() or false
            if Logic.shouldOpenNested(itemId, isContainer, settings.itemSet) then
                nested = nested or item
            elseif Logic.shouldTakeItem(itemId, isContainer, settings.lootAll, settings.itemSet) then
                item.autoLootTries = (item.autoLootTries or 0) + 1
                if item.autoLootTries <= 5 then
                    local move = Logic.pickMove({
                        id = itemId,
                        count = item.getCount and item:getCount() or 1,
                        stackable = item.isStackable and item:isStackable() or false
                    }, destinations)
                    if not move then
                        setStatus('No space')
                        return false
                    end
                    local destination = destinations[move.containerIndex]
                    g_game.move(item, destination.container:getSlotPosition(move.slot), move.count)
                    waitUntil = nowMs() + settings.lootDelay
                    setStatus('Looting')
                    return true
                end
            end
        end
    end

    if nested then
        nested.autoLootTries = (nested.autoLootTries or 0) + 1
        if nested.autoLootTries <= 2 then
            waitingForId = nested:getId()
            g_game.open(nested, container)
            waitUntil = nowMs() + settings.lootDelay
            setStatus('Opening bag')
            return true
        end
    end

    finishCorpse(container)
    setStatus('Idle')
    return true
end

local function process()
    if not settings.enabled or not g_game.isOnline() then
        setStatus('Idle')
        return
    end

    local pos, player = playerPos()
    if not pos or not player then
        return
    end
    if inProtectionZone(player) then
        setStatus('Protection zone')
        return
    end
    if not hasCapacity(player) then
        setStatus('No capacity')
        return
    end
    if not settings.containerSet or not next(settings.containerSet) then
        setStatus('Set a backpack')
        return
    end
    if not settings.lootAll and (not settings.itemSet or not next(settings.itemSet)) then
        setStatus('Set items to loot')
        return
    end

    local now = nowMs()
    if now < waitUntil then
        return
    end

    for key, seenAt in pairs(recentDeaths) do
        if now - seenAt > 5000 then
            recentDeaths[key] = nil
        end
    end

    if activeContainer and activeContainer.isClosed and not activeContainer:isClosed() then
        local destinations, nested, openedById, opened = collectDestinations()
        if not destinations[1] then
            if nested then
                g_game.open(nested.item, nested.parent)
                waitUntil = now + math.max(settings.lootDelay, 400)
                setStatus('Opening backpack')
                return
            end
            if openFallbackContainer(openedById, opened) then
                return
            end
            setStatus('No space')
            return
        end
        lootOpenContainer(activeContainer, destinations)
        return
    end
    activeContainer = nil

    local entry = queue[1]
    if not entry then
        if statusText ~= 'No space' and statusText ~= 'Opening backpack' then
            setStatus('Idle')
        end
        return
    end
    if Logic.corpseShouldDrop(entry, pos, now, settings.maxDistance, CORPSE_MAX_AGE) then
        removeQueueIndex(1)
        waitingForId = nil
        return
    end

    local distance = Logic.chebyshev(pos, entry.pos) or 99
    if distance > 1 then
        local attacking = g_game.getAttackingCreature and g_game.getAttackingCreature() or nil
        if settings.walkToCorpse and not attacking and not recentManualWalk() and entry.position then
            if not entry.walkAt or now - entry.walkAt > 1000 then
                if player.autoWalk then
                    player:autoWalk(entry.position)
                end
                entry.walkAt = now
            end
            setStatus('Walking')
        end
        return
    end

    if entry.tries > 8 then
        removeQueueIndex(1)
        waitingForId = nil
        return
    end

    local tile = entry.position and g_map.getTile(entry.position) or nil
    local thing = tile and tile.getTopUseThing and tile:getTopUseThing() or nil
    if not thing or not thing.isContainer or not thing:isContainer() then
        removeQueueIndex(1)
        return
    end

    waitingForId = thing:getId()
    g_game.open(thing)
    waitUntil = now + settings.lootDelay
    entry.tries = entry.tries + 1
    setStatus('Opening corpse')
end

local function ensureLoop()
    if loopEvent then
        return
    end
    loopEvent = scheduleEvent(function()
        loopEvent = nil
        local ok, err = pcall(process)
        if not ok then
            g_logger.error('Auto loot failed: ' .. tostring(err))
            setStatus('Error')
        end
        if settings.enabled and g_game.isOnline() then
            ensureLoop()
        end
    end, LOOP_MS)
end

local function stopLoop()
    if loopEvent then
        removeEvent(loopEvent)
        loopEvent = nil
    end
end

function onTextMessage(mode, text)
    if not settings.enabled or #queue == 0 then
        return
    end
    if not Logic.isOwnerDenied(text) then
        return
    end
    if activeContainer then
        activeContainer.autoLoot = false
        activeContainer = nil
    end
    waitingForId = nil
    removeQueueIndex(1)
end

function onContainerOpen(container)
    if not container or not container.getContainerItem then
        return
    end
    local containerItem = container:getContainerItem()
    if not containerItem or not waitingForId then
        return
    end
    if containerItem:getId() ~= waitingForId then
        return
    end
    container.autoLoot = true
    activeContainer = container
    waitingForId = nil
    setStatus('Looting')
end

function onContainerClose(container)
    if container and container == activeContainer then
        activeContainer = nil
    end
end

function onHealthPercentChange(creature, healthPercent)
    if not settings.enabled or not healthPercent or healthPercent > 0 then
        return
    end
    if not creature or not creature.isMonster or not creature:isMonster() then
        return
    end
    local pos = creature:getPosition()
    local key = pos and Logic.positionKey({ x = pos.x, y = pos.y, z = pos.z }) or nil
    if key then
        recentDeaths[key] = nowMs()
    end
    queueCorpse(creature, false)
end

function onCreatureDisappear(creature)
    if not settings.enabled or not creature or not creature.isMonster or not creature:isMonster() then
        return
    end
    local pos = creature:getPosition()
    local key = pos and Logic.positionKey({ x = pos.x, y = pos.y, z = pos.z }) or nil
    local sawDeath = key and recentDeaths[key] and (nowMs() - recentDeaths[key] < 2000)
    queueCorpse(creature, not sawDeath)
end

local function connectEvents()
    if connected then
        return
    end
    connect(g_game, { onTextMessage = onTextMessage })
    connect(Creature, {
        onDisappear = onCreatureDisappear,
        onHealthPercentChange = onHealthPercentChange
    })
    connect(Container, {
        onOpen = onContainerOpen,
        onClose = onContainerClose
    })
    connected = true
end

local function disconnectEvents()
    if not connected then
        return
    end
    disconnect(g_game, { onTextMessage = onTextMessage })
    disconnect(Creature, {
        onDisappear = onCreatureDisappear,
        onHealthPercentChange = onHealthPercentChange
    })
    disconnect(Container, {
        onOpen = onContainerOpen,
        onClose = onContainerClose
    })
    connected = false
end

local function onSlotItemChange()
    if applying then
        return
    end
    saveSettings()
end

local function bindSlot(widget)
    widget.onItemChange = onSlotItemChange
    widget.onMouseRelease = function(w, mousePos, mouseButton)
        if mouseButton == MouseRightButton then
            w:setItemId(0)
            return true
        end
        return false
    end
end

local function createSlots(panel, count)
    local slots = {}
    for _ = 1, count do
        local widget = g_ui.createWidget('AutoLootItem', panel)
        bindSlot(widget)
        slots[#slots + 1] = widget
    end
    return slots
end

local function hideExtraButtons(window)
    for _, id in ipairs({ 'toggleFilterButton', 'contextMenuButton', 'newWindowButton' }) do
        local widget = window:recursiveGetChildById(id)
        if widget then
            widget:setVisible(false)
        end
    end
    local lockButton = window:recursiveGetChildById('lockButton')
    local minimizeButton = window:recursiveGetChildById('minimizeButton')
    if lockButton and minimizeButton then
        lockButton:breakAnchors()
        lockButton:addAnchor(AnchorTop, minimizeButton:getId(), AnchorTop)
        lockButton:addAnchor(AnchorRight, minimizeButton:getId(), AnchorLeft)
        lockButton:setMarginRight(7)
        lockButton:setMarginTop(0)
    end
end

function onMiniWindowOpen()
    if autoLootButton then
        autoLootButton:setOn(true)
    end
end

function onMiniWindowClose()
    if autoLootButton then
        autoLootButton:setOn(false)
    end
end

function toggle()
    if not autoLootWindow then
        return
    end
    if autoLootWindow:isVisible() then
        autoLootWindow:close()
    else
        if not autoLootWindow:getParent() then
            local panel = modules.game_interface.findContentPanelAvailable(autoLootWindow, autoLootWindow:getMinimumHeight())
            if not panel then
                return
            end
            panel:addChild(autoLootWindow)
        end
        autoLootWindow:open()
    end
end

local function online()
    connectEvents()
    applySettingsToUi()
    if settings.enabled then
        ensureLoop()
    end
end

local function offline()
    stopLoop()
    disconnectEvents()
    clearQueue()
    setStatus('Idle')
end

function init()
    loadSettings()

    autoLootWindow = g_ui.loadUI('autoloot')
    autoLootWindow:setup()
    hideExtraButtons(autoLootWindow)

    itemSlots = createSlots(widgetById('items'), ITEM_SLOTS)
    containerSlots = createSlots(widgetById('containers'), CONTAINER_SLOTS)

    widgetById('enabled').onCheckChange = function(widget)
        if applying then
            return
        end
        settings.enabled = widget:isChecked()
        saveSettings()
        if settings.enabled and g_game.isOnline() then
            connectEvents()
            ensureLoop()
        else
            clearQueue()
            setStatus('Idle')
        end
    end
    widgetById('lootAll').onCheckChange = function(widget)
        if applying then
            return
        end
        settings.lootAll = widget:isChecked()
        updateItemsLabel()
        saveSettings()
    end
    widgetById('walkToCorpse').onCheckChange = function(widget)
        if applying then
            return
        end
        settings.walkToCorpse = widget:isChecked()
        saveSettings()
    end
    local function onNumberChange(widget, key, minValue, maxValue, fallback)
        if applying then
            return
        end
        settings[key] = Logic.clampNumber(widget:getText(), minValue, maxValue, fallback)
        saveSettings()
    end
    widgetById('maxDistance').onTextChange = function(widget)
        onNumberChange(widget, 'maxDistance', 1, 30, 6)
    end
    widgetById('lootDelay').onTextChange = function(widget)
        onNumberChange(widget, 'lootDelay', 50, 2000, 250)
    end

    autoLootButton = modules.game_mainpanel.addToggleButton('autoLootButton', tr('Auto Loot'),
        '/game_autoloot/images/button', toggle, false, 8)

    applySettingsToUi()

    connect(g_game, {
        onGameStart = online,
        onGameEnd = offline
    })

    if g_game.isOnline() then
        online()
    end
end

function terminate()
    stopLoop()
    disconnectEvents()
    disconnect(g_game, {
        onGameStart = online,
        onGameEnd = offline
    })
    clearQueue()
    if autoLootButton then
        autoLootButton:destroy()
        autoLootButton = nil
    end
    if autoLootWindow then
        autoLootWindow:destroy()
        autoLootWindow = nil
    end
end
