local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler:new(eventBus)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.pools = {}
    o.tasks = {}
    o.nextTaskId = 1
    o.workerLabels = "0123456789ABCDEF"
    return o
end

function Scheduler:createPool(name, size)
    self.pools[name] = {
        name = name,
        size = size,
        workers = {},
        queue = {},
        active = 0
    }

    -- Create workers for pool
    for i = 1, size do
        local worker = {
            id = i,
            label = self.workerLabels:sub(i, i),
            busy = false,
            currentTask = nil
        }
        self.pools[name].workers[i] = worker
    end

    self.eventBus:publish("scheduler.poolCreated", {
        pool = name,
        size = size
    })
end

function Scheduler:runWorkers()
    -- Create all worker processes
    local processes = {}

    for poolName, pool in pairs(self.pools) do
        for workerId = 1, pool.size do
            table.insert(processes, function()
                self:workerLoop(poolName, workerId)
            end)
        end
    end

    -- Run all workers in parallel
    parallel.waitForAny(table.unpack(processes))
end

function Scheduler:workerLoop(poolName, workerId)
    local pool = self.pools[poolName]
    local worker = pool.workers[workerId]

    while true do
        if #pool.queue > 0 then
            local task = table.remove(pool.queue, 1)
            worker.busy = true
            worker.currentTask = task.id
            pool.active = pool.active + 1

            self.eventBus:publish("task.start", {
                pool = poolName,
                worker = workerId,
                task = task.id,
                label = worker.label,
                taskType = task.taskType or "generic"
            })

            local ok, result = pcall(task.fn)

            if ok then
                task.future:resolve(result)
                self.eventBus:publish("task.end", {
                    pool = poolName,
                    worker = workerId,
                    task = task.id,
                    taskType = task.taskType or "generic"
                })
            else
                task.future:reject(result)
                self.eventBus:publish("task.error", {
                    pool = poolName,
                    worker = workerId,
                    task = task.id,
                    taskType = task.taskType or "generic",
                    error = result
                })
            end

            worker.busy = false
            worker.currentTask = nil
            pool.active = pool.active - 1
        else
            os.sleep(0.05)
        end
    end
end

function Scheduler:submit(poolName, fn, taskType)
    local pool = self.pools[poolName]
    if not pool then
        error("Unknown pool: " .. poolName)
    end

    local taskId = self.nextTaskId
    self.nextTaskId = self.nextTaskId + 1

    local future = self:createFuture()

    local task = {
        id = taskId,
        fn = fn,
        future = future,
        taskType = taskType or "generic"  -- Default to generic if not specified
    }

    table.insert(pool.queue, task)
    self.tasks[taskId] = task

    return future
end

function Scheduler:createFuture()
    local future = {
        resolved = false,
        rejected = false,
        result = nil,
        callbacks = {}
    }

    function future:await()
        while not self.resolved and not self.rejected do
            os.sleep(0.05)
        end
        if self.rejected then
            error(self.result)
        end
        return self.result
    end

    function future:resolve(value)
        self.resolved = true
        self.result = value
        for _, cb in ipairs(self.callbacks) do
            cb(value)
        end
    end

    function future:reject(err)
        self.rejected = true
        self.result = err
    end

    function future:then_(callback)
        if self.resolved then
            callback(self.result)
        else
            table.insert(self.callbacks, callback)
        end
        return self
    end

    return future
end

function Scheduler:getPools()
    return self.pools
end

function Scheduler:getPoolStats(poolName)
    local pool = self.pools[poolName]
    if not pool then return nil end

    return {
        name = poolName,
        size = pool.size,
        active = pool.active,
        queued = #pool.queue,
        workers = pool.workers
    }
end

return Scheduler