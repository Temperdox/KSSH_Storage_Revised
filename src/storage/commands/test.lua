local TestCommand = {}

function TestCommand.register(factory, context)
    factory:register("test", {
        description = "Run system tests",
        aliases = {"t"},
        usage = "test <test_name>",
        autocomplete = function(args)
            if #args == 2 then
                return {"io_burst", "index_stress", "net_load", "event_storm", "memory"}
            end
            return {}
        end,
        execute = function(args)
            local testName = args[1]

            if not testName then
                return "Available tests: io_burst, index_stress, net_load, event_storm, memory"
            end

            -- Trigger test via event
            context.eventBus:publish("tests.run", {
                test = testName
            })

            return "Test '" .. testName .. "' started - check Tests page for output"
        end
    })
end

return TestCommand