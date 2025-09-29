-- modules/process_manager.lua
-- Process management with PID tracking

local ProcessManager = {}
ProcessManager.__index = ProcessManager

function ProcessManager:new()
    local self = setmetatable({}, ProcessManager)
    self.processes = {}
    self.nextPid = 1
    return self
end

function ProcessManager:register(name, func)
    local process = {
        name = name,
        func = func,
        pid = nil,
        thread = nil,
        status = "stopped",
        restartCount = 0,
        maxRestarts = 3
    }
    self.processes[name] = process
    return process
end

function ProcessManager:start(name)
    local process = self.processes[name]
    if not process then
        return false, "Process not found"
    end

    if process.status == "running" then
        return false, "Process already running"
    end

    process.pid = self.nextPid
    self.nextPid = self.nextPid + 1
    process.status = "running"

    -- Create wrapper function for error handling
    local wrapper = function()
        local ok, err = pcall(process.func)
        if not ok then
            process.status = "crashed"
            process.error = err

            -- Auto-restart logic
            if process.restartCount < process.maxRestarts then
                process.restartCount = process.restartCount + 1
                sleep(2) -- Wait before restart
                self:start(name)
            end
        else
            process.status = "stopped"
        end
    end

    process.thread = coroutine.create(wrapper)
    return true, process.pid
end

function ProcessManager:stop(name)
    local process = self.processes[name]
    if not process then
        return false, "Process not found"
    end

    if process.status ~= "running" then
        return false, "Process not running"
    end

    -- Send termination event to process
    if _G.eventBus then
        _G.eventBus:emit("process:stop:" .. name)
    end

    process.status = "stopping"

    -- Give process time to clean up
    sleep(1)

    -- Force stop if still running
    if process.thread and coroutine.status(process.thread) ~= "dead" then
        process.thread = nil
    end

    process.status = "stopped"
    process.pid = nil

    return true
end

function ProcessManager:restart(name)
    self:stop(name)
    sleep(0.5)
    return self:start(name)
end

function ProcessManager:startAll()
    for name, _ in pairs(self.processes) do
        self:start(name)
    end
end

function ProcessManager:stopAll()
    for name, _ in pairs(self.processes) do
        self:stop(name)
    end
end

function ProcessManager:getStatus(name)
    local process = self.processes[name]
    if not process then
        return nil
    end

    return {
        name = process.name,
        pid = process.pid,
        status = process.status,
        restartCount = process.restartCount,
        error = process.error
    }
end

function ProcessManager:getAllStatus()
    local statuses = {}
    for name, _ in pairs(self.processes) do
        statuses[name] = self:getStatus(name)
    end
    return statuses
end

function ProcessManager:tick()
    for _, process in pairs(self.processes) do
        if process.thread and process.status == "running" then
            if coroutine.status(process.thread) == "suspended" then
                local ok, err = coroutine.resume(process.thread)
                if not ok then
                    process.status = "crashed"
                    process.error = err
                end
            elseif coroutine.status(process.thread) == "dead" then
                process.status = "stopped"
                process.thread = nil
                process.pid = nil
            end
        end
    end
end

return ProcessManager