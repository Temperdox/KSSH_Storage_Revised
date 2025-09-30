local SoundProfileFactory = {}
SoundProfileFactory.__index = SoundProfileFactory

function SoundProfileFactory:new()
    local o = setmetatable({}, self)
    o.profiles = {}
    o.currentProfile = "default"

    -- Register default profiles
    self:registerDefaults()

    return o
end

function SoundProfileFactory:registerDefaults()
    -- Default profile - balanced sounds
    self:register("default", {
        name = "Default",
        description = "Balanced sound profile",
        sounds = {
            ["storage.inputReceived"] = {
                sound = "block.chest.open",
                pitch = 1.2,
                volume = 0.3
            },
            ["storage.itemWithdrawn"] = {
                sound = "entity.item.pickup",
                pitch = 1.5,
                volume = 0.4
            },
            ["task.error"] = {
                sound = "block.note_block.didgeridoo",
                pitch = 0.5,
                volume = 0.6
            },
            ["system.ready"] = {
                sound = "block.note_block.chime",
                pitch = 1.0,
                volume = 0.8
            }
        },
        muted = {
            "ui.monitor.update",
            "log.trace",
            "log.debug"
        }
    })

    -- Quiet profile - minimal sounds
    self:register("quiet", {
        name = "Quiet",
        description = "Minimal sound feedback",
        sounds = {
            ["storage.withdrawFailed"] = {
                sound = "block.note_block.bass",
                pitch = 0.5,
                volume = 0.2
            },
            ["task.error"] = {
                sound = "block.note_block.bass",
                pitch = 0.3,
                volume = 0.2
            },
            ["system.ready"] = {
                sound = "block.note_block.bell",
                pitch = 1.0,
                volume = 0.3
            }
        },
        muted = {
            "ui.monitor.update",
            "task.start",
            "task.end",
            "storage.inputReceived",
            "storage.movedToBuffer",
            "storage.movedToStorage",
            "index.update",
            "log.trace",
            "log.debug",
            "log.info"
        }
    })

    -- Active profile - rich feedback
    self:register("active", {
        name = "Active",
        description = "Rich audio feedback",
        sounds = {
            ["storage.inputReceived"] = {
                sound = "block.chest.open",
                pitch = 1.2,
                volume = 0.5
            },
            ["storage.movedToBuffer"] = {
                sound = "entity.experience_orb.pickup",
                pitch = 0.8,
                volume = 0.3
            },
            ["storage.movedToStorage"] = {
                sound = "block.chest.close",
                pitch = 0.9,
                volume = 0.4
            },
            ["task.start"] = {
                sound = "block.note_block.harp",
                pitch = 1.0,
                volume = 0.2
            },
            ["task.end"] = {
                sound = "block.note_block.harp",
                pitch = 1.5,
                volume = 0.2
            },
            ["ui.monitor.interacted"] = {
                sound = "ui.button.click",
                pitch = 1.0,
                volume = 0.5
            }
        },
        muted = {
            "log.trace",
            "log.debug"
        }
    })

    -- Musical profile - note block focused
    self:register("musical", {
        name = "Musical",
        description = "Note block symphony",
        sounds = {
            ["storage.inputReceived"] = {
                sound = "block.note_block.pling",
                pitch = 1.0,
                volume = 0.4
            },
            ["storage.movedToBuffer"] = {
                sound = "block.note_block.harp",
                pitch = 1.2,
                volume = 0.3
            },
            ["storage.movedToStorage"] = {
                sound = "block.note_block.bell",
                pitch = 0.8,
                volume = 0.4
            },
            ["task.start"] = {
                sound = "block.note_block.bit",
                pitch = 1.0,
                volume = 0.2
            },
            ["task.end"] = {
                sound = "block.note_block.bit",
                pitch = 1.5,
                volume = 0.2
            },
            ["task.error"] = {
                sound = "block.note_block.bass",
                pitch = 0.5,
                volume = 0.6
            },
            ["system.ready"] = {
                sound = "block.note_block.chime",
                pitch = 1.0,
                volume = 1.0
            }
        },
        muted = {
            "ui.monitor.update",
            "log.trace",
            "log.debug"
        }
    })
end

function SoundProfileFactory:register(name, profile)
    self.profiles[name] = profile
end

function SoundProfileFactory:getProfile(name)
    return self.profiles[name] or self.profiles["default"]
end

function SoundProfileFactory:setCurrentProfile(name)
    if self.profiles[name] then
        self.currentProfile = name
        return true
    end
    return false
end

function SoundProfileFactory:getCurrentProfile()
    return self:getProfile(self.currentProfile)
end

function SoundProfileFactory:getProfileList()
    local list = {}
    for name, profile in pairs(self.profiles) do
        table.insert(list, {
            name = name,
            displayName = profile.name,
            description = profile.description
        })
    end
    return list
end

function SoundProfileFactory:getSoundForEvent(eventName)
    local profile = self:getCurrentProfile()
    return profile.sounds[eventName]
end

function SoundProfileFactory:isEventMuted(eventName)
    local profile = self:getCurrentProfile()
    for _, mutedEvent in ipairs(profile.muted or {}) do
        if eventName == mutedEvent or eventName:match("^" .. mutedEvent) then
            return true
        end
    end
    return false
end

return SoundProfileFactory