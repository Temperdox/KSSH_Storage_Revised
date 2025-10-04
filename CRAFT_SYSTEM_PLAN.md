# Crafting System Implementation Plan

## Status: UI In Progress

### Completed ✅
1. Transformed ORDER modal to ITEM INFO page
2. Added ORDER and CRAFT tab headers with active state highlighting
3. Separated tab content rendering into drawOrderTab() and drawCraftTab()

### UI Tasks Remaining (This Session)

#### 1. Complete drawCraftTab() Function
```lua
function MonitorService:drawCraftTab(contentX, contentY, modalWidth, startX, startY, modalHeight, maxAmount, itemName)
    -- Amount field with triple arrows (same as ORDER)
    -- Autocraft checkbox: [ ] Autocraft
    -- Warning message if insufficient items
    -- Craft button (disabled if insufficient items AND autocraft off)
end
```

#### 2. Add Tab Click Handling
In `MonitorService:handleClick()`, detect clicks on ORDER/CRAFT tabs and switch `self.itemInfoTab`

#### 3. Add Autocraft Checkbox Click Handler
Toggle `self.autocraft` when checkbox is clicked

#### 4. Calculate Craftable Amount
```lua
function MonitorService:calculateCraftable(itemName, requestedAmount)
    -- Check recipe exists
    -- Check ingredients available
    -- Return {canCraft = N, missing = {items...}}
end
```

### Turtle System Architecture (Future Sessions)

#### File Structure
```
/turtle/
  services/
    craft_service.lua         -- Main crafting logic
    recipe_manager.lua        -- Recipe save/load from disk
  ui/
    craft_save_mode.lua       -- Grid UI for recipe entry
  protocols/
    computer_protocol.lua     -- Handle commands from computer

/storage/
  services/
    craft_queue_service.lua   -- BST priority queue
  protocols/
    turtle_craft_protocol.lua -- Send craft requests to turtle
```

#### Communication Protocol
```lua
-- Computer → Turtle
{
  type = "CRAFT_REQUEST",
  item = "minecraft:stick",
  amount = 64,
  ingredients = {items...}
}

-- Turtle → Computer
{
  type = "CRAFT_COMPLETE",
  item = "minecraft:stick",
  crafted = 64
}

{
  type = "CRAFT_FAILED",
  item = "minecraft:stick",
  reason = "missing_recipe",
  returned_items = {items...}
}

{
  type = "RECIPE_REQUEST",
  item = "minecraft:stick"
}
```

#### Recipe Storage Format (JSON on Disk)
```json
{
  "minecraft:stick": {
    "pattern": [
      ["minecraft:planks", null, null],
      ["minecraft:planks", null, null],
      [null, null, null]
    ],
    "result": {
      "item": "minecraft:stick",
      "count": 4
    },
    "dependencies": ["minecraft:planks"]
  },
  "minecraft:planks": {
    "pattern": [
      ["minecraft:oak_log", null, null],
      [null, null, null],
      [null, null, null]
    ],
    "result": {
      "item": "minecraft:oak_planks",
      "count": 4
    },
    "dependencies": []
  }
}
```

#### Recursive Crafting Algorithm
```lua
function craftRecursive(item, amount, recipes, inventory)
    local recipe = recipes[item]
    if not recipe then
        return error("No recipe for " .. item)
    end

    -- Check dependencies
    for _, dep in ipairs(recipe.dependencies) do
        local needed = calculateNeeded(dep, amount, recipe)
        local available = inventory[dep] or 0

        if available < needed then
            -- Recursively craft dependency
            craftRecursive(dep, needed - available, recipes, inventory)
        end
    end

    -- Craft the item
    craft(item, amount, recipe)
end
```

#### BST Priority Queue
```lua
-- Priority based on item name (alphabetical BST)
-- Multiple requests for same item get combined
CraftQueue = {
    root = nil,
    insert = function(item, amount) end,
    getNext = function() end,  -- Returns highest priority
    combine = function(item, amount) end  -- Combines duplicate requests
}
```

#### Craft Save Mode UI (Turtle Terminal)
```
┌─────────────────────────────┐
│ CRAFT RECIPE SAVE MODE      │
├─────────────────────────────┤
│ Place items in slots 1-9    │
│                             │
│   [A][B][ ]   =  [?]       │
│   [C][ ][ ]                │
│   [ ][ ][ ]                │
│                             │
│ Legend:                     │
│ [A] = minecraft:stick       │
│ [B] = minecraft:iron_ingot │
│ [C] = minecraft:stick       │
│                             │
│ [Craft & Save] [Cancel]     │
└─────────────────────────────┘
```

### Implementation Phases

**Phase 1: UI (Current)**
- Complete ITEM INFO page with both tabs
- Add click handlers
- Create stub functions for turtle communication

**Phase 2: Basic Communication**
- Implement turtle protocol on both sides
- Simple send/receive item transfer
- Test with manual crafting

**Phase 3: Recipe System**
- Recipe save/load on disk drive
- Craft save mode UI on turtle
- Recipe validation

**Phase 4: Recursive Crafting**
- Dependency resolver
- Recursive craft algorithm
- Inventory tracking

**Phase 5: Priority Queue**
- BST implementation
- Request combining
- Fair scheduling (interleave crafts)

### Testing Checklist
- [ ] ORDER tab shows existing functionality
- [ ] CRAFT tab shows triple arrows
- [ ] Autocraft checkbox toggles
- [ ] Warning shows when insufficient items
- [ ] Craft button disabled appropriately
- [ ] Tab switching works
- [ ] Turtle receives craft requests
- [ ] Turtle saves recipes to disk
- [ ] Recursive crafting works (logs→planks→sticks)
- [ ] Priority queue combines duplicates
- [ ] Fair scheduling across multiple items
- [ ] Retry logic (3 attempts)
- [ ] Failure notifications logged

### Notes
- Use `/disk/recipes.json` for recipe storage
- Turtle slots 1-9 for crafting grid (slots 10-16 are inventory)
- Computer should check recipe exists before sending craft request
- If recipe missing, trigger craft save mode on turtle
- BST uses string comparison on item names for ordering
- Fair scheduling: Round-robin between different items in queue
