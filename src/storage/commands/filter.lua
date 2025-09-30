local FilterCommand = {}

function FilterCommand.register(factory, context)
    factory:register("filter", {
        description = "Filter displayed logs",
        aliases = {"f"},
        usage = "filter <type> <value>",
        autocomplete = function(args)
            if #args == 2 then
                return {"level", "source", "event", "clear"}
            elseif #args == 3 then
                if args[1] == "level" then
                    return {"trace", "debug", "info", "warn", "error"}
                elseif args[1] == "source" then
                    local sources = {}
                    for source, _ in pairs(context.services.events.stats.bySource) do
                        table.insert(sources, source)
                    end
                    return sources
                elseif args[1] == "event" then
                    local types = {}
                    for eventType, _ in pairs(context.services.events.stats.byType) do
                        table.insert(types, eventType)
                    end
                    return types
                end
            end
            return {}
        end,
        execute = function(args)
            local filterType = args[1]
            local filterValue = args[2]

            if filterType == "clear" then
                context.eventBus:publish("events.filter", {
                    logLevel = "info",
                    sources = {},
                    types = {}
                })
                return "Filters cleared"
            end

            if not filterValue then
                return "Usage: filter <type> <value>"
            end

            local filters = {}

            if filterType == "level" then
                filters.logLevel = filterValue
            elseif filterType == "source" then
                filters.sources = {filterValue}
            elseif filterType == "event" then
                filters.types = {filterValue}
            else
                return "Unknown filter type: " .. filterType
            end

            context.eventBus:publish("events.filter", filters)

            return string.format("Filter applied: %s = %s", filterType, filterValue)
        end
    })
end

return FilterCommand