local CommandFactory = {}
CommandFactory.__index = CommandFactory

function CommandFactory:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.commands = {}
    o.aliases = {}
    o.history = {}
    o.maxHistory = 100

    return o
end

function CommandFactory:register(name, config)
    -- Config structure:
    -- {
    --   description = "Command description",
    --   aliases = {"alias1", "alias2"},
    --   usage = "command <arg1> [arg2]",
    --   autocomplete = true/false or function,
    --   execute = function(args, context),
    --   validate = function(args) -> boolean, error,
    --   permissions = "user"/"admin"
    -- }

    self.commands[name] = config

    -- Register aliases
    if config.aliases then
        for _, alias in ipairs(config.aliases) do
            self.aliases[alias] = name
        end
    end

    return self
end

function CommandFactory:execute(input)
    local parts = {}
    for part in input:gmatch("%S+") do
        table.insert(parts, part)
    end

    if #parts == 0 then
        return false, "No command specified"
    end

    local cmdName = parts[1]
    local args = {table.unpack(parts, 2)}

    -- Check for alias
    if self.aliases[cmdName] then
        cmdName = self.aliases[cmdName]
    end

    -- Find command
    local command = self.commands[cmdName]
    if not command then
        return false, "Unknown command: " .. cmdName
    end

    -- Validate arguments if validator provided
    if command.validate then
        local valid, err = command.validate(args)
        if not valid then
            return false, err or "Invalid arguments"
        end
    end

    -- Add to history
    table.insert(self.history, input)
    if #self.history > self.maxHistory then
        table.remove(self.history, 1)
    end

    -- Execute command
    local ok, result = pcall(command.execute, args, self.context)
    if not ok then
        return false, "Command error: " .. tostring(result)
    end

    -- Publish event
    self.context.eventBus:publish("cli.commandRan", {
        command = cmdName,
        args = args,
        success = true,
        result = result
    })

    return true, result
end

function CommandFactory:getAutocomplete(partial)
    local suggestions = {}

    -- Split partial input
    local parts = {}
    for part in partial:gmatch("%S+") do
        table.insert(parts, part)
    end

    if #parts == 0 or (#parts == 1 and not partial:match("%s$")) then
        -- Completing command name
        local prefix = parts[1] or ""

        for name, _ in pairs(self.commands) do
            if name:sub(1, #prefix) == prefix then
                table.insert(suggestions, name)
            end
        end

        for alias, _ in pairs(self.aliases) do
            if alias:sub(1, #prefix) == prefix then
                table.insert(suggestions, alias)
            end
        end
    else
        -- Completing arguments
        local cmdName = parts[1]

        if self.aliases[cmdName] then
            cmdName = self.aliases[cmdName]
        end

        local command = self.commands[cmdName]
        if command and command.autocomplete then
            if type(command.autocomplete) == "function" then
                suggestions = command.autocomplete(parts, self.context) or {}
            elseif command.autocomplete == true then
                -- Basic autocomplete (could be extended)
                suggestions = {}
            end
        end
    end

    table.sort(suggestions)
    return suggestions
end

function CommandFactory:getHelp(cmdName)
    if cmdName then
        -- Get help for specific command
        if self.aliases[cmdName] then
            cmdName = self.aliases[cmdName]
        end

        local command = self.commands[cmdName]
        if not command then
            return "Unknown command: " .. cmdName
        end

        local help = {}
        table.insert(help, "Command: " .. cmdName)

        if command.description then
            table.insert(help, "  " .. command.description)
        end

        if command.usage then
            table.insert(help, "  Usage: " .. command.usage)
        end

        if command.aliases and #command.aliases > 0 then
            table.insert(help, "  Aliases: " .. table.concat(command.aliases, ", "))
        end

        return table.concat(help, "\n")
    else
        -- Get general help
        local help = {"Available commands:"}

        for name, cmd in pairs(self.commands) do
            local desc = cmd.description or "No description"
            table.insert(help, string.format("  %s - %s", name, desc))
        end

        return table.concat(help, "\n")
    end
end

function CommandFactory:getHistory()
    return self.history
end

function CommandFactory:clearHistory()
    self.history = {}
end

return CommandFactory