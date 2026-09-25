-- Pure auto-loot decisions. No UI or game globals, so the rules can be tested on their own.

local Logic = {}

local function addId(list, set, id)
    id = tonumber(id)
    if not id or id < 100 or set[id] then
        return
    end
    set[id] = true
    list[#list + 1] = id
end

function Logic.parseIdList(value)
    local list = {}
    local set = {}
    if type(value) == 'string' then
        for token in value:gmatch('%d+') do
            addId(list, set, token)
        end
    elseif type(value) == 'table' then
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            local na, nb = tonumber(a), tonumber(b)
            if na and nb then
                return na < nb
            end
            return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(keys) do
            addId(list, set, value[key])
        end
    end
    return list, set
end

function Logic.formatIdList(list)
    if type(list) ~= 'table' then
        return ''
    end
    local parts = {}
    for _, id in ipairs(list) do
        id = tonumber(id)
        if id and id >= 100 then
            parts[#parts + 1] = tostring(math.floor(id))
        end
    end
    return table.concat(parts, ',')
end

function Logic.asBool(value)
    return value == true or value == 1 or value == '1' or value == 'true'
end

function Logic.clampNumber(value, minValue, maxValue, fallback)
    local number = tonumber(value)
    if not number then
        return fallback
    end
    number = math.floor(number)
    if number < minValue then
        return minValue
    end
    if number > maxValue then
        return maxValue
    end
    return number
end

-- Whitelist: take listed items, including listed bags.
-- Loot-all: take every non-container that is not listed (the list is an ignore list).
-- Nested bags are opened by the caller, not taken, unless they are explicitly listed.
function Logic.shouldTakeItem(itemId, isContainer, lootAll, itemSet)
    itemId = tonumber(itemId)
    if not itemId or itemId < 100 then
        return false
    end
    local listed = type(itemSet) == 'table' and itemSet[itemId] == true
    if lootAll then
        if isContainer then
            return false
        end
        return not listed
    end
    return listed
end

function Logic.shouldOpenNested(itemId, isContainer, itemSet)
    itemId = tonumber(itemId)
    if not isContainer or not itemId or itemId < 100 then
        return false
    end
    if type(itemSet) == 'table' and itemSet[itemId] then
        return false
    end
    return true
end

function Logic.chebyshev(a, b)
    if not a or not b or a.x == nil or b.x == nil or a.z ~= b.z then
        return nil
    end
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

function Logic.positionKey(pos)
    if not pos or pos.x == nil or pos.y == nil or pos.z == nil then
        return nil
    end
    if pos.x <= 0 or pos.x >= 65535 or pos.y <= 0 or pos.y >= 65535 then
        return nil
    end
    return string.format('%d,%d,%d', pos.x, pos.y, pos.z)
end

function Logic.isOwnerDenied(text)
    if type(text) ~= 'string' then
        return false
    end
    return text:lower():find('not the owner', 1, true) ~= nil
end

function Logic.corpseShouldDrop(entry, playerPos, now, maxDistance, maxAgeMs)
    if not entry or not entry.pos or not playerPos then
        return true
    end
    if entry.pos.z ~= playerPos.z then
        return true
    end
    local distance = Logic.chebyshev(playerPos, entry.pos)
    if not distance or distance > maxDistance then
        return true
    end
    if entry.added and now and maxAgeMs and (now - entry.added) > maxAgeMs then
        return true
    end
    return false
end

-- containers: { items = { {id, count, slot} }, itemsCount, capacity, hasPages }
-- Returns { containerIndex, slot, count } using a 0-based slot, or nil when every destination is full.
function Logic.pickMove(item, containers)
    if not item or not item.id or type(containers) ~= 'table' or not containers[1] then
        return nil
    end
    local itemCount = tonumber(item.count) or 1
    if itemCount < 1 then
        itemCount = 1
    end

    if item.stackable then
        for index, container in ipairs(containers) do
            for _, stored in ipairs(container.items or {}) do
                local storedCount = tonumber(stored.count) or 1
                if stored.id == item.id and stored.slot ~= nil and storedCount < 100 then
                    local room = 100 - storedCount
                    local count = math.min(itemCount, room)
                    if count > 0 then
                        return {
                            containerIndex = index,
                            slot = stored.slot,
                            count = count
                        }
                    end
                end
            end
        end
    end

    for index, container in ipairs(containers) do
        local count = tonumber(container.itemsCount) or 0
        local capacity = tonumber(container.capacity) or 0
        if count < capacity or container.hasPages then
            return {
                containerIndex = index,
                slot = count,
                count = item.stackable and itemCount or 1
            }
        end
    end

    return nil
end

return Logic
