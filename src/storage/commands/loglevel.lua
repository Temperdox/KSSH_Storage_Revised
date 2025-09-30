local LogLevelCommand = {}

function LogLevelCommand.register(factory, context)
    factory:register("loglevel", {
        description = "Change log level",
        aliases = {"ll"},
        usage = "loglevel <level>",
        autocomplete = function(args)
            if #args == 2 then
                return {"trace", "debug", "info", "warn", "error"}
            end
            return {}
        end,
        execute = function(args)
            local level = args[1]

            if not level then
                return "Current log level: " .. (context.settings.logLevel or "info")
            end

            local validLevels = {"trace", "debug", "info", "warn", "error"}
            local valid = false

            for _, lvl in ipairs(validLevels) do
                if lvl == level then
                    valid = true
                    break
                end
            end

            if not valid then
                return "Invalid level. Available: trace, debug, info, warn, error"
            end

            context.settings.logLevel = level
            context.logger.level = context.logger.levels[level]

            -- Save settings
            local settingsPath = "/storage/cfg/settings.json"
            local file = fs.open(settingsPath, "w")
            if file then
                local ok, serialized = pcall(textutils.serialiseJSON, context.settings)
                if ok then
                    file.write(serialized)
                else
                    context.logger:error("LogLevel", "Failed to serialize settings")
                end
                file.close()
            end

            context.eventBus:publish("settings.changed", {
                logLevel = level
            })

            return "Log level changed to: " .. level
        end
    })
end

return LogLevelCommand