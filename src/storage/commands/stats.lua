local StatsCommand = {}

function StatsCommand.register(factory, context)
    factory:register("stats", {
        description = "Show system statistics",
        aliases = {"s", "status"},
        usage = "stats [category]",
        autocomplete = function(args)
            if #args == 2 then
                return {"items", "storage", "events", "pools", "network"}
            end
            return {}
        end,
        execute = function(args)
            local category = args[1] or "all"

            local stats = {}

            if category == "all" or category == "items" then
                local items = context.services.storage:getItems()
                local totalItems = 0
                for _, item in ipairs(items) do
                    totalItems = totalItems + (item.value.count or 0)
                end

                stats.items = {
                    unique = #items,
                    total = totalItems
                }
            end

            if category == "all" or category == "storage" then
                stats.storage = {
                    inventories = #context.storageMap,
                    buffer = context.bufferInventory.name
                }
            end

            if category == "all" or category == "events" then
                local eventStats = context.services.events:getStats()
                stats.events = {
                    total = eventStats.total,
                    rate = eventStats.rate
                }
            end

            if category == "all" or category == "pools" then
                local pools = context.scheduler:getPools()
                stats.pools = {}
                for name, pool in pairs(pools) do
                    stats.pools[name] = {
                        size = pool.size,
                        active = pool.active,
                        queued = #pool.queue
                    }
                end
            end

            return textutils.serialiseJSON(stats, {compact = true})
        end
    })
end

return StatsCommand