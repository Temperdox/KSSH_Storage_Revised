local RebuildIndexCommand = {}

function RebuildIndexCommand.register(factory, context)
    factory:register("rebuild_index", {
        description = "Rebuild the item index from scratch",
        aliases = {"ri", "reindex"},
        usage = "rebuild_index",
        execute = function(args)
            context.logger:info("Command", "Rebuilding item index...")

            -- Clear current index
            context.services.storage.itemIndex:clear()

            -- Rebuild
            context.scheduler:submit("index", function()
                context.services.storage:rebuildIndex()
            end)

            return "Item index rebuild initiated"
        end
    })
end

return RebuildIndexCommand