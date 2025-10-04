-- Place ingredients in the crafting grid (slots 1-9) and run this program
local function openAnyModems()
    for _, side in ipairs({"left","right","top","bottom","front","back"}) do
        if peripheral.getType(side) == "modem" then
            if not rednet.isOpen(side) then
                pcall(rednet.open, side)
            end
        end
    end
end

local function log(...) print("[recipe]", ...) end

-- Map item IDs to tag categories
local function getItemTag(itemId)
    itemId = itemId:lower()

    -- Check for logs
    if itemId:match("_log$") or itemId:match("_stem$") then
        return "tag:log"
    end

    -- Check for planks
    if itemId:match("_planks$") then
        return "tag:planks"
    end

    -- Check for coal/charcoal
    if itemId == "minecraft:coal" or itemId == "minecraft:charcoal" then
        return "tag:coal"
    end

    -- Check for wood slabs
    if itemId:match("_slab$") and not itemId:match("stone") then
        return "tag:wood_slabs"
    end

    -- Check for wood stairs
    if itemId:match("_stairs$") and not itemId:match("stone") then
        return "tag:wood_stairs"
    end

    -- Check for general wood items
    if itemId:match("wood") or itemId:match("oak") or itemId:match("birch") or
            itemId:match("spruce") or itemId:match("jungle") or itemId:match("acacia") or
            itemId:match("dark_oak") or itemId:match("cherry") or itemId:match("mangrove") or
            itemId:match("bamboo") or itemId:match("crimson") or itemId:match("warped") then
        -- Already handled specific cases above, this is fallback
        return nil
    end

    return nil
end

-- Analyze the 3x3 grid to create pattern and key
local function analyzeGrid()
    local grid = {}
    local uniqueItems = {}
    local symbolMap = {}
    local nextSymbol = 97 -- 'a' in ASCII

    -- Read the 3x3 grid (turtle crafting slots: 1,2,3,5,6,7,9,10,11)
    -- Skip slots 4, 8, 12
    local craftingSlots = {1, 2, 3, 5, 6, 7, 9, 10, 11}
    local gridPos = 1

    for _, slot in ipairs(craftingSlots) do
        local item = turtle.getItemDetail(slot)
        if item then
            local itemKey = item.name .. "@" .. (item.nbt or "")

            -- Assign a symbol if we haven't seen this item yet
            if not symbolMap[itemKey] then
                local symbol = string.char(nextSymbol)
                symbolMap[itemKey] = symbol

                -- Determine if this item should use a tag
                local tag = getItemTag(item.name)
                local useTag = tag ~= nil

                uniqueItems[symbol] = {
                    item = useTag and tag or item.name,
                    wildcard = useTag
                }

                nextSymbol = nextSymbol + 1
            end

            grid[gridPos] = symbolMap[itemKey]
        else
            grid[gridPos] = "e" -- empty
        end

        gridPos = gridPos + 1
    end

    -- Convert grid to recipe pattern (3 strings)
    local recipe = {}
    for row = 0, 2 do
        local rowStr = ""
        for col = 1, 3 do
            local pos = row * 3 + col
            rowStr = rowStr .. (grid[pos] or "e")
            if col < 3 then rowStr = rowStr .. " " end
        end
        table.insert(recipe, rowStr)
    end

    -- Add 'e' for empty to the key
    uniqueItems["e"] = { item = "none" }

    return recipe, uniqueItems
end

-- Get user input for recipe metadata
local function getRecipeInfo()
    print("=== Recipe Learning Mode ===")
    print("Place items in crafting grid (slots 1,2,3,5,6,7,9,10,11)")
    print("Current grid contents:")

    -- Show what's in the grid
    local craftingSlots = {1, 2, 3, 5, 6, 7, 9, 10, 11}
    local gridPos = 1

    for _, slot in ipairs(craftingSlots) do
        local item = turtle.getItemDetail(slot)
        if item then
            local row = math.floor((gridPos - 1) / 3) + 1
            local col = ((gridPos - 1) % 3) + 1
            print(string.format("  [%d,%d]: %s x%d", row, col, item.displayName or item.name, item.count))
        end
        gridPos = gridPos + 1
    end

    print("\nEnter display name for this recipe:")
    local displayName = read()

    print("Is this a wildcard recipe? (outputs different items based on input)")
    print("For example: any planks -> any wood slabs")
    print("(y/n):")
    local wildcardInput = read()
    local isWildcard = (wildcardInput:lower() == "y")

    return displayName, isWildcard
end

-- Main program
local function main()
    openAnyModems()

    -- Get recipe metadata
    local displayName, isWildcard = getRecipeInfo()

    -- Analyze the current grid
    log("Analyzing crafting grid...")
    local recipe, key = analyzeGrid()

    -- Display the pattern for confirmation
    print("\nDetected pattern:")
    for i, row in ipairs(recipe) do
        print("  " .. row)
    end

    print("\nKey mapping:")
    for symbol, data in pairs(key) do
        if symbol ~= "e" then
            print(string.format("  %s = %s%s", symbol, data.item, data.wildcard and " (wildcard)" or ""))
        end
    end

    -- Try to craft
    print("\nAttempting to craft...")
    local success, error = turtle.craft()

    if not success then
        print("Craft failed: " .. (error or "unknown error"))
        print("Make sure you have the correct items in the right pattern!")
        return
    end

    -- Analyze the result (it should be in slot 1 after crafting)
    local result = turtle.getItemDetail(1)
    if not result then
        print("Error: No result found after crafting!")
        return
    end

    log("Crafted:", result.displayName or result.name, "x" .. result.count)

    -- Determine if the result should use a wildcard tag
    local resultTag = nil
    local resultWildcard = false

    if isWildcard then
        resultTag = getItemTag(result.name)
        if resultTag then
            resultWildcard = true
        end
    end

    -- Create the recipe object
    local recipeId = result.name
    local recipeData = {
        display = displayName,
        wildcard = isWildcard,
        key = key,
        recipe = recipe,
        result = {
            item = resultWildcard and resultTag or result.name,
            count = result.count,
            wildcard = resultWildcard
        }
    }

    -- Send to computer
    log("Sending recipe to storage system...")
    local packet = {
        action = "store_recipe",
        recipe_id = recipeId,
        recipe_data = recipeData
    }

    rednet.broadcast(packet)

    -- Wait for confirmation
    local timer = os.startTimer(5)
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            local sender, msg = p1, p2
            if type(msg) == "table" and msg.action == "recipe_stored" then
                if msg.success then
                    print("\nRecipe successfully stored!")
                    print("Recipe ID: " .. recipeId)
                    print("You can now use this recipe for automated crafting.")
                else
                    print("\nFailed to store recipe: " .. (msg.error or "unknown error"))
                end
                break
            end
        elseif event == "timer" and p1 == timer then
            print("\nNo response from storage system. Recipe may not have been saved.")
            print("Make sure the computer is running and has the recipe listener enabled.")
            break
        end
    end

    -- Clear inventory
    print("\nDrop crafted items? (y/n):")
    local dropInput = read()
    if dropInput:lower() == "y" then
        for slot = 1, 16 do
            if turtle.getItemDetail(slot) then
                turtle.select(slot)
                turtle.drop()
            end
        end
        print("Inventory cleared.")
    end
end

-- Run the program
main()