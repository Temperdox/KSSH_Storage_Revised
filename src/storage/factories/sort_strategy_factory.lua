local SortStrategyFactory = {}
SortStrategyFactory.__index = SortStrategyFactory

function SortStrategyFactory:new()
    local o = setmetatable({}, self)
    o.strategies = {}

    -- Register default strategies
    self:registerDefaults()

    return o
end

function SortStrategyFactory:registerDefaults()
    -- Sort by name
    self:register("name", function(a, b)
        local nameA = a.key or a.name or ""
        local nameB = b.key or b.name or ""
        return nameA:lower() < nameB:lower()
    end)

    -- Sort by count
    self:register("count", function(a, b)
        local countA = (a.value and a.value.count) or a.count or 0
        local countB = (b.value and b.value.count) or b.count or 0
        return countA > countB
    end)

    -- Sort by ID (minecraft:stone -> stone)
    self:register("id", function(a, b)
        local idA = (a.key or a.name or ""):match("([^:]+)$") or ""
        local idB = (b.key or b.name or ""):match("([^:]+)$") or ""
        return idA:lower() < idB:lower()
    end)

    -- Sort by mod (minecraft:stone -> minecraft)
    self:register("mod", function(a, b)
        local modA = (a.key or a.name or ""):match("^([^:]+)") or ""
        local modB = (b.key or b.name or ""):match("^([^:]+)") or ""
        return modA:lower() < modB:lower()
    end)

    -- Sort by NBT hash
    self:register("nbt", function(a, b)
        local nbtA = (a.value and a.value.nbtHash) or a.nbtHash or ""
        local nbtB = (b.value and b.value.nbtHash) or b.nbtHash or ""
        return nbtA < nbtB
    end)

    -- Sort by stack count
    self:register("stacks", function(a, b)
        local stackSizeA = (a.value and a.value.stackSize) or a.stackSize or 64
        local stackSizeB = (b.value and b.value.stackSize) or b.stackSize or 64
        local countA = (a.value and a.value.count) or a.count or 0
        local countB = (b.value and b.value.count) or b.count or 0

        local stacksA = math.ceil(countA / stackSizeA)
        local stacksB = math.ceil(countB / stackSizeB)

        return stacksA > stacksB
    end)

    -- Sort by last modified
    self:register("recent", function(a, b)
        local timeA = (a.value and a.value.lastModified) or a.lastModified or 0
        local timeB = (b.value and b.value.lastModified) or b.lastModified or 0
        return timeA > timeB
    end)
end

function SortStrategyFactory:register(name, compareFn)
    self.strategies[name] = compareFn
end

function SortStrategyFactory:sort(items, strategyName, reverse)
    local strategy = self.strategies[strategyName]
    if not strategy then
        strategy = self.strategies["name"]  -- Default to name sort
    end

    table.sort(items, function(a, b)
        local result = strategy(a, b)
        if reverse then
            return not result
        end
        return result
    end)

    return items
end

function SortStrategyFactory:getStrategies()
    local list = {}
    for name, _ in pairs(self.strategies) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

return SortStrategyFactory