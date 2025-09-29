-- startup.lua
-- Choose how to run the storage system

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

print("Storage System v2.0.0")
print("")
print("Choose startup mode:")
print("1. Background + Terminal (Recommended)")
print("2. Original (All-in-one, may block)")
print("3. Background only")
print("4. Terminal only")
print("")
write("Select (1-4): ")

local choice = read()

if choice == "1" then
    print("Starting background system...")
    shell.run("background.lua &")  -- Run in background
    sleep(2)  -- Give it time to start
    print("Starting terminal...")
    shell.run("terminal_only.lua")

elseif choice == "2" then
    print("Starting original system...")
    shell.run("main.lua")

elseif choice == "3" then
    print("Starting background only...")
    shell.run("background.lua")

elseif choice == "4" then
    print("Starting terminal only...")
    shell.run("terminal_only.lua")

else
    print("Invalid choice, starting background + terminal...")
    shell.run("background.lua &")
    sleep(2)
    shell.run("terminal_only.lua")
end