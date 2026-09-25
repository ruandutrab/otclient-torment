local Logic = dofile('modules/game_autoloot/autoloot_logic.lua')

local failures = 0

local function expect(condition, message)
    if condition then
        return
    end
    failures = failures + 1
    io.stderr:write('FAIL: ' .. message .. '\n')
end

local items, itemSet = Logic.parseIdList('3031, 3035, 3031, abc, 50')
expect(#items == 2, 'parse keeps unique ids at or above 100')
expect(itemSet[3031] and itemSet[3035] and not itemSet[50], 'parse builds a lookup set')
expect(Logic.formatIdList(items) == '3031,3035', 'format round-trips the whitelist')

local fromTable = Logic.parseIdList({ ['2'] = '3043', ['1'] = 3031 })
expect(fromTable[1] == 3031 and fromTable[2] == 3043, 'numeric table keys stay in order')

expect(Logic.shouldTakeItem(3031, false, false, itemSet), 'whitelist takes a listed item')
expect(not Logic.shouldTakeItem(3492, false, false, itemSet), 'whitelist skips an unlisted item')
expect(Logic.shouldTakeItem(3492, false, true, itemSet), 'loot-all takes an unlisted item')
expect(not Logic.shouldTakeItem(3031, false, true, itemSet), 'loot-all ignores a listed item')
expect(not Logic.shouldTakeItem(2854, true, true, {}), 'loot-all does not take containers')
expect(Logic.shouldTakeItem(2854, true, false, { [2854] = true }), 'whitelist can take a listed bag')
expect(Logic.shouldOpenNested(2854, true, itemSet), 'unlisted bags are opened')
expect(not Logic.shouldOpenNested(3031, false, itemSet), 'plain items are not opened as bags')

expect(Logic.chebyshev({ x = 0, y = 0, z = 7 }, { x = 2, y = 1, z = 7 }) == 2, 'chebyshev distance')
expect(Logic.chebyshev({ x = 0, y = 0, z = 7 }, { x = 0, y = 0, z = 6 }) == nil, 'different floors have no distance')
expect(Logic.positionKey({ x = 100, y = 200, z = 7 }) == '100,200,7', 'position key')
expect(Logic.positionKey({ x = 0, y = 1, z = 7 }) == nil, 'invalid map position is ignored')
expect(Logic.positionKey(nil) == nil, 'missing position is ignored')

expect(Logic.isOwnerDenied('You are not the owner.'), 'owner denial is detected')
expect(not Logic.isOwnerDenied('You looted a gold coin.'), 'loot text is not an owner denial')

expect(Logic.corpseShouldDrop({ pos = { x = 1, y = 1, z = 7 }, added = 0 }, { x = 1, y = 9, z = 7 }, 1000, 6, 20000),
    'far corpses are dropped')
expect(not Logic.corpseShouldDrop({ pos = { x = 1, y = 2, z = 7 }, added = 0 }, { x = 1, y = 1, z = 7 }, 1000, 6, 20000),
    'nearby corpses stay queued')
expect(Logic.corpseShouldDrop({ pos = { x = 1, y = 1, z = 7 }, added = 0 }, { x = 1, y = 1, z = 7 }, 25000, 6, 20000),
    'old corpses are dropped')

local stacked = Logic.pickMove({ id = 3031, count = 40, stackable = true }, {
    { items = { { id = 3031, count = 80, slot = 2 } }, itemsCount = 3, capacity = 20 }
})
expect(stacked and stacked.slot == 2 and stacked.count == 20, 'stackable loot fills the existing stack')

local fresh = Logic.pickMove({ id = 3031, count = 5, stackable = true }, {
    { items = {}, itemsCount = 0, capacity = 20 }
})
expect(fresh and fresh.slot == 0 and fresh.count == 5, 'stackable loot uses the first free slot')

local single = Logic.pickMove({ id = 3264, count = 1, stackable = false }, {
    { items = { { id = 3264, count = 1, slot = 0 } }, itemsCount = 1, capacity = 20 }
})
expect(single and single.slot == 1 and single.count == 1, 'non-stackable loot does not merge')

local full = Logic.pickMove({ id = 3031, count = 1, stackable = true }, {
    { items = { { id = 3031, count = 100, slot = 0 } }, itemsCount = 20, capacity = 20 }
})
expect(full == nil, 'a full backpack cannot accept more loot')

local paged = Logic.pickMove({ id = 3031, count = 1, stackable = false }, {
    { items = {}, itemsCount = 20, capacity = 20, hasPages = true }
})
expect(paged and paged.slot == 20, 'paged containers still accept loot when the page looks full')

expect(Logic.clampNumber('9', 1, 30, 6) == 9, 'numeric text is clamped')
expect(Logic.clampNumber('nope', 1, 30, 6) == 6, 'invalid numbers use the fallback')
expect(Logic.asBool('1') and Logic.asBool(true) and not Logic.asBool(false), 'bool coercion')

if failures > 0 then
    io.stderr:write(failures .. ' assertion(s) failed\n')
    os.exit(1)
end

print('autoloot logic ok')
