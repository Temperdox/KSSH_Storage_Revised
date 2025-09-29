-- modules/task_executor.lua
-- Thread pool executor for concurrent tasks

local TaskExecutor = {}
TaskExecutor.__index = TaskExecutor

function TaskExecutor:new(logger, threadCount)
    local self = setmetatable({}, TaskExecutor)
    self.logger = logger
    self.threadCount = threadCount or 16
    self.threads = {}
    self.taskQueue = {}
    self.running = true

    -- Initialize thread pool
    for i = 1, self.threadCount do
        self.threads[i] = {
            id = i,
            active = false,
            currentTask = nil,
            log = {},
            coroutine = nil
        }
    end

    return self
end

function TaskExecutor:submit(taskType, func, priority)
    priority = priority or 5

    local task = {
        type = taskType,
        func = func,
        priority = priority,
        submitted = os.epoch("utc"),
        id = string.format("%s_%d", taskType, os.epoch("utc"))
    }

    -- Insert task in priority order
    local inserted = false
    for i, existingTask in ipairs(self.taskQueue) do
        if existingTask.priority < task.priority then
            table.insert(self.taskQueue, i, task)
            inserted = true
            break
        end
    end

    if not inserted then
        table.insert(self.taskQueue, task)
    end

    self.logger:debug(string.format("Task %s queued (priority: %d)", task.id, priority), "Executor")

    -- Try to execute immediately if thread available
    self:executeNext()

    return task.id
end

function TaskExecutor:executeNext()
    if #self.taskQueue == 0 then
        return
    end

    -- Find available thread
    local thread = nil
    for _, t in ipairs(self.threads) do
        if not t.active then
            thread = t
            break
        end
    end

    if not thread then
        return -- All threads busy
    end

    -- Get next task
    local task = table.remove(self.taskQueue, 1)

    -- Execute task in thread
    thread.active = true
    thread.currentTask = task

    thread.coroutine = coroutine.create(function()
        self.logger:debug(string.format("Thread %d executing %s", thread.id, task.id), "Executor")

        local ok, err = pcall(task.func)

        if ok then
            self.logger:debug(string.format("Thread %d completed %s", thread.id, task.id), "Executor")
        else
            self.logger:error(string.format("Thread %d error in %s: %s", thread.id, task.id, tostring(err)), "Executor")
        end

        thread.active = false
        thread.currentTask = nil

        -- Try to execute next task
        self:executeNext()
    end)

    -- Start coroutine
    coroutine.resume(thread.coroutine)
end

function TaskExecutor:getStatus()
    local status = {
        queue = #self.taskQueue,
        threads = {}
    }

    for _, thread in ipairs(self.threads) do
        table.insert(status.threads, {
            id = thread.id,
            active = thread.active,
            task = thread.currentTask and thread.currentTask.id or nil,
            log = thread.log
        })
    end

    return status
end

function TaskExecutor:tick()
    -- Resume all active coroutines
    for _, thread in ipairs(self.threads) do
        if thread.coroutine and coroutine.status(thread.coroutine) == "suspended" then
            local ok, err = coroutine.resume(thread.coroutine)
            if not ok then
                self.logger:error(string.format("Thread %d coroutine error: %s", thread.id, tostring(err)), "Executor")
                thread.active = false
                thread.currentTask = nil
                thread.coroutine = nil
            end
        end
    end

    -- Try to execute queued tasks
    self:executeNext()
end

function TaskExecutor:stop()
    self.running = false
    self.taskQueue = {}

    -- Wait for active tasks to complete
    local timeout = os.startTimer(5)
    while true do
        local hasActive = false
        for _, thread in ipairs(self.threads) do
            if thread.active then
                hasActive = true
                break
            end
        end

        if not hasActive then
            break
        end

        local event, p1 = os.pullEvent()
        if event == "timer" and p1 == timeout then
            self.logger:warning("Task executor force stopped with active tasks", "Executor")
            break
        end
    end
end

return TaskExecutor