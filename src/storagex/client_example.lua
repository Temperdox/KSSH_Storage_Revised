-- client_example.lua
-- Example client for interacting with the storage system API

local StorageClient = {}
StorageClient.__index = StorageClient

function StorageClient:new(serverID)
    local self = setmetatable({}, StorageClient)
    self.serverID = serverID

    -- Find and open modem
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            break
        end
    end

    -- Look up server if not provided
    if not self.serverID then
        self.serverID = rednet.lookup("storage", "main")
        if not self.serverID then
            error("Could not find storage server")
        end
    end

    return self
end

function StorageClient:request(action, data)
    local request = {
        action = action,
        data = data or {}
    }

    rednet.send(self.serverID, textutils.serialise(request))

    local sender, response = rednet.receive("storage_response", 5)
    if sender == self.serverID and response then
        local ok, parsed = pcall(textutils.unserialise, response)
        if ok then
            return parsed
        end
    end

    return {error = "Request timeout"}
end

function StorageClient:getItems()
    return self:request("items")
end

function StorageClient:orderItem(itemName, amount)
    return self:request("order", {
        item = {name = itemName},
        amount = amount
    })
end

function StorageClient:reload()
    return self:request("reload")
end

function StorageClient:sort(consolidate)
    return self:request("sort", {consolidate = consolidate})
end

function StorageClient:getInfo()
    return self:request("info")
end

-- Example usage
local function main()
    print("Storage System Client")
    print("====================")

    -- Create client
    local client = StorageClient:new()

    while true do
        print("\nCommands:")
        print("1. List items")
        print("2. Order item")
        print("3. Reload storage")
        print("4. Sort storage")
        print("5. System info")
        print("6. Exit")

        write("Choice: ")
        local choice = read()

        if choice == "1" then
            print("Fetching items...")
            local result = client:getItems()
            if result.items then
                for _, item in ipairs(result.items) do
                    print(string.format("%s: %d", item.displayName, item.count))
                end
            else
                print("Error: " .. tostring(result.error))
            end

        elseif choice == "2" then
            write("Item name: ")
            local itemName = read()
            write("Amount: ")
            local amount = tonumber(read())

            local result = client:orderItem(itemName, amount)
            if result.success then
                print("Order placed successfully")
            else
                print("Error: " .. tostring(result.error))
            end

        elseif choice == "3" then
            print("Reloading storage...")
            local result = client:reload()
            if result.success then
                print("Reload initiated")
            else
                print("Error: " .. tostring(result.error))
            end

        elseif choice == "4" then
            write("Consolidate? (y/n): ")
            local consolidate = read():lower() == "y"

            print("Sorting storage...")
            local result = client:sort(consolidate)
            if result.success then
                print("Sort initiated")
            else
                print("Error: " .. tostring(result.error))
            end

        elseif choice == "5" then
            print("Fetching system info...")
            local result = client:getInfo()
            if result.version then
                print("Version: " .. result.version)
                print("Uptime: " .. string.format("%.1f", result.uptime) .. "s")
                print("\nProcesses:")
                for name, status in pairs(result.processes) do
                    print(string.format("  %s: %s (PID: %s)",
                            name, status.status, status.pid or "N/A"))
                end
            else
                print("Error: " .. tostring(result.error))
            end

        elseif choice == "6" then
            print("Goodbye!")
            break

        else
            print("Invalid choice")
        end
    end
end

-- Run if executed directly
if not ... then
    main()
end

return StorageClient