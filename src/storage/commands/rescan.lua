local RescanCommand = {}

function RescanCommand.register(factory, context)
    factory:register("rescan", {
        description = "Rescan all storage inventories",
        aliases = {"rs", "rebuild"},
        usage = "rescan",
        execute = function(args)
            context.scheduler:submit("index", function()
                context.services.storage:rebuildIndex()
            end)

            return "Storage rescan initiated - rebuilding index..."
        end
    })
end

return RescanCommand