local ThemeCommand = {}

function ThemeCommand.register(factory, context)
    factory:register("theme", {
        description = "Change UI theme",
        usage = "theme <theme_name>",
        autocomplete = function(args)
            if #args == 2 then
                return {"dark", "light", "high_contrast"}
            end
            return {}
        end,
        execute = function(args)
            local themeName = args[1]

            if not themeName then
                return "Current theme: " .. (context.settings.theme or "dark")
            end

            local validThemes = {"dark", "light", "high_contrast"}
            local valid = false

            for _, theme in ipairs(validThemes) do
                if theme == themeName then
                    valid = true
                    break
                end
            end

            if not valid then
                return "Invalid theme. Available: dark, light, high_contrast"
            end

            context.settings.theme = themeName

            -- Save settings
            local settingsPath = "/storage/cfg/settings.json"
            local file = fs.open(settingsPath, "w")
            if file then
                file.write(textutils.serialiseJSON(context.settings))
                file.close()
            end

            context.eventBus:publish("settings.changed", {
                theme = themeName
            })

            return "Theme changed to: " .. themeName
        end
    })
end

return ThemeCommand