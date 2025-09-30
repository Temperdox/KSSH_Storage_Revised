local WithdrawCommand = {}

function WithdrawCommand.register(factory, context)
    factory:register("withdraw", {
        description = "Withdraw items from storage",
        aliases = {"w", "get", "take"},
        usage = "withdraw <item> <count>",
        autocomplete = function(args)
            if #args == 2 then
                -- Autocomplete item names
                local items = context.services.storage:getItems()
                local names = {}
                for _, item in ipairs(items) do
                    local shortName = item.key:match("([^:]+)$") or item.key
                    table.insert(names, shortName)
                end
                return names
            end
            return {}
        end,
        validate = function(args)
            if #args < 2 then
                return false, "Usage: withdraw <item> <count>"
            end

            local count = tonumber(args[2])
            if not count or count <= 0 then
                return false, "Count must be a positive number"
            end

            return true
        end,
        execute = function(args)
            local itemName = args[1]
            local count = tonumber(args[2])

            -- Try to find full item name if partial given
            local items = context.services.storage:getItems()
            local fullName = nil

            for _, item in ipairs(items) do
                if item.key:lower():find(itemName:lower()) then
                    fullName = item.key
                    break
                end
            end

            if not fullName then
                return "Item not found: " .. itemName
            end

            local withdrawn = context.services.storage:withdraw(fullName, count)

            if withdrawn > 0 then
                return string.format("Withdrawn %d x %s", withdrawn, fullName)
            else
                return "Failed to withdraw " .. fullName
            end
        end
    })
end

return WithdrawCommand