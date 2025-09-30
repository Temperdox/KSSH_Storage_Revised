local DepositCommand = {}

function DepositCommand.register(factory, context)
    factory:register("deposit", {
        description = "Deposit items from output chest",
        aliases = {"d", "put", "store"},
        usage = "deposit",
        execute = function(args)
            context.services.storage:deposit()
            return "Deposit initiated - items will be moved to storage"
        end
    })
end

return DepositCommand