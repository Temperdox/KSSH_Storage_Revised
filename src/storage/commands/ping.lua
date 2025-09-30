local PingCommand = {}

function PingCommand.register(factory, context)
    factory:register("ping", {
        description = "Test system responsiveness",
        usage = "ping",
        execute = function(args)
            return string.format("Pong! System time: %s, Uptime: %ds",
                    os.date("%H:%M:%S"),
                    os.epoch("utc") - (context.startTime or 0)
            )
        end
    })
end

return PingCommand