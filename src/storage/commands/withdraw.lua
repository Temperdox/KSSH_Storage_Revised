local WithdrawCommand = {}

function WithdrawCommand.register(factory, context)
    factory:register("withdraw", {
        description = "Withdraw items from storage (opens interactive UI)",
        aliases = {"w", "get", "take"},
        usage = "withdraw [item] [count] - Opens interactive UI, or quick withdraw if args provided",
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
            -- Allow no args (opens UI) or require both args for quick withdraw
            if #args == 0 then
                return true
            end

            if #args < 2 then
                return false, "Usage: withdraw <item> <count> or just 'withdraw' for interactive UI"
            end

            local count = tonumber(args[2])
            if not count or count <= 0 then
                return false, "Count must be a positive number"
            end

            return true
        end,
        execute = function(args)
            -- If no args, open interactive UI
            if #args == 0 then
                context.router:navigate("withdraw")
                return "" -- No message, just navigate
            end

            -- Quick withdraw with args (legacy behavior)
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
                return string.format("Withdrawn %d x %s from local storage", withdrawn, fullName)
            else
                return "Failed to withdraw " .. fullName
            end
        end
    })
end

return WithdrawCommand