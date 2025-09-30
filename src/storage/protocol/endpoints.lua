local Endpoints = {}
Endpoints.__index = Endpoints

function Endpoints:new(context)
    local o = setmetatable({}, self)
    o.context = context

    -- Define all endpoints
    o.endpoints = {}

    -- Register endpoints
    o:registerEndpoints()

    return o
end

function Endpoints:getEndpoint(name)
    return self.endpoints[name]
end

function Endpoints:registerEndpoints()
    -- List items endpoint
    self:register("listItems", {
        description = "List all items in storage",
        params = {
            filter = {type = "string", optional = true},
            sort = {type = "string", optional = true, default = "name"},
            limit = {type = "number", optional = true, default = 100},
            offset = {type = "number", optional = true, default = 0}
        },
        execute = function(params)
            local items = self.context.services.storage:getItems()

            -- Apply filter
            if params.filter then
                local filtered = {}
                for _, item in ipairs(items) do
                    if item.key:lower():find(params.filter:lower()) then
                        table.insert(filtered, item)
                    end
                end
                items = filtered
            end

            -- Sort items
            local sortFactory = require("factories.sort_strategy_factory"):new()
            items = sortFactory:sort(items, params.sort or "name")

            -- Apply pagination
            local result = {}
            local startIdx = params.offset + 1
            local endIdx = math.min(startIdx + params.limit - 1, #items)

            for i = startIdx, endIdx do
                if items[i] then
                    table.insert(result, {
                        name = items[i].key,
                        count = items[i].value.count,
                        stackSize = items[i].value.stackSize
                    })
                end
            end

            return {
                items = result,
                total = #items,
                offset = params.offset,
                limit = params.limit
            }
        end
    })

    -- Find item endpoint
    self:register("find", {
        description = "Find specific item",
        params = {
            name = {type = "string", required = true}
        },
        execute = function(params)
            local itemData = self.context.services.storage.itemIndex:get(params.name)

            if not itemData then
                return {found = false}
            end

            return {
                found = true,
                item = {
                    name = params.name,
                    count = itemData.count,
                    stackSize = itemData.stackSize,
                    locations = itemData.locations
                }
            }
        end
    })

    -- Withdraw endpoint
    self:register("withdraw", {
        description = "Withdraw items to output chest",
        params = {
            name = {type = "string", required = true},
            count = {type = "number", required = true, min = 1}
        },
        execute = function(params)
            local withdrawn = self.context.services.storage:withdraw(
                    params.name, params.count
            )

            return {
                requested = params.count,
                withdrawn = withdrawn,
                success = withdrawn > 0
            }
        end
    })

    -- Deposit endpoint
    self:register("deposit", {
        description = "Deposit items from output chest",
        params = {},
        execute = function(params)
            self.context.services.storage:deposit()

            return {
                success = true,
                message = "Deposit initiated"
            }
        end
    })

    -- Stats endpoint
    self:register("stats", {
        description = "Get system statistics",
        params = {},
        execute = function(params)
            local items = self.context.services.storage:getItems()
            local totalItems = 0

            for _, item in ipairs(items) do
                totalItems = totalItems + (item.value.count or 0)
            end

            local pools = self.context.scheduler:getPools()
            local activeTasks = 0

            for _, pool in pairs(pools) do
                activeTasks = activeTasks + pool.active
            end

            return {
                items = {
                    unique = #items,
                    total = totalItems
                },
                storage = {
                    inventories = #self.context.storageMap,
                    buffer = self.context.bufferInventory.name
                },
                system = {
                    uptime = os.epoch("utc") - (self.context.startTime or 0),
                    activeTasks = activeTasks,
                    computerId = os.getComputerID()
                }
            }
        end
    })

    -- Tail events endpoint
    self:register("tailEvents", {
        description = "Get recent events",
        params = {
            count = {type = "number", optional = true, default = 50},
            filter = {type = "string", optional = true}
        },
        execute = function(params)
            local events = self.context.eventBus:getRecentEvents(params.count)

            -- Apply filter
            if params.filter then
                local filtered = {}
                for _, event in ipairs(events) do
                    if event.name:find(params.filter) then
                        table.insert(filtered, event)
                    end
                end
                events = filtered
            end

            return {
                events = events,
                count = #events
            }
        end
    })

    -- Ping endpoint
    self:register("ping", {
        description = "Test connectivity",
        params = {},
        execute = function(params)
            return {
                pong = true,
                timestamp = os.epoch("utc"),
                version = "1.0.0"
            }
        end
    })

    -- Rescan endpoint
    self:register("rescan", {
        description = "Rescan all storage inventories",
        params = {},
        execute = function(params)
            self.context.scheduler:submit("index", function()
                self.context.services.storage:rebuildIndex()
            end)

            return {
                success = true,
                message = "Rescan initiated"
            }
        end
    })

    -- Get settings endpoint
    self:register("getSettings", {
        description = "Get current settings",
        params = {},
        execute = function(params)
            return {
                settings = self.context.settings
            }
        end
    })

    -- Update setting endpoint
    self:register("updateSetting", {
        description = "Update a setting",
        params = {
            key = {type = "string", required = true},
            value = {required = true}
        },
        execute = function(params)
            -- Update setting based on key path
            local keys = {}
            for key in params.key:gmatch("[^%.]+") do
                table.insert(keys, key)
            end

            local current = self.context.settings
            for i = 1, #keys - 1 do
                current = current[keys[i]]
                if not current then
                    return {
                        success = false,
                        error = "Invalid setting path"
                    }
                end
            end

            current[keys[#keys]] = params.value

            -- Save settings
            local settingsPath = "/storage/cfg/settings.json"
            local file = fs.open(settingsPath, "w")
            if file then
                file.write(textutils.serialiseJSON(self.context.settings))
                file.close()
            end

            -- Publish change
            self.context.eventBus:publish("settings.changed", {
                key = params.key,
                value = params.value
            })

            return {
                success = true,
                key = params.key,
                value = params.value
            }
        end
    })
end

function Endpoints:register(name, config)
    self.endpoints[name] = config
end

return Endpoints