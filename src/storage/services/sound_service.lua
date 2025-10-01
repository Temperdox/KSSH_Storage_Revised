local SoundService = {}
SoundService.__index = SoundService

function SoundService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger
    o.settings = context.settings

    -- Find speakers
    o.speakers = {}
    local modem = peripheral.find("modem", function(name, p)
        return name == "back" and not p.isWireless()
    end)

    if modem then
        local peripherals = modem.getNamesRemote()
        for _, name in ipairs(peripherals) do
            if peripheral.getType(name) == "speaker" then
                table.insert(o.speakers, peripheral.wrap(name))
                o.logger:debug("SoundService", "Found speaker: " .. name)
            end
        end
    end

    o.currentSpeaker = 1
    o.enabled = context.settings.soundEnabled or true
    o.volume = context.settings.soundVolume or 0.5

    -- Throttling
    o.lastPlayed = {}
    o.throttleWindow = 0.1  -- 100ms between same event type
    o.globalThrottle = 0.05  -- 50ms between any sound
    o.lastGlobalPlay = 0
    o.burstLimit = 10
    o.burstWindow = 1
    o.burstCount = 0
    o.burstReset = 0

    -- Sound mappings
    o.soundMap = self:initializeSoundMap()

    -- Muted events by default (too chatty)
    o.mutedEvents = {
        ["ui.monitor.update"] = true,
        ["task.start"] = false,  -- Allow task sounds
        ["task.end"] = false,
        ["log.trace"] = true,
        ["log.debug"] = true
    }

    return o
end

function SoundService:initializeSoundMap()
    return {
        -- Storage events
        ["storage.inputReceived"] = {
            sound = "block.chest.open",
            pitch = 1.2,
            volume = 0.3
        },
        ["storage.movedToBuffer"] = {
            sound = "entity.item.pickup",
            pitch = 1.0,
            volume = 0.2
        },
        ["storage.movedToStorage"] = {
            sound = "block.chest.close",
            pitch = 0.9,
            volume = 0.3
        },
        ["storage.itemWithdrawn"] = {
            sound = "entity.item.pickup",
            pitch = 1.5,
            volume = 0.4
        },
        ["storage.withdrawFailed"] = {
            sound = "block.anvil.land",
            pitch = 0.5,
            volume = 0.5
        },

        -- Task events
        ["task.start"] = {
            sound = "entity.experience_orb.pickup",
            pitch = 1.0,
            volume = 0.1
        },
        ["task.end"] = {
            sound = "entity.experience_orb.pickup",
            pitch = 1.5,
            volume = 0.1
        },
        ["task.error"] = {
            sound = "entity.villager.no",
            pitch = 0.5,
            volume = 0.6
        },

        -- System events
        ["system.ready"] = {
            sound = "block.bell.use",
            pitch = 1.0,
            volume = 0.8
        },
        ["system.serviceStarted"] = {
            sound = "block.bell.use",
            pitch = 1.2,
            volume = 0.3
        },

        -- Network events
        ["net.rpc.request"] = {
            sound = "block.dispenser.dispense",
            pitch = 1.0,
            volume = 0.2
        },
        ["net.rpc.response"] = {
            sound = "block.dispenser.dispense",
            pitch = 1.3,
            volume = 0.2
        },

        -- UI events
        ["ui.monitor.interacted"] = {
            sound = "block.lever.click",
            pitch = 1.0,
            volume = 0.4
        },
        ["cli.commandRan"] = {
            sound = "block.dispenser.dispense",
            pitch = 1.0,
            volume = 0.3
        },

        -- Index events
        ["index.update"] = {
            sound = "block.comparator.click",
            pitch = 1.1,
            volume = 0.15
        },
        ["storage.indexRebuilt"] = {
            sound = "block.beacon.activate",
            pitch = 1.0,
            volume = 0.5
        },

        -- Stats events
        ["stats.minuteTick"] = {
            sound = "entity.experience_orb.pickup",
            pitch = 2.0,
            volume = 0.1
        },

        -- Test events
        ["tests.started"] = {
            sound = "block.anvil.use",
            pitch = 1.0,
            volume = 0.4
        },
        ["tests.completed"] = {
            sound = "entity.player.levelup",
            pitch = 1.0,
            volume = 0.5
        },
        ["tests.failed"] = {
            sound = "entity.villager.no",
            pitch = 0.8,
            volume = 0.5
        }
    }
end

function SoundService:start()
    -- Subscribe to all events for sound playback
    self.eventBus:subscribe(".*", function(eventName, data)
        self:handleEvent(eventName, data)
    end)

    -- Subscribe to settings changes
    self.eventBus:subscribe("settings.changed", function(event, data)
        if data.soundEnabled ~= nil then
            o.enabled = data.soundEnabled
        end
        if data.soundVolume ~= nil then
            o.volume = data.soundVolume
        end
        if data.mutedEvents then
            for event, muted in pairs(data.mutedEvents) do
                o.mutedEvents[event] = muted
            end
        end
    end)

    self.logger:info("SoundService", string.format(
            "Service started with %d speakers", #self.speakers
    ))
end

function SoundService:stop()
    self.logger:info("SoundService", "Service stopped")
end

function SoundService:handleEvent(eventName, data)
    if not self.enabled or #self.speakers == 0 then
        return
    end

    -- Check if event is muted
    if self.mutedEvents[eventName] then
        return
    end

    -- Check if we have a sound for this event
    local soundConfig = self.soundMap[eventName]
    if not soundConfig then
        return
    end

    -- Apply throttling
    if not self:checkThrottle(eventName) then
        return
    end

    -- Play the sound
    self:playSound(
            soundConfig.sound,
            soundConfig.pitch or 1.0,
            soundConfig.volume or self.volume
    )

    -- Fire sound played event (but don't play sound for it!)
    if eventName ~= "sound.played" then
        self.eventBus:publish("sound.played", {
            event = eventName,
            sound = soundConfig.sound
        })
    end
end

function SoundService:checkThrottle(eventName)
    local now = os.epoch("utc") / 1000

    -- Global throttle
    if now - self.lastGlobalPlay < self.globalThrottle then
        return false
    end

    -- Per-event throttle
    local lastEventPlay = self.lastPlayed[eventName] or 0
    if now - lastEventPlay < self.throttleWindow then
        return false
    end

    -- Burst limit
    if now > self.burstReset then
        self.burstCount = 0
        self.burstReset = now + self.burstWindow
    end

    if self.burstCount >= self.burstLimit then
        return false
    end

    -- Update throttle tracking
    self.lastPlayed[eventName] = now
    self.lastGlobalPlay = now
    self.burstCount = self.burstCount + 1

    return true
end

function SoundService:playSound(sound, pitch, volume)
    if #self.speakers == 0 then
        return
    end

    -- Get current speaker (round-robin)
    local speaker = self.speakers[self.currentSpeaker]

    -- Play sound
    local ok, err = pcall(function()
        speaker.playSound(sound, volume * self.volume, pitch)
    end)

    if not ok then
        self.logger:debug("SoundService", "Failed to play sound: " .. tostring(err))
    end

    -- Alternate speakers for stereo effect
    self.currentSpeaker = (self.currentSpeaker % #self.speakers) + 1
end

function SoundService:testSound(eventName)
    if self.soundMap[eventName] then
        self:handleEvent(eventName, {test = true})
        return true
    end
    return false
end

function SoundService:setSoundEnabled(enabled)
    self.enabled = enabled
    self.logger:info("SoundService", "Sound " .. (enabled and "enabled" or "disabled"))
end

function SoundService:setVolume(volume)
    self.volume = math.max(0, math.min(1, volume))
    self.logger:info("SoundService", "Volume set to " .. math.floor(self.volume * 100) .. "%")
end

function SoundService:muteEvent(eventName, muted)
    self.mutedEvents[eventName] = muted
    self.logger:debug("SoundService", string.format(
            "Event '%s' %s", eventName, muted and "muted" or "unmuted"
    ))
end

return SoundService