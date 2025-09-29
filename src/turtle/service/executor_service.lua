-- Simplified executor service for turtle
-- Lighter weight than computer version due to turtle limitations
local ExecutorService = {}

function ExecutorService.new(coreSize, maxSize)
    local self = {
        corePoolSize = tonumber(coreSize) or 4,
        maxPoolSize  = tonumber(maxSize)  or 8,
        taskQueue = {},
        recurringTasks = {},
        running = false,
        threads = {},
        nextThreadId = 1,
        stats = { submitted = 0, completed = 0, failed = 0 },
    }
    setmetatable(self, { __index = ExecutorService })
    return self
end

function ExecutorService:submit(func, name, priority)
    local task = {
        func = func,
        name = name or "anonymous",
        recurring = false,
        priority = priority or 5
    }

    table.insert(self.taskQueue, task)
    self.stats.submitted = self.stats.submitted + 1

    -- Sort by priority
    table.sort(self.taskQueue, function(a, b) return a.priority > b.priority end)
end

function ExecutorService:submitRecurring(func, interval, name, priority)
    local task = {
        func = func,
        name = name or "recurring",
        recurring = true,
        interval = interval or 1,
        priority = priority or 5
    }

    table.insert(self.recurringTasks, task)
    table.insert(self.taskQueue, task)
    self.stats.submitted = self.stats.submitted + 1

    table.sort(self.taskQueue, function(a, b) return a.priority > b.priority end)
end

function ExecutorService:getNextTask()
    if #self.taskQueue > 0 then
        return table.remove(self.taskQueue, 1)
    end
    return nil
end

function ExecutorService:createWorker(id)
    return function()
        while self.running do
            local task = self:getNextTask()

            if task then
                local ok, err = pcall(task.func)

                if not ok then
                    self.stats.failed = self.stats.failed + 1
                    print("[executor] Task", task.name, "failed:", err)
                else
                    self.stats.completed = self.stats.completed + 1
                end

                -- Re-queue recurring tasks
                if task.recurring then
                    sleep(task.interval or 1)
                    table.insert(self.taskQueue, task)
                    table.sort(self.taskQueue, function(a, b)
                        return a.priority > b.priority
                    end)
                end
            else
                sleep(0.1)  -- Idle sleep
            end
        end
    end
end

function ExecutorService:start()
    if self.running then return {} end
    self.running = true
    local workers = {}

    local cores = math.max(1, tonumber(self.corePoolSize) or 1)
    for i = 1, cores do
        table.insert(workers, self:createWorker(i))
    end

    local function manager()
        while self.running do
            sleep(30)
            if self.stats.submitted > 0 then
                print(string.format(
                        "[executor] Stats - Submitted: %d, Completed: %d, Failed: %d, Queue: %d",
                        self.stats.submitted, self.stats.completed, self.stats.failed, #self.taskQueue
                ))
            end
        end
    end
    table.insert(workers, manager)
    return workers
end

function ExecutorService:shutdown()
    self.running = false
    self.taskQueue = {}
    self.recurringTasks = {}
end

function ExecutorService:getStats()
    return {
        tasks = {
            submitted = self.stats.submitted,
            completed = self.stats.completed,
            failed = self.stats.failed,
            queued = #self.taskQueue,
            recurring = #self.recurringTasks
        },
        threads = {
            core = self.corePoolSize,
            max = self.maxPoolSize
        }
    }
end

return ExecutorService