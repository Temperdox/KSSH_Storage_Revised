local CommandLoader = {}

function CommandLoader.loadAll(factory, context)
    local commands = {
        "help",
        "stats",
        "withdraw",
        "deposit",
        "filter",
        "test",
        "rescan",
        "theme",
        "loglevel",
        "rebuild_index",
        "ping"
    }

    for _, cmdName in ipairs(commands) do
        local ok, cmd = pcall(require, "commands." .. cmdName)
        if ok and cmd.register then
            cmd.register(factory, context)
            context.logger:debug("CommandLoader", "Loaded command: " .. cmdName)
        else
            context.logger:warn("CommandLoader", "Failed to load command: " .. cmdName)
        end
    end

    context.logger:info("CommandLoader", string.format(
            "Loaded %d commands", #commands
    ))
end

return CommandLoader