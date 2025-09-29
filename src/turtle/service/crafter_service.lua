-- Turtle-side crafting service with smart output routing.
-- Output order of preference:
--   1) minecraft:trapped_chest
--   2) any inventory that's NOT minecraft:chest (barrels, sacks, modded drawers, etc.)
-- If no eligible target exists, items remain in the local buffer.

-- Optional logging shim (works with your util/log_print if present)
local LogPrint_ok, LogPrint = pcall(require, "util.log_print")
local function logf(level, ...)
    local msg = table.concat({ ... }, " ")
    if LogPrint_ok and LogPrint and LogPrint[level] then
        LogPrint[level](msg)
    else
        print(("[" .. level:upper() .. "] ") .. msg)
    end
end

local CrafterService = {}

-- =========================
-- Construction / init
-- =========================
function CrafterService.new(bridge)
    local self = {
        bridge = bridge or nil,
        currentPattern = nil,        -- { pattern=..., key=... } if you use layout logic
        bufferDirection = "front",   -- "front" | "up" | "down"
        stats = { prepared=0, crafted=0, failed=0, totalItems=0 },
    }
    return setmetatable(self, { __index = CrafterService })
end

-- Called from main.lua after construction
function CrafterService:init()
    -- Auto-pick a buffer side if we can detect an inventory on a side
    local function sideHasInventory(side)
        local ok = pcall(peripheral.call, side, "list")
        return ok
    end
    for _, dir in ipairs({ "front", "up", "down" }) do
        if sideHasInventory(dir) then
            self.bufferDirection = dir
            break
        end
    end
    logf("info", "[crafter] Initialized. Buffer side:", self.bufferDirection)
    return true
end

function CrafterService:setBuffer(dir)
    dir = tostring(dir or ""):lower()
    if dir == "front" or dir == "up" or dir == "down" then
        self.bufferDirection = dir
        logf("info", "[crafter] Buffer direction set to", dir)
        return true
    end
    logf("warn", "[crafter] Invalid buffer direction:", dir, "(use front|up|down)")
    return false
end

function CrafterService:setPattern(patternObj)
    self.currentPattern = patternObj
end

-- =========================
-- Turtle inventory helpers
-- =========================
function CrafterService:countInventory()
    local total = 0
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d then total = total + (d.count or 0) end
    end
    return total
end

function CrafterService:compactInventory()
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.count < (d.maxCount or 64) then
            for t = s + 1, 16 do
                local e = turtle.getItemDetail(t)
                if e and e.name == d.name and e.nbt == d.nbt then
                    turtle.select(t); turtle.transferTo(s)
                    d = turtle.getItemDetail(s)
                    if not d or d.count >= (d.maxCount or 64) then break end
                end
            end
        end
    end
    turtle.select(1)
end

-- =========================
-- Buffer IO (local chest)
-- =========================
local function suckDir(dir)
    if dir == "up" then return turtle.suckUp()
    elseif dir == "down" then return turtle.suckDown()
    else return turtle.suck() end
end

local function dropDir(dir)
    if dir == "up" then return turtle.dropUp()
    elseif dir == "down" then return turtle.dropDown()
    else return turtle.drop() end
end

function CrafterService:dropAllToBuffer()
    local dir = self.bufferDirection or "front"
    local dropped = 0
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.count and d.count > 0 then
            turtle.select(s)
            if dropDir(dir) then
                dropped = dropped + d.count
                logf("debug", "[crafter] Dropped", d.count, "x", d.name, "to", dir)
            else
                logf("error", "[crafter] Failed to drop from slot", s, "to", dir)
            end
        end
    end
    turtle.select(1)
    if dropped > 0 then
        logf("info", "[crafter] Dropped", dropped, "items into local buffer (", dir, ")")
    end
    return dropped
end

function CrafterService:suckFromBuffer(total)
    total = tonumber(total) or 0
    if total <= 0 then return 0 end

    local sucked, attempts, maxAttempts = 0, 0, 20
    logf("info", "[crafter] Requesting", total, "items from buffer:", self.bufferDirection)

    while sucked < total and attempts < maxAttempts do
        if suckDir(self.bufferDirection) then
            attempts = 0
            self:compactInventory()
            sucked = self:countInventory()
            logf("debug", "[crafter] Progress:", sucked, "/", total)
        else
            attempts = attempts + 1
            if attempts % 5 == 0 then
                logf("warn", "[crafter] Waiting for items... attempt", attempts, "of", maxAttempts)
            end
            sleep(0.5)
        end
    end

    if sucked < total then
        logf("warn", "[crafter] Only obtained", sucked, "of", total, "requested items")
    else
        logf("info", "[crafter] Successfully collected all items")
    end
    self.stats.totalItems = self.stats.totalItems + sucked
    return sucked
end

-- =========================
-- Network inventory helpers
-- =========================
local function isInventoryName(name)
    local t = peripheral.getType(name)
    if not t then return false end
    if t == "inventory" then return true end
    t = tostring(t):lower()
    return t:find("chest") or t:find("barrel") or t:find("drawer") or t:find("shulker")
end

local function blockId(name)
    -- Best: metadata.name (e.g., "minecraft:chest")
    local ok, md = pcall(peripheral.call, name, "getMetadata")
    if ok and type(md) == "table" and md.name and md.name ~= "" then
        return md.name:lower()
    end
    -- Fallback: strip trailing _N from network name "minecraft:chest_3"
    if type(name) == "string" then
        return name:gsub("_[%d_]+$", ""):lower()
    end
    return ""
end

-- Peripheral name of the local buffer (side or network)
function CrafterService:getBufferPeripheralName()
    local side = self.bufferDirection or "front"
    local ok, p = pcall(peripheral.wrap, side)
    if not ok or not p then return nil end
    local ok2, n = pcall(peripheral.getName, p)
    -- If there's no modem on the buffer, 'n' may be a side like "front" — that's
    -- still fine because we'll call pushItems FROM the buffer to the target.
    return ok2 and n or side
end

-- Choose output target:
-- 1) first minecraft:trapped_chest
-- 2) else first inventory whose block id ~= minecraft:chest
function CrafterService:resolveOutputTarget()
    local trapped, fallback
    for _, name in ipairs(peripheral.getNames()) do
        if isInventoryName(name) then
            local id = blockId(name)
            if id == "minecraft:trapped_chest" then
                trapped = name; break
            elseif id ~= "minecraft:chest" then
                fallback = fallback or name
            end
        end
    end

    if trapped then
        logf("info", "[crafter] Output target: trapped chest ->", trapped)
        return trapped
    end
    if fallback then
        logf("info", "[crafter] Output target: general storage ->", fallback)
        return fallback
    end

    logf("warn", "[crafter] No eligible output/storage inventory found.")
    return nil
end

-- Move items FROM buffer -> target using buffer.pushItems(target, ...)
-- Works even if buffer is only side-attached (no modem).
function CrafterService:moveFromBufferToTarget()
    local bufferName = self:getBufferPeripheralName()
    if not bufferName then
        logf("warn", "[crafter] No buffer peripheral found (is a chest present at", self.bufferDirection, "?)")
        return 0
    end

    local target = self:resolveOutputTarget()
    if not target then
        logf("warn", "[crafter] Leaving items in buffer; no output/storage target found.")
        return 0
    end

    local ok, list = pcall(peripheral.call, bufferName, "list")
    if not ok or type(list) ~= "table" then
        logf("error", "[crafter] Failed to list buffer inventory:", bufferName)
        return 0
    end

    local moved = 0
    for slot, stack in pairs(list) do
        if stack and stack.count and stack.count > 0 then
            local ok2, movedHere = pcall(peripheral.call, bufferName, "pushItems", target, slot, stack.count)
            moved = moved + (ok2 and (tonumber(movedHere) or 0) or 0)
        end
    end

    if moved > 0 then
        logf("info", string.format("[crafter] Moved %d items from %s -> %s", moved, bufferName, target))
    else
        logf("warn", "[crafter] Nothing moved from buffer; target may be full.")
    end
    return moved
end

-- =========================
-- Craft pipeline
-- =========================

-- Stub for your layout routine; return false,"reason" to abort a craft
function CrafterService:layoutOneCraft(_pattern, _key)
    return true
end

function CrafterService:totalNeed(expect)
    local total = 0
    for _, e in ipairs(expect or {}) do
        total = total + (tonumber(e.need) or 0)
    end
    return total
end

-- Craft N times; after each craft: drop -> buffer, then buffer -> target
function CrafterService:craftN(crafts)
    crafts = tonumber(crafts) or 1
    local made = 0
    for i = 1, crafts do
        logf("info", "[crafter] Craft attempt", i, "/", crafts)

        if self.currentPattern and (self.currentPattern.pattern or self.currentPattern.key) then
            local ok, err = self:layoutOneCraft(self.currentPattern.pattern, self.currentPattern.key)
            if not ok then
                logf("error", "[crafter] Layout failed:", err or "unknown")
                self.stats.failed = self.stats.failed + 1
                return false, err or "layout failed", made
            end
        end

        local success, reason = turtle.craft()
        if not success then
            logf("error", "[crafter] craft() failed:", reason or "unknown")
            self.stats.failed = self.stats.failed + 1
            return false, reason or "craft failed", made
        end

        made = made + 1
        self.stats.crafted = self.stats.crafted + 1

        self:dropAllToBuffer()
        self:moveFromBufferToTarget()
    end
    return true, nil, made
end

function CrafterService:prepareAndCraft(expect, crafts)
    local need = self:totalNeed(expect)
    if need > 0 then
        self:suckFromBuffer(need)
        self.stats.prepared = self.stats.prepared + need
    end
    return self:craftN(crafts)
end

return CrafterService