-- startup.lua
-- Auto-start storage system on computer boot

-- Check if storage system is installed
if not fs.exists("main.lua") then
    print("Storage System not found!")
    print("Please ensure all files are properly installed.")
    return
end

-- Create required directories
local dirs = {"modules", "logs", "config"}
for _, dir in ipairs(dirs) do
    if not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

-- Launch storage system
print("Starting Storage System...")
shell.run("main.lua")