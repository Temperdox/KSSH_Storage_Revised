local HelpCommand = {}

function HelpCommand.register(factory)
    factory:register("help", {
        description = "Show help information",
        aliases = {"h", "?"},
        usage = "help [command]",
        autocomplete = function(args, context)
            if #args == 2 then
                -- Autocomplete command names
                local commands = {}
                for name, _ in pairs(factory.commands) do
                    table.insert(commands, name)
                end
                return commands
            end
            return {}
        end,
        execute = function(args, context)
            local commandName = args[1]
            return factory:getHelp(commandName)
        end
    })
end

return HelpCommand