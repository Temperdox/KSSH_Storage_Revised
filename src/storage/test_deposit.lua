-- test_deposit.lua
-- Simple test to verify deposit works without the complex executor

-- Find peripherals
local inputChest = nil
local storageChests = {}

for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    local pType = peripheral.getType(name)

    if pType == "minecraft:chest" then
        inputChest = p
        print("Input chest found: " .. name)
    elseif pType == "minecraft:barrel" then
        table.insert(storageChests, {
            peripheral = p,
            name = name
        })
        print("Storage found: " .. name)
    end
end

if not inputChest then
    print("ERROR: No input chest found!")
    return
end

if #storageChests == 0 then
    print("ERROR: No storage chests found!")
    return
end

-- Count items in input
local inputCount = 0
for slot = 1, inputChest.size() do
    local item = inputChest.getItemDetail(slot)
    if item then
        inputCount = inputCount + item.count
        print(string.format("Input slot %d: %dx %s", slot, item.count, item.displayName or item.name))
    end
end

print(string.format("\nTotal items in input: %d", inputCount))

if inputCount == 0 then
    print("No items to deposit!")
    return
end

-- Try to deposit to first storage chest
local targetChest = storageChests[1]
print(string.format("\nTrying to deposit to %s...", targetChest.name))

local totalMoved = 0

for inputSlot = 1, inputChest.size() do
    local item = inputChest.getItemDetail(inputSlot)
    if item then
        print(string.format("Processing %dx %s from slot %d", item.count, item.displayName or item.name, inputSlot))

        -- Try to find empty slot in target
        for targetSlot = 1, targetChest.peripheral.size() do
            if not targetChest.peripheral.getItemDetail(targetSlot) then
                print(string.format("  Found empty target slot %d", targetSlot))

                -- Try to move items
                local moved = inputChest.pushItems(targetChest.name, inputSlot, item.count, targetSlot)

                if moved and moved > 0 then
                    print(string.format("  SUCCESS: Moved %d items!", moved))
                    totalMoved = totalMoved + moved
                    break
                else
                    print(string.format("  FAILED: pushItems returned %s", tostring(moved)))
                end
            end
        end
    end
end

print(string.format("\n=== RESULT: Moved %d items total ===", totalMoved))