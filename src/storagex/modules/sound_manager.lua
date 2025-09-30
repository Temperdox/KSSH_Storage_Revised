-- modules/sound_manager.lua
-- Sound management for audio feedback

local SoundManager = {}
SoundManager.__index = SoundManager

function SoundManager:new(logger)
    local self = setmetatable({}, SoundManager)
    self.logger = logger
    self.mainSpeaker = nil
    self.tickSpeaker = nil
    self.enabled = true

    self:findSpeakers()

    return self
end

function SoundManager:findSpeakers()
    local badPos = {"top", "bottom", "front", "back", "left", "right"}

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "speaker" then
            local skip = false
            for _, pos in ipairs(badPos) do
                if name == pos then
                    skip = true
                    break
                end
            end

            if not skip then
                local speaker = peripheral.wrap(name)
                if not self.mainSpeaker then
                    self.mainSpeaker = speaker
                    self.logger:info("Main speaker found: " .. name, "Sound")
                elseif not self.tickSpeaker then
                    self.tickSpeaker = speaker
                    self.logger:info("Tick speaker found: " .. name, "Sound")
                end
            end
        end
    end

    if not self.mainSpeaker and not self.tickSpeaker then
        self.logger:warning("No speakers found, audio disabled", "Sound")
        self.enabled = false
    end
end

function SoundManager:play(sound, pitch, useMain)
    if not self.enabled then return end

    pitch = pitch or 1

    if useMain and self.mainSpeaker then
        self.mainSpeaker.playSound(sound, 0.5, pitch)
    elseif self.tickSpeaker then
        self.tickSpeaker.playSound(sound, 0.5, pitch)
    elseif self.mainSpeaker then
        self.mainSpeaker.playSound(sound, 0.5, pitch)
    end
end

function SoundManager:setEnabled(enabled)
    self.enabled = enabled
end

return SoundManager